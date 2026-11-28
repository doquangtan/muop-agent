//! Chỉ mục và trạng thái tăng dần của transcript agy.
//!
//! - `agy_transcript_lines` (SQLite): vị trí byte của từng dòng hợp lệ (seq, step_index, offset, độ dài). Chỉ
//!   lưu vị trí, không lưu nội dung nên không nhân đôi dữ liệu hội thoại.
//! - `transcript_state` (SQLite): trạng thái parser (tổng token, subagent, tệp/lệnh gần nhất, bước cuối...).
//!   Khi transcript lớn thêm, chỉ đọc đúng phần byte mới và cập nhật trạng thái (O(phần mới), không đọc lại cả file).
//! - Steps cuối được đọc bằng seek theo chỉ mục khi cần; không giữ trong RAM.

use super::transcript::{finish, parse_single_agent_step, transcript_fingerprint, transcript_path};
use super::*;
use std::io::{BufRead, BufReader, Read, Seek, SeekFrom};
use std::sync::Mutex;

/// Số bước cuối được nạp cho một transcript khi cần đầy đủ (giống giới hạn parser cũ)
pub(super) const TAIL_STEPS: usize = 150;
/// Giới hạn tệp và lệnh gần nhất giữ trong trạng thái (giống parser cũ)
const FILES_CAP: usize = 80;
const COMMANDS_CAP: usize = 40;
const KIND: &str = "agy";

/// Khóa tuần tự hóa việc đồng bộ: nhiều lần quét song song không ghi chỉ mục trùng nhau
static SYNC_LOCK: Mutex<()> = Mutex::new(());

/// Trạng thái parser lưu trong SQLite. Đủ để cập nhật tiếp từ `indexed_bytes` mà không đọc lại file.
#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
pub(super) struct ParserState {
    /// Số byte đã xử lý (luôn trỏ tới đầu một dòng)
    pub(super) indexed_bytes: u64,
    pub(super) total_step_count: usize,
    pub(super) first_user_prompt_title: String,
    pub(super) created_at: Option<DateTime<Utc>>,
    pub(super) max_step_time: Option<DateTime<Utc>>,
    pub(super) total_input: u64,
    pub(super) total_output: u64,
    pub(super) total_cache: u64,
    pub(super) spawned_subagents: Vec<SpawnedSubagentMeta>,
    pub(super) pending_subagent_indices: Vec<usize>,
    pub(super) turn_spawn_start: usize,
    pub(super) referenced_ids: Vec<String>,
    pub(super) has_verify: bool,
    pub(super) has_edit_or_parallel: bool,
    pub(super) last_step: Option<LastStepMeta>,
    pub(super) files: Vec<FileTouchRecord>,
    pub(super) commands: Vec<CommandExecutionRecord>,
}

/// Một dòng transcript đã xử lý, dùng để ghi chỉ mục: (seq, step_index, offset, độ dài kể cả xuống dòng)
type IndexRow = (i64, i64, i64, i64);

/// Cập nhật trạng thái bằng một bước mới (tương đương vòng lặp parse cũ, không lưu steps)
fn feed(
    state: &mut ParserState,
    map: &Value,
    step_index: usize,
    file_modified: DateTime<Utc>,
    conv_id_re: &Regex,
) {
    let step = parse_single_agent_step(map, step_index, file_modified);
    let step_time = match DateTime::parse_from_rfc3339(&step.created_at) {
        Ok(dt) => dt.with_timezone(&Utc),
        Err(_) => file_modified,
    };

    if state.created_at.is_none() {
        state.created_at = Some(step_time);
    }
    if state.max_step_time.map_or(true, |m| step_time > m) {
        state.max_step_time = Some(step_time);
    }

    state.total_input += step.input_tokens;
    state.total_output += step.output_tokens;
    state.total_cache += step.cache_read_tokens;

    if step.step_type == "USER_INPUT" && !step.content.is_empty() {
        state.turn_spawn_start = state.spawned_subagents.len();
    }

    if step.step_type == "USER_INPUT"
        && !step.content.is_empty()
        && state.first_user_prompt_title.is_empty()
    {
        let extracted = extract_user_request(&step.content);
        if !extracted.is_empty() {
            state.first_user_prompt_title = extracted;
        }
    }

    if step.phase == "crossVerification" {
        state.has_verify = true;
    } else if step.phase == "parallelExecution" {
        state.has_edit_or_parallel = true;
    }

    state.last_step = Some(LastStepMeta {
        step_type: step.step_type.clone(),
        status: step.status.clone(),
        has_tool_calls: !step.tool_calls.is_empty(),
    });

    for tc in &step.tool_calls {
        let path_arg = tc.target_path.as_deref().unwrap_or("");
        if !path_arg.is_empty() {
            let action = match tc.name.as_str() {
                "read_file" | "view_file_outline" => Some("READ"),
                "write_file" => Some("WRITE"),
                "edit_file" => Some("EDIT"),
                _ => None,
            };
            if let Some(act) = action {
                let (added_lines, removed_lines, diff_preview) =
                    extract_tool_diff(&tc.name, &tc.args);
                let touch_agent = if tc.repo_tag == "muop-erp-server" {
                    "erp-server-agent"
                } else if tc.repo_tag == "muop-erp-app" {
                    "erp-app-agent"
                } else {
                    "Coordinator"
                };
                state.files.push(FileTouchRecord {
                    path: path_arg.to_string(),
                    action: act.to_string(),
                    repo: tc.repo_tag.clone(),
                    agent_name: touch_agent.to_string(),
                    step_index,
                    timestamp: step.created_at.clone(),
                    added_lines,
                    removed_lines,
                    diff_preview: safe_truncate(&diff_preview, 200).to_string(),
                    source: String::new(),
                });
                if state.files.len() > FILES_CAP {
                    state.files.remove(0);
                }
            }
        }

        if tc.name == "run_command" {
            let cmd_line = tc
                .args
                .get("CommandLine")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            let summary = tc
                .args
                .get("toolSummary")
                .and_then(|v| v.as_str())
                .unwrap_or("Thực thi lệnh terminal")
                .to_string();
            let cmd_agent = if cmd_line.contains("flutter analyze") || cmd_line.contains("go build")
            {
                "erp-contract-verifier"
            } else if cmd_line.contains("muop-erp-server") {
                "erp-server-agent"
            } else if cmd_line.contains("muop-erp-app") {
                "erp-app-agent"
            } else {
                "Coordinator"
            };
            state.commands.push(CommandExecutionRecord {
                command_line: cmd_line,
                summary,
                agent_name: cmd_agent.to_string(),
                step_index,
                timestamp: step.created_at.clone(),
                output_preview: String::new(),
                is_success: true,
            });
            if state.commands.len() > COMMANDS_CAP {
                state.commands.remove(0);
            }
        }

        if tc.name == "invoke_subagent" {
            let role = tc
                .args
                .get("Role")
                .and_then(|v| v.as_str())
                .unwrap_or("Subagent Worker")
                .to_string();
            let type_name = tc
                .args
                .get("TypeName")
                .and_then(|v| v.as_str())
                .unwrap_or("self")
                .to_string();
            let prompt = tc
                .args
                .get("Prompt")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            let name = if type_name == "self" {
                role.clone()
            } else {
                type_name
            };
            let idx = state.spawned_subagents.len();
            state.spawned_subagents.push(SpawnedSubagentMeta {
                id: String::new(),
                name,
                role: role.clone(),
                prompt,
                step_index,
                status: "running".to_string(),
                last_action: format!("Đang khởi chạy Subagent: {}", role),
                tool_name: "invoke_subagent".to_string(),
            });
            state.pending_subagent_indices.push(idx);
        }
    }

    if step.step_type == "GENERIC"
        && step.content.contains("Created the following subagent:")
        && !state.pending_subagent_indices.is_empty()
    {
        let idx = state.pending_subagent_indices.remove(0);
        if let Some(caps) = conv_id_re.captures(&step.content) {
            if let Some(m) = caps.get(1) {
                if let Some(sub) = state.spawned_subagents.get_mut(idx) {
                    sub.id = m.as_str().to_string();
                }
            }
        }
    }

    if step.step_type == "SYSTEM_MESSAGE" && step.content.contains("<SYSTEM_MESSAGE>") {
        for sub in &mut state.spawned_subagents {
            if !sub.id.is_empty() && step.content.contains(&sub.id) {
                if step.content.contains("encountered an error") {
                    sub.status = "error".to_string();
                    sub.last_action = "Subagent gặp lỗi khi thực thi".to_string();
                } else {
                    sub.status = "completed".to_string();
                    sub.last_action =
                        "Đã hoàn thành nhiệm vụ & gửi báo cáo về Coordinator".to_string();
                }
            }
        }
    }
}

/// Id conversation con được nhắc trong dòng spawn/invoke (cùng điều kiện với bản quét cũ)
fn referenced_id(line: &str, conv_id_re: &Regex) -> Option<String> {
    if line.contains("Created the following subagent:") || line.contains("invoke_subagent") {
        return conv_id_re
            .captures(line)
            .and_then(|c| c.get(1))
            .map(|m| m.as_str().to_string());
    }
    None
}

/// Metadata dẫn xuất từ trạng thái parser (cùng ý nghĩa với bản cũ `TranscriptMeta`)
fn meta_from_state(state: &ParserState, file_modified: DateTime<Utc>) -> TranscriptMeta {
    let updated = match state.max_step_time {
        Some(t) if t > file_modified => t,
        _ => file_modified,
    };
    let fallback_repo = state
        .files
        .iter()
        .find(|f| f.repo != "system" && f.repo != ".agents")
        .map(|f| f.repo.clone())
        .unwrap_or_default();
    TranscriptMeta {
        first_prompt_title: state.first_user_prompt_title.clone(),
        created_at: state.created_at.unwrap_or(file_modified).to_rfc3339(),
        updated_at: updated.to_rfc3339(),
        last_step: state.last_step.clone(),
        has_verify: state.has_verify,
        has_edit_or_parallel: state.has_edit_or_parallel,
        spawned_subagents: state.spawned_subagents.clone(),
        turn_spawn_start: state.turn_spawn_start,
        total_input_tokens: state.total_input,
        total_output_tokens: state.total_output,
        total_cache_tokens: state.total_cache,
        total_steps: state.total_step_count,
        fallback_repo,
        referenced_ids: state.referenced_ids.clone(),
    }
}

fn load_state(id: &str) -> Option<ParserState> {
    crate::infra::store::transcript_state_get(KIND, id)
        .and_then(|json| serde_json::from_str::<ParserState>(&json).ok())
}

/// Đồng bộ chỉ mục và trạng thái với transcript rồi trả về metadata. Chỉ đọc phần byte mới kể từ
/// `indexed_bytes`; file bị viết lại (ngắn hơn chỉ mục) thì dựng lại từ đầu.
pub(super) fn sync(id: &str, file_modified: DateTime<Utc>) -> Option<TranscriptMeta> {
    let _guard = SYNC_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let path = transcript_path(id);
    let len = fs::metadata(&path).ok()?.len();
    let fingerprint = transcript_fingerprint(&path)?;

    // Đường nhanh: metadata khớp dấu vết file và trạng thái còn tồn tại thì dùng metadata, không đọc trạng thái
    if crate::infra::store::transcript_state_exists(KIND, id) {
        if let Some((stored_fp, json)) = crate::infra::store::transcript_meta_get(KIND, id) {
            if stored_fp == fingerprint {
                if let Ok(meta) = serde_json::from_str::<TranscriptMeta>(&json) {
                    return Some(meta);
                }
            }
        }
    }

    let stored = load_state(id);
    if let Some(state) = &stored {
        if state.indexed_bytes == len {
            // Không có byte mới: metadata đã lưu vẫn đúng, chỉ làm mới nếu dấu vết file đổi
            if let Some((stored_fp, json)) = crate::infra::store::transcript_meta_get(KIND, id) {
                if stored_fp == fingerprint {
                    if let Ok(meta) = serde_json::from_str::<TranscriptMeta>(&json) {
                        return Some(meta);
                    }
                }
            }
            let meta = meta_from_state(state, file_modified);
            if let Ok(json) = serde_json::to_string(&meta) {
                crate::infra::store::transcript_meta_set(KIND, id, &fingerprint, &json);
            }
            return Some(meta);
        }
    }

    let (mut state, reset) = match stored {
        Some(s) if s.indexed_bytes < len => (s, false),
        _ => (ParserState::default(), true),
    };

    let conv_id_re = Regex::new(r#""conversationId"\s*:\s*"([^"]+)""#).ok()?;
    let mut file = fs::File::open(&path).ok()?;
    file.seek(SeekFrom::Start(state.indexed_bytes)).ok()?;
    let mut reader = BufReader::new(file);
    let mut offset = state.indexed_bytes;
    let mut rows: Vec<IndexRow> = Vec::new();
    let mut buf: Vec<u8> = Vec::new();

    loop {
        buf.clear();
        let n = match reader.read_until(b'\n', &mut buf) {
            Ok(0) | Err(_) => break,
            Ok(n) => n,
        };
        // Dòng chưa kết thúc bằng xuống dòng: agy còn đang ghi, để lần đồng bộ sau xử lý
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
        if line.trim().is_empty() {
            continue;
        }
        if let Some(sid) = referenced_id(line, &conv_id_re) {
            if !state.referenced_ids.contains(&sid) {
                state.referenced_ids.push(sid);
            }
        }
        let Ok(map) = serde_json::from_str::<Value>(line) else {
            continue;
        };
        let step_index = map
            .get("step_index")
            .and_then(|v| v.as_u64())
            .map(|v| v as usize)
            .unwrap_or(state.total_step_count);
        let seq = state.total_step_count;
        state.total_step_count += 1;
        feed(&mut state, &map, step_index, file_modified, &conv_id_re);
        rows.push((seq as i64, step_index as i64, line_offset as i64, n as i64));
    }
    state.indexed_bytes = offset;

    let meta = meta_from_state(&state, file_modified);
    let (Ok(state_json), Ok(meta_json)) =
        (serde_json::to_string(&state), serde_json::to_string(&meta))
    else {
        return None;
    };
    crate::infra::store::transcript_sync_write(
        KIND,
        id,
        &fingerprint,
        &meta_json,
        &state_json,
        &rows,
        reset,
    );
    Some(meta)
}

/// Steps cuối của transcript, đọc theo chỉ mục (seek tới từng dòng), không parse cả file
pub(super) fn tail_steps(id: &str, n: usize, file_modified: DateTime<Utc>) -> Vec<AgentStep> {
    if n == 0 {
        return Vec::new();
    }
    let rows = crate::infra::store::agy_tail_rows(id, n);
    if rows.is_empty() {
        return Vec::new();
    }
    let Ok(mut file) = fs::File::open(transcript_path(id)) else {
        return Vec::new();
    };
    let agy_turns = load_agy_turn_models(id);
    let mut out = Vec::with_capacity(rows.len());
    for (step_index, offset, len) in rows {
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
        let Ok(map) = serde_json::from_str::<Value>(text.trim()) else {
            continue;
        };
        let step_index = step_index as usize;
        let mut step = parse_single_agent_step(&map, step_index, file_modified);
        if step.step_type == "PLANNER_RESPONSE" {
            let step_time = match DateTime::parse_from_rfc3339(&step.created_at) {
                Ok(dt) => dt.with_timezone(&Utc),
                Err(_) => file_modified,
            };
            // agy ghi model ngay trong từng bước; chỉ dùng bản ghi DB khi bước không có model
            step.model = map
                .get("model")
                .and_then(|v| v.as_str())
                .filter(|m| !m.is_empty())
                .map(String::from)
                .unwrap_or_else(|| agy_turn_model_at(&agy_turns, step_time));
        }
        out.push(step);
    }
    out
}

/// Transcript đầy đủ cho một conversation: metadata + `tail` bước cuối (+ tệp/lệnh gần nhất nếu `with_files`).
/// `None` khi transcript không có bước nào.
pub(super) fn load_parsed(
    id: &str,
    file_modified: DateTime<Utc>,
    db_meta: Option<&DbConversationMeta>,
    tail: usize,
    with_files: bool,
) -> Option<ParsedTranscript> {
    let meta = sync(id, file_modified)?;
    if meta.total_steps == 0 {
        return None;
    }
    let steps = tail_steps(id, tail, file_modified);
    let (files, commands) = match with_files.then(|| load_state(id)).flatten() {
        Some(state) => (state.files, state.commands),
        None => (Vec::new(), Vec::new()),
    };
    Some(finish(id, &meta, steps, files, commands, db_meta))
}
