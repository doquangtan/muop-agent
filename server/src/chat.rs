use crate::models::{ChatSendRequest, ChatSendResponse, ChatTurnStreamState};
use crate::scanner;
use chrono::Utc;
use serde_json::Value;
use socketioxide::SocketIo;
use std::collections::HashMap;
use std::path::Path;
use std::process::Stdio;
use std::sync::{Arc, Mutex};
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::Command;
use tokio::sync::oneshot;
use tokio::time::{timeout, Duration};

#[derive(Clone)]
pub struct AppState {
    pub io: SocketIo,
    pub active_streams: Arc<Mutex<HashMap<String, ChatTurnStreamState>>>,
    pub running_pids: Arc<Mutex<HashMap<String, u32>>>,
}

impl AppState {
    pub fn new(io: SocketIo) -> Self {
        Self {
            io,
            active_streams: Arc::new(Mutex::new(HashMap::new())),
            running_pids: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    pub fn broadcast_stream_state(&self, state: &ChatTurnStreamState) {
        if let Ok(val) = serde_json::to_value(state) {
            if let Some(ns) = self.io.of("/") {
                let _ = ns.emit("chat:stream", &val);
            }
        }
    }

    pub fn broadcast_snapshot(&self) {
        let streams = self
            .active_streams
            .lock()
            .map(|g| g.clone())
            .unwrap_or_default();
        let snapshot = scanner::build_full_snapshot(&streams, None, 100);
        if let Ok(val) = serde_json::to_value(&snapshot) {
            if let Some(ns) = self.io.of("/") {
                let _ = ns.emit("snapshot:update", &val);
            }
        }
    }
}

pub async fn start_chat_turn(state: AppState, req: ChatSendRequest) -> ChatSendResponse {
    let trimmed_prompt = req.prompt.trim().to_string();
    if trimmed_prompt.is_empty() {
        return ChatSendResponse {
            ok: false,
            conversation_id: req.conversation_id,
            project_path: req.project_path,
            error: "Nội dung tin nhắn trống".to_string(),
        };
    }

    let agy_bin = if Path::new("/home/john/.local/bin/agy").exists() {
        "/home/john/.local/bin/agy"
    } else {
        "/home/john/.gemini/bin/agy"
    };

    let mut effective_cwd = req.project_path.trim().to_string();
    if effective_cwd.is_empty() || !Path::new(&effective_cwd).exists() {
        effective_cwd = "/home/john/Documents/muop-ecosystem/muop-erp-server".to_string();
    }

    let mut args = vec![
        "--app_data_dir=antigravity".to_string(),
        "--dangerously-skip-permissions".to_string(),
        "--output-format=stream-json".to_string(),
    ];

    let clean_conv_id = req.conversation_id.trim().to_string();
    if !clean_conv_id.is_empty()
        && clean_conv_id != "new"
        && !clean_conv_id.starts_with("sim-")
    {
        args.push("--conversation".to_string());
        args.push(clean_conv_id.clone());
    }

    let clean_agent = req.agent_name.trim().to_string();
    if !clean_agent.is_empty() && clean_agent != "Coordinator" && clean_agent != "default" {
        args.push("--agent".to_string());
        args.push(clean_agent);
    }

    // Luôn luôn chỉ định model còn quota (gemini-3.8-flash-high mặc định), không để CLI tự chọn gemini-4-argon hết quota
    let clean_model = if !req.model.trim().is_empty() && req.model.trim() != "default" {
        req.model.trim().to_string()
    } else {
        "gemini-3.8-flash-high".to_string()
    };
    args.push("--model".to_string());
    args.push(clean_model.clone());

    args.push("-p".to_string());
    args.push(trimmed_prompt.clone());

    eprintln!(
        "[CHAT_SEND] Spawning agy CLI: bin={} conv='{}' model='{}' cwd='{}' prompt='{}'",
        agy_bin, clean_conv_id, clean_model, effective_cwd, trimmed_prompt
    );

    let mut child = match Command::new(agy_bin)
        .args(&args)
        .current_dir(&effective_cwd)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
    {
        Ok(c) => c,
        Err(e) => {
            return ChatSendResponse {
                ok: false,
                conversation_id: clean_conv_id,
                project_path: effective_cwd,
                error: format!("Không thể khởi chạy agy CLI: {}", e),
            };
        }
    };

    let pid = child.id().unwrap_or(0);
    let started_at_str = Utc::now().to_rfc3339();

    if !clean_conv_id.is_empty() {
        if pid > 0 {
            if let Ok(mut pids) = state.running_pids.lock() {
                pids.insert(clean_conv_id.clone(), pid);
            }
        }
        let init_state = ChatTurnStreamState {
            conversation_id: clean_conv_id.clone(),
            project_path: effective_cwd.clone(),
            user_prompt: trimmed_prompt.clone(),
            streaming_text: String::new(),
            is_running: true,
            active_step_type: "starting".to_string(),
            started_at: started_at_str.clone(),
            error: String::new(),
        };
        if let Ok(mut map) = state.active_streams.lock() {
            map.insert(clean_conv_id.clone(), init_state.clone());
        }
        state.broadcast_stream_state(&init_state);

        let start_cid = clean_conv_id.clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(2200)).await;
            let _ = Command::new("python3")
                .arg("/home/john/Documents/muop-ecosystem/muop-agent/server/scripts/sync_antigravity_ide.py")
                .arg(&start_cid)
                .output()
                .await;
        });
    }

    let (tx, rx) = oneshot::channel::<String>();
    let mut init_tx = Some(tx);

    let stdout = child.stdout.take();
    let stderr = child.stderr.take();

    let state_clone = state.clone();
    let cwd_clone = effective_cwd.clone();
    let prompt_clone = trimmed_prompt.clone();
    let initial_cid = clean_conv_id.clone();

    tokio::spawn(async move {
        let mut tracked_id = initial_cid;
        let mut text_buffer = String::new();

        if let Some(out) = stdout {
            let mut reader = BufReader::new(out).lines();
            while let Ok(Some(line)) = reader.next_line().await {
                let trimmed = line.trim();
                if trimmed.is_empty() {
                    continue;
                }
                let Ok(map) = serde_json::from_str::<Value>(trimmed) else {
                    continue;
                };
                let event = map.get("event").and_then(|v| v.as_str()).unwrap_or("");

                if event == "init" {
                    let cid = map
                        .get("conversation_id")
                        .and_then(|v| v.as_str())
                        .unwrap_or("")
                        .trim()
                        .to_string();
                    if !cid.is_empty() {
                        tracked_id = cid.clone();
                        if pid > 0 {
                            if let Ok(mut pids) = state_clone.running_pids.lock() {
                                pids.insert(tracked_id.clone(), pid);
                            }
                        }
                        let stream_state = ChatTurnStreamState {
                            conversation_id: tracked_id.clone(),
                            project_path: cwd_clone.clone(),
                            user_prompt: prompt_clone.clone(),
                            streaming_text: String::new(),
                            is_running: true,
                            active_step_type: "init".to_string(),
                            started_at: started_at_str.clone(),
                            error: String::new(),
                        };
                        if let Ok(mut streams) = state_clone.active_streams.lock() {
                            streams.insert(tracked_id.clone(), stream_state.clone());
                        }
                        state_clone.broadcast_stream_state(&stream_state);
                        if let Some(sender) = init_tx.take() {
                            let _ = sender.send(tracked_id.clone());
                        }
                    }
                } else if event == "step_update" {
                    if let Some(su) = map.get("step_update") {
                        let cid = su
                            .get("conversation_id")
                            .and_then(|v| v.as_str())
                            .unwrap_or(&tracked_id)
                            .trim()
                            .to_string();
                        if !cid.is_empty() {
                            tracked_id = cid.clone();
                            if let Some(sender) = init_tx.take() {
                                let _ = sender.send(tracked_id.clone());
                            }
                        }
                        let step_type = su
                            .get("step_type")
                            .and_then(|v| v.as_str())
                            .unwrap_or("agent_response")
                            .to_string();
                        let delta = su
                            .get("text_delta")
                            .and_then(|v| v.as_str())
                            .unwrap_or("");
                        if !delta.is_empty() {
                            text_buffer.push_str(delta);
                        }
                        if !tracked_id.is_empty() {
                            let stream_state = ChatTurnStreamState {
                                conversation_id: tracked_id.clone(),
                                project_path: cwd_clone.clone(),
                                user_prompt: prompt_clone.clone(),
                                streaming_text: text_buffer.clone(),
                                is_running: true,
                                active_step_type: step_type,
                                started_at: started_at_str.clone(),
                                error: String::new(),
                            };
                            if let Ok(mut streams) = state_clone.active_streams.lock() {
                                streams.insert(tracked_id.clone(), stream_state.clone());
                            }
                            state_clone.broadcast_stream_state(&stream_state);
                        }
                    }
                } else if event == "result" {
                    if let Some(res) = map.get("result") {
                        let resp_text = res
                            .get("response")
                            .and_then(|v| v.as_str())
                            .unwrap_or("")
                            .trim();
                        if !resp_text.is_empty() && text_buffer.is_empty() {
                            text_buffer.push_str(resp_text);
                        }
                    }
                    if !tracked_id.is_empty() {
                        let stream_state = ChatTurnStreamState {
                            conversation_id: tracked_id.clone(),
                            project_path: cwd_clone.clone(),
                            user_prompt: prompt_clone.clone(),
                            streaming_text: text_buffer.clone(),
                            is_running: false,
                            active_step_type: "done".to_string(),
                            started_at: started_at_str.clone(),
                            error: String::new(),
                        };
                        if let Ok(mut streams) = state_clone.active_streams.lock() {
                            streams.insert(tracked_id.clone(), stream_state.clone());
                        }
                        state_clone.broadcast_stream_state(&stream_state);
                    }
                }
            }
        }

        let mut stderr_msg = String::new();
        if let Some(err_pipe) = stderr {
            let mut err_reader = BufReader::new(err_pipe).lines();
            while let Ok(Some(line)) = err_reader.next_line().await {
                if !line.trim().is_empty() {
                    stderr_msg = line.trim().to_string();
                }
            }
        }

        let status = child.wait().await;
        let is_ok = status.map(|s| s.success()).unwrap_or(false);

        if !tracked_id.is_empty() {
            if let Ok(mut pids) = state_clone.running_pids.lock() {
                pids.remove(&tracked_id);
            }
            let final_state = ChatTurnStreamState {
                conversation_id: tracked_id.clone(),
                project_path: cwd_clone.clone(),
                user_prompt: prompt_clone.clone(),
                streaming_text: text_buffer,
                is_running: false,
                active_step_type: if is_ok {
                    "done".to_string()
                } else {
                    "error".to_string()
                },
                started_at: started_at_str,
                error: if is_ok { String::new() } else { stderr_msg },
            };
            if let Ok(mut streams) = state_clone.active_streams.lock() {
                streams.insert(tracked_id.clone(), final_state.clone());
            }
            state_clone.broadcast_stream_state(&final_state);
            state_clone.broadcast_snapshot();

            let finish_cid = tracked_id.clone();
            tokio::spawn(async move {
                tokio::time::sleep(Duration::from_millis(300)).await;
                let _ = Command::new("python3")
                    .arg("/home/john/Documents/muop-ecosystem/muop-agent/server/scripts/sync_antigravity_ide.py")
                    .arg(&finish_cid)
                    .output()
                    .await;
            });

            let cleanup_state = state_clone.clone();
            let cid_cleanup = tracked_id.clone();
            tokio::spawn(async move {
                tokio::time::sleep(Duration::from_secs(6)).await;
                let mut removed = false;
                if let Ok(mut streams) = cleanup_state.active_streams.lock() {
                    if let Some(st) = streams.get(&cid_cleanup) {
                        if !st.is_running {
                            streams.remove(&cid_cleanup);
                            removed = true;
                        }
                    }
                }
                if removed {
                    cleanup_state.broadcast_snapshot();
                }
            });
        }
    });

    let resolved_id = match timeout(Duration::from_secs(4), rx).await {
        Ok(Ok(cid)) => cid,
        _ => clean_conv_id,
    };

    ChatSendResponse {
        ok: true,
        conversation_id: resolved_id,
        project_path: effective_cwd,
        error: String::new(),
    }
}

pub fn stop_chat_turn(state: &AppState, conversation_id: &str) -> bool {
    let cid = conversation_id.trim();
    if cid.is_empty() {
        return false;
    }
    let pid_opt = state
        .running_pids
        .lock()
        .ok()
        .and_then(|mut map| map.remove(cid));

    if let Some(pid) = pid_opt {
        let _ = std::process::Command::new("kill")
            .arg("-TERM")
            .arg(pid.to_string())
            .status();

        let mut updated_stream: Option<ChatTurnStreamState> = None;
        if let Ok(mut streams) = state.active_streams.lock() {
            if let Some(prev) = streams.get_mut(cid) {
                prev.is_running = false;
                prev.active_step_type = "stopped".to_string();
                updated_stream = Some(prev.clone());
            }
        }
        if let Some(st) = updated_stream {
            state.broadcast_stream_state(&st);
            state.broadcast_snapshot();
        }
        return true;
    }
    false
}
