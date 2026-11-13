use crate::claude_code;
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

/// Tiền tố id model để UI chọn đúng backend (phải khớp với `scanner::default_models`)
pub const AGY_PREFIX: &str = "agy:";
pub const CLAUDE_PREFIX: &str = "claude-cli:";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Provider {
    /// Antigravity CLI (`agy`)
    Agy,
    /// Claude Code CLI (`claude`)
    ClaudeCli,
}

/// Tách provider và tên model thực tế từ id model do UI gửi lên.
/// Id không có tiền tố được coi là id cũ: alias `sonnet/opus/haiku` → Claude, còn lại → agy.
pub fn resolve_model(raw: &str) -> (Provider, String) {
    let m = raw.trim();
    if let Some(rest) = m.strip_prefix(CLAUDE_PREFIX) {
        return (Provider::ClaudeCli, claude_code::normalize_model(rest));
    }
    if let Some(rest) = m.strip_prefix(AGY_PREFIX) {
        return (Provider::Agy, agy_model(rest));
    }
    if matches!(m, "sonnet" | "opus" | "haiku") {
        return (Provider::ClaudeCli, claude_code::normalize_model(m));
    }
    (Provider::Agy, agy_model(m))
}

fn agy_model(raw: &str) -> String {
    let m = raw.trim();
    if m.is_empty() || m == "default" {
        // Luôn chỉ định model còn quota, không để CLI tự chọn model đã hết quota
        "gemini-3.8-flash-high".to_string()
    } else {
        m.to_string()
    }
}

fn agy_bin() -> &'static str {
    if Path::new("/home/john/.local/bin/agy").exists() {
        "/home/john/.local/bin/agy"
    } else {
        "/home/john/.gemini/bin/agy"
    }
}

#[derive(Clone)]
pub struct AppState {
    pub io: SocketIo,
    pub active_streams: Arc<Mutex<HashMap<String, ChatTurnStreamState>>>,
    pub running_pids: Arc<Mutex<HashMap<String, u32>>>,
    /// Bản quota đã phát gần nhất (JSON) để chỉ phát `quotas:update` khi có thay đổi
    pub last_quotas_json: Arc<Mutex<String>>,
    /// Câu hỏi từ AI: key = conversation_id, value = danh sách câu hỏi
    pub ai_questions: Arc<Mutex<HashMap<String, Vec<crate::models::AIQuestion>>>>,
}

impl AppState {
    pub fn new(io: SocketIo) -> Self {
        Self {
            io,
            active_streams: Arc::new(Mutex::new(HashMap::new())),
            running_pids: Arc::new(Mutex::new(HashMap::new())),
            last_quotas_json: Arc::new(Mutex::new(String::new())),
            ai_questions: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    pub fn broadcast_stream_state(&self, state: &ChatTurnStreamState) {
        if let Ok(val) = serde_json::to_value(state) {
            if let Some(ns) = self.io.of("/") {
                let _ = ns.emit("chat:stream", &val);
            }
        }
    }

    /// Phát event cập nhật chỉ riêng cho 1 session cụ thể (Granular Event)
    pub fn broadcast_session_update(&self, session_id: &str) {
        let streams = self
            .active_streams
            .lock()
            .map(|g| g.clone())
            .unwrap_or_default();
        if let Some(session) = scanner::get_single_session_with_streams(session_id, &streams) {
            if let Ok(val) = serde_json::to_value(&session) {
                if let Some(ns) = self.io.of("/") {
                    let _ = ns.emit("session:update", &val);
                }
            }
        }
    }

    /// Phát files change vào room conversation (để chỉ UI client trong conversation đó nhận)
    pub fn emit_session_files_to_room(&self, session_id: &str) {
        let streams = self
            .active_streams
            .lock()
            .map(|g| g.clone())
            .unwrap_or_default();
        if let Some(session) = scanner::get_single_session_with_streams(session_id, &streams) {
            if let Ok(val) = serde_json::to_value(&session) {
                let room = format!("conv:{}", session.id);
                if let Some(ns) = self.io.of("/") {
                    let _ = ns.to(room).emit("fileschange", &val);
                }
            }
        }
    }

    /// Phát event cập nhật danh sách projects khi có thay đổi
    pub fn broadcast_projects_update(&self) {
        let streams = self
            .active_streams
            .lock()
            .map(|g| g.clone())
            .unwrap_or_default();
        let sessions = scanner::scan_all_sessions(&streams, None, 500);
        let projects = scanner::discover_projects(&sessions);
        if let Ok(val) = serde_json::to_value(&projects) {
            if let Some(ns) = self.io.of("/") {
                let _ = ns.emit("projects:update", &val);
            }
        }
    }

    /// Lấy quota/limit mới nhất (Antigravity + Claude Code) và chỉ phát `quotas:update` nếu thay đổi.
    /// Hàm có I/O đồng bộ (daemon TCP, curl) nên phải được gọi trong `spawn_blocking`.
    /// Trả về `true` nếu đã phát event.
    pub fn broadcast_quotas_update(&self, force: bool) -> bool {
        let quotas = scanner::fetch_all_model_quotas();
        let val = match serde_json::to_value(&quotas) {
            Ok(v) => v,
            Err(_) => return false,
        };
        let serialized = val.to_string();
        if let Ok(mut last) = self.last_quotas_json.lock() {
            if !force && *last == serialized {
                return false;
            }
            *last = serialized;
        }
        if let Some(ns) = self.io.of("/") {
            let _ = ns.emit("quotas:update", &val);
        }
        true
    }

    /// Chạy `broadcast_quotas_update` ở thread blocking (an toàn khi gọi từ async context)
    pub fn spawn_quotas_update(&self, invalidate_cache: bool, force: bool) {
        let st = self.clone();
        tokio::task::spawn_blocking(move || {
            if invalidate_cache {
                scanner::invalidate_quota_cache();
            }
            st.broadcast_quotas_update(force);
        });
    }

    /// Phát file changes vào room conversation riêng (để chỉ clients trong conversation đó nhận)
    pub fn emit_conversation_files_change(&self, conversation_id: &str, files_change: Value) {
        let room = format!("conv:{}", conversation_id);
        if let Some(ns) = self.io.of("/") {
            let _ = ns.to(room).emit("fileschange", &files_change);
        }
    }

    /// Phát toàn bộ snapshot (full resync) — chỉ dùng cho các thay đổi mà event nhỏ không diễn tả được,
    /// ví dụ conversation bị xoá khỏi đĩa. Quét nặng nên chạy ở thread blocking.
    pub fn spawn_snapshot_resync(&self) {
        let st = self.clone();
        tokio::task::spawn_blocking(move || st.broadcast_snapshot());
    }

    pub fn broadcast_snapshot(&self) {
        let streams = self
            .active_streams
            .lock()
            .map(|g| g.clone())
            .unwrap_or_default();
        let snapshot = scanner::build_full_snapshot(&streams, None, 500);
        if let Ok(val) = serde_json::to_value(&snapshot) {
            if let Some(ns) = self.io.of("/") {
                let _ = ns.emit("snapshot:update", &val);
            }
        }
    }
}

/// Ghép phần đã chốt (committed) với phần đang stream dở (live).
fn compose_text(committed: &str, live: &str) -> String {
    match (committed.is_empty(), live.is_empty()) {
        (_, true) => committed.to_string(),
        (true, false) => live.to_string(),
        (false, false) => format!("{}\n\n{}", committed, live),
    }
}

/// Ngữ cảnh chung của một lượt chat, dùng để phát `chat:stream`
struct TurnCtx {
    state: AppState,
    pid: u32,
    cwd: String,
    prompt: String,
    started_at: String,
    model: String,
}

impl TurnCtx {
    fn emit(&self, cid: &str, text: String, step: &str, thinking: String) {
        let stream_state = ChatTurnStreamState {
            conversation_id: cid.to_string(),
            project_path: self.cwd.clone(),
            user_prompt: self.prompt.clone(),
            streaming_text: text,
            is_running: true,
            active_step_type: step.to_string(),
            started_at: self.started_at.clone(),
            error: String::new(),
            thinking_text: thinking,
        };
        if let Ok(mut streams) = self.state.active_streams.lock() {
            streams.insert(cid.to_string(), stream_state.clone());
        }
        self.state.broadcast_stream_state(&stream_state);
    }

    /// Đăng ký session id khi CLI báo init (cũng ghi pid để có thể dừng)
    fn register(&self, cid: &str) {
        if self.pid > 0 {
            if let Ok(mut pids) = self.state.running_pids.lock() {
                pids.insert(cid.to_string(), self.pid);
            }
        }
    }
}

/// Trạng thái đọc một lượt chat (cập nhật liên tục khi đọc stdout)
struct TurnState {
    tracked_id: String,
    committed: String,
    live: String,
    thinking_text: String,
    current_block_type: String,
    result_error: Option<String>,
    init_tx: Option<oneshot::Sender<String>>,
}

impl TurnState {
    fn set_init(&mut self, cid: String) {
        self.tracked_id = cid.clone();
        if let Some(sender) = self.init_tx.take() {
            let _ = sender.send(cid);
        }
    }
}

/// Xử lý một dòng stream-json của Antigravity CLI (`agy`)
fn handle_agy_event(ctx: &TurnCtx, st: &mut TurnState, map: &Value) {
    match map.get("event").and_then(|v| v.as_str()).unwrap_or("") {
        "init" => {
            let cid = map
                .get("conversation_id")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .trim()
                .to_string();
            if !cid.is_empty() {
                ctx.register(&cid);
                crate::scanner::record_agy_turn_model(&cid, &ctx.started_at, &ctx.model);
                st.set_init(cid.clone());
                ctx.emit(&cid, st.committed.clone(), "init", String::new());
            }
        }
        "step_update" => {
            let Some(su) = map.get("step_update") else {
                return;
            };
            let cid = su
                .get("conversation_id")
                .and_then(|v| v.as_str())
                .unwrap_or(&st.tracked_id)
                .trim()
                .to_string();
            if !cid.is_empty() && cid != st.tracked_id {
                st.set_init(cid);
            }
            let step_type = su
                .get("step_type")
                .and_then(|v| v.as_str())
                .unwrap_or("agent_response")
                .to_string();
            if let Some(delta) = su.get("text_delta").and_then(|v| v.as_str()) {
                st.committed.push_str(delta);
            }
            if !st.tracked_id.is_empty() {
                let tid = st.tracked_id.clone();
                ctx.emit(&tid, st.committed.clone(), &step_type, String::new());
            }
        }
        "result" => {
            if let Some(res) = map.get("result") {
                let resp_text = res
                    .get("response")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .trim();
                if !resp_text.is_empty() && st.committed.is_empty() {
                    st.committed.push_str(resp_text);
                }
            }
        }
        _ => {}
    }
}

/// Xử lý một dòng stream-json của Claude Code CLI (`claude -p --output-format stream-json`)
fn handle_claude_event(ctx: &TurnCtx, st: &mut TurnState, map: &Value) {
    let kind = map.get("type").and_then(|v| v.as_str()).unwrap_or("");
    match kind {
        // Đầu tiên: session_id của Claude Code
        "system" => {
            if map.get("subtype").and_then(|v| v.as_str()) != Some("init") {
                return;
            }
            let cid = map
                .get("session_id")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .trim()
                .to_string();
            if cid.is_empty() {
                return;
            }
            ctx.register(&cid);
            st.set_init(cid.clone());
            ctx.emit(&cid, compose_text(&st.committed, &st.live), "init", st.thinking_text.clone());
        }
        // Token-level streaming (cần --include-partial-messages)
        "stream_event" => {
            let Some(ev) = map.get("event") else {
                return;
            };
            match ev.get("type").and_then(|v| v.as_str()).unwrap_or("") {
                "message_start" => {
                    st.live.clear();
                    st.thinking_text.clear();
                    st.current_block_type.clear();
                }
                "content_block_start" => {
                    let block_type = ev
                        .get("content_block")
                        .and_then(|b| b.get("type"))
                        .and_then(|v| v.as_str())
                        .unwrap_or("")
                        .to_string();
                    st.current_block_type = block_type.clone();
                    let step = match block_type.as_str() {
                        "tool_use" => "tool_use",
                        "thinking" => "thinking",
                        _ => "agent_response",
                    };
                    if !st.tracked_id.is_empty() {
                        let tid = st.tracked_id.clone();
                        ctx.emit(&tid, compose_text(&st.committed, &st.live), step, st.thinking_text.clone());
                    }
                }
                "content_block_delta" => {
                    let Some(delta) = ev.get("delta") else {
                        return;
                    };
                    if delta.get("type").and_then(|v| v.as_str()) == Some("text_delta") {
                        if let Some(t) = delta.get("text").and_then(|v| v.as_str()) {
                            if st.current_block_type == "thinking" {
                                st.thinking_text.push_str(t);
                            } else {
                                st.live.push_str(t);
                            }
                        }
                        if !st.tracked_id.is_empty() {
                            let tid = st.tracked_id.clone();
                            let step = if st.current_block_type == "thinking" {
                                "thinking"
                            } else {
                                "agent_response"
                            };
                            ctx.emit(&tid, compose_text(&st.committed, &st.live), step, st.thinking_text.clone());
                        }
                    }
                }
                _ => {}
            }
        }
        // Message hoàn chỉnh của assistant: chốt text và ghi nhận tool_use
        "assistant" => {
            let blocks = map
                .get("message")
                .and_then(|m| m.get("content"))
                .and_then(|c| c.as_array())
                .cloned()
                .unwrap_or_default();
            let mut step = "agent_response";
            for b in &blocks {
                match b.get("type").and_then(|v| v.as_str()).unwrap_or("") {
                    "text" => {
                        if let Some(t) = b.get("text").and_then(|v| v.as_str()) {
                            if !t.trim().is_empty() {
                                if !st.committed.is_empty() {
                                    st.committed.push_str("\n\n");
                                }
                                st.committed.push_str(t.trim_end());
                            }
                        }
                    }
                    "thinking" => {
                        if let Some(t) = b.get("thinking").and_then(|v| v.as_str()) {
                            if !st.thinking_text.is_empty() {
                                st.thinking_text.push_str("\n\n");
                            }
                            st.thinking_text.push_str(t.trim_end());
                        }
                    }
                    "tool_use" => step = "tool_use",
                    _ => {}
                }
            }
            st.live.clear();
            if !st.tracked_id.is_empty() {
                let tid = st.tracked_id.clone();
                ctx.emit(&tid, compose_text(&st.committed, &st.live), step, st.thinking_text.clone());
            }
        }
        // Kết quả tool trả về cho Claude
        "user" => {
            if !st.tracked_id.is_empty() {
                let tid = st.tracked_id.clone();
                ctx.emit(&tid, compose_text(&st.committed, &st.live), "tool_result", st.thinking_text.clone());
            }
        }
        "result" => {
            let is_error = map
                .get("is_error")
                .and_then(|v| v.as_bool())
                .unwrap_or(false);
            let text = map
                .get("result")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .trim()
                .to_string();
            if is_error {
                st.result_error = Some(if text.is_empty() {
                    "Claude Code CLI báo lỗi".to_string()
                } else {
                    text
                });
            } else if st.committed.is_empty() && !text.is_empty() {
                st.committed = text;
            }
            st.live.clear();
        }
        _ => {}
    }
}

fn agy_args(prompt: &str, model: &str, conv_id: Option<&str>, agent: &str) -> Vec<String> {
    let mut args = vec![
        "--app_data_dir=antigravity".to_string(),
        "--dangerously-skip-permissions".to_string(),
        "--output-format=stream-json".to_string(),
    ];
    if let Some(cid) = conv_id {
        args.push("--conversation".to_string());
        args.push(cid.to_string());
    }
    if !agent.is_empty() && agent != "Coordinator" && agent != "default" {
        args.push("--agent".to_string());
        args.push(agent.to_string());
    }
    args.push("--model".to_string());
    args.push(model.to_string());
    args.push("-p".to_string());
    args.push(prompt.to_string());
    args
}

/// Nhãn source của session Claude Code, khớp với `ConversationSession.source` phía scanner
pub const CLAUDE_SOURCE: &str = "claude-cli";
/// Nhãn source của session Antigravity (agy)
pub const AGY_SOURCE: &str = "agy";

fn provider_source(provider: Provider) -> &'static str {
    match provider {
        Provider::ClaudeCli => CLAUDE_SOURCE,
        Provider::Agy => AGY_SOURCE,
    }
}

/// Tách lệnh `/plan` ở đầu prompt: trả về (có bật plan mode, nội dung còn lại)
fn strip_plan_command(prompt: &str) -> (bool, &str) {
    match prompt.strip_prefix("/plan") {
        Some(rest) if rest.is_empty() || rest.starts_with(char::is_whitespace) => {
            (true, rest.trim())
        }
        _ => (false, prompt),
    }
}

fn claude_args(
    prompt: &str,
    model: &str,
    conv_id: Option<&str>,
    cwd: &str,
    plan_mode: bool,
) -> Vec<String> {
    // Claude Code không tự nhận thư mục làm việc từ tiến trình cha một cách đáng tin cậy,
    // nên đưa đường dẫn project vào system prompt và cấp quyền truy cập thư mục đó tường minh.
    let cwd_prompt = format!(
        "Thư mục project đang làm việc là: {cwd}. Mọi thao tác đọc/ghi file và lệnh shell phải thực hiện trong thư mục này. Khi người dùng hỏi về thư mục hiện tại, hãy trả lời theo đường dẫn trên."
    );
    let mut args: Vec<String> = vec![
        "-p".to_string(),
        prompt.to_string(),
        "--output-format".to_string(),
        "stream-json".to_string(),
        "--verbose".to_string(),
        "--include-partial-messages".to_string(),
        "--model".to_string(),
        model.to_string(),
        "--append-system-prompt".to_string(),
        cwd_prompt,
    ];
    if plan_mode {
        // Plan mode chỉ có hiệu lực khi không đi kèm --dangerously-skip-permissions
        args.push("--permission-mode".to_string());
        args.push("plan".to_string());
    } else {
        // CLI chạy không hỏi quyền (không có người trả lời prompt)
        args.push("--dangerously-skip-permissions".to_string());
    }
    if let Some(cid) = conv_id {
        args.push("--resume".to_string());
        args.push(cid.to_string());
    }
    // `--add-dir` nhận nhiều giá trị nên đặt cuối cùng
    args.push("--add-dir".to_string());
    args.push(cwd.to_string());
    args
}

/// Chạy script đồng bộ session của Antigravity IDE (chỉ dùng cho provider agy)
fn spawn_agy_sync(cid: String, delay_ms: u64) {
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(delay_ms)).await;
        let _ = Command::new("python3")
            .arg("/home/john/Documents/muop-ecosystem/muop-agent/server/scripts/sync_antigravity_ide.py")
            .arg(&cid)
            .output()
            .await;
    });
}

/// Gửi một lượt chat tới backend tương ứng với model đã chọn:
/// - `claude-cli:<alias>` → Claude Code CLI, tiếp tục session bằng `--resume`
/// - `agy:<model>` → Antigravity CLI (`agy`)
pub async fn start_chat_turn(state: AppState, req: ChatSendRequest) -> ChatSendResponse {
    let trimmed_prompt = req.prompt.trim().to_string();
    if trimmed_prompt.is_empty() {
        return ChatSendResponse {
            ok: false,
            conversation_id: req.conversation_id,
            project_path: req.project_path,
            error: "Nội dung tin nhắn trống".to_string(),
            source: String::new(),
        };
    }

    let (provider, model) = resolve_model(&req.model);

    let mut effective_cwd = req.project_path.trim().to_string();
    if effective_cwd.is_empty() || !Path::new(&effective_cwd).exists() {
        effective_cwd = "/home/john/Documents/muop-ecosystem/muop-erp-server".to_string();
    }

    let clean_conv_id = req.conversation_id.trim().to_string();
    let is_resume =
        !clean_conv_id.is_empty() && clean_conv_id != "new" && !clean_conv_id.starts_with("sim-");
    let resume_id = if is_resume {
        Some(clean_conv_id.as_str())
    } else {
        None
    };

    let (bin, args) = match provider {
        Provider::ClaudeCli => {
            let (plan_mode, body) = strip_plan_command(&trimmed_prompt);
            if body.is_empty() {
                return ChatSendResponse {
                    ok: false,
                    conversation_id: req.conversation_id,
                    project_path: req.project_path,
                    error: "Nhập nội dung kế hoạch sau /plan".to_string(),
                    source: String::new(),
                };
            }
            (
                claude_code::claude_bin(),
                claude_args(body, &model, resume_id, &effective_cwd, plan_mode),
            )
        }
        Provider::Agy => (
            agy_bin().to_string(),
            agy_args(&trimmed_prompt, &model, resume_id, req.agent_name.trim()),
        ),
    };

    eprintln!(
        "[CHAT_SEND] provider={:?} bin={} conv='{}' model='{}' cwd='{}' prompt='{}'",
        provider, bin, clean_conv_id, model, effective_cwd, trimmed_prompt
    );

    let use_systemd_scope =
        Path::new("/usr/bin/systemd-run").exists() || Path::new("/bin/systemd-run").exists();
    let mut cmd = if use_systemd_scope {
        let mut c = Command::new("systemd-run");
        c.arg("--user")
            .arg("--scope")
            .arg("--quiet")
            .arg(&bin)
            .args(&args);
        c
    } else {
        let mut c = Command::new(&bin);
        c.args(&args);
        c
    };

    let mut child = match cmd
        .current_dir(&effective_cwd)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
    {
        Ok(c) => c,
        Err(e) => {
            let label = match provider {
                Provider::ClaudeCli => "Claude Code CLI",
                Provider::Agy => "agy CLI",
            };
            return ChatSendResponse {
                ok: false,
                conversation_id: clean_conv_id,
                project_path: effective_cwd,
                error: format!("Không thể khởi chạy {} ({}): {}", label, bin, e),
                source: provider_source(provider).to_string(),
            };
        }
    };

    let pid = child.id().unwrap_or(0);
    let ctx = TurnCtx {
        state: state.clone(),
        pid,
        cwd: effective_cwd.clone(),
        prompt: trimmed_prompt.clone(),
        started_at: Utc::now().to_rfc3339(),
        model: model.clone(),
    };

    if !clean_conv_id.is_empty() {
        ctx.register(&clean_conv_id);
        ctx.emit(&clean_conv_id, String::new(), "starting", String::new());
        if provider == Provider::Agy {
            spawn_agy_sync(clean_conv_id.clone(), 2200);
        }
    }

    let (tx, rx) = oneshot::channel::<String>();
    let stdout = child.stdout.take();
    let stderr = child.stderr.take();
    let initial_cid = clean_conv_id.clone();

    tokio::spawn(async move {
        let mut st = TurnState {
            tracked_id: initial_cid,
            committed: String::new(),
            live: String::new(),
            thinking_text: String::new(),
            current_block_type: String::new(),
            result_error: None,
            init_tx: Some(tx),
        };

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
                match provider {
                    Provider::Agy => handle_agy_event(&ctx, &mut st, &map),
                    Provider::ClaudeCli => handle_claude_event(&ctx, &mut st, &map),
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
        let is_ok = status.map(|s| s.success()).unwrap_or(false) && st.result_error.is_none();
        finish_turn(&ctx, st, is_ok, stderr_msg, provider);
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
        source: provider_source(provider).to_string(),
    }
}

/// Chốt trạng thái cuối của lượt chat, phát session mới và làm mới quota/limit
fn finish_turn(ctx: &TurnCtx, st: TurnState, is_ok: bool, stderr_msg: String, provider: Provider) {
    if st.tracked_id.is_empty() {
        return;
    }
    let state = &ctx.state;
    if let Ok(mut pids) = state.running_pids.lock() {
        pids.remove(&st.tracked_id);
    }
    let error = if is_ok {
        String::new()
    } else {
        st.result_error.clone().unwrap_or(stderr_msg)
    };
    let final_state = ChatTurnStreamState {
        conversation_id: st.tracked_id.clone(),
        project_path: ctx.cwd.clone(),
        user_prompt: ctx.prompt.clone(),
        streaming_text: compose_text(&st.committed, &st.live),
        is_running: false,
        active_step_type: if is_ok {
            "done".to_string()
        } else {
            "error".to_string()
        },
        started_at: ctx.started_at.clone(),
        error,
        thinking_text: st.thinking_text,
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
            state.broadcast_session_update(cid);
            state.spawn_quotas_update(true, false);
        }
        return true;
    }
    false
}
