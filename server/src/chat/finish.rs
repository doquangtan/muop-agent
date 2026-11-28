use super::*;

/// Chốt trạng thái cuối của lượt chat, phát session mới và làm mới quota/limit
pub(super) fn finish_turn(
    ctx: &TurnCtx,
    st: TurnState,
    is_ok: bool,
    stderr_msg: String,
    provider: Provider,
) {
    if st.tracked_id.is_empty() {
        return;
    }
    let state = &ctx.state;
    if let Ok(mut pids) = state.running_pids.lock() {
        pids.remove(&st.tracked_id);
    }
    crate::infra::store::delete_running_turn(&st.tracked_id);
    // `/compact` của agy: việc nén đã xong nếu transcript có CHECKPOINT sau lệnh compact,
    // dù lượt sau đó có thể lỗi định dạng function call.
    let compacted = !is_ok
        && provider == Provider::Agy
        && ctx.prompt.trim() == "/compact"
        && agy_compact_checkpoint_written(&st.tracked_id);
    let is_ok = is_ok || compacted;
    let error = if is_ok {
        String::new()
    } else {
        friendly_error(&st.result_error.clone().unwrap_or(stderr_msg))
    };
    let mut streaming_text = compose_text(&st.committed, &st.live);
    if compacted {
        streaming_text.push_str("\n\n✅ Đã nén ngữ cảnh (/compact) thành công.");
    }
    if !is_ok && crate::chat::retry::is_rate_limit_error(&error) {
        let mut request = ctx.request.clone();
        request.conversation_id = st.tracked_id.clone();
        crate::chat::retry::schedule(
            state,
            request,
            provider_source(provider),
            &error,
            ctx.attempt + 1,
        );
    }
    let final_state = ChatTurnStreamState {
        conversation_id: st.tracked_id.clone(),
        project_path: ctx.cwd.clone(),
        user_prompt: ctx.prompt.clone(),
        streaming_text,
        is_running: false,
        active_step_type: if is_ok {
            "done".to_string()
        } else {
            "error".to_string()
        },
        started_at: ctx.started_at.clone(),
        error,
        thinking_text: st.thinking_text,
        thinking_tokens: 0,
    };
    if let Ok(mut streams) = state.active_streams.lock() {
        streams.insert(st.tracked_id.clone(), final_state.clone());
    }
    state.broadcast_stream_state(&final_state);
    state.broadcast_session_update(&st.tracked_id);
    // Lượt chat vừa kết thúc -> quota đã thay đổi, làm mới cache và phát nếu có khác biệt
    state.spawn_quotas_update(true, false);

    if provider == Provider::Agy {
        spawn_agy_sync(st.tracked_id.clone(), 300);
        // Lượt vừa kết thúc (hoàn tất, lỗi hoặc bị dừng): lấy lại quota sau khi agy đã ghi nhận lượt
        crate::agy_account::request_refresh();
    }

    let cleanup_state = state.clone();
    let cid_cleanup = st.tracked_id;
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_secs(6)).await;
        let mut removed = false;
        if let Ok(mut streams) = cleanup_state.active_streams.lock() {
            if let Some(s) = streams.get(&cid_cleanup) {
                if !s.is_running {
                    streams.remove(&cid_cleanup);
                    removed = true;
                }
            }
        }
        if removed {
            cleanup_state.broadcast_session_update(&cid_cleanup);
        }
    });
}

/// Thời gian chờ sau SIGTERM trước khi SIGKILL. agy bắt SIGTERM (có handler) nên không thoát khi chỉ nhận TERM.
const STOP_GRACE: std::time::Duration = std::time::Duration::from_secs(4);

fn process_alive(pid: u32) -> bool {
    std::process::Command::new("kill")
        .arg("-0")
        .arg(pid.to_string())
        .stderr(std::process::Stdio::null())
        .status()
        .map(|st| st.success())
        .unwrap_or(false)
}

/// Dừng tiến trình lượt chat và các tiến trình con: SIGTERM cho cả nhóm (pgid = pid khi khởi chạy
/// bằng `process_group(0)`) và cho chính PID (tiến trình cũ trước khi có nhóm riêng). Sau STOP_GRACE
/// nếu vẫn còn sống thì SIGKILL. Chạy trên luồng riêng để không chặn socket/REST.
fn terminate_turn_process(pid: u32) {
    let group = format!("-{pid}");
    let send = |sig: &str, target: &str| {
        let _ = std::process::Command::new("kill")
            .args(["-s", sig, "--", target])
            .stderr(std::process::Stdio::null())
            .status();
    };
    send("TERM", &group);
    send("TERM", &pid.to_string());
    std::thread::spawn(move || {
        let deadline = std::time::Instant::now() + STOP_GRACE;
        while std::time::Instant::now() < deadline {
            if !process_alive(pid) {
                return;
            }
            std::thread::sleep(std::time::Duration::from_millis(200));
        }
        if process_alive(pid) {
            tracing::warn!("Tiến trình lượt chat {pid} không thoát sau SIGTERM, gửi SIGKILL");
            let send = |sig: &str, target: &str| {
                let _ = std::process::Command::new("kill")
                    .args(["-s", sig, "--", target])
                    .stderr(std::process::Stdio::null())
                    .status();
            };
            send("KILL", &format!("-{pid}"));
            send("KILL", &pid.to_string());
        }
    });
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
    if let Ok(mut adopted) = state.adopted_turns.lock() {
        adopted.remove(cid);
    }
    // Người dùng dừng chủ động: lượt không còn được nhận lại sau khi server khởi động lại
    crate::infra::store::delete_running_turn(cid);

    if let Some(pid) = pid_opt {
        terminate_turn_process(pid);

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
            state.broadcast_session_update(cid);
            state.spawn_quotas_update(true, false);
        }
        return true;
    }
    false
}

/// Đổi thông báo lỗi kỹ thuật của CLI thành câu dễ hiểu cho người dùng
pub(super) fn friendly_error(msg: &str) -> String {
    if msg.contains("Malformed function call") {
        return "Agent trả về lệnh gọi công cụ sai định dạng (Malformed function call). Hãy gửi lại yêu cầu."
            .to_string();
    }
    msg.to_string()
}

/// Transcript của agy có CHECKPOINT ghi sau lệnh `/compact` gần nhất không.
/// Chỉ đọc 4MB cuối file để không tốn IO khi transcript lớn.
pub(super) fn agy_compact_checkpoint_written(conversation_id: &str) -> bool {
    use std::io::{Read, Seek, SeekFrom};

    let cid = conversation_id.trim();
    if cid.is_empty() || !cid.chars().all(|c| c.is_ascii_alphanumeric() || c == '-') {
        return false;
    }
    let Some(home) = std::env::var("HOME").ok() else {
        return false;
    };
    let path = Path::new(&home)
        .join(".gemini/antigravity/brain")
        .join(cid)
        .join(".system_generated/logs/transcript.jsonl");
    let Ok(mut file) = std::fs::File::open(&path) else {
        return false;
    };
    const TAIL_BYTES: u64 = 4 * 1024 * 1024;
    let Ok(len) = file.metadata().map(|m| m.len()) else {
        return false;
    };
    let start = len.saturating_sub(TAIL_BYTES);
    if file.seek(SeekFrom::Start(start)).is_err() {
        return false;
    }
    let mut raw = Vec::new();
    if file.read_to_end(&mut raw).is_err() {
        return false;
    }
    // Điểm cắt có thể nằm giữa ký tự UTF-8: dùng lossy để không mất cả đoạn
    let buf = String::from_utf8_lossy(&raw);
    let mut lines: Vec<&str> = buf.lines().collect();
    if start > 0 && !lines.is_empty() {
        // Dòng đầu có thể bị cắt dở
        lines.remove(0);
    }

    // Duyệt ngược: gặp CHECKPOINT trước khi gặp lệnh /compact nghĩa là nén đã xong
    let mut checkpoint_seen = false;
    for line in lines.iter().rev() {
        let Ok(v) = serde_json::from_str::<Value>(line) else {
            continue;
        };
        match v.get("type").and_then(Value::as_str).unwrap_or("") {
            "CHECKPOINT" => checkpoint_seen = true,
            "USER_INPUT" => {
                let content = v.get("content").and_then(Value::as_str).unwrap_or("");
                if content.contains("/compact") {
                    return checkpoint_seen;
                }
            }
            _ => {}
        }
    }
    false
}

#[cfg(test)]
mod compact_tests {
    use super::*;

    #[test]
    fn detects_checkpoint_after_compact_input() {
        let dir = std::env::temp_dir().join(format!("muop-compact-test-{}", std::process::id()));
        let cid = "11111111-2222-3333-4444-555555555555";
        let logs = dir
            .join(".gemini/antigravity/brain")
            .join(cid)
            .join(".system_generated/logs");
        std::fs::create_dir_all(&logs).unwrap();
        let file = logs.join("transcript.jsonl");
        std::fs::write(
            &file,
            "{\"type\":\"USER_INPUT\",\"content\":\"hello\"}\n\
             {\"type\":\"USER_INPUT\",\"content\":\"<USER_REQUEST>\\n/compact\\n</USER_REQUEST>\"}\n\
             {\"type\":\"CHECKPOINT\",\"content\":\"# Resuming\"}\n",
        )
        .unwrap();
        // Khôi phục HOME sau test: các test khác trong cùng tiến trình đọc HOME
        let previous_home = std::env::var_os("HOME");
        std::env::set_var("HOME", &dir);
        assert!(agy_compact_checkpoint_written(cid));

        // Không có CHECKPOINT sau lệnh compact thì không tính là đã nén
        std::fs::write(
            &file,
            "{\"type\":\"USER_INPUT\",\"content\":\"<USER_REQUEST>/compact</USER_REQUEST>\"}\n\
             {\"type\":\"PLANNER_RESPONSE\",\"content\":\"x\"}\n",
        )
        .unwrap();
        assert!(!agy_compact_checkpoint_written(cid));
        assert!(!agy_compact_checkpoint_written("../etc"));
        match previous_home {
            Some(home) => std::env::set_var("HOME", home),
            None => std::env::remove_var("HOME"),
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn friendly_error_translates_malformed_call() {
        assert!(
            friendly_error("Malformed function call: Function call is empty")
                .contains("sai định dạng")
        );
        assert_eq!(friendly_error("boom"), "boom");
    }
}

#[cfg(all(test, unix))]
mod stop_tests {
    use super::*;
    use std::os::unix::process::CommandExt;

    /// Tiến trình bỏ qua SIGTERM và có tiến trình con (như agy): phải bị SIGKILL sau STOP_GRACE, cả con
    #[test]
    fn stop_kills_term_ignoring_process_and_children() {
        let mut child = std::process::Command::new("sh")
            .args(["-c", "trap '' TERM; sleep 600 & wait"])
            .process_group(0)
            .spawn()
            .expect("spawn sh");
        let pid = child.id();
        std::thread::sleep(std::time::Duration::from_millis(300));
        terminate_turn_process(pid);
        // Chờ đúng tiến trình thoát (có SIGKILL sau STOP_GRACE); status phải là bị kill bởi tín hiệu
        let status = child.wait().expect("wait child");
        assert!(!status.success(), "tiến trình không được thoát bình thường");
        std::thread::sleep(std::time::Duration::from_millis(300));
        let left = std::process::Command::new("sh")
            .args([
                "-c",
                &format!("pgrep -g {pid} >/dev/null && echo alive || echo dead"),
            ])
            .output()
            .expect("pgrep");
        assert_eq!(
            String::from_utf8_lossy(&left.stdout).trim(),
            "dead",
            "còn tiến trình con trong nhóm"
        );
    }
}
