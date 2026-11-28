//! Chỉ mục và trạng thái tăng dần của transcript Claude Code (JSONL).
//!
//! - `claude_transcript_lines` (SQLite): vị trí byte và token của từng bước (step_index, offset, độ dài).
//!   Chỉ lưu vị trí, không lưu nội dung nên không nhân đôi dữ liệu hội thoại.
//! - `transcript_state` (SQLite): trạng thái parser (token, subagent đã gọi, tệp/lệnh, lượt hiện tại...).
//!   Khi transcript lớn thêm, chỉ đọc đúng phần byte mới và cập nhật trạng thái.
//! - Bước cuối được đọc bằng seek theo chỉ mục khi cần; không giữ trong RAM.
//!
//! Logic từng dòng giữ nguyên như parser cũ (`parse_session_parts`); chỉ khác ở chỗ bước được dựng lại
//! từ dòng JSON khi cần (`build_*_step`) thay vì giữ trong bộ nhớ.

use super::*;
use chrono::{DateTime, Utc};
use std::io::{BufRead, BufReader, Read, Seek, SeekFrom};

/// Số bước cuối nạp cho session đầy đủ (giống giới hạn snapshot cũ)
pub(super) const TAIL_STEPS: usize = SNAPSHOT_STEP_LIMIT;

/// Trạng thái parser lưu trong SQLite
#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
pub(super) struct ClaudeState {
    pub(super) indexed_bytes: u64,
    pub(super) steps_count: usize,
    pub(super) is_subagent: bool,
    pub(super) cwd: String,
    pub(super) first_ts: Option<String>,
    pub(super) last_ts: Option<String>,
    pub(super) ai_title: Option<String>,
    pub(super) first_user_text: String,
    pub(super) last_record: Option<LastRecord>,
    pub(super) total_in: u64,
    pub(super) total_out: u64,
    pub(super) total_cache: u64,
    pub(super) context_tokens: u64,
    pub(super) context_model: String,
    pub(super) counted_message_ids: HashSet<String>,
    pub(super) spawns: Vec<SpawnedAgent>,
    pub(super) turn_spawn_start: usize,
    pub(super) files: Vec<FileTouchRecord>,
    pub(super) commands: Vec<CommandExecutionRecord>,
    /// Bước Bash đang chờ bước kế tiếp để đóng khoảng thời gian (step_index, thời điểm)
    pub(super) bash_open: Option<(usize, DateTime<Utc>)>,
}

/// Metadata session lưu trong SQLite (không có bước, lanes, lệnh)
#[derive(serde::Serialize, serde::Deserialize)]
pub(super) struct ClaudeMeta {
    pub(super) session: ConversationSession,
    pub(super) steps_count: usize,
}

/// Một dòng chỉ mục: (step_index, offset, độ dài, token input, output, cache)
type IndexRow = (i64, i64, i64, i64, i64, i64);

/// Tuần tự hóa đồng bộ: nhiều lần quét song song không ghi chỉ mục trùng nhau
static SYNC_LOCK: Mutex<()> = Mutex::new(());

pub(super) fn session_id_of(path: &Path) -> Option<String> {
    path.file_stem()?.to_str().map(String::from)
}

pub(super) fn fp_key(fp: (u64, u64)) -> String {
    format!("{}:{}", fp.0, fp.1)
}

fn load_state(id: &str) -> Option<ClaudeState> {
    crate::infra::store::transcript_state_get("claude", id)
        .and_then(|json| serde_json::from_str::<ClaudeState>(&json).ok())
}

fn parse_ts(s: &str) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(s)
        .ok()
        .map(|d| d.with_timezone(&Utc))
}

/// Thư mục project đã phân giải (tên, đường dẫn): ưu tiên bản ghi lúc bắt đầu lượt, sau đó theo cwd.
/// Conversation chạy trong mount thì thêm tiền tố "Mount - ".
fn resolve_project(state: &ClaudeState, path: &Path, session_id: &str) -> (String, String) {
    let project_path = if state.cwd.is_empty() {
        path.parent()
            .map(|p| p.to_string_lossy().to_string())
            .unwrap_or_default()
    } else {
        state.cwd.clone()
    };
    let (project_name, project_path) = match crate::infra::store::conversation_project(session_id) {
        Some((name, path)) => (name, path),
        None => (
            Path::new(&project_path)
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or("")
                .to_string(),
            project_path,
        ),
    };
    let project_name =
        if crate::fsmount::is_mount_path(&project_path) && !project_name.starts_with("Mount - ") {
            format!("Mount - {project_name}")
        } else {
            project_name
        };
    (project_name, project_path)
}

/// Repo để suy ra thay đổi từ Bash: None với project trên mount (git đi qua mạng quá chậm)
fn detection_repo(state: &ClaudeState, path: &Path, session_id: &str) -> Option<String> {
    let (_, project_path) = resolve_project(state, path, session_id);
    if project_path.is_empty() || crate::fsmount::is_mount_path(&project_path) {
        None
    } else {
        Some(project_path)
    }
}

/// Nội dung text của tin nhắn người dùng (bỏ block tool_result)
fn user_text(msg: &Value) -> String {
    let texts: Vec<String> = match msg.get("content") {
        Some(Value::String(s)) => vec![s.clone()],
        Some(Value::Array(blocks)) => blocks
            .iter()
            .filter(|b| b.get("type").and_then(|x| x.as_str()) == Some("text"))
            .filter_map(|b| b.get("text").and_then(|x| x.as_str()).map(String::from))
            .collect(),
        _ => Vec::new(),
    };
    texts.join("\n").trim().to_string()
}

/// Dựng bước USER_INPUT từ dòng người dùng (đã qua các kiểm tra: không phải isMeta/task-notification, text không rỗng)
fn build_user_step(v: &Value, idx: usize, ts_str: String, session_id: &str) -> Option<AgentStep> {
    let msg = v.get("message")?;
    let text = user_text(msg);
    if text.is_empty() {
        return None;
    }
    let image_count = match msg.get("content") {
        Some(Value::Array(blocks)) => blocks
            .iter()
            .filter(|b| b.get("type").and_then(|x| x.as_str()) == Some("image"))
            .count(),
        _ => 0,
    };
    let mut step = make_step(
        idx,
        "USER_INPUT",
        "USER_EXPLICIT",
        "user",
        ts_str,
        text,
        String::new(),
        Vec::new(),
        0,
        0,
        0,
    );
    step.image_count = image_count;
    let uuid = v.get("uuid").and_then(|x| x.as_str()).unwrap_or("");
    if !uuid.is_empty() && !session_id.is_empty() {
        step.image_urls = (0..image_count)
            .map(|i| crate::chat::attachments::transcript_attachment_url(session_id, uuid, i))
            .collect();
    }
    Some(step)
}

/// Dựng bước PLANNER_RESPONSE từ dòng assistant. None khi không có text, thinking hay tool call.
fn build_assistant_step(
    v: &Value,
    idx: usize,
    ts_str: String,
    inp: u64,
    out: u64,
    cache: u64,
) -> Option<AgentStep> {
    let msg = v.get("message")?;
    let mut text_parts: Vec<String> = Vec::new();
    let mut thinking_parts: Vec<String> = Vec::new();
    let mut tool_calls: Vec<ToolCallInfo> = Vec::new();
    if let Some(Value::Array(blocks)) = msg.get("content") {
        for b in blocks {
            match b.get("type").and_then(|x| x.as_str()).unwrap_or("") {
                "text" => {
                    if let Some(t) = b.get("text").and_then(|x| x.as_str()) {
                        text_parts.push(t.to_string());
                    }
                }
                "thinking" => {
                    if let Some(t) = b.get("thinking").and_then(|x| x.as_str()) {
                        thinking_parts.push(t.to_string());
                    }
                }
                "tool_use" => {
                    let name = b
                        .get("name")
                        .and_then(|x| x.as_str())
                        .unwrap_or("tool")
                        .to_string();
                    let args: HashMap<String, Value> = b
                        .get("input")
                        .and_then(|x| x.as_object())
                        .map(|o| o.iter().map(|(k, v)| (k.clone(), v.clone())).collect())
                        .unwrap_or_default();
                    let target_path = ["file_path", "notebook_path", "path"]
                        .iter()
                        .find_map(|k| args.get(*k).and_then(|x| x.as_str()))
                        .map(String::from);
                    tool_calls.push(ToolCallInfo {
                        summary_label: tool_summary(&name, &args),
                        name,
                        args,
                        target_path,
                        repo_tag: String::new(),
                    });
                }
                _ => {}
            }
        }
    }
    if text_parts.is_empty() && thinking_parts.is_empty() && tool_calls.is_empty() {
        return None;
    }
    let model_name = msg
        .get("model")
        .and_then(|x| x.as_str())
        .filter(|m| !m.is_empty() && !m.starts_with('<'))
        .unwrap_or("")
        .to_string();
    let mut step = make_step(
        idx,
        "PLANNER_RESPONSE",
        "MODEL",
        "Coordinator",
        ts_str,
        text_parts.join("\n\n"),
        thinking_parts.join("\n\n"),
        tool_calls,
        inp,
        out,
        cache,
    );
    step.model = model_name;
    Some(step)
}

/// Đưa một bước mới vào chỉ mục: đóng cửa sổ Bash đang mở bằng bước này, mở cửa sổ mới nếu bước có lệnh Bash,
/// và quét lệnh rm/git rm của bước.
fn push_step(
    state: &mut ClaudeState,
    rows: &mut Vec<IndexRow>,
    step: &AgentStep,
    offset: u64,
    len: usize,
    tokens: (u64, u64, u64),
    repo: Option<&str>,
) {
    let idx = step.step_index;
    rows.push((
        idx as i64,
        offset as i64,
        len as i64,
        tokens.0 as i64,
        tokens.1 as i64,
        tokens.2 as i64,
    ));
    state.steps_count = idx + 1;
    let ts = parse_ts(&step.created_at);
    if let Some((prev_idx, prev_start)) = state.bash_open.take() {
        if let Some(repo) = repo {
            detect_bash_window(
                repo,
                prev_idx,
                prev_start,
                ts.unwrap_or_else(Utc::now),
                &mut state.files,
            );
        }
    }
    if step.tool_calls.iter().any(|t| t.name == "Bash") {
        if let Some(start) = ts {
            state.bash_open = Some((idx, start));
        }
    }
    if let Some(repo) = repo {
        detect_bash_deletions_in_step(repo, step, &mut state.files);
    }
}

/// Xử lý các dòng mới của transcript kể từ `state.indexed_bytes`. Chỉ dòng đã kết thúc bằng xuống dòng
/// được tính; dòng dở dang để lần sau. Trả về số byte đã xử lý.
fn advance(
    state: &mut ClaudeState,
    path: &Path,
    session_id: &str,
    rows: &mut Vec<IndexRow>,
) -> Option<u64> {
    let mut file = fs::File::open(path).ok()?;
    file.seek(SeekFrom::Start(state.indexed_bytes)).ok()?;
    let mut reader = BufReader::new(file);
    let start_bytes = state.indexed_bytes;
    let mut offset = state.indexed_bytes;
    let mut buf: Vec<u8> = Vec::new();
    // Repo để suy ra thay đổi Bash: tra cứu một lần cho mỗi lần đồng bộ (không tra DB từng dòng)
    let mut repo_memo: Option<Option<String>> = None;
    loop {
        buf.clear();
        let n = match reader.read_until(b'\n', &mut buf) {
            Ok(0) | Err(_) => break,
            Ok(n) => n,
        };
        // Dòng cuối chưa có xuống dòng: chỉ xử lý khi đã là JSON hợp lệ (đang ghi thì còn dở dang)
        if buf.last() != Some(&b'\n') && serde_json::from_slice::<Value>(&buf).is_err() {
            break;
        }
        let line_offset = offset;
        offset += n as u64;
        let Ok(text) = std::str::from_utf8(&buf) else {
            continue;
        };
        let line = text.trim_end_matches(['\n', '\r']);
        let Ok(v) = serde_json::from_str::<Value>(line) else {
            continue;
        };
        // Hội thoại của sub-agent (sidechain) không trộn vào luồng chính
        if !state.is_subagent
            && v.get("isSidechain")
                .and_then(|x| x.as_bool())
                .unwrap_or(false)
        {
            continue;
        }
        if state.cwd.is_empty() {
            if let Some(c) = v.get("cwd").and_then(|x| x.as_str()) {
                state.cwd = c.to_string();
            }
        }
        let ts = v
            .get("timestamp")
            .and_then(|x| x.as_str())
            .map(|s| s.to_string());
        if let Some(t) = &ts {
            if state.first_ts.is_none() {
                state.first_ts = Some(t.clone());
            }
            state.last_ts = Some(t.clone());
        }
        let ts_str = ts.clone().unwrap_or_default();
        // Chưa đọc được cwd thì chưa biết repo: không ghi nhớ kết quả tạm thời này
        let repo = if state.cwd.is_empty() {
            None
        } else {
            repo_memo
                .get_or_insert_with(|| detection_repo(state, path, session_id))
                .clone()
        };

        match v.get("type").and_then(|x| x.as_str()).unwrap_or("") {
            "ai-title" => {
                if let Some(t) = v.get("aiTitle").and_then(|x| x.as_str()) {
                    state.ai_title = Some(t.to_string());
                }
            }
            "user" => {
                record_agent_results(&v, &mut state.spawns);
                if v.get("isMeta").and_then(|x| x.as_bool()).unwrap_or(false) {
                    continue;
                }
                let Some(msg) = v.get("message") else {
                    continue;
                };
                let text = user_text(msg);
                // Thông báo hoàn tất của subagent nền, không phải tin nhắn của người dùng
                if text.starts_with("<task-notification>") {
                    continue;
                }
                if !text.starts_with("<local-command") {
                    state.last_record = Some(LastRecord::User);
                }
                if text.is_empty() {
                    continue;
                }
                if !text.starts_with("<local-command") {
                    state.turn_spawn_start = state.spawns.len();
                }
                if state.first_user_text.is_empty() && !text.starts_with('<') {
                    state.first_user_text = text.clone();
                }
                let idx = state.steps_count;
                if let Some(step) = build_user_step(&v, idx, ts_str, session_id) {
                    push_step(
                        state,
                        rows,
                        &step,
                        line_offset,
                        n,
                        (0, 0, 0),
                        repo.as_deref(),
                    );
                }
            }
            "assistant" => {
                let Some(msg) = v.get("message") else {
                    continue;
                };
                state.last_record = Some(LastRecord::Assistant {
                    stop_reason: msg
                        .get("stop_reason")
                        .and_then(|x| x.as_str())
                        .unwrap_or("")
                        .to_string(),
                });
                let idx = state.steps_count;
                // Claude ghi mỗi content block thành một dòng riêng cùng message.id,
                // usage chỉ được cộng một lần cho mỗi message.id.
                let msg_id = msg
                    .get("id")
                    .and_then(|x| x.as_str())
                    .unwrap_or("")
                    .to_string();
                let first_time_for_message =
                    msg_id.is_empty() || state.counted_message_ids.insert(msg_id);
                let (mut inp, mut out, mut cache) = (0u64, 0u64, 0u64);
                if first_time_for_message {
                    if let Some(u) = msg.get("usage") {
                        inp = u.get("input_tokens").and_then(|x| x.as_u64()).unwrap_or(0);
                        out = u.get("output_tokens").and_then(|x| x.as_u64()).unwrap_or(0);
                        cache = u
                            .get("cache_read_input_tokens")
                            .and_then(|x| x.as_u64())
                            .unwrap_or(0);
                        state.total_in += inp;
                        state.total_out += out;
                        state.total_cache += cache;
                        let cache_created = u
                            .get("cache_creation_input_tokens")
                            .and_then(|x| x.as_u64())
                            .unwrap_or(0);
                        let ctx = inp + cache_created + cache;
                        if ctx > 0 {
                            state.context_tokens = ctx;
                            state.context_model = msg
                                .get("model")
                                .and_then(|x| x.as_str())
                                .filter(|m| !m.is_empty() && !m.starts_with('<'))
                                .map(|m| format!("claude-cli:{m}"))
                                .unwrap_or_default();
                        }
                    }
                }
                // Subagent gọi (Agent/Task) và thay đổi file/lệnh của các tool_use trong dòng này
                if let Some(Value::Array(blocks)) = msg.get("content") {
                    for b in blocks {
                        if b.get("type").and_then(|x| x.as_str()) != Some("tool_use") {
                            continue;
                        }
                        let name = b
                            .get("name")
                            .and_then(|x| x.as_str())
                            .unwrap_or("tool")
                            .to_string();
                        let args: HashMap<String, Value> = b
                            .get("input")
                            .and_then(|x| x.as_object())
                            .map(|o| o.iter().map(|(k, v)| (k.clone(), v.clone())).collect())
                            .unwrap_or_default();
                        if name == "Agent" || name == "Task" {
                            state.spawns.push(SpawnedAgent {
                                tool_use_id: b
                                    .get("id")
                                    .and_then(|x| x.as_str())
                                    .unwrap_or("")
                                    .to_string(),
                                name: args
                                    .get("subagent_type")
                                    .and_then(|x| x.as_str())
                                    .filter(|s| !s.is_empty())
                                    .unwrap_or("general-purpose")
                                    .to_string(),
                                role: args
                                    .get("description")
                                    .and_then(|x| x.as_str())
                                    .unwrap_or("")
                                    .to_string(),
                                prompt: args
                                    .get("prompt")
                                    .and_then(|x| x.as_str())
                                    .unwrap_or("")
                                    .to_string(),
                                agent_id: None,
                                completed: false,
                            });
                        }
                        record_side_effects(
                            &name,
                            &args,
                            idx,
                            &ts_str,
                            &mut state.files,
                            &mut state.commands,
                        );
                    }
                }
                if let Some(step) = build_assistant_step(&v, idx, ts_str, inp, out, cache) {
                    push_step(
                        state,
                        rows,
                        &step,
                        line_offset,
                        n,
                        (inp, out, cache),
                        repo.as_deref(),
                    );
                }
            }
            _ => {}
        }
    }
    state.indexed_bytes = offset;
    // Cửa sổ Bash chưa đóng (bước Bash là bước cuối): tính đến hiện tại, như parser cũ
    if let Some((idx, start)) = state.bash_open.clone() {
        if let Some(repo) = detection_repo(state, path, session_id) {
            detect_bash_window(&repo, idx, start, Utc::now(), &mut state.files);
        }
    }
    Some(offset - start_bytes)
}

/// Đọc các bước theo chỉ mục: seek tới từng dòng, dựng lại bước từ dòng JSON
fn read_steps(path: &Path, session_id: &str, rows: &[IndexRow]) -> Vec<AgentStep> {
    if rows.is_empty() {
        return Vec::new();
    }
    let Ok(mut file) = fs::File::open(path) else {
        return Vec::new();
    };
    let mut out = Vec::with_capacity(rows.len());
    for &(step_index, offset, len, inp, o, cache) in rows {
        if file.seek(SeekFrom::Start(offset as u64)).is_err() {
            continue;
        }
        let mut buf = vec![0u8; len as usize];
        if file.read_exact(&mut buf).is_err() {
            continue;
        }
        let Ok(text) = std::str::from_utf8(&buf) else {
            continue;
        };
        let Ok(v) = serde_json::from_str::<Value>(text.trim()) else {
            continue;
        };
        let ts_str = v
            .get("timestamp")
            .and_then(|x| x.as_str())
            .unwrap_or("")
            .to_string();
        let idx = step_index as usize;
        let step = match v.get("type").and_then(|x| x.as_str()).unwrap_or("") {
            "user" => build_user_step(&v, idx, ts_str, session_id),
            "assistant" => {
                build_assistant_step(&v, idx, ts_str, inp as u64, o as u64, cache as u64)
            }
            _ => None,
        };
        out.extend(step);
    }
    out
}

/// Metadata (không bước) dựng từ trạng thái, dùng cho danh sách
fn build_session(
    path: &Path,
    state: &ClaudeState,
    steps: Vec<AgentStep>,
    with_lanes: bool,
) -> (ConversationSession, Vec<SpawnedAgent>) {
    let session_id = session_id_of(path).unwrap_or_default();
    let fallback_time = fingerprint(path)
        .map(|(ms, _)| DateTime::<Utc>::from(UNIX_EPOCH + Duration::from_millis(ms)).to_rfc3339())
        .unwrap_or_default();
    let created_at = state
        .first_ts
        .clone()
        .unwrap_or_else(|| fallback_time.clone());
    let updated_at = state.last_ts.clone().unwrap_or(fallback_time);
    // Lượt chưa xong: bản ghi cuối là prompt/tool_result, hoặc assistant đang chờ tool_result
    let unfinished = !state.is_subagent
        && match &state.last_record {
            Some(LastRecord::User) => true,
            Some(LastRecord::Assistant { stop_reason }) => stop_reason == "tool_use",
            None => false,
        };
    let base_status = if unfinished {
        UNFINISHED_STATUS
    } else {
        "completed"
    };
    let title = match &state.ai_title {
        Some(t) if !t.trim().is_empty() => t.trim().to_string(),
        _ => {
            let fallback: String = state.first_user_text.chars().take(60).collect();
            if fallback.trim().is_empty() {
                "Phiên Claude Code".to_string()
            } else {
                fallback.replace('\n', " ")
            }
        }
    };
    let (project_name, project_path) = resolve_project(state, path, &session_id);

    let mut files = state.files.clone();
    files.sort_by(|a, b| b.timestamp.cmp(&a.timestamp));
    files.truncate(100);
    let mut commands = state.commands.clone();
    commands.sort_by(|a, b| b.timestamp.cmp(&a.timestamp));
    commands.truncate(50);

    let spawns = state.spawns.clone();
    // Chỉ session chính dựng cây sub-agent; lane chỉ gồm các lần gọi của lượt hiện tại
    let subagent_lanes = if !state.is_subagent && with_lanes {
        let start = state.turn_spawn_start.min(spawns.len());
        build_subagent_lanes(path, &spawns[start..], &project_name)
    } else {
        Vec::new()
    };
    let has_parallel_flow = !subagent_lanes.is_empty();

    let session = ConversationSession {
        id: session_id,
        title,
        created_at,
        updated_at,
        status: base_status.to_string(),
        current_phase: base_status.to_string(),
        steps,
        subagent_lanes,
        lanes_loaded: with_lanes,
        files_touched: files,
        commands_run: commands,
        total_input_tokens: state.total_in,
        total_output_tokens: state.total_out,
        total_cache_tokens: state.total_cache,
        project_name,
        project_path,
        is_simulated: false,
        pending_plans: Vec::new(),
        git_sync_status: None,
        is_interrupted: false,
        interrupted_reason: None,
        custom_agents: Vec::new(),
        available_agents: Vec::new(),
        has_parallel_flow,
        source: "claude-cli".to_string(),
        context_tokens: state.context_tokens,
        context_model: state.context_model.clone(),
        selected_model: String::new(),
    };
    (session, spawns)
}

/// Đảm bảo chỉ mục và trạng thái khớp với transcript. Chỉ đọc phần byte mới kể từ `indexed_bytes`;
/// file bị viết lại (ngắn hơn chỉ mục hoặc đổi loại subagent) thì dựng lại từ đầu.
pub(super) fn sync(path: &Path, is_subagent: bool) -> Option<()> {
    let _guard = SYNC_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let id = session_id_of(path)?;
    let fp = fingerprint(path)?;
    let len = fp.1;
    let key = fp_key(fp);

    // Đường nhanh: metadata khớp dấu vết file và trạng thái còn tồn tại thì không cần đọc trạng thái
    // (trạng thái JSON có thể lớn; danh sách gọi hàm này cho mọi session)
    if crate::infra::store::transcript_state_exists("claude", &id)
        && crate::infra::store::transcript_meta_get("claude", &id)
            .is_some_and(|(stored_fp, _)| stored_fp == key)
    {
        return Some(());
    }

    let stored = load_state(&id);
    if let Some(state) = &stored {
        if state.indexed_bytes == len && state.is_subagent == is_subagent {
            // Không có byte mới: chỉ làm mới metadata nếu dấu vết file đổi (ví dụ mtime)
            let meta_ok = crate::infra::store::transcript_meta_get("claude", &id)
                .is_some_and(|(stored_fp, _)| stored_fp == key);
            if !meta_ok {
                let (session, _) = build_session(path, state, Vec::new(), false);
                let mut session = session;
                session.commands_run.clear();
                session.lanes_loaded = false;
                let json = serde_json::to_string(&ClaudeMeta {
                    session,
                    steps_count: state.steps_count,
                })
                .ok()?;
                crate::infra::store::claude_meta_only_write(&id, &key, &json);
            }
            return Some(());
        }
    }

    let (mut state, reset) = match stored {
        Some(s) if s.indexed_bytes < len && s.is_subagent == is_subagent => (s, false),
        _ => (
            ClaudeState {
                is_subagent,
                ..ClaudeState::default()
            },
            true,
        ),
    };
    let mut rows: Vec<IndexRow> = Vec::new();
    let consumed = advance(&mut state, path, &id, &mut rows)?;
    if consumed == 0 && !reset {
        return Some(());
    }

    let (session, _) = build_session(path, &state, Vec::new(), false);
    let mut session = session;
    session.commands_run.clear();
    session.lanes_loaded = false;
    let meta_json = serde_json::to_string(&ClaudeMeta {
        session,
        steps_count: state.steps_count,
    })
    .ok()?;
    let state_json = serde_json::to_string(&state).ok()?;
    crate::infra::store::claude_sync_write(&id, &key, &meta_json, &state_json, &rows, reset);
    Some(())
}

/// Session dựng từ chỉ mục: `tail` bước cuối, tùy chọn lanes. Dùng cho chi tiết và lanes.
pub(super) fn session_indexed(
    path: &Path,
    is_subagent: bool,
    with_lanes: bool,
    tail: usize,
) -> Option<(ConversationSession, Vec<SpawnedAgent>)> {
    sync(path, is_subagent)?;
    let id = session_id_of(path)?;
    let state = load_state(&id)?;
    let rows = crate::infra::store::claude_line_rows(&id, None, tail);
    let steps = read_steps(path, &id, &rows);
    Some(build_session(path, &state, steps, with_lanes))
}

/// Metadata session (không bước, lanes, lệnh) và số bước, lấy từ SQLite
pub(super) fn meta_indexed(path: &Path) -> Option<(ConversationSession, usize)> {
    sync(path, false)?;
    let id = session_id_of(path)?;
    let (_, json) = crate::infra::store::transcript_meta_get("claude", &id)?;
    let meta: ClaudeMeta = serde_json::from_str(&json).ok()?;
    Some((meta.session, meta.steps_count))
}

/// Một trang bước (cùng quy ước với Antigravity: `limit` bước ngay trước `before`), đọc theo chỉ mục
pub(super) fn steps_page(
    path: &Path,
    before: Option<usize>,
    limit: usize,
) -> Option<crate::models::SessionStepsPageResponse> {
    sync(path, false)?;
    let id = session_id_of(path)?;
    let rows = crate::infra::store::claude_line_rows(&id, before.map(|b| b as i64), limit);
    let page = read_steps(path, &id, &rows);
    let (_, total_steps) = meta_indexed(path)?;
    let earliest = page.first().map(|s| s.step_index).unwrap_or(0);
    Some(crate::models::SessionStepsPageResponse {
        session_id: id,
        steps: page,
        has_more: earliest > 0,
        earliest_step_index: earliest,
        total_steps,
    })
}

/// Parse trong bộ nhớ (không ghi DB): chỉ dùng cho kiểm thử
#[cfg(test)]
pub(super) fn parse_in_memory(
    path: &Path,
    is_subagent: bool,
) -> Option<(ConversationSession, Vec<SpawnedAgent>)> {
    let id = session_id_of(path)?;
    let mut state = ClaudeState {
        is_subagent,
        ..ClaudeState::default()
    };
    let mut rows: Vec<IndexRow> = Vec::new();
    advance(&mut state, path, &id, &mut rows)?;
    let tail = rows.len().saturating_sub(TAIL_STEPS);
    let steps = read_steps(path, &id, &rows[tail..]);
    Some(build_session(path, &state, steps, true))
}
