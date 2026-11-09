//! Đọc session của Claude Code CLI từ `~/.claude/projects/<slug>/<session-id>.jsonl`
//! và chuyển thành `ConversationSession` để hiển thị chung với session Antigravity.
//!
//! Các session được cache theo (mtime, size) nên chỉ parse lại khi file thay đổi.

use crate::models::{
    AgentStep, ChatTurnStreamState, CommandExecutionRecord, ConversationSession, FileTouchRecord,
    ModelQuotaBucket, ModelQuotaGroup, SessionStepsPageResponse, ToolCallInfo,
};
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant, UNIX_EPOCH};

/// Tên hiển thị của nhóm limit Claude Code trong danh sách quota
pub const CLAUDE_LIMIT_GROUP_PREFIX: &str = "Claude Code CLI";
/// Thời gian giữ kết quả limit trong cache (tránh gọi API usage quá dày)
const LIMITS_CACHE_TTL: Duration = Duration::from_secs(60);
const USAGE_URL: &str = "https://api.anthropic.com/api/oauth/usage";

struct LimitsCache {
    fetched_at: Instant,
    group: Option<ModelQuotaGroup>,
}

static LIMITS_CACHE: OnceLock<Mutex<Option<LimitsCache>>> = OnceLock::new();

fn limits_cache() -> &'static Mutex<Option<LimitsCache>> {
    LIMITS_CACHE.get_or_init(|| Mutex::new(None))
}

/// Xoá cache limit để lần lấy kế tiếp gọi lại API (dùng sau mỗi lượt chat Claude)
pub fn invalidate_limits_cache() {
    if let Ok(mut c) = limits_cache().lock() {
        *c = None;
    }
}

/// Đọc accessToken OAuth của Claude Code từ `~/.claude/.credentials.json`.
/// Trả về `(token, subscriptionType)`. Không ghi log token.
fn read_oauth_credentials() -> Result<(String, String), String> {
    let path = home_dir().join(".claude/.credentials.json");
    let raw = fs::read_to_string(&path)
        .map_err(|_| "Chưa đăng nhập Claude Code CLI (không tìm thấy credentials)".to_string())?;
    let v: Value = serde_json::from_str(&raw)
        .map_err(|_| "File credentials của Claude Code CLI không hợp lệ".to_string())?;
    let oauth = v
        .get("claudeAiOauth")
        .ok_or_else(|| "Không có thông tin OAuth của Claude Code CLI".to_string())?;
    let token = oauth
        .get("accessToken")
        .and_then(|x| x.as_str())
        .ok_or_else(|| "Thiếu accessToken của Claude Code CLI".to_string())?
        .to_string();
    let expires_at = oauth.get("expiresAt").and_then(|x| x.as_i64()).unwrap_or(0);
    let now_ms = chrono::Utc::now().timestamp_millis();
    if expires_at > 0 && expires_at <= now_ms {
        return Err("Token Claude đã hết hạn — mở Claude Code CLI một lần để làm mới".to_string());
    }
    let plan = oauth
        .get("subscriptionType")
        .and_then(|x| x.as_str())
        .unwrap_or("")
        .to_string();
    Ok((token, plan))
}

/// Gọi endpoint usage (cùng nguồn với `/usage` của Claude Code). Token được đưa qua stdin của curl
/// (`-K -`) để không lộ trên dòng lệnh.
fn fetch_usage_json(token: &str) -> Result<Value, String> {
    let config = format!(
        "header = \"Authorization: Bearer {}\"\nheader = \"anthropic-beta: oauth-2025-04-20\"\nuser-agent = \"muop-agent\"\n",
        token
    );
    let mut child = Command::new("curl")
        .args(["-s", "-m", "15", "-K", "-", USAGE_URL])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| format!("Không chạy được curl: {}", e))?;
    if let Some(mut stdin) = child.stdin.take() {
        let _ = stdin.write_all(config.as_bytes());
    }
    let out = child
        .wait_with_output()
        .map_err(|e| format!("curl lỗi: {}", e))?;
    let v: Value = serde_json::from_slice(&out.stdout)
        .map_err(|_| "Không đọc được phản hồi usage từ Anthropic".to_string())?;
    if v.get("error").is_some() {
        return Err("Anthropic từ chối yêu cầu usage (token có thể đã hết hiệu lực)".to_string());
    }
    Ok(v)
}

fn build_limit_group(usage: &Value, plan: &str) -> ModelQuotaGroup {
    let mut buckets = Vec::new();
    if let Some(items) = usage.get("limits").and_then(|x| x.as_array()) {
        for item in items {
            let kind = item.get("kind").and_then(|x| x.as_str()).unwrap_or("limit");
            let group = item.get("group").and_then(|x| x.as_str()).unwrap_or("");
            let percent = item.get("percent").and_then(|x| x.as_f64()).unwrap_or(0.0);
            let resets_at = item
                .get("resets_at")
                .and_then(|x| x.as_str())
                .unwrap_or("")
                .to_string();
            let is_active = item
                .get("is_active")
                .and_then(|x| x.as_bool())
                .unwrap_or(false);
            let remaining = (100.0 - percent).clamp(0.0, 100.0);
            let display_name = match kind {
                "session" => "Phiên 5 giờ".to_string(),
                "weekly_all" => "Tuần (tất cả model)".to_string(),
                other => other.replace('_', " "),
            };
            buckets.push(ModelQuotaBucket {
                bucket_id: kind.to_string(),
                display_name,
                description: format!(
                    "Đã dùng {:.0}%{}",
                    percent,
                    if is_active {
                        " · đang áp dụng"
                    } else {
                        ""
                    }
                ),
                window: if group == "session" {
                    "5h".to_string()
                } else {
                    "weekly".to_string()
                },
                remaining_fraction: remaining / 100.0,
                remaining_percent: remaining,
                reset_time: resets_at,
            });
        }
    }
    let plan_label = if plan.is_empty() {
        String::new()
    } else {
        format!(" ({})", plan)
    };
    ModelQuotaGroup {
        display_name: format!("{}{}", CLAUDE_LIMIT_GROUP_PREFIX, plan_label),
        description: "Limit tài khoản Claude đồng bộ từ Claude Code CLI".to_string(),
        buckets,
    }
}

fn fetch_limit_group_uncached() -> Option<ModelQuotaGroup> {
    let creds_path = home_dir().join(".claude/.credentials.json");
    if !creds_path.exists() {
        return None;
    }
    let group = match read_oauth_credentials() {
        Ok((token, plan)) => match fetch_usage_json(&token) {
            Ok(usage) => build_limit_group(&usage, &plan),
            Err(msg) => ModelQuotaGroup {
                display_name: format!("{} ({})", CLAUDE_LIMIT_GROUP_PREFIX, plan),
                description: msg,
                buckets: Vec::new(),
            },
        },
        Err(msg) => ModelQuotaGroup {
            display_name: CLAUDE_LIMIT_GROUP_PREFIX.to_string(),
            description: msg,
            buckets: Vec::new(),
        },
    };
    Some(group)
}

/// Limit Claude Code CLI dưới dạng `ModelQuotaGroup` để dùng chung luồng quota với Antigravity.
/// Kết quả được cache `LIMITS_CACHE_TTL`. Trả về `None` nếu chưa từng đăng nhập Claude Code CLI.
pub fn fetch_limit_group() -> Option<ModelQuotaGroup> {
    if let Ok(cache) = limits_cache().lock() {
        if let Some(c) = cache.as_ref() {
            if c.fetched_at.elapsed() < LIMITS_CACHE_TTL {
                return c.group.clone();
            }
        }
    }
    let group = fetch_limit_group_uncached();
    if let Ok(mut cache) = limits_cache().lock() {
        *cache = Some(LimitsCache {
            fetched_at: Instant::now(),
            group: group.clone(),
        });
    }
    group
}

/// Số file session tối đa được quét (mới nhất trước)
const MAX_SESSION_FILES: usize = 200;
/// Số step tối đa gửi kèm trong snapshot (giống session Antigravity)
const SNAPSHOT_STEP_LIMIT: usize = 100;

fn home_dir() -> PathBuf {
    PathBuf::from(std::env::var("HOME").unwrap_or_else(|_| "/home/john".to_string()))
}

pub fn projects_dir() -> PathBuf {
    home_dir().join(".claude/projects")
}

/// Đường dẫn binary `claude`. Ưu tiên biến môi trường `MUOP_CLAUDE_BIN`,
/// sau đó các vị trí cài đặt phổ biến, cuối cùng là tìm trong PATH.
pub fn claude_bin() -> String {
    if let Ok(p) = std::env::var("MUOP_CLAUDE_BIN") {
        if !p.trim().is_empty() {
            return p.trim().to_string();
        }
    }
    let home = home_dir();
    let candidates = [
        home.join(".local/bin/claude"),
        home.join(".nvm/versions/node/v22.21.1/bin/claude"),
        PathBuf::from("/usr/local/bin/claude"),
    ];
    for c in candidates.iter() {
        // `exists()` trả về false với symlink hỏng nên các đường dẫn hỏng sẽ bị bỏ qua
        if c.exists() {
            return c.to_string_lossy().to_string();
        }
    }
    "claude".to_string()
}

/// Chuẩn hoá tên model gửi xuống CLI. Các model cũ của Antigravity (gemini-*) hoặc rỗng
/// sẽ được đưa về alias mặc định `sonnet`.
pub fn normalize_model(raw: &str) -> String {
    let m = raw.trim();
    if m.is_empty() || m == "default" || m.starts_with("gemini") {
        return "sonnet".to_string();
    }
    m.to_string()
}

fn fingerprint(path: &Path) -> Option<(u64, u64)> {
    let meta = fs::metadata(path).ok()?;
    let mtime = meta
        .modified()
        .ok()?
        .duration_since(UNIX_EPOCH)
        .ok()?
        .as_millis() as u64;
    Some((mtime, meta.len()))
}

/// Liệt kê file session `.jsonl` mới nhất trong toàn bộ thư mục projects
fn list_session_files() -> Vec<(PathBuf, (u64, u64))> {
    let mut files: Vec<(PathBuf, (u64, u64))> = Vec::new();
    let Ok(dirs) = fs::read_dir(projects_dir()) else {
        return files;
    };
    for dir in dirs.flatten() {
        let Ok(entries) = fs::read_dir(dir.path()) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().and_then(|e| e.to_str()) != Some("jsonl") {
                continue;
            }
            if let Some(fp) = fingerprint(&path) {
                files.push((path, fp));
            }
        }
    }
    files.sort_by(|a, b| b.1 .0.cmp(&a.1 .0));
    files.truncate(MAX_SESSION_FILES);
    files
}

/// Tìm file `<session-id>.jsonl` trong các thư mục project
fn find_session_file(session_id: &str) -> Option<PathBuf> {
    if session_id.is_empty()
        || session_id.contains('/')
        || session_id.contains('\\')
        || session_id.contains("..")
    {
        return None;
    }
    let file_name = format!("{}.jsonl", session_id);
    let dirs = fs::read_dir(projects_dir()).ok()?;
    for dir in dirs.flatten() {
        let candidate = dir.path().join(&file_name);
        if candidate.is_file() {
            return Some(candidate);
        }
    }
    None
}

fn line_count(s: &str) -> usize {
    if s.is_empty() {
        0
    } else {
        s.lines().count()
    }
}

fn tool_summary(name: &str, args: &HashMap<String, Value>) -> String {
    let detail = ["file_path", "path", "command", "pattern", "description"]
        .iter()
        .find_map(|k| args.get(*k).and_then(|v| v.as_str()))
        .unwrap_or("");
    let detail: String = detail.chars().take(80).collect();
    if detail.is_empty() {
        name.to_string()
    } else {
        format!("{}: {}", name, detail)
    }
}

#[allow(clippy::too_many_arguments)]
fn make_step(
    index: usize,
    step_type: &str,
    source: &str,
    agent_name: &str,
    timestamp: String,
    content: String,
    thinking: String,
    tool_calls: Vec<ToolCallInfo>,
    input_tokens: u64,
    output_tokens: u64,
    cache_read_tokens: u64,
) -> AgentStep {
    let (vi_title, vi_detail) = if step_type == "USER_INPUT" {
        ("Yêu cầu của người dùng", "")
    } else {
        ("Phản hồi của Claude Code", "")
    };
    AgentStep {
        step_index: index,
        source: source.to_string(),
        step_type: step_type.to_string(),
        status: "DONE".to_string(),
        created_at: timestamp,
        content,
        thinking,
        tool_calls,
        input_tokens,
        output_tokens,
        cache_read_tokens,
        agent_name: agent_name.to_string(),
        phase: "completed".to_string(),
        vietnamese_title: vi_title.to_string(),
        vietnamese_detail: vi_detail.to_string(),
    }
}

/// Parse toàn bộ file session thành `ConversationSession` (đủ mọi step).
fn parse_session_file(path: &Path) -> Option<ConversationSession> {
    let session_id = path.file_stem()?.to_str()?.to_string();
    let content = fs::read_to_string(path).ok()?;

    let mut steps: Vec<AgentStep> = Vec::new();
    let mut files: Vec<FileTouchRecord> = Vec::new();
    let mut commands: Vec<CommandExecutionRecord> = Vec::new();
    let mut ai_title: Option<String> = None;
    let mut cwd = String::new();
    let mut first_ts: Option<String> = None;
    let mut last_ts: Option<String> = None;
    let mut counted_message_ids: HashSet<String> = HashSet::new();
    let (mut total_in, mut total_out, mut total_cache) = (0u64, 0u64, 0u64);
    let mut first_user_text = String::new();

    for line in content.lines() {
        let Ok(v) = serde_json::from_str::<Value>(line) else {
            continue;
        };
        // Bỏ qua hội thoại của subagent (sidechain) để không trộn vào luồng chính
        if v.get("isSidechain")
            .and_then(|x| x.as_bool())
            .unwrap_or(false)
        {
            continue;
        }
        if cwd.is_empty() {
            if let Some(c) = v.get("cwd").and_then(|x| x.as_str()) {
                cwd = c.to_string();
            }
        }
        let ts = v
            .get("timestamp")
            .and_then(|x| x.as_str())
            .map(|s| s.to_string());
        if let Some(t) = &ts {
            if first_ts.is_none() {
                first_ts = Some(t.clone());
            }
            last_ts = Some(t.clone());
        }
        let ts_str = ts.clone().unwrap_or_default();

        match v.get("type").and_then(|x| x.as_str()).unwrap_or("") {
            "ai-title" => {
                if let Some(t) = v.get("aiTitle").and_then(|x| x.as_str()) {
                    ai_title = Some(t.to_string());
                }
            }
            "user" => {
                if v.get("isMeta").and_then(|x| x.as_bool()).unwrap_or(false) {
                    continue;
                }
                let Some(msg) = v.get("message") else {
                    continue;
                };
                // Chỉ lấy text do người dùng gõ; các block tool_result được bỏ qua
                let texts: Vec<String> = match msg.get("content") {
                    Some(Value::String(s)) => vec![s.clone()],
                    Some(Value::Array(blocks)) => blocks
                        .iter()
                        .filter(|b| b.get("type").and_then(|x| x.as_str()) == Some("text"))
                        .filter_map(|b| b.get("text").and_then(|x| x.as_str()).map(String::from))
                        .collect(),
                    _ => Vec::new(),
                };
                let text = texts.join("\n").trim().to_string();
                if text.is_empty() {
                    continue;
                }
                // Bỏ qua các text bọc trong tag hệ thống (<ide_selection>, <command-name>...) khi lấy tiêu đề
                if first_user_text.is_empty() && !text.starts_with('<') {
                    first_user_text = text.clone();
                }
                let idx = steps.len();
                steps.push(make_step(
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
                ));
            }
            "assistant" => {
                let Some(msg) = v.get("message") else {
                    continue;
                };
                let idx = steps.len();

                // Claude ghi mỗi content block thành một dòng riêng cùng message.id,
                // usage chỉ được cộng một lần cho mỗi message.id.
                let msg_id = msg
                    .get("id")
                    .and_then(|x| x.as_str())
                    .unwrap_or("")
                    .to_string();
                let first_time_for_message =
                    msg_id.is_empty() || counted_message_ids.insert(msg_id);
                let (mut inp, mut out, mut cache) = (0u64, 0u64, 0u64);
                if first_time_for_message {
                    if let Some(u) = msg.get("usage") {
                        inp = u.get("input_tokens").and_then(|x| x.as_u64()).unwrap_or(0);
                        out = u.get("output_tokens").and_then(|x| x.as_u64()).unwrap_or(0);
                        cache = u
                            .get("cache_read_input_tokens")
                            .and_then(|x| x.as_u64())
                            .unwrap_or(0);
                        total_in += inp;
                        total_out += out;
                        total_cache += cache;
                    }
                }

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
                                    .map(|o| {
                                        o.iter().map(|(k, v)| (k.clone(), v.clone())).collect()
                                    })
                                    .unwrap_or_default();
                                let target_path = ["file_path", "notebook_path", "path"]
                                    .iter()
                                    .find_map(|k| args.get(*k).and_then(|x| x.as_str()))
                                    .map(String::from);
                                record_side_effects(
                                    &name,
                                    &args,
                                    idx,
                                    &ts_str,
                                    &mut files,
                                    &mut commands,
                                );
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
                    continue;
                }
                steps.push(make_step(
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
                ));
            }
            _ => {}
        }
    }

    let fallback_time = fingerprint(path)
        .map(|(ms, _)| {
            chrono::DateTime::<chrono::Utc>::from(UNIX_EPOCH + std::time::Duration::from_millis(ms))
                .to_rfc3339()
        })
        .unwrap_or_default();
    let created_at = first_ts.clone().unwrap_or_else(|| fallback_time.clone());
    let updated_at = last_ts.unwrap_or(fallback_time);

    let title = match ai_title {
        Some(t) if !t.trim().is_empty() => t.trim().to_string(),
        _ => {
            let fallback: String = first_user_text.chars().take(60).collect();
            if fallback.trim().is_empty() {
                "Phiên Claude Code".to_string()
            } else {
                fallback.replace('\n', " ")
            }
        }
    };

    let project_path = if cwd.is_empty() {
        path.parent()
            .map(|p| p.to_string_lossy().to_string())
            .unwrap_or_default()
    } else {
        cwd
    };
    let project_name = Path::new(&project_path)
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("")
        .to_string();

    files.sort_by(|a, b| b.timestamp.cmp(&a.timestamp));
    files.truncate(100);
    commands.sort_by(|a, b| b.timestamp.cmp(&a.timestamp));
    commands.truncate(50);

    Some(ConversationSession {
        id: session_id,
        title,
        created_at,
        updated_at,
        status: "completed".to_string(),
        current_phase: "completed".to_string(),
        steps,
        subagent_lanes: Vec::new(),
        files_touched: files,
        commands_run: commands,
        total_input_tokens: total_in,
        total_output_tokens: total_out,
        total_cache_tokens: total_cache,
        project_name,
        project_path,
        is_simulated: false,
        pending_plans: Vec::new(),
        git_sync_status: None,
        is_interrupted: false,
        interrupted_reason: None,
        custom_agents: Vec::new(),
        available_agents: Vec::new(),
        has_parallel_flow: false,
        source: "claude-cli".to_string(),
    })
}

fn record_side_effects(
    name: &str,
    args: &HashMap<String, Value>,
    step_index: usize,
    timestamp: &str,
    files: &mut Vec<FileTouchRecord>,
    commands: &mut Vec<CommandExecutionRecord>,
) {
    let str_arg = |k: &str| args.get(k).and_then(|v| v.as_str()).unwrap_or("");
    match name {
        "Edit" | "MultiEdit" | "Write" | "NotebookEdit" => {
            let path = {
                let p = str_arg("file_path");
                if p.is_empty() {
                    str_arg("notebook_path")
                } else {
                    p
                }
            };
            if path.is_empty() {
                return;
            }
            let (added, removed, action) = match name {
                "Write" => (line_count(str_arg("content")), 0, "created"),
                "Edit" => (
                    line_count(str_arg("new_string")),
                    line_count(str_arg("old_string")),
                    "modified",
                ),
                _ => (line_count(str_arg("new_source")), 0, "modified"),
            };
            files.push(FileTouchRecord {
                path: path.to_string(),
                action: action.to_string(),
                repo: String::new(),
                agent_name: "Coordinator".to_string(),
                step_index,
                timestamp: timestamp.to_string(),
                added_lines: added,
                removed_lines: removed,
                diff_preview: String::new(),
            });
        }
        "Bash" => {
            let cmd = str_arg("command");
            if cmd.is_empty() {
                return;
            }
            commands.push(CommandExecutionRecord {
                command_line: cmd.to_string(),
                summary: str_arg("description").to_string(),
                agent_name: "Coordinator".to_string(),
                step_index,
                timestamp: timestamp.to_string(),
                output_preview: String::new(),
                is_success: true,
            });
        }
        _ => {}
    }
}

/// Cache session đã parse: chỉ giữ `SNAPSHOT_STEP_LIMIT` step cuối để giới hạn RAM.
struct CachedSession {
    fingerprint: (u64, u64),
    session: ConversationSession,
}

static CACHE: OnceLock<Mutex<HashMap<PathBuf, CachedSession>>> = OnceLock::new();

fn cache() -> &'static Mutex<HashMap<PathBuf, CachedSession>> {
    CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

fn trim_for_snapshot(mut session: ConversationSession) -> ConversationSession {
    let total = session.steps.len();
    if total > SNAPSHOT_STEP_LIMIT {
        session.steps = session.steps.split_off(total - SNAPSHOT_STEP_LIMIT);
    }
    session
}

/// Lấy session từ cache nếu file không đổi, ngược lại parse lại.
fn load_cached(path: &Path, fp: (u64, u64)) -> Option<ConversationSession> {
    if let Ok(map) = cache().lock() {
        if let Some(entry) = map.get(path) {
            if entry.fingerprint == fp {
                return Some(entry.session.clone());
            }
        }
    }
    let session = trim_for_snapshot(parse_session_file(path)?);
    if let Ok(mut map) = cache().lock() {
        map.insert(
            path.to_path_buf(),
            CachedSession {
                fingerprint: fp,
                session: session.clone(),
            },
        );
    }
    Some(session)
}

fn apply_live_status(
    mut session: ConversationSession,
    active_streams: &HashMap<String, ChatTurnStreamState>,
) -> ConversationSession {
    let running = active_streams
        .get(&session.id)
        .map(|s| s.is_running)
        .unwrap_or(false);
    if running {
        session.status = "running".to_string();
        session.current_phase = "running".to_string();
    }
    session
}

/// Danh sách session Claude Code (đã áp trạng thái đang chạy từ active_streams)
pub fn scan_sessions(
    active_streams: &HashMap<String, ChatTurnStreamState>,
) -> Vec<ConversationSession> {
    let files = list_session_files();
    // Loại bỏ cache của các file đã không còn
    if let Ok(mut map) = cache().lock() {
        let alive: HashSet<&PathBuf> = files.iter().map(|(p, _)| p).collect();
        map.retain(|p, _| alive.contains(p));
    }
    files
        .iter()
        .filter_map(|(path, fp)| load_cached(path, *fp))
        .filter(|s| !s.steps.is_empty())
        .map(|s| apply_live_status(s, active_streams))
        .collect()
}

/// Chi tiết một session (với tối đa `SNAPSHOT_STEP_LIMIT` step cuối)
pub fn get_session(
    session_id: &str,
    active_streams: &HashMap<String, ChatTurnStreamState>,
) -> Option<ConversationSession> {
    let path = find_session_file(session_id)?;
    let fp = fingerprint(&path)?;
    load_cached(&path, fp).map(|s| apply_live_status(s, active_streams))
}

/// Phân trang step theo cùng quy ước với Antigravity: lấy `limit` step ngay trước `before_step`.
pub fn get_steps_page(
    session_id: &str,
    before_step: Option<usize>,
    limit: usize,
) -> Option<SessionStepsPageResponse> {
    let path = find_session_file(session_id)?;
    let full = parse_session_file(&path)?;
    let total_steps = full.steps.len();
    let candidates: Vec<&AgentStep> = full
        .steps
        .iter()
        .filter(|s| before_step.map_or(true, |b| s.step_index < b))
        .collect();
    let take = limit.min(candidates.len());
    let start = candidates.len() - take;
    let page: Vec<AgentStep> = candidates[start..].iter().map(|s| (*s).clone()).collect();
    let earliest = page.first().map(|s| s.step_index).unwrap_or(0);
    Some(SessionStepsPageResponse {
        session_id: session_id.to_string(),
        steps: page,
        has_more: earliest > 0,
        earliest_step_index: earliest,
        total_steps,
    })
}

/// Kết quả so sánh thay đổi file session Claude Code giữa hai lần quét
#[derive(Debug, Default)]
pub struct ClaudeChanges {
    pub changed_ids: Vec<String>,
    pub removed: bool,
    pub added: bool,
}

/// So sánh fingerprint hiện tại với lần trước (lưu trong `fingerprints`)
pub fn detect_changes(fingerprints: &mut HashMap<String, (u64, u64)>) -> ClaudeChanges {
    let mut changes = ClaudeChanges::default();
    let mut seen: HashSet<String> = HashSet::new();
    for (path, fp) in list_session_files() {
        let Some(id) = path.file_stem().and_then(|s| s.to_str()).map(String::from) else {
            continue;
        };
        seen.insert(id.clone());
        match fingerprints.get(&id) {
            Some(prev) if *prev == fp => {}
            Some(_) => changes.changed_ids.push(id.clone()),
            None => {
                changes.added = true;
                changes.changed_ids.push(id.clone());
            }
        }
        fingerprints.insert(id, fp);
    }
    let before = fingerprints.len();
    fingerprints.retain(|id, _| seen.contains(id));
    if fingerprints.len() != before {
        changes.removed = true;
    }
    changes
}
