use crate::claude_code;
use crate::models::{
    AgentMonitorSnapshot, AgentStep, ChatTurnStreamState, CommandExecutionRecord,
    ConversationSession, CustomAgentSpec, FileTouchRecord, GitSyncStatus, ModelQuotaBucket,
    ModelQuotaGroup, PlanArtifactInfo, ProjectWorkspace, SessionStepsPageResponse, SubagentLane,
    ToolCallInfo,
};
use chrono::{DateTime, Utc};
use regex::Regex;
use rusqlite::{Connection, OpenFlags};
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::{Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant, SystemTime};

pub const DEFAULT_PORT: u16 = 8787;
pub const BRAIN_DIR_PATH: &str = "/home/john/.gemini/antigravity/brain";
pub const DAEMON_DIR_PATH: &str = "/home/john/.gemini/antigravity/daemon";
pub const SUMMARY_DB_PATH: &str = "/home/john/.gemini/antigravity/conversation_summaries.db";
pub const ECOSYSTEM_DIR_PATH: &str = "/home/john/Documents/muop-ecosystem";
#[allow(dead_code)]
pub const AGENTS_CONFIG_DIR_PATH: &str =
    "/home/john/Documents/muop-ecosystem/muop-erp-server/.agents";

/// Danh sách model gửi xuống UI. Id có tiền tố provider để chọn đúng backend:
/// - `agy:<model>` → Antigravity CLI (`agy`)
/// - `claude-cli:<model-id>` → Claude Code CLI (`claude --model <model-id>`, ID đầy đủ có version)
pub fn default_models() -> Vec<String> {
    let mut models = vec![
        "claude-cli:claude-sonnet-5-5".to_string(),
        "claude-cli:claude-opus-5-5".to_string(),
        "claude-cli:claude-haiku-5-5".to_string(),
    ];
    models.extend(agy_models());
    models
}

/// Model dự phòng của Antigravity, dùng khi `agy models` không chạy được
const AGY_FALLBACK_MODELS: &[&str] = &[
    "gemini-3.8-flash-high",
    "gemini-3.8-flash-medium",
    "claude-sonnet-5-5-high",
    "claude-opus-5-5-high",
    "gemini-4-argon-high",
    "gemini-4-argon-medium",
];

const AGY_MODELS_TTL: Duration = Duration::from_secs(600);

struct AgyModelsCache {
    fetched_at: Option<Instant>,
    /// Sau khi `agy models` lỗi, chỉ thử lại sau mốc này
    retry_at: Option<Instant>,
    ids: Vec<String>,
    refreshing: bool,
}

static AGY_MODELS: OnceLock<Mutex<AgyModelsCache>> = OnceLock::new();

fn agy_models_cache() -> &'static Mutex<AgyModelsCache> {
    AGY_MODELS.get_or_init(|| {
        Mutex::new(AgyModelsCache {
            fetched_at: None,
            retry_at: None,
            ids: AGY_FALLBACK_MODELS
                .iter()
                .map(|m| format!("agy:{}", m))
                .collect(),
            refreshing: false,
        })
    })
}

/// Đọc output của `agy models` (mỗi dòng `<id>\t<tên hiển thị>`) thành danh sách `agy:<id>`
fn parse_agy_models(output: &str) -> Vec<String> {
    output
        .lines()
        .filter_map(|line| {
            let (id, _label) = line.split_once('\t')?;
            let id = id.trim();
            let valid = !id.is_empty()
                && id
                    .chars()
                    .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '.' | '_'));
            valid.then(|| format!("agy:{}", id))
        })
        .collect()
}

fn run_agy_models() -> Option<Vec<String>> {
    let output = Command::new(crate::chat::agy_bin())
        .arg("models")
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let ids = parse_agy_models(&String::from_utf8_lossy(&output.stdout));
    (!ids.is_empty()).then_some(ids)
}

/// Danh sách model Antigravity lấy từ `agy models`. Trả về ngay bản đã cache (hoặc dự phòng),
/// và làm mới nền khi cache quá 10 phút, để không chặn snapshot khi CLI chậm.
fn agy_models() -> Vec<String> {
    let Ok(mut cache) = agy_models_cache().lock() else {
        return AGY_FALLBACK_MODELS.iter().map(|m| format!("agy:{}", m)).collect();
    };
    let now = Instant::now();
    let stale = cache
        .fetched_at
        .map(|t| now.duration_since(t) >= AGY_MODELS_TTL)
        .unwrap_or(true);
    let retry_ok = cache.retry_at.map(|t| now >= t).unwrap_or(true);
    if stale && retry_ok && !cache.refreshing {
        cache.refreshing = true;
        std::thread::spawn(|| {
            let fetched = run_agy_models();
            if let Ok(mut cache) = agy_models_cache().lock() {
                match fetched {
                    Some(ids) => {
                        cache.ids = ids;
                        cache.fetched_at = Some(Instant::now());
                        cache.retry_at = None;
                    }
                    // Lỗi: giữ danh sách cũ và chỉ thử lại sau 1 phút
                    None => cache.retry_at = Some(Instant::now() + Duration::from_secs(60)),
                }
                cache.refreshing = false;
            }
        });
    }
    cache.ids.clone()
}

pub fn default_agents() -> Vec<String> {
    vec!["Coordinator".to_string()]
}

#[derive(Debug, Clone)]
struct DbConversationMeta {
    pub title: String,
    pub project_name: String,
    pub project_path: String,
    #[allow(dead_code)]
    pub status: String,
    pub parent_id: String,
    pub agent_name: String,
}

#[derive(Debug, Clone)]
struct SpawnedSubagentMeta {
    pub id: String,
    pub name: String,
    pub role: String,
    pub prompt: String,
    pub step_index: usize,
    pub status: String,
    pub last_action: String,
    pub tool_name: String,
}

#[derive(Debug, Clone)]
struct ParsedTranscript {
    pub id: String,
    pub title: String,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub status: String,
    pub current_phase: String,
    pub steps: Vec<AgentStep>,
    pub files_touched: Vec<FileTouchRecord>,
    pub commands_run: Vec<CommandExecutionRecord>,
    pub spawned_subagents: Vec<SpawnedSubagentMeta>,
    pub total_input_tokens: u64,
    pub total_output_tokens: u64,
    pub total_cache_tokens: u64,
    pub project_name: String,
    pub project_path: String,
    pub total_steps: usize,
}

pub fn detect_hostname() -> String {
    if let Ok(h) = fs::read_to_string("/etc/hostname") {
        let trimmed = h.trim().to_string();
        if !trimmed.is_empty() {
            return trimmed;
        }
    }
    "linux-pc".to_string()
}

pub fn detect_lan_ips() -> Vec<String> {
    let mut ips = Vec::new();
    if let Ok(out) = Command::new("hostname").arg("-I").output() {
        if out.status.success() {
            let text = String::from_utf8_lossy(&out.stdout);
            for part in text.split_whitespace() {
                if part.contains(':') {
                    continue; // Skip IPv6
                }
                if part.starts_with("172.17.")
                    || part.starts_with("172.18.")
                    || part.starts_with("172.19.")
                    || part.starts_with("127.")
                {
                    continue;
                }
                if !ips.contains(&part.to_string()) {
                    ips.push(part.to_string());
                }
            }
        }
    }
    if ips.is_empty() {
        ips.push("192.168.31.96".to_string());
    }
    ips
}

/// Quét toàn bộ /proc để tìm danh sách các conversation_id của các tiến trình agy CLI đang thực sự chạy trên hệ thống
pub fn scan_running_agy_conversations() -> std::collections::HashSet<String> {
    let mut running_ids = std::collections::HashSet::new();
    let proc_dir = match fs::read_dir("/proc") {
        Ok(d) => d,
        Err(_) => return running_ids,
    };

    for entry in proc_dir.flatten() {
        let file_name = entry.file_name();
        let name_str = file_name.to_string_lossy();
        if !name_str.chars().all(|c| c.is_ascii_digit()) {
            continue;
        }

        let cmdline_path = entry.path().join("cmdline");
        if let Ok(bytes) = fs::read(&cmdline_path) {
            let cmdline = String::from_utf8_lossy(&bytes);
            if cmdline.contains("agy") && cmdline.contains("--conversation") {
                let parts: Vec<&str> = cmdline.split('\0').collect();
                for i in 0..parts.len() {
                    if parts[i] == "--conversation" && i + 1 < parts.len() {
                        let cid = parts[i + 1].trim();
                        if !cid.is_empty() {
                            running_ids.insert(cid.to_string());
                        }
                    } else if let Some(rest) = parts[i].strip_prefix("--conversation=") {
                        let cid = rest.trim();
                        if !cid.is_empty() {
                            running_ids.insert(cid.to_string());
                        }
                    }
                }
            }
        }
    }
    running_ids
}

/// Bộ theo dõi dấu vết thay đổi từng session độc lập để phát event nhỏ gọn (Granular Events)
#[derive(Debug, Clone, Default)]
pub struct SessionChangeTracker {
    pub transcript_fingerprints: HashMap<String, (u64, u64)>, // id -> (mtime_ms, file_size)
    pub sqlite_mtime: u64,
    /// Fingerprint (mtime, size) của các file session Claude Code CLI
    pub claude_fingerprints: HashMap<String, (u64, u64)>,
}

pub fn init_session_change_tracker() -> SessionChangeTracker {
    let mut tracker = SessionChangeTracker::default();
    let brain_dir = Path::new(BRAIN_DIR_PATH);
    if let Ok(entries) = fs::read_dir(brain_dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                if let Some(id) = path.file_name().and_then(|n| n.to_str()) {
                    if id != "tempmediaStorage" && !id.starts_with('.') {
                        let transcript_path = path.join(".system_generated/logs/transcript.jsonl");
                        if let Ok(meta) = fs::metadata(&transcript_path) {
                            let mtime = meta
                                .modified()
                                .unwrap_or(SystemTime::UNIX_EPOCH)
                                .duration_since(SystemTime::UNIX_EPOCH)
                                .map(|d| d.as_millis() as u64)
                                .unwrap_or(0);
                            let size = meta.len();
                            tracker.transcript_fingerprints.insert(id.to_string(), (mtime, size));
                        }
                    }
                }
            }
        }
    }

    if let Ok(meta) = fs::metadata(SUMMARY_DB_PATH) {
        tracker.sqlite_mtime = meta
            .modified()
            .unwrap_or(SystemTime::UNIX_EPOCH)
            .duration_since(SystemTime::UNIX_EPOCH)
            .map(|d| d.as_millis() as u64)
            .unwrap_or(0);
    }

    tracker
}

/// Kết quả phát hiện thay đổi của watcher: mỗi loại thay đổi map vào một event riêng
#[derive(Debug, Clone, Default)]
pub struct DetectedChanges {
    /// Các conversation top-level có thay đổi -> `session:update` cho từng conversation
    pub changed_sessions: Vec<String>,
    /// Có conversation bị xoá khỏi đĩa -> cần `snapshot:update` để client đồng bộ lại toàn bộ
    pub sessions_removed: bool,
    /// Metadata project thay đổi -> `projects:update`
    pub projects_changed: bool,
}

/// Xoá cache quota để lần fetch kế tiếp lấy dữ liệu mới nhất từ daemon
pub fn invalidate_quota_cache() {
    claude_code::invalidate_limits_cache();
    if let Some(cache) = QUOTA_CACHE.get() {
        if let Ok(mut guard) = cache.lock() {
            guard.0 = Instant::now() - Duration::from_secs(3600);
        }
    }
}

/// Phát hiện danh sách các conversation có thay đổi thực tế (chỉ scan và gửi event mỗi conversation đó)
pub fn detect_changed_sessions(tracker: &mut SessionChangeTracker) -> DetectedChanges {
    let mut changed_top_ids = HashSet::new();
    let mut projects_changed = false;
    let mut seen_ids: HashSet<String> = HashSet::new();

    let brain_dir = Path::new(BRAIN_DIR_PATH);
    if !brain_dir.exists() {
        return DetectedChanges::default();
    }

    let db_meta_map = load_conversation_summary_meta();

    // Map to quickly find parent ID for subagents
    let mut child_to_parent: HashMap<String, String> = HashMap::new();
    let mut subagent_ids: HashSet<String> = HashSet::new();
    for (id, m) in &db_meta_map {
        if !m.parent_id.is_empty() {
            child_to_parent.insert(id.clone(), m.parent_id.clone());
            subagent_ids.insert(id.clone());
        } else if !m.agent_name.is_empty()
            && m.agent_name != "Coordinator"
            && m.agent_name != "user"
        {
            subagent_ids.insert(id.clone());
        }
    }

    // 1. Quét các directory trong brain
    if let Ok(entries) = fs::read_dir(brain_dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            if !path.is_dir() {
                continue;
            }
            let id = match path.file_name().and_then(|n| n.to_str()) {
                Some(s) => s.to_string(),
                None => continue,
            };
            if id == "tempmediaStorage" || id.starts_with('.') {
                continue;
            }

            let transcript_path = path.join(".system_generated/logs/transcript.jsonl");
            if let Ok(meta) = fs::metadata(&transcript_path) {
                seen_ids.insert(id.clone());
                let mtime = meta
                    .modified()
                    .unwrap_or(SystemTime::UNIX_EPOCH)
                    .duration_since(SystemTime::UNIX_EPOCH)
                    .map(|d| d.as_millis() as u64)
                    .unwrap_or(0);
                let size = meta.len();

                let changed = match tracker.transcript_fingerprints.get(&id) {
                    Some(&(old_mtime, old_size)) => old_mtime != mtime || old_size != size,
                    None => true,
                };

                if changed {
                    tracker.transcript_fingerprints.insert(id.clone(), (mtime, size));
                    // Nếu id là subagent, trigger cập nhật session cha
                    if let Some(parent) = child_to_parent.get(&id) {
                        changed_top_ids.insert(parent.clone());
                    } else if !subagent_ids.contains(&id) {
                        // Nếu là top-level session
                        changed_top_ids.insert(id.clone());
                    }
                }
            }
        }
    }

    // 1b. Phát hiện conversation đã bị xoá khỏi đĩa
    let before = tracker.transcript_fingerprints.len();
    tracker
        .transcript_fingerprints
        .retain(|id, _| seen_ids.contains(id));
    let mut sessions_removed = tracker.transcript_fingerprints.len() != before;

    // 1c. Session của Claude Code CLI
    let claude_changes = claude_code::detect_changes(&mut tracker.claude_fingerprints);
    changed_top_ids.extend(claude_changes.changed_ids);
    if claude_changes.removed {
        sessions_removed = true;
    }
    if claude_changes.added {
        projects_changed = true;
    }

    // 2. Kiểm tra SQLite db mtime
    let db_path = Path::new(SUMMARY_DB_PATH);
    if let Ok(meta) = fs::metadata(db_path) {
        let db_mtime = meta
            .modified()
            .unwrap_or(SystemTime::UNIX_EPOCH)
            .duration_since(SystemTime::UNIX_EPOCH)
            .map(|d| d.as_millis() as u64)
            .unwrap_or(0);
        if tracker.sqlite_mtime != db_mtime {
            tracker.sqlite_mtime = db_mtime;
            for (id, m) in &db_meta_map {
                if m.parent_id.is_empty()
                    && (m.agent_name.is_empty() || m.agent_name == "Coordinator")
                {
                    if !tracker.transcript_fingerprints.contains_key(id) {
                        changed_top_ids.insert(id.clone());
                    }
                }
            }
            projects_changed = true;
        }
    }

    DetectedChanges {
        changed_sessions: changed_top_ids.into_iter().collect(),
        sessions_removed,
        projects_changed,
    }
}

pub fn build_full_snapshot(
    active_streams: &HashMap<String, ChatTurnStreamState>,
    active_id: Option<&str>,
    max_sessions: usize,
) -> AgentMonitorSnapshot {
    let limit = if max_sessions == 0 { 500 } else { max_sessions };
    let sessions = scan_all_sessions(active_streams, active_id, limit);
    let custom_agents = load_custom_agent_specs();
    let projects = discover_projects(&sessions);
    let hostname = detect_hostname();
    let lan_ips = detect_lan_ips();
    let model_quotas = fetch_all_model_quotas();

    AgentMonitorSnapshot {
        sessions,
        custom_agents,
        projects,
        available_models: default_models(),
        available_agents: default_agents(),
        active_streams: active_streams.clone(),
        model_quotas,
        hostname,
        lan_ips,
        port: DEFAULT_PORT,
        timestamp: Utc::now().to_rfc3339(),
    }
}

static QUOTA_CACHE: OnceLock<Mutex<(Instant, Vec<ModelQuotaGroup>)>> = OnceLock::new();

/// Toàn bộ quota/limit hiển thị trên UI: Antigravity + limit tài khoản Claude Code CLI
pub fn fetch_all_model_quotas() -> Vec<ModelQuotaGroup> {
    let mut groups = fetch_antigravity_model_quotas();
    if let Some(claude) = claude_code::fetch_limit_group() {
        groups.push(claude);
    }
    groups
}

pub fn fetch_antigravity_model_quotas() -> Vec<ModelQuotaGroup> {
    let cache = QUOTA_CACHE.get_or_init(|| {
        Mutex::new((
            Instant::now() - Duration::from_secs(60),
            default_fallback_quotas(),
        ))
    });

    if let Ok(guard) = cache.lock() {
        if guard.0.elapsed() < Duration::from_secs(10) && !guard.1.is_empty() {
            return guard.1.clone();
        }
    }

    if let Some(live) = query_daemon_quota_summary() {
        if !live.is_empty() {
            if let Ok(mut guard) = cache.lock() {
                *guard = (Instant::now(), live.clone());
            }
            return live;
        }
    }

    if let Ok(guard) = cache.lock() {
        return guard.1.clone();
    }
    default_fallback_quotas()
}

fn query_daemon_quota_summary() -> Option<Vec<ModelQuotaGroup>> {
    let entries = fs::read_dir(DAEMON_DIR_PATH).ok()?;
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().to_string();
        if !name.starts_with("hub_") || !name.ends_with(".json") {
            continue;
        }
        let raw = fs::read_to_string(entry.path()).ok()?;
        let val: Value = serde_json::from_str(&raw).ok()?;
        let port = val.get("httpPort").and_then(|v| v.as_u64())? as u16;
        let csrf = val
            .get("csrfToken")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        if port == 0 || csrf.is_empty() {
            continue;
        }
        if let Some(groups) = call_retrieve_user_quota_summary(port, &csrf) {
            if !groups.is_empty() {
                return Some(groups);
            }
        }
    }
    None
}

fn call_retrieve_user_quota_summary(port: u16, csrf_token: &str) -> Option<Vec<ModelQuotaGroup>> {
    let addr = SocketAddr::from(([127, 0, 0, 1], port));
    let mut stream = TcpStream::connect_timeout(&addr, Duration::from_millis(600)).ok()?;
    let _ = stream.set_read_timeout(Some(Duration::from_millis(900)));
    let _ = stream.set_write_timeout(Some(Duration::from_millis(600)));

    let req = format!(
        "POST /exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary HTTP/1.1\r\n\
         Host: 127.0.0.1:{}\r\n\
         Content-Type: application/json\r\n\
         Connect-Protocol-Version: 1\r\n\
         x-codeium-csrf-token: {}\r\n\
         Content-Length: 2\r\n\
         Connection: close\r\n\r\n{{}}",
        port, csrf_token
    );

    stream.write_all(req.as_bytes()).ok()?;
    let mut resp_bytes = Vec::new();
    stream.read_to_end(&mut resp_bytes).ok()?;
    let resp_str = String::from_utf8_lossy(&resp_bytes);
    let (_, body) = resp_str.split_once("\r\n\r\n")?;
    let body_trimmed = body.trim();
    // Handle chunked or direct JSON
    let json_start = body_trimmed.find('{')?;
    let json_end = body_trimmed.rfind('}')?;
    let json_slice = &body_trimmed[json_start..=json_end];

    let root: Value = serde_json::from_str(json_slice).ok()?;
    let groups_arr = root
        .get("response")
        .and_then(|r| r.get("groups"))
        .and_then(|g| g.as_array())?;

    let mut result = Vec::new();
    for g in groups_arr {
        let display_name = g
            .get("displayName")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        let description = g
            .get("description")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        let mut buckets = Vec::new();
        if let Some(b_arr) = g.get("buckets").and_then(|v| v.as_array()) {
            for b in b_arr {
                let bucket_id = b
                    .get("bucketId")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string();
                let b_name = b
                    .get("displayName")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string();
                let b_desc = b
                    .get("description")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string();
                let window = b
                    .get("window")
                    .and_then(|v| v.as_str())
                    .unwrap_or("weekly")
                    .to_string();
                let frac = b
                    .get("remainingFraction")
                    .and_then(|v| v.as_f64())
                    .unwrap_or(1.0)
                    .clamp(0.0, 1.0);
                let pct = (frac * 100.0).round();
                let reset_time = b
                    .get("resetTime")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string();
                buckets.push(ModelQuotaBucket {
                    bucket_id,
                    display_name: b_name,
                    description: b_desc,
                    window,
                    remaining_fraction: frac,
                    remaining_percent: pct,
                    reset_time,
                });
            }
        }
        result.push(ModelQuotaGroup {
            display_name,
            description,
            buckets,
        });
    }
    Some(result)
}

fn default_fallback_quotas() -> Vec<ModelQuotaGroup> {
    vec![
        ModelQuotaGroup {
            display_name: "Gemini Models".to_string(),
            description: "Models within this group: Gemini Flash, Gemini Pro".to_string(),
            buckets: vec![
                ModelQuotaBucket {
                    bucket_id: "gemini-weekly".to_string(),
                    display_name: "Weekly Limit Remaining".to_string(),
                    description: "Weekly limit remaining".to_string(),
                    window: "weekly".to_string(),
                    remaining_fraction: 0.70,
                    remaining_percent: 70.0,
                    reset_time: String::new(),
                },
                ModelQuotaBucket {
                    bucket_id: "gemini-5h".to_string(),
                    display_name: "Five Hour Limit Remaining".to_string(),
                    description: "5-hour limit remaining".to_string(),
                    window: "5h".to_string(),
                    remaining_fraction: 0.95,
                    remaining_percent: 95.0,
                    reset_time: String::new(),
                },
            ],
        },
    ]
}

fn load_conversation_summary_meta() -> HashMap<String, DbConversationMeta> {
    let mut map = HashMap::new();
    if !Path::new(SUMMARY_DB_PATH).exists() {
        return map;
    }

    let conn = match Connection::open_with_flags(
        SUMMARY_DB_PATH,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    ) {
        Ok(c) => c,
        Err(_) => return map,
    };

    let mut stmt = match conn.prepare(
        "SELECT conversation_id, COALESCE(title, ''), COALESCE(workspace_uris, '[]'), COALESCE(status, ''), COALESCE(parent_conversation_id, ''), COALESCE(agent_name, '') FROM conversation_summaries",
    ) {
        Ok(s) => s,
        Err(_) => return map,
    };

    let rows = stmt.query_map([], |row| {
        let id: String = row.get(0)?;
        let title: String = row.get(1)?;
        let uris_raw: String = row.get(2)?;
        let status: String = row.get(3)?;
        let parent_id: String = row.get(4)?;
        let agent_name: String = row.get(5)?;
        Ok((id, title, uris_raw, status, parent_id, agent_name))
    });

    if let Ok(iter) = rows {
        for item in iter.flatten() {
            let (id, title, uris_raw, status, parent_id, agent_name) = item;
            let (project_name, project_path) = resolve_project_from_workspace_uris(&uris_raw);
            map.insert(
                id,
                DbConversationMeta {
                    title: title.trim().to_string(),
                    project_name,
                    project_path,
                    status,
                    parent_id: parent_id.trim().to_string(),
                    agent_name: agent_name.trim().to_string(),
                },
            );
        }
    }

    map
}

fn resolve_project_from_workspace_uris(uris_json: &str) -> (String, String) {
    if let Ok(Value::Array(arr)) = serde_json::from_str::<Value>(uris_json) {
        if let Some(Value::String(first)) = arr.first() {
            let cleaned = first.replacen("file://", "", 1).trim().to_string();
            if !cleaned.is_empty() {
                return normalize_project_path(&cleaned);
            }
        }
    }
    (
        "muop-erp-server".to_string(),
        format!("{}/muop-erp-server", ECOSYSTEM_DIR_PATH),
    )
}

fn normalize_project_path(raw_path: &str) -> (String, String) {
    let name = raw_path
        .split('/')
        .filter(|s| !s.is_empty())
        .last()
        .unwrap_or("muop-erp-server")
        .to_string();
    let candidate = format!("{}/{}", ECOSYSTEM_DIR_PATH, name);
    if Path::new(&candidate).exists() {
        return (name, candidate);
    }
    (name, raw_path.to_string())
}

/// Kiểm tra trạng thái Git (nhánh hiện tại, commit mới nhất, số commit chưa push lên server)
pub fn check_git_sync_status(project_path_str: &str) -> Option<GitSyncStatus> {
    if project_path_str.trim().is_empty() {
        return None;
    }
    let p = Path::new(project_path_str);
    if !p.exists() || !p.is_dir() {
        return None;
    }
    if !p.join(".git").exists() {
        return None;
    }

    // 1. Lấy tên nhánh hiện tại (branch name)
    let branch_out = Command::new("git")
        .args(["rev-parse", "--abbrev-ref", "HEAD"])
        .current_dir(p)
        .output()
        .ok()?;
    if !branch_out.status.success() {
        return None;
    }
    let branch = String::from_utf8_lossy(&branch_out.stdout).trim().to_string();
    if branch.is_empty() || branch == "HEAD" {
        return None;
    }

    // 2. Kiểm tra số commit chưa push lên remote (ahead count)
    let mut ahead_count: usize = 0;
    let mut count_determined = false;

    // Cách 1: Thử git rev-list --count @{u}..HEAD (nếu upstream đã thiết lập)
    if let Ok(out) = Command::new("git")
        .args(["rev-list", "--count", "@{u}..HEAD"])
        .current_dir(p)
        .output()
    {
        if out.status.success() {
            let s = String::from_utf8_lossy(&out.stdout).trim().to_string();
            if let Ok(n) = s.parse::<usize>() {
                ahead_count = n;
                count_determined = true;
            }
        }
    }

    // Cách 2: Fallback thử origin/<branch>..HEAD
    if !count_determined {
        let origin_ref = format!("origin/{}..HEAD", branch);
        if let Ok(out) = Command::new("git")
            .args(["rev-list", "--count", &origin_ref])
            .current_dir(p)
            .output()
        {
            if out.status.success() {
                let s = String::from_utf8_lossy(&out.stdout).trim().to_string();
                if let Ok(n) = s.parse::<usize>() {
                    ahead_count = n;
                    count_determined = true;
                }
            }
        }
    }

    // Cách 3: Fallback phân tích cú pháp git status -sb (tìm chuỗi [ahead X])
    if !count_determined {
        if let Ok(out) = Command::new("git")
            .args(["status", "-sb"])
            .current_dir(p)
            .output()
        {
            let s = String::from_utf8_lossy(&out.stdout);
            if let Some(pos) = s.find("[ahead ") {
                let rest = &s[pos + 7..];
                if let Some(end_pos) = rest.find(']') {
                    let num_str = rest[..end_pos].trim();
                    if let Ok(n) = num_str.parse::<usize>() {
                        ahead_count = n;
                    }
                }
            }
        }
    }

    // 3. Lấy thông tin commit mới nhất
    let log_out = Command::new("git")
        .args(["log", "-1", "--pretty=format:%h\t%s\t%an\t%cI"])
        .current_dir(p)
        .output()
        .ok()?;
    let log_str = String::from_utf8_lossy(&log_out.stdout).trim().to_string();
    let parts: Vec<&str> = log_str.split('\t').collect();
    let last_commit_hash = parts.first().unwrap_or(&"").to_string();
    let last_commit_message = parts.get(1).unwrap_or(&"").to_string();
    let last_commit_author = parts.get(2).unwrap_or(&"").to_string();
    let last_commit_at = parts.get(3).unwrap_or(&"").to_string();

    let project_name = p
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("project")
        .to_string();

    Some(GitSyncStatus {
        project_path: project_path_str.to_string(),
        project_name,
        branch,
        ahead_count,
        last_commit_hash,
        last_commit_message,
        last_commit_author,
        last_commit_at,
        is_ahead: ahead_count > 0,
    })
}

pub fn discover_projects(sessions: &[ConversationSession]) -> Vec<ProjectWorkspace> {
    let mut project_map: HashMap<String, (String, usize, usize, Option<String>)> = HashMap::new();

    if let Ok(entries) = fs::read_dir(ECOSYSTEM_DIR_PATH) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                if let Some(name) = path.file_name().and_then(|n| n.to_str()) {
                    if !name.starts_with('.') {
                        project_map.insert(
                            name.to_string(),
                            (path.to_string_lossy().to_string(), 0, 0, None),
                        );
                    }
                }
            }
        }
    }

    for s in sessions {
        let entry = project_map.entry(s.project_name.clone()).or_insert_with(|| {
            (s.project_path.clone(), 0, 0, None)
        });
        entry.1 += 1;
        if s.status == "running" {
            entry.2 += 1;
        }
        let update_str = s.updated_at.clone();
        match &entry.3 {
            Some(prev) => {
                if update_str > *prev {
                    entry.3 = Some(update_str);
                }
            }
            None => entry.3 = Some(update_str),
        }
    }

    let mut list: Vec<ProjectWorkspace> = project_map
        .into_iter()
        .map(|(name, (path, count, running, last_active))| {
            let git_sync_status = check_git_sync_status(&path);
            let (custom_agents, available_agents) =
                scan_project_agents_and_skills(Path::new(&path));
            ProjectWorkspace {
                id: name.clone(),
                name,
                path,
                session_count: count,
                running_count: running,
                last_active_at: last_active,
                git_sync_status,
                custom_agents,
                available_agents,
            }
        })
        .collect();

    list.sort_by(|a, b| {
        b.running_count
            .cmp(&a.running_count)
            .then_with(|| b.session_count.cmp(&a.session_count))
            .then_with(|| a.name.cmp(&b.name))
    });

    list
}

pub fn create_new_project(
    name: &str,
    template: &str,
    description: &str,
) -> Result<ProjectWorkspace, String> {
    let trimmed_name = name.trim();
    if trimmed_name.is_empty() {
        return Err("Tên dự án không được để trống".to_string());
    }

    if !trimmed_name
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
    {
        return Err(
            "Tên dự án chỉ được chứa chữ cái, số, gạch nối (-) và gạch dưới (_)".to_string(),
        );
    }

    let target_path = PathBuf::from(ECOSYSTEM_DIR_PATH).join(trimmed_name);
    if target_path.exists() {
        return Err(format!(
            "Dự án [{}] đã tồn tại trong thư mục muop-ecosystem",
            trimmed_name
        ));
    }

    fs::create_dir_all(&target_path)
        .map_err(|e| format!("Không thể tạo thư mục dự án: {}", e))?;

    let desc_text = if description.trim().is_empty() {
        format!("Dự án {}", trimmed_name)
    } else {
        description.trim().to_string()
    };

    match template {
        "go" => {
            let mod_name = trimmed_name.replace('-', "_");
            let go_mod = format!("module muop/{}\n\ngo 1.22\n", mod_name);
            let _ = fs::write(target_path.join("go.mod"), go_mod);
            let main_go = format!(
                "package main\n\nimport \"fmt\"\n\nfunc main() {{\n    fmt.Println(\"🚀 Khởi chạy dự án {}!\")\n}}\n",
                trimmed_name
            );
            let _ = fs::write(target_path.join("main.go"), main_go);
            let gitignore = "*.exe\n*.exe~\n*.dll\n*.so\n*.dylib\n*.test\n*.out\nvendor/\n.idea/\n.vscode/\n";
            let _ = fs::write(target_path.join(".gitignore"), gitignore);
            let readme = format!(
                "# {}\n\n{}\n\n- Ngôn ngữ: Go\n- Kiến trúc: Hexagonal Clean Architecture\n- Khởi tạo qua: Mướp Agent Monitor\n",
                trimmed_name, desc_text
            );
            let _ = fs::write(target_path.join("README.md"), readme);
        }
        "flutter" => {
            let clean_name = trimmed_name.replace('-', "_").to_lowercase();
            let pubspec = format!(
                "name: {}\ndescription: \"{}\"\nversion: 1.0.0+1\nenvironment:\n  sdk: '>=3.0.0 <4.0.0'\ndependencies:\n  flutter:\n    sdk: flutter\n  flutter_riverpod: ^2.5.1\ndev_dependencies:\n  flutter_test:\n    sdk: flutter\n  flutter_lints: ^3.0.0\nflutter:\n  uses-material-design: true\n",
                clean_name, desc_text
            );
            let _ = fs::write(target_path.join("pubspec.yaml"), pubspec);
            let lib_dir = target_path.join("lib");
            let _ = fs::create_dir_all(&lib_dir);
            let main_dart = format!(
                "import 'package:flutter/material.dart';\n\nvoid main() {{\n  runApp(const MyApp());\n}}\n\nclass MyApp extends StatelessWidget {{\n  const MyApp({{super.key}});\n\n  @override\n  Widget build(BuildContext context) {{\n    return MaterialApp(\n      title: '{}',\n      theme: ThemeData(useMaterial3: true),\n      home: const Scaffold(\n        body: Center(\n          child: Text('{} - Mướp Ecosystem'),\n        ),\n      ),\n    );\n  }}\n}}\n",
                trimmed_name, trimmed_name
            );
            let _ = fs::write(lib_dir.join("main.dart"), main_dart);
            let gitignore = ".dart_tool/\n.flutter-plugins\n.flutter-plugins-dependencies\n.packages\nbuild/\n.idea/\n.vscode/\n";
            let _ = fs::write(target_path.join(".gitignore"), gitignore);
            let readme = format!(
                "# {}\n\n{}\n\n- Nền tảng: Flutter Client\n- Material 3 & Riverpod\n- Khởi tạo qua: Mướp Agent Monitor\n",
                trimmed_name, desc_text
            );
            let _ = fs::write(target_path.join("README.md"), readme);
        }
        _ => {
            let gitignore = ".idea/\n.vscode/\n*.log\n.DS_Store\nnode_modules/\n";
            let _ = fs::write(target_path.join(".gitignore"), gitignore);
            let readme = format!(
                "# {}\n\n{}\n\nKhởi tạo tự động qua Mướp Agent Monitor.\n",
                trimmed_name, desc_text
            );
            let _ = fs::write(target_path.join("README.md"), readme);
        }
    }

    let (custom_agents, available_agents) = scan_project_agents_and_skills(&target_path);
    Ok(ProjectWorkspace {
        id: trimmed_name.to_string(),
        name: trimmed_name.to_string(),
        path: target_path.to_string_lossy().to_string(),
        session_count: 0,
        running_count: 0,
        last_active_at: Some(Utc::now().to_rfc3339()),
        git_sync_status: None,
        custom_agents,
        available_agents,
    })
}

/// Quét toàn bộ agents, skills, rules từ thư mục `.agents/` của project (hoặc tệp `.agents`)
pub fn scan_project_agents_and_skills(project_path: &Path) -> (Vec<CustomAgentSpec>, Vec<String>) {
    let mut specs = Vec::new();
    let mut available_agents = vec!["Coordinator".to_string()];

    // 1. Quét từ thư mục .agents hoặc file .agents trong project
    let agents_dir = project_path.join(".agents");
    if agents_dir.exists() {
        if agents_dir.is_dir() {
            scan_agent_subdir(&agents_dir.join("agents"), "agent", &mut specs);
            scan_agent_subdir(&agents_dir.join("skills"), "skill", &mut specs);
            scan_agent_subdir(&agents_dir.join("rules"), "rule", &mut specs);
        } else if agents_dir.is_file() {
            if let Ok(raw) = fs::read_to_string(&agents_dir) {
                let stem = agents_dir
                    .file_stem()
                    .and_then(|s| s.to_str())
                    .unwrap_or("agent");
                let (name, desc, _) = parse_markdown_frontmatter(&raw, stem, "agent");
                specs.push(CustomAgentSpec {
                    name,
                    description: desc,
                    kind: "agent".to_string(),
                    file_path: agents_dir.to_string_lossy().to_string(),
                    body_content: String::new(),
                });
            }
        }
    }

    // 2. Thêm built-in skills từ ~/.gemini/antigravity/builtin/skills nếu chưa có
    let builtin_skills_dir = Path::new("/home/john/.gemini/antigravity/builtin/skills");
    if builtin_skills_dir.exists() {
        scan_agent_subdir(builtin_skills_dir, "skill", &mut specs);
    }

    // Lọc danh sách available_agents: Coordinator + các agent có kind == "agent"
    for s in &specs {
        if s.kind == "agent" && !available_agents.contains(&s.name) {
            available_agents.push(s.name.clone());
        }
    }

    (specs, available_agents)
}

pub fn load_custom_agent_specs() -> Vec<CustomAgentSpec> {
    let (specs, _) = scan_project_agents_and_skills(Path::new(&format!(
        "{}/muop-erp-server",
        ECOSYSTEM_DIR_PATH
    )));
    specs
}

fn scan_agent_subdir(dir: &Path, kind: &str, specs: &mut Vec<CustomAgentSpec>) {
    if !dir.exists() {
        return;
    }
    if let Ok(entries) = fs::read_dir(dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                scan_agent_subdir(&path, kind, specs);
            } else if path.extension().and_then(|e| e.to_str()) == Some("md") {
                if let Ok(raw) = fs::read_to_string(&path) {
                    let file_stem = path
                        .file_stem()
                        .and_then(|s| s.to_str())
                        .unwrap_or("custom")
                        .to_string();
                    let default_name = if file_stem == "SKILL" || file_stem == "skill" {
                        path.parent()
                            .and_then(|p| p.file_name())
                            .and_then(|n| n.to_str())
                            .unwrap_or(&file_stem)
                    } else {
                        &file_stem
                    };
                    let (name, desc, _) = parse_markdown_frontmatter(&raw, default_name, kind);
                    if !specs.iter().any(|s| s.name == name && s.kind == kind) {
                        specs.push(CustomAgentSpec {
                            name,
                            description: desc,
                            kind: kind.to_string(),
                            file_path: path.to_string_lossy().to_string(),
                            body_content: String::new(),
                        });
                    }
                }
            }
        }
    }
}

pub(crate) fn parse_markdown_frontmatter(
    raw: &str,
    default_name: &str,
    kind: &str,
) -> (String, String, String) {
    let mut name = default_name.to_string();
    let mut desc = format!("Cấu hình {}", kind);
    let mut body = raw.to_string();

    if raw.starts_with("---") {
        if let Some(end_idx) = raw[3..].find("\n---") {
            let header = raw[3..3 + end_idx].trim();
            body = raw[3 + end_idx + 4..].trim().to_string();

            let mut current_key = "";
            let mut desc_buf = String::new();
            for line in header.lines() {
                let trimmed = line.trim();
                if let Some(rest) = trimmed.strip_prefix("name:") {
                    current_key = "name";
                    let n = rest.trim();
                    if !n.is_empty() {
                        name = n.to_string();
                    }
                } else if let Some(rest) = trimmed.strip_prefix("description:") {
                    current_key = "description";
                    let after = rest.trim();
                    if after != ">-" && after != ">" && after != "|" && !after.is_empty() {
                        desc_buf.push_str(after);
                    }
                } else if current_key == "description" && line.starts_with("  ") {
                    if !desc_buf.is_empty() {
                        desc_buf.push(' ');
                    }
                    desc_buf.push_str(trimmed);
                } else if trimmed.contains(':') {
                    current_key = "";
                }
            }
            if !desc_buf.is_empty() {
                desc = desc_buf;
            }
        }
    }

    (name, desc, body)
}

pub fn scan_all_sessions(
    active_streams: &HashMap<String, ChatTurnStreamState>,
    active_id: Option<&str>,
    max_sessions: usize,
) -> Vec<ConversationSession> {
    let brain_dir = Path::new(BRAIN_DIR_PATH);
    if !brain_dir.exists() {
        return Vec::new();
    }

    let db_meta_map = load_conversation_summary_meta();
    let mut child_subagent_ids: HashSet<String> = HashSet::new();

    // 1. Nhận diện trước toàn bộ subagents từ database meta: nếu có parent_id hoặc agent_name != "" (và != "Coordinator")
    for (id, m) in &db_meta_map {
        if !m.parent_id.is_empty()
            || (!m.agent_name.is_empty()
                && m.agent_name != "Coordinator"
                && m.agent_name != "user")
        {
            child_subagent_ids.insert(id.clone());
        }
    }

    // 2. Quét nhanh transcript để bổ sung các subagent ID được spawn trong phiên làm việc
    let conv_id_re = Regex::new(r#""conversationId"\s*:\s*"([^"]+)""#).ok();
    if let Ok(read_dir) = fs::read_dir(brain_dir) {
        for entry in read_dir.flatten() {
            let path = entry.path();
            if path.is_dir() {
                let transcript_path = path.join(".system_generated/logs/transcript.jsonl");
                if let Ok(file) = fs::File::open(&transcript_path) {
                    use std::io::{BufRead, BufReader};
                    let reader = BufReader::new(file);
                    for line_res in reader.lines() {
                        if let Ok(line) = line_res {
                            if line.contains("Created the following subagent:") || line.contains("invoke_subagent") {
                                if let Some(ref re) = conv_id_re {
                                    if let Some(caps) = re.captures(&line) {
                                        if let Some(m) = caps.get(1) {
                                            child_subagent_ids.insert(m.as_str().to_string());
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    let mut entries: Vec<(String, DateTime<Utc>)> = Vec::new();

    if let Ok(read_dir) = fs::read_dir(brain_dir) {
        for entry in read_dir.flatten() {
            let path = entry.path();
            if path.is_dir() {
                let id = match path.file_name().and_then(|n| n.to_str()) {
                    Some(s) => s.to_string(),
                    None => continue,
                };
                if id == "tempmediaStorage" || id.starts_with('.') {
                    continue;
                }
                let transcript_path = path.join(".system_generated/logs/transcript.jsonl");
                if let Ok(meta) = fs::metadata(&transcript_path) {
                    let modified: DateTime<Utc> = meta
                        .modified()
                        .unwrap_or(SystemTime::UNIX_EPOCH)
                        .into();
                    entries.push((id, modified));
                }
            }
        }
    }

    entries.sort_by(|a, b| b.1.cmp(&a.1));

    // Lọc ra các conversation top-level (loại bỏ child subagents ngay từ đầu)
    let mut top_level_entries: Vec<(String, DateTime<Utc>)> = Vec::new();
    for (id, modified) in entries {
        if child_subagent_ids.contains(&id) {
            continue;
        }
        top_level_entries.push((id, modified));
    }

    let selected: Vec<(String, DateTime<Utc>)> =
        if max_sessions == 0 || max_sessions >= top_level_entries.len() {
            top_level_entries
        } else {
            top_level_entries.into_iter().take(max_sessions).collect()
        };

    let target_active = active_id
        .map(|s| s.to_string())
        .or_else(|| selected.first().map(|(id, _)| id.clone()));

    let mut raw_sessions: HashMap<String, ParsedTranscript> = HashMap::new();

    for (id, modified) in &selected {
        let meta = db_meta_map.get(id);
        if let Some(parsed) = parse_transcript_file(id, *modified, meta) {
            for s in &parsed.spawned_subagents {
                if !s.id.is_empty() {
                    child_subagent_ids.insert(s.id.clone());
                }
            }
            raw_sessions.insert(id.clone(), parsed);
        }
    }

    for sub_id in &child_subagent_ids {
        if !sub_id.is_empty() && !raw_sessions.contains_key(sub_id) {
            let sub_path = PathBuf::from(BRAIN_DIR_PATH)
                .join(sub_id)
                .join(".system_generated/logs/transcript.jsonl");
            if let Ok(meta) = fs::metadata(&sub_path) {
                let modified: DateTime<Utc> = meta
                    .modified()
                    .unwrap_or(SystemTime::UNIX_EPOCH)
                    .into();
                if let Some(parsed) =
                    parse_transcript_file(sub_id, modified, db_meta_map.get(sub_id))
                {
                    raw_sessions.insert(sub_id.clone(), parsed);
                }
            }
        }
    }

    let live_agy_cids = scan_running_agy_conversations();
    let mut git_sync_cache: HashMap<String, Option<GitSyncStatus>> = HashMap::new();
    let mut project_agents_cache: HashMap<String, (Vec<CustomAgentSpec>, Vec<String>)> = HashMap::new();
    let mut sessions = Vec::new();
    for (idx, (id, _)) in selected.iter().enumerate() {
        if let Some(m) = db_meta_map.get(id) {
            if !m.parent_id.is_empty() {
                continue;
            }
        }
        if child_subagent_ids.contains(id) {
            continue;
        }
        let parsed = match raw_sessions.get(id) {
            Some(p) => p,
            None => continue,
        };

        let is_active_session = target_active.as_deref() == Some(id.as_str())
            || (target_active.is_none() && idx == 0);

        let is_stream_running = active_streams
            .get(&parsed.id)
            .map(|st| st.is_running)
            .unwrap_or(false);
        let is_os_agy_running = live_agy_cids.contains(&parsed.id);
        let is_actually_running = is_stream_running || is_os_agy_running;

        let (effective_status, is_interrupted, interrupted_reason) = if is_actually_running {
            ("running".to_string(), false, None)
        } else if parsed.status == "running" || parsed.status == "interrupted" {
            (
                "interrupted".to_string(),
                true,
                Some("Tiến trình Agent bị gián đoạn do máy chủ khởi động lại hoặc agy CLI dừng đột ngột.".to_string()),
            )
        } else {
            (parsed.status.clone(), false, None)
        };

        // Khi có 2 hay nhiều conversation cùng chạy, tất cả các conversation đang chạy
        // hoặc conversation active đều phải được nạp đầy đủ lanes và 150 steps gần nhất.
        let should_load_full = is_active_session || is_actually_running;

        let lanes = if should_load_full {
            build_subagent_lanes(parsed, &raw_sessions, is_actually_running)
        } else {
            Vec::new()
        };

        let sub_to_parent_step: HashMap<String, usize> = parsed
            .spawned_subagents
            .iter()
            .filter(|s| !s.id.is_empty())
            .map(|s| (s.id.clone(), s.step_index))
            .collect();

        // Tối ưu Payload Snapshot:
        // CHỈ nạp files, commands và steps cho session đang active hoặc đang chạy!
        // Các session inactive trong snapshot chỉ cần metadata gọn nhẹ để sidebar hiển thị.
        // Khi người dùng bấm vào session bất kỳ, client sẽ fetch full detail qua /api/session.
        let (files, commands) = if should_load_full {
            let mut f_list = parsed.files_touched.clone();
            let mut c_list = parsed.commands_run.clone();

            for lane in &lanes {
                if let Some(sub_parsed) = raw_sessions.get(&lane.id) {
                    let parent_step = sub_to_parent_step.get(&lane.id).cloned().unwrap_or(0);
                    for mut f in sub_parsed.files_touched.clone() {
                        if parent_step > 0 {
                            f.step_index = parent_step;
                        }
                        f_list.push(f);
                    }
                    for mut c in sub_parsed.commands_run.clone() {
                        if parent_step > 0 {
                            c.step_index = parent_step;
                        }
                        c_list.push(c);
                    }
                }
            }

            f_list.sort_by(|a, b| b.timestamp.cmp(&a.timestamp));
            c_list.sort_by(|a, b| b.timestamp.cmp(&a.timestamp));

            if f_list.len() > 80 {
                f_list.truncate(80);
            }
            for f in &mut f_list {
                if f.diff_preview.len() > 200 {
                    f.diff_preview = format!("{}...", safe_truncate(&f.diff_preview, 200));
                }
            }
            if c_list.len() > 40 {
                c_list.truncate(40);
            }
            for c in &mut c_list {
                if c.output_preview.len() > 200 {
                    c.output_preview = format!("{}...", safe_truncate(&c.output_preview, 200));
                }
            }
            (f_list, c_list)
        } else {
            (Vec::new(), Vec::new())
        };

        // Chỉ nạp 100 steps gần nhất cho session active/running, rỗng cho session inactive
        let steps = if should_load_full {
            if parsed.steps.len() > 100 {
                parsed.steps[parsed.steps.len() - 100..].to_vec()
            } else {
                parsed.steps.clone()
            }
        } else {
            Vec::new()
        };

        let mut final_steps = steps;
        if is_interrupted {
            if let Some(last) = final_steps.last() {
                if last.step_type == "PLANNER_RESPONSE" && !last.tool_calls.is_empty() {
                    final_steps.push(AgentStep {
                        step_index: last.step_index + 1,
                        source: "SYSTEM".to_string(),
                        step_type: "GENERIC".to_string(),
                        status: "INTERRUPTED".to_string(),
                        created_at: Utc::now().to_rfc3339(),
                        content: "⚠️ Tiến trình Agent bị gián đoạn do máy chủ khởi động lại hoặc lệnh CLI bị ngắt đột ngột. Bạn có thể gửi tin nhắn tiếp theo để tiếp tục.".to_string(),
                        thinking: String::new(),
                        tool_calls: Vec::new(),
                        input_tokens: 0,
                        output_tokens: 0,
                        cache_read_tokens: 0,
                        agent_name: "Coordinator".to_string(),
                        phase: "completed".to_string(),
                        vietnamese_title: "Tiến trình Agent bị gián đoạn".to_string(),
                        vietnamese_detail: "Tiến trình xử lý của Agent đã bị ngắt do server restart hoặc dừng đột ngột. Bạn có thể tiếp tục bằng cách gửi tin nhắn tiếp theo.".to_string(),
                        model: String::new(),
                    });
                }
            }
        }

        let (p_custom_agents, p_available_agents) = project_agents_cache
            .entry(parsed.project_path.clone())
            .or_insert_with(|| scan_project_agents_and_skills(Path::new(&parsed.project_path)))
            .clone();

        let is_erp_proj = parsed.project_name == "muop-erp-server"
            || parsed.project_name == "muop-erp-app"
            || Path::new(&parsed.project_path).join(".agents/rules/parallel-erp-sync.md").exists();
        let has_parallel_flow = is_erp_proj || !parsed.spawned_subagents.is_empty() || lanes.len() > 1;

        sessions.push(ConversationSession {
            id: parsed.id.clone(),
            title: parsed.title.clone(),
            created_at: parsed.created_at.to_rfc3339(),
            updated_at: parsed.updated_at.to_rfc3339(),
            status: effective_status,
            current_phase: if is_interrupted {
                "completed".to_string()
            } else {
                parsed.current_phase.clone()
            },
            steps: final_steps,
            subagent_lanes: lanes,
            files_touched: files,
            commands_run: commands,
            total_input_tokens: parsed.total_input_tokens,
            total_output_tokens: parsed.total_output_tokens,
            total_cache_tokens: parsed.total_cache_tokens,
            project_name: parsed.project_name.clone(),
            project_path: parsed.project_path.clone(),
            is_simulated: false,
            pending_plans: scan_pending_plans(&parsed.id),
            git_sync_status: git_sync_cache
                .entry(parsed.project_path.clone())
                .or_insert_with(|| check_git_sync_status(&parsed.project_path))
                .clone(),
            is_interrupted,
            interrupted_reason,
            custom_agents: if should_load_full {
                p_custom_agents
            } else {
                Vec::new()
            },
            available_agents: p_available_agents,
            has_parallel_flow,
            source: "agy".to_string(),
        });
    }

    // Session của Claude Code CLI (~/.claude/projects) được gộp chung vào danh sách
    sessions.extend(claude_code::scan_sessions(active_streams));
    sessions
}

/// Quét các Artifact / Kế hoạch (Plan) đang yêu cầu phê duyệt trong thư mục brain của phiên hội thoại
pub fn scan_pending_plans(session_id: &str) -> Vec<PlanArtifactInfo> {
    let mut plans = Vec::new();
    let brain_dir = Path::new(BRAIN_DIR_PATH).join(session_id);
    if !brain_dir.exists() || !brain_dir.is_dir() {
        return plans;
    }

    if let Ok(entries) = fs::read_dir(&brain_dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_file() {
                let name = entry.file_name().to_string_lossy().to_string();
                if name.ends_with(".metadata.json") {
                    let artifact_name = name.trim_end_matches(".metadata.json").to_string();
                    let artifact_path = brain_dir.join(&artifact_name);
                    if artifact_path.exists() && artifact_path.is_file() {
                        let mut summary = String::new();
                        let mut updated_at = String::new();
                        let mut req_feedback = false;

                        if let Ok(meta_content) = fs::read_to_string(&path) {
                            if let Ok(val) = serde_json::from_str::<serde_json::Value>(&meta_content) {
                                summary = val.get("summary").and_then(|v| v.as_str()).unwrap_or("").to_string();
                                updated_at = val.get("updatedAt").and_then(|v| v.as_str()).unwrap_or("").to_string();
                                req_feedback = val.get("requestFeedback").and_then(|v| v.as_bool()).unwrap_or(false);
                            }
                        }

                        let content = fs::read_to_string(&artifact_path).unwrap_or_default();
                        let title = content
                            .lines()
                            .find(|l| l.starts_with("# "))
                            .map(|l| l.trim_start_matches("# ").trim().to_string())
                            .unwrap_or_else(|| artifact_name.clone());

                        plans.push(PlanArtifactInfo {
                            file_name: artifact_name,
                            file_path: artifact_path.to_string_lossy().to_string(),
                            title,
                            summary,
                            updated_at,
                            request_feedback: req_feedback,
                            content,
                        });
                    }
                }
            }
        }
    }
    plans.sort_by(|a, b| b.updated_at.cmp(&a.updated_at));
    plans
}

/// Đọc đầy đủ 100% chi tiết các steps của một session cụ thể khi người dùng chọn xem
pub fn get_single_session_full(session_id: &str) -> Option<ConversationSession> {
    get_single_session_with_streams(session_id, &HashMap::new())
}

/// Đọc đầy đủ session kết hợp kiểm tra trạng thái active_streams hiện thời
pub fn get_single_session_with_streams(
    session_id: &str,
    active_streams: &HashMap<String, ChatTurnStreamState>,
) -> Option<ConversationSession> {
    if let Some(session) = claude_code::get_session(session_id, active_streams) {
        return Some(session);
    }
    let brain_dir = Path::new(BRAIN_DIR_PATH);

    let db_meta_map = load_conversation_summary_meta();
    // Nếu session_id là child subagent, tự động chuyển sang đọc session cha
    let target_id = if let Some(m) = db_meta_map.get(session_id) {
        if !m.parent_id.is_empty() {
            m.parent_id.as_str()
        } else {
            session_id
        }
    } else {
        session_id
    };

    let session_dir = brain_dir.join(target_id);
    if !session_dir.exists() {
        return None;
    }
    let transcript_path = session_dir.join(".system_generated/logs/transcript.jsonl");
    let meta = fs::metadata(&transcript_path).ok()?;
    let modified: DateTime<Utc> = meta.modified().unwrap_or(SystemTime::UNIX_EPOCH).into();

    let db_meta = db_meta_map.get(target_id);

    let parsed = parse_transcript_file(target_id, modified, db_meta)?;

    let mut raw_sessions: HashMap<String, ParsedTranscript> = HashMap::new();
    for s in &parsed.spawned_subagents {
        if !s.id.is_empty() {
            let sub_path = brain_dir.join(&s.id).join(".system_generated/logs/transcript.jsonl");
            if let Ok(smeta) = fs::metadata(&sub_path) {
                let smod: DateTime<Utc> = smeta.modified().unwrap_or(SystemTime::UNIX_EPOCH).into();
                if let Some(sparsed) = parse_transcript_file(&s.id, smod, db_meta_map.get(&s.id)) {
                    raw_sessions.insert(s.id.clone(), sparsed);
                }
            }
        }
    }

    let live_agy_cids = scan_running_agy_conversations();
    let is_stream_running = active_streams
        .get(target_id)
        .map(|st| st.is_running)
        .unwrap_or(false);
    let is_actually_running = is_stream_running || live_agy_cids.contains(target_id);
    let (status, is_interrupted, interrupted_reason) = if is_actually_running {
        ("running".to_string(), false, None)
    } else if parsed.status == "running" || parsed.status == "interrupted" {
        (
            "interrupted".to_string(),
            true,
            Some("Tiến trình Agent bị gián đoạn do máy chủ khởi động lại hoặc agy CLI dừng đột ngột.".to_string()),
        )
    } else {
        (parsed.status.clone(), false, None)
    };

    let lanes = build_subagent_lanes(&parsed, &raw_sessions, is_actually_running);
    let sub_to_parent_step: HashMap<String, usize> = parsed
        .spawned_subagents
        .iter()
        .filter(|s| !s.id.is_empty())
        .map(|s| (s.id.clone(), s.step_index))
        .collect();

    let mut files = parsed.files_touched.clone();
    let mut commands = parsed.commands_run.clone();
    for lane in &lanes {
        if let Some(sub_parsed) = raw_sessions.get(&lane.id) {
            let parent_step = sub_to_parent_step.get(&lane.id).cloned().unwrap_or(0);
            for mut f in sub_parsed.files_touched.clone() {
                if parent_step > 0 {
                    f.step_index = parent_step;
                }
                files.push(f);
            }
            for mut c in sub_parsed.commands_run.clone() {
                if parent_step > 0 {
                    c.step_index = parent_step;
                }
                commands.push(c);
            }
        }
    }
    files.sort_by(|a, b| b.timestamp.cmp(&a.timestamp));
    commands.sort_by(|a, b| b.timestamp.cmp(&a.timestamp));

    if files.len() > 100 {
        files.truncate(100);
    }
    if commands.len() > 50 {
        commands.truncate(50);
    }

    let mut final_steps = if parsed.steps.len() > 100 {
        parsed.steps[parsed.steps.len() - 100..].to_vec()
    } else {
        parsed.steps
    };
    if is_interrupted {
        if let Some(last) = final_steps.last() {
            if last.step_type == "PLANNER_RESPONSE" && !last.tool_calls.is_empty() {
                final_steps.push(AgentStep {
                    step_index: last.step_index + 1,
                    source: "SYSTEM".to_string(),
                    step_type: "GENERIC".to_string(),
                    status: "INTERRUPTED".to_string(),
                    created_at: Utc::now().to_rfc3339(),
                    content: "⚠️ Tiến trình Agent bị gián đoạn do máy chủ khởi động lại hoặc lệnh CLI bị ngắt đột ngột. Bạn có thể gửi tin nhắn tiếp theo để tiếp tục.".to_string(),
                    thinking: String::new(),
                    tool_calls: Vec::new(),
                    input_tokens: 0,
                    output_tokens: 0,
                    cache_read_tokens: 0,
                    agent_name: "Coordinator".to_string(),
                    phase: "completed".to_string(),
                    vietnamese_title: "Tiến trình Agent bị gián đoạn".to_string(),
                    vietnamese_detail: "Tiến trình xử lý của Agent đã bị ngắt do server restart hoặc dừng đột ngột. Bạn có thể tiếp tục bằng cách gửi tin nhắn tiếp theo.".to_string(),
                    model: String::new(),
                });
            }
        }
    }

    let (custom_agents, available_agents) =
        scan_project_agents_and_skills(Path::new(&parsed.project_path));
    let is_erp_proj = parsed.project_name == "muop-erp-server"
        || parsed.project_name == "muop-erp-app"
        || Path::new(&parsed.project_path).join(".agents/rules/parallel-erp-sync.md").exists();
    let has_parallel_flow = is_erp_proj || !parsed.spawned_subagents.is_empty() || lanes.len() > 1;

    Some(ConversationSession {
        id: parsed.id.clone(),
        title: parsed.title.clone(),
        created_at: parsed.created_at.to_rfc3339(),
        updated_at: parsed.updated_at.to_rfc3339(),
        status,
        current_phase: if is_interrupted {
            "completed".to_string()
        } else {
            parsed.current_phase
        },
        steps: final_steps,
        subagent_lanes: lanes,
        files_touched: files,
        commands_run: commands,
        total_input_tokens: parsed.total_input_tokens,
        total_output_tokens: parsed.total_output_tokens,
        total_cache_tokens: parsed.total_cache_tokens,
        git_sync_status: check_git_sync_status(&parsed.project_path),
        project_name: parsed.project_name,
        project_path: parsed.project_path,
        is_simulated: false,
        pending_plans: scan_pending_plans(&parsed.id),
        is_interrupted,
        interrupted_reason,
        custom_agents,
        available_agents,
        has_parallel_flow,
        source: "agy".to_string(),
    })
}

/// Lấy danh sách các bước (steps) theo phân trang (paging):
/// Trả về `limit` bước xảy ra ngay trước `before_step` (sắp xếp tăng dần theo thời gian).
pub fn get_session_steps_page(
    session_id: &str,
    before_step: Option<usize>,
    limit: usize,
) -> Option<SessionStepsPageResponse> {
    if let Some(page) = claude_code::get_steps_page(session_id, before_step, limit) {
        return Some(page);
    }
    let brain_dir = Path::new(BRAIN_DIR_PATH);
    let session_dir = brain_dir.join(session_id);
    if !session_dir.exists() {
        return None;
    }
    let transcript_path = session_dir.join(".system_generated/logs/transcript.jsonl");
    let meta = fs::metadata(&transcript_path).ok()?;
    let modified: DateTime<Utc> = meta.modified().unwrap_or(SystemTime::UNIX_EPOCH).into();

    let db_meta_map = load_conversation_summary_meta();
    let db_meta = db_meta_map.get(session_id);

    let parsed = parse_transcript_file(session_id, modified, db_meta)?;
    let total_steps = parsed.total_steps;

    let earliest_in_cache = parsed.steps.first().map(|s| s.step_index).unwrap_or(0);
    let can_use_cache = match before_step {
        None => true,
        Some(target) => target > earliest_in_cache,
    };

    if can_use_cache {
        let candidate_steps: Vec<&AgentStep> = if let Some(target) = before_step {
            parsed.steps.iter().filter(|s| s.step_index < target).collect()
        } else {
            parsed.steps.iter().collect()
        };

        let count = candidate_steps.len();
        let take_count = limit.min(count);
        let start_idx = count.saturating_sub(take_count);
        let page_steps: Vec<AgentStep> = candidate_steps[start_idx..count]
            .iter()
            .map(|&s| s.clone())
            .collect();

        let earliest_step_index = page_steps.first().map(|s| s.step_index).unwrap_or(0);
        let has_more = earliest_step_index > 0;

        return Some(SessionStepsPageResponse {
            session_id: session_id.to_string(),
            steps: page_steps,
            has_more,
            earliest_step_index,
            total_steps,
        });
    }

    read_steps_page_from_file(&transcript_path, session_id, before_step, limit, total_steps, modified)
}

fn read_steps_page_from_file(
    path: &Path,
    session_id: &str,
    before_step: Option<usize>,
    limit: usize,
    total_steps: usize,
    file_modified: DateTime<Utc>,
) -> Option<SessionStepsPageResponse> {
    use std::collections::VecDeque;
    use std::io::{BufRead, BufReader};
    let file = fs::File::open(path).ok()?;
    let reader = BufReader::new(file);

    let target_step = before_step.unwrap_or(usize::MAX);
    let mut candidate_deque: VecDeque<AgentStep> = VecDeque::new();

    for line_res in reader.lines() {
        let line = match line_res {
            Ok(l) => l,
            Err(_) => continue,
        };
        if line.trim().is_empty() {
            continue;
        }
        let map: Value = match serde_json::from_str(&line) {
            Ok(v) => v,
            Err(_) => continue,
        };

        let step_index = map
            .get("step_index")
            .and_then(|v| v.as_u64())
            .map(|v| v as usize)
            .unwrap_or(0);

        if step_index >= target_step {
            continue;
        }

        let step = parse_single_agent_step(&map, step_index, file_modified);
        candidate_deque.push_back(step);
        if candidate_deque.len() > limit {
            candidate_deque.pop_front();
        }
    }

    let page_steps: Vec<AgentStep> = candidate_deque.into_iter().collect();
    let earliest_step_index = page_steps.first().map(|s| s.step_index).unwrap_or(0);
    let has_more = earliest_step_index > 0;

    Some(SessionStepsPageResponse {
        session_id: session_id.to_string(),
        steps: page_steps,
        has_more,
        earliest_step_index,
        total_steps,
    })
}

fn classify_step_agent(
    _step_type: &str,
    tool_calls: &[ToolCallInfo],
    content: &str,
    thinking: &str,
) -> String {
    for tc in tool_calls {
        if let Some(ref path) = tc.target_path {
            if path.contains("muop-erp-server") {
                return "erp-server-agent".to_string();
            }
            if path.contains("muop-erp-app") {
                return "erp-app-agent".to_string();
            }
        }
        if tc.name == "run_command" {
            let cmd = tc
                .args
                .get("CommandLine")
                .and_then(|v| v.as_str())
                .unwrap_or("");
            if cmd.contains("flutter analyze") || cmd.contains("flutter test") {
                return "erp-contract-verifier".to_string();
            }
            if cmd.contains("go build") || cmd.contains("go test") {
                return "erp-contract-verifier".to_string();
            }
            if cmd.contains("muop-erp-server") {
                return "erp-server-agent".to_string();
            }
            if cmd.contains("muop-erp-app") {
                return "erp-app-agent".to_string();
            }
        }
    }
    let lower_thinking = thinking.to_lowercase();
    if lower_thinking.contains("go build")
        || lower_thinking.contains("flutter analyze")
        || lower_thinking.contains("contract verifier")
    {
        return "erp-contract-verifier".to_string();
    }
    if lower_thinking.contains("muop-erp-server") && !lower_thinking.contains("muop-erp-app") {
        return "erp-server-agent".to_string();
    }
    if lower_thinking.contains("muop-erp-app") && !lower_thinking.contains("muop-erp-server") {
        return "erp-app-agent".to_string();
    }
    let lower_content = content.to_lowercase();
    if lower_content.contains("muop-erp-server") && !lower_content.contains("muop-erp-app") {
        return "erp-server-agent".to_string();
    }
    if lower_content.contains("muop-erp-app") && !lower_content.contains("muop-erp-server") {
        return "erp-app-agent".to_string();
    }
    "Coordinator".to_string()
}

fn build_subagent_lanes(
    parent: &ParsedTranscript,
    all_parsed: &HashMap<String, ParsedTranscript>,
    is_session_actually_running: bool,
) -> Vec<SubagentLane> {
    let mut lanes = Vec::new();
    let mut added_names = HashSet::new();
    let is_session_running = is_session_actually_running;

    // 0. Coordinator Orchestrator Lane
    let mut coordinator_steps: Vec<AgentStep> = parent
        .steps
        .iter()
        .filter(|s| s.agent_name == "Coordinator" || s.step_type == "USER_INPUT")
        .cloned()
        .collect();
    if coordinator_steps.len() > 25 {
        coordinator_steps = coordinator_steps[coordinator_steps.len() - 25..].to_vec();
    }
    let last_parent_step = parent.steps.last();
    let is_coordinator_active = is_session_running
        && last_parent_step
            .map(|s| s.agent_name == "Coordinator")
            .unwrap_or(true);

    lanes.push(SubagentLane {
        id: "Coordinator".to_string(),
        name: "Coordinator".to_string(),
        role: "Architecture Lead & Parallel Dispatcher (Antigravity Engine)".to_string(),
        target_repo: parent.project_name.clone(),
        status: if is_coordinator_active {
            "running".to_string()
        } else if is_session_running {
            "waiting".to_string()
        } else {
            "completed".to_string()
        },
        current_phase: parent.current_phase.clone(),
        current_step_index: last_parent_step.map(|s| s.step_index).unwrap_or(0),
        current_action_text: if is_coordinator_active {
            last_parent_step
                .map(|s| s.vietnamese_title.clone())
                .unwrap_or_else(|| "Đang điều phối luồng thực thi song song".to_string())
        } else if is_session_running {
            "Đang ủy quyền công việc cho các Subagent song song".to_string()
        } else if parent.status == "interrupted" || !is_session_actually_running {
            "Tiến trình đã dừng (Sẵn sàng nhận lệnh mới)".to_string()
        } else {
            "Đã hoàn thành điều phối toàn bộ quy trình".to_string()
        },
        current_tool_name: if is_coordinator_active {
            last_parent_step
                .and_then(|s| s.tool_calls.first().map(|t| t.name.clone()))
                .unwrap_or_else(|| "dispatch".to_string())
        } else {
            "standby".to_string()
        },
        prompt_brief: "Tiếp nhận yêu cầu từ người dùng, thiết kế Shared Contract, phân chia công việc cho erp-server-agent & erp-app-agent, và tổng hợp kết quả.".to_string(),
        steps: coordinator_steps,
        progress: if is_session_running { 0.6 } else { 1.0 },
        files_modified: Vec::new(),
        last_updated: Some(parent.updated_at.to_rfc3339()),
    });
    added_names.insert("Coordinator".to_string());

    // 1. Spawned Subagents (via invoke_subagent / define_subagent)
    for spawned in &parent.spawned_subagents {
        let child_transcript = if !spawned.id.is_empty() {
            all_parsed.get(&spawned.id)
        } else {
            None
        };
        let mut child_steps = child_transcript
            .map(|c| c.steps.clone())
            .unwrap_or_else(|| {
                parent
                    .steps
                    .iter()
                    .filter(|s| s.agent_name == spawned.name)
                    .cloned()
                    .collect()
            });
        if child_steps.len() > 25 {
            child_steps = child_steps[child_steps.len() - 25..].to_vec();
        }
        let last_child_step = child_steps.last();

        let status = if !is_session_actually_running {
            let st = child_transcript
                .map(|c| c.status.as_str())
                .unwrap_or_else(|| spawned.status.as_str());
            if st == "running" {
                "interrupted".to_string()
            } else {
                st.to_string()
            }
        } else {
            child_transcript
                .map(|c| c.status.clone())
                .unwrap_or_else(|| spawned.status.clone())
        };

        let mut modified_files = Vec::new();
        if let Some(ct) = child_transcript {
            for f in &ct.files_touched {
                if (f.action == "WRITE" || f.action == "EDIT") && !modified_files.contains(&f.path)
                {
                    modified_files.push(f.path.clone());
                }
            }
        }

        let progress = if status == "completed" {
            1.0
        } else if !child_steps.is_empty() {
            ((child_steps.len() as f64) / ((child_steps.len() + 4) as f64)).clamp(0.25, 0.9)
        } else {
            0.15
        };

        let current_tool_name = last_child_step
            .and_then(|s| s.tool_calls.first().map(|t| t.name.clone()))
            .unwrap_or_else(|| spawned.tool_name.clone());

        lanes.push(SubagentLane {
            id: if !spawned.id.is_empty() {
                spawned.id.clone()
            } else {
                spawned.name.clone()
            },
            name: spawned.name.clone(),
            role: spawned.role.clone(),
            target_repo: infer_target_repo(&spawned.name, &spawned.role, &spawned.prompt),
            status,
            current_phase: last_child_step
                .map(|s| s.phase.clone())
                .unwrap_or_else(|| parent.current_phase.clone()),
            current_step_index: last_child_step
                .map(|s| s.step_index)
                .unwrap_or(spawned.step_index),
            current_action_text: last_child_step
                .map(|s| s.vietnamese_title.clone())
                .unwrap_or_else(|| spawned.last_action.clone()),
            current_tool_name,
            prompt_brief: spawned.prompt.clone(),
            steps: child_steps,
            progress,
            files_modified: modified_files,
            last_updated: Some(
                child_transcript
                    .map(|c| c.updated_at.to_rfc3339())
                    .unwrap_or_else(|| parent.updated_at.to_rfc3339()),
            ),
        });
        added_names.insert(spawned.name.clone());
    }

    // 2. Dual-Repo Parallel Agents (Chỉ nạp nếu là dự án ERP)
    let is_erp_project = parent.project_name == "muop-erp-server"
        || parent.project_name == "muop-erp-app"
        || Path::new(&parent.project_path).join(".agents/rules/parallel-erp-sync.md").exists()
        || Path::new(&parent.project_path).join(".agents/agents/erp-server-agent.md").exists();

    if is_erp_project {
        let standard_agents = [
            (
                "erp-server-agent",
                "ERP Server Backend Specialist (Go / Fiber v3 / MongoDB)",
                "muop-erp-server",
                "Phụ trách Clean Architecture api/v1/internal/, Isolated Collections, RBAC, Socket.IO, docs/ và go build -v .",
            ),
            (
                "erp-app-agent",
                "ERP App Flutter Specialist (Riverpod / M3 / i18n)",
                "muop-erp-app",
                "Phụ trách đồng bộ Model, executeRequest, Riverpod Provider, Socket.IO, Material 3, vi/en.json và flutter analyze.",
            ),
            (
                "erp-contract-verifier",
                "Cross-Repo Contract & QA Verifier",
                "muop-erp-server ↔ muop-erp-app",
                "Đối soát chéo Canonical Endpoint, JSON DTO, RBAC Permission, Socket.IO event và nghiệm thu kép.",
            ),
        ];

        for (name, role, repo, desc) in standard_agents {
            if !added_names.contains(name) {
                let mut related_files = Vec::new();
                for f in &parent.files_touched {
                    if ((repo == "muop-erp-server" && f.repo == "muop-erp-server")
                        || (repo == "muop-erp-app" && f.repo == "muop-erp-app"))
                        && !related_files.contains(&f.path)
                    {
                        related_files.push(f.path.clone());
                    }
                }

                // Lọc các steps thuộc về agent này
                let mut agent_steps: Vec<AgentStep> = parent
                    .steps
                    .iter()
                    .filter(|s| {
                        if s.agent_name == name {
                            return true;
                        }
                        if name == "erp-server-agent" {
                            return s.tool_calls.iter().any(|tc| {
                                tc.target_path
                                    .as_deref()
                                    .map(|p| p.contains("muop-erp-server"))
                                    .unwrap_or(false)
                            });
                        }
                        if name == "erp-app-agent" {
                            return s.tool_calls.iter().any(|tc| {
                                tc.target_path
                                    .as_deref()
                                    .map(|p| p.contains("muop-erp-app"))
                                    .unwrap_or(false)
                            });
                        }
                        if name == "erp-contract-verifier" {
                            return s.phase == "crossVerification"
                                || s.tool_calls.iter().any(|tc| {
                                    tc.name == "run_command"
                                        && tc
                                            .args
                                            .get("CommandLine")
                                            .and_then(|v| v.as_str())
                                            .map(|c| {
                                                c.contains("go build") || c.contains("flutter analyze")
                                            })
                                            .unwrap_or(false)
                                });
                        }
                        false
                    })
                    .cloned()
                    .collect();

                if agent_steps.len() > 25 {
                    agent_steps = agent_steps[agent_steps.len() - 25..].to_vec();
                }
                let last_step = agent_steps.last();
                let is_this_agent_active = is_session_running
                    && last_parent_step
                        .map(|s| s.agent_name == name)
                        .unwrap_or(false);

                let lane_status = if is_this_agent_active {
                    "running".to_string()
                } else if !agent_steps.is_empty() || !related_files.is_empty() {
                    "completed".to_string()
                } else {
                    "idle".to_string()
                };

                let current_action = if is_this_agent_active {
                    last_parent_step
                        .map(|s| s.vietnamese_title.clone())
                        .unwrap_or_else(|| format!("Đang thực thi tác vụ trên {}", repo))
                } else if !related_files.is_empty() {
                    format!("Đã cập nhật {} tệp trong {}", related_files.len(), repo)
                } else {
                    format!("Đã đăng ký trong .agents — Sẵn sàng nhận lệnh thực thi trên {}", repo)
                };

                let current_tool = if is_this_agent_active {
                    last_parent_step
                        .and_then(|s| s.tool_calls.first().map(|t| t.name.clone()))
                        .unwrap_or_else(|| "running".to_string())
                } else if !agent_steps.is_empty() {
                    "completed".to_string()
                } else {
                    "standby".to_string()
                };

                let progress = if lane_status == "running" {
                    0.7
                } else if lane_status == "completed" {
                    1.0
                } else {
                    0.0
                };

                lanes.push(SubagentLane {
                    id: name.to_string(),
                    name: name.to_string(),
                    role: role.to_string(),
                    target_repo: repo.to_string(),
                    status: lane_status,
                    current_phase: last_step
                        .map(|s| s.phase.clone())
                        .unwrap_or_else(|| parent.current_phase.clone()),
                    current_step_index: last_step
                        .map(|s| s.step_index)
                        .unwrap_or_else(|| last_parent_step.map(|s| s.step_index).unwrap_or(0)),
                    current_action_text: current_action,
                    current_tool_name: current_tool,
                    prompt_brief: desc.to_string(),
                    steps: agent_steps,
                    progress,
                    files_modified: related_files,
                    last_updated: Some(parent.updated_at.to_rfc3339()),
                });
                added_names.insert(name.to_string());
            }
        }
    } else {
        // Dự án độc lập (như muop-agent): Quét xem có custom agent trong .agents/agents/*.md không
        let p_agents = Path::new(&parent.project_path).join(".agents/agents");
        if p_agents.is_dir() {
            if let Ok(entries) = fs::read_dir(p_agents) {
                for entry in entries.flatten() {
                    let path = entry.path();
                    if path.extension().and_then(|e| e.to_str()) == Some("md") {
                        if let Ok(raw) = fs::read_to_string(&path) {
                            let stem = path
                                .file_stem()
                                .and_then(|s| s.to_str())
                                .unwrap_or("agent");
                            let (name, desc, _) = parse_markdown_frontmatter(&raw, stem, "agent");
                            if !added_names.contains(&name) {
                                let mut agent_steps: Vec<AgentStep> = parent
                                    .steps
                                    .iter()
                                    .filter(|s| s.agent_name == name)
                                    .cloned()
                                    .collect();
                                let lane_status = if agent_steps.is_empty() {
                                    "idle".to_string()
                                } else {
                                    "completed".to_string()
                                };
                                if agent_steps.len() > 25 {
                                    agent_steps = agent_steps[agent_steps.len() - 25..].to_vec();
                                }
                                lanes.push(SubagentLane {
                                    id: name.clone(),
                                    name: name.clone(),
                                    role: desc.clone(),
                                    target_repo: parent.project_name.clone(),
                                    status: lane_status,
                                    current_phase: parent.current_phase.clone(),
                                    current_step_index: 0,
                                    current_action_text: format!("Custom Agent trong .agents ({})", name),
                                    current_tool_name: "standby".to_string(),
                                    prompt_brief: desc,
                                    steps: agent_steps,
                                    progress: 0.0,
                                    files_modified: Vec::new(),
                                    last_updated: Some(parent.updated_at.to_rfc3339()),
                                });
                                added_names.insert(name);
                            }
                        }
                    }
                }
            }
        }
    }

    lanes
}

fn infer_target_repo(name: &str, role: &str, prompt: &str) -> String {
    let combined = format!("{} {} {}", name, role, prompt).to_lowercase();
    if combined.contains("erp-app")
        || combined.contains("muop-erp-app")
        || combined.contains("flutter")
    {
        if combined.contains("verifier") || combined.contains("contract") {
            return "muop-erp-server ↔ muop-erp-app".to_string();
        }
        return "muop-erp-app".to_string();
    }
    if combined.contains("erp-server")
        || combined.contains("muop-erp-server")
        || combined.contains("golang")
        || combined.contains("kitchen")
    {
        return "muop-erp-server".to_string();
    }
    "muop-ecosystem".to_string()
}

#[derive(Clone)]
struct CachedTranscript {
    modified: DateTime<Utc>,
    len: u64,
    parsed: std::sync::Arc<ParsedTranscript>,
}

static TRANSCRIPT_CACHE: OnceLock<Mutex<HashMap<String, CachedTranscript>>> = OnceLock::new();

fn get_transcript_cache() -> &'static Mutex<HashMap<String, CachedTranscript>> {
    TRANSCRIPT_CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Ghi model đã dùng cho một lượt agy. Transcript của agy không lưu model nên server tự ghi nhận
/// vào SQLite (xem `store`).
pub fn record_agy_turn_model(conversation_id: &str, started_at: &str, model: &str) {
    crate::store::record_agy_turn_model(conversation_id, started_at, model);
}

fn load_agy_turn_models(conversation_id: &str) -> Vec<(DateTime<Utc>, String)> {
    let mut turns: Vec<(DateTime<Utc>, String)> = crate::store::agy_turn_models(conversation_id)
        .into_iter()
        .filter_map(|(started, model)| {
            let started = DateTime::parse_from_rfc3339(&started)
                .ok()?
                .with_timezone(&Utc);
            Some((started, model))
        })
        .collect();
    turns.sort_by_key(|(started, _)| *started);
    turns
}

#[cfg(test)]
mod agy_model_tests {
    use super::parse_agy_models;

    #[test]
    fn parses_tab_separated_model_list_and_skips_noise() {
        let output = "Fetching available models...\n\
            gemini-4-argon-medium\tGemini 4 Argon (Medium)\n\
            claude-opus-5-5-high\tClaude Opus 5.5 (High)\n\
            \n\
            bad id with space\tX\n";
        assert_eq!(
            parse_agy_models(output),
            vec![
                "agy:gemini-4-argon-medium".to_string(),
                "agy:claude-opus-5-5-high".to_string(),
            ]
        );
    }
}

fn agy_turn_model_at(turns: &[(DateTime<Utc>, String)], at: DateTime<Utc>) -> String {
    // Step được làm tròn theo giây nên cho phép lệch 1 giây khi so với thời điểm bắt đầu lượt
    turns
        .iter()
        .rev()
        .find(|(started, _)| *started <= at + chrono::Duration::seconds(1))
        .map(|(_, model)| model.clone())
        .unwrap_or_default()
}

fn parse_single_agent_step(
    map: &Value,
    step_index: usize,
    file_modified: DateTime<Utc>,
) -> AgentStep {
    let source = map
        .get("source")
        .and_then(|v| v.as_str())
        .unwrap_or("MODEL")
        .to_string();
    let step_type = map
        .get("type")
        .and_then(|v| v.as_str())
        .unwrap_or("GENERIC")
        .to_string();
    let status = map
        .get("status")
        .and_then(|v| v.as_str())
        .unwrap_or("DONE")
        .to_string();
    let content = map
        .get("content")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    let thinking = map
        .get("thinking")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();

    let step_time = map
        .get("created_at")
        .and_then(|v| v.as_str())
        .and_then(|s| DateTime::parse_from_rfc3339(s).ok())
        .map(|dt| dt.with_timezone(&Utc))
        .unwrap_or(file_modified);

    let mut in_tok = map
        .get("input_tokens")
        .and_then(|v| v.as_u64())
        .unwrap_or(0);
    let mut out_tok = map
        .get("output_tokens")
        .and_then(|v| v.as_u64())
        .unwrap_or(0);
    let mut cache_tok = map
        .get("cache_read_tokens")
        .and_then(|v| v.as_u64())
        .unwrap_or(0);

    if in_tok == 0 && out_tok == 0 {
        let char_len = (content.len() + thinking.len()) as u64;
        if step_type == "PLANNER_RESPONSE" {
            out_tok = (char_len / 4).max(48);
            in_tok = 950 + (step_index as u64) * 210;
            cache_tok = (step_index as u64) * 640;
        } else {
            in_tok = (char_len / 4).max(32);
        }
    }

    let mut tool_calls = Vec::new();
    if let Some(Value::Array(raw_calls)) = map.get("tool_calls") {
        for item in raw_calls {
            let t_name = item
                .get("name")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            let mut args_map: HashMap<String, Value> = HashMap::new();
            if let Some(Value::Object(raw_args)) = item.get("args") {
                for (k, v) in raw_args {
                    let str_val = match v {
                        Value::String(s) => clean_quoted_string(s),
                        other => clean_quoted_string(&other.to_string()),
                    };
                    args_map.insert(k.clone(), Value::String(str_val));
                }
            }

            let path_arg = args_map
                .get("Path")
                .and_then(|v| v.as_str())
                .map(|s| s.to_string());
            let repo_tag = classify_repo_from_path(path_arg.as_deref().unwrap_or(""));
            let summary_label = build_tool_summary_label(&t_name, &args_map);

            tool_calls.push(ToolCallInfo {
                name: t_name,
                args: args_map,
                summary_label,
                target_path: path_arg,
                repo_tag,
            });
        }
    }

    let phase = determine_step_phase(&step_type, &tool_calls, &content);
    let (vn_title, vn_detail) =
        describe_step_vietnamese(&step_type, &tool_calls, &content, &thinking);
    let step_agent = classify_step_agent(&step_type, &tool_calls, &content, &thinking);

    AgentStep {
        step_index,
        source,
        step_type: step_type.clone(),
        status,
        created_at: step_time.to_rfc3339(),
        content: clean_user_request_envelope(&step_type, &content),
        thinking,
        tool_calls,
        input_tokens: in_tok,
        output_tokens: out_tok,
        cache_read_tokens: cache_tok,
        agent_name: step_agent,
        phase,
        vietnamese_title: vn_title,
        vietnamese_detail: vn_detail,
        model: String::new(),
    }
}

fn parse_transcript_file(
    id: &str,
    file_modified: DateTime<Utc>,
    db_meta: Option<&DbConversationMeta>,
) -> Option<ParsedTranscript> {
    let path = PathBuf::from(BRAIN_DIR_PATH)
        .join(id)
        .join(".system_generated/logs/transcript.jsonl");

    let meta = fs::metadata(&path).ok()?;
    let file_len = meta.len();

    // 1. Kiểm tra cache trong bộ nhớ RAM (tránh đọc đĩa và parse JSON lặp đi lặp lại)
    if let Ok(cache) = get_transcript_cache().lock() {
        if let Some(entry) = cache.get(id) {
            if entry.modified == file_modified && entry.len == file_len {
                return Some((*entry.parsed).clone());
            }
        }
    }

    use std::collections::VecDeque;
    use std::io::{BufRead, BufReader};

    let file = fs::File::open(&path).ok()?;
    let reader = BufReader::new(file);

    let mut title = db_meta
        .filter(|m| !m.title.is_empty())
        .map(|m| m.title.clone())
        .unwrap_or_else(|| format!("Phiên #{}", id));
    let mut first_user_prompt_title = String::new();
    let mut created_at: Option<DateTime<Utc>> = None;
    let mut updated_at = file_modified;
    let mut total_input: u64 = 0;
    let mut total_output: u64 = 0;
    let mut total_cache: u64 = 0;

    let mut steps_deque: VecDeque<AgentStep> = VecDeque::new();
    let mut files_deque: VecDeque<FileTouchRecord> = VecDeque::new();
    let mut commands_deque: VecDeque<CommandExecutionRecord> = VecDeque::new();
    let mut spawned_subagents: Vec<SpawnedSubagentMeta> = Vec::new();
    let mut pending_subagent_indices: Vec<usize> = Vec::new();

    let conv_id_re = Regex::new(r#""conversationId"\s*:\s*"([^"]+)""#).ok()?;
    let mut total_step_count: usize = 0;
    let mut has_verify = false;
    let mut has_edit_or_parallel = false;
    let agy_turns = load_agy_turn_models(id);

    for line_res in reader.lines() {
        let line = match line_res {
            Ok(l) => l,
            Err(_) => continue,
        };
        if line.trim().is_empty() {
            continue;
        }
        let map: Value = match serde_json::from_str(&line) {
            Ok(v) => v,
            Err(_) => continue,
        };

        let step_index = map
            .get("step_index")
            .and_then(|v| v.as_u64())
            .map(|v| v as usize)
            .unwrap_or(total_step_count);

        total_step_count += 1;

        let mut step = parse_single_agent_step(&map, step_index, file_modified);
        let step_time = match DateTime::parse_from_rfc3339(&step.created_at) {
            Ok(dt) => dt.with_timezone(&Utc),
            Err(_) => file_modified,
        };
        if step.step_type == "PLANNER_RESPONSE" {
            step.model = agy_turn_model_at(&agy_turns, step_time);
        }

        if created_at.is_none() {
            created_at = Some(step_time);
        }
        if step_time > updated_at {
            updated_at = step_time;
        }

        total_input += step.input_tokens;
        total_output += step.output_tokens;
        total_cache += step.cache_read_tokens;

        if step.step_type == "USER_INPUT" && !step.content.is_empty() && first_user_prompt_title.is_empty() {
            let extracted = extract_user_request(&step.content);
            if !extracted.is_empty() {
                first_user_prompt_title = extracted;
            }
        }

        if step.phase == "crossVerification" {
            has_verify = true;
        } else if step.phase == "parallelExecution" {
            has_edit_or_parallel = true;
        }

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
                    files_deque.push_back(FileTouchRecord {
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
                    if files_deque.len() > 80 {
                        files_deque.pop_front();
                    }
                }
            }

            if tc.name == "run_command" {
                let cmd_line = tc.args
                    .get("CommandLine")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string();
                let summary = tc.args
                    .get("toolSummary")
                    .and_then(|v| v.as_str())
                    .unwrap_or("Thực thi lệnh terminal")
                    .to_string();
                let cmd_agent = if cmd_line.contains("flutter analyze")
                    || cmd_line.contains("go build")
                {
                    "erp-contract-verifier"
                } else if cmd_line.contains("muop-erp-server") {
                    "erp-server-agent"
                } else if cmd_line.contains("muop-erp-app") {
                    "erp-app-agent"
                } else {
                    "Coordinator"
                };
                commands_deque.push_back(CommandExecutionRecord {
                    command_line: cmd_line,
                    summary,
                    agent_name: cmd_agent.to_string(),
                    step_index,
                    timestamp: step.created_at.clone(),
                    output_preview: String::new(),
                    is_success: true,
                });
                if commands_deque.len() > 40 {
                    commands_deque.pop_front();
                }
            }

            if tc.name == "invoke_subagent" {
                let role = tc.args
                    .get("Role")
                    .and_then(|v| v.as_str())
                    .unwrap_or("Subagent Worker")
                    .to_string();
                let type_name = tc.args
                    .get("TypeName")
                    .and_then(|v| v.as_str())
                    .unwrap_or("self")
                    .to_string();
                let prompt = tc.args
                    .get("Prompt")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string();
                let name = if type_name == "self" {
                    role.clone()
                } else {
                    type_name
                };
                let idx = spawned_subagents.len();
                spawned_subagents.push(SpawnedSubagentMeta {
                    id: String::new(),
                    name,
                    role: role.clone(),
                    prompt,
                    step_index,
                    status: "running".to_string(),
                    last_action: format!("Đang khởi chạy Subagent: {}", role),
                    tool_name: "invoke_subagent".to_string(),
                });
                pending_subagent_indices.push(idx);
            }
        }

        if step.step_type == "GENERIC"
            && step.content.contains("Created the following subagent:")
            && !pending_subagent_indices.is_empty()
        {
            let idx = pending_subagent_indices.remove(0);
            if let Some(caps) = conv_id_re.captures(&step.content) {
                if let Some(m) = caps.get(1) {
                    if let Some(sub) = spawned_subagents.get_mut(idx) {
                        sub.id = m.as_str().to_string();
                    }
                }
            }
        }

        if step.step_type == "SYSTEM_MESSAGE" && step.content.contains("<SYSTEM_MESSAGE>") {
            for sub in &mut spawned_subagents {
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

        steps_deque.push_back(step);
        if steps_deque.len() > 150 {
            steps_deque.pop_front();
        }
    }

    if total_step_count == 0 {
        return None;
    }

    let steps: Vec<AgentStep> = steps_deque.into_iter().collect();
    let files_touched: Vec<FileTouchRecord> = files_deque.into_iter().collect();
    let commands_run: Vec<CommandExecutionRecord> = commands_deque.into_iter().collect();

    if title.starts_with("Phiên #") && !first_user_prompt_title.is_empty() {
        title = first_user_prompt_title;
    }

    let mut project_name = db_meta.map(|m| m.project_name.clone()).unwrap_or_default();
    let mut project_path = db_meta.map(|m| m.project_path.clone()).unwrap_or_default();
    if project_name.is_empty() {
        for f in &files_touched {
            if f.repo != "system" && f.repo != ".agents" {
                project_name = f.repo.clone();
                project_path = format!("{}/{}", ECOSYSTEM_DIR_PATH, f.repo);
                break;
            }
        }
        if project_name.is_empty() {
            project_name = "muop-erp-server".to_string();
            project_path = format!("{}/muop-erp-server", ECOSYSTEM_DIR_PATH);
        }
    }

    let mut session_status = "completed".to_string();
    let mut current_phase = "completed".to_string();

    if let Some(last) = steps.last() {
        // Đánh giá trạng thái chính xác theo tiến trình thực tế trong transcript:
        // 1. Nếu bước cuối cùng là PLANNER_RESPONSE và không còn tool_calls -> ĐÃ HOÀN TẤT LƯỢT TRẢ LỜI
        if last.step_type == "PLANNER_RESPONSE" && last.tool_calls.is_empty() {
            session_status = "completed".to_string();
        } else if last.status != "DONE" || !last.tool_calls.is_empty() {
            // Bước cuối chưa DONE hoặc đang gọi tool_call:
            // Chỉ coi là đang chạy nếu file vừa mới được ghi log gần đây (dưới 20 giây).
            // Nếu đã quá 20 giây không có hoạt động, tiến trình đã dừng hoặc bị ngắt!
            let age_secs = (Utc::now() - updated_at).num_seconds().abs();
            if age_secs < 20 {
                session_status = "running".to_string();
            } else {
                session_status = "interrupted".to_string();
            }
        } else {
            // Bước cuối là GENERIC hoặc USER_INPUT: chỉ coi là đang chạy nếu phát sinh rất gần (dưới 15 giây)
            let age_secs = (Utc::now() - updated_at).num_seconds().abs();
            if age_secs < 15 && (last.step_type == "GENERIC" || last.step_type == "USER_INPUT") {
                session_status = "running".to_string();
            } else {
                session_status = "completed".to_string();
            }
        }

        if session_status == "completed" {
            current_phase = "completed".to_string();
        } else if has_verify {
            current_phase = "crossVerification".to_string();
        } else if has_edit_or_parallel {
            current_phase = "parallelExecution".to_string();
        } else {
            current_phase = "contractDiscovery".to_string();
        }
    }

    let parsed_res = ParsedTranscript {
        id: id.to_string(),
        title,
        created_at: created_at.unwrap_or(file_modified),
        updated_at,
        status: session_status,
        current_phase,
        steps,
        files_touched,
        commands_run,
        spawned_subagents,
        total_input_tokens: total_input,
        total_output_tokens: total_output,
        total_cache_tokens: total_cache,
        project_name,
        project_path,
        total_steps: total_step_count,
    };

    if let Ok(mut cache) = get_transcript_cache().lock() {
        cache.insert(
            id.to_string(),
            CachedTranscript {
                modified: file_modified,
                len: file_len,
                parsed: std::sync::Arc::new(parsed_res.clone()),
            },
        );
    }

    Some(parsed_res)
}

fn clean_user_request_envelope(step_type: &str, raw: &str) -> String {
    if step_type != "USER_INPUT" {
        return raw.to_string();
    }
    if let Some(start) = raw.find("<USER_REQUEST>") {
        let after = &raw[start + "<USER_REQUEST>".len()..];
        if let Some(end) = after.find("</USER_REQUEST>") {
            return after[..end].trim().to_string();
        }
    }
    raw.trim().to_string()
}

fn extract_user_request(raw: &str) -> String {
    let cleaned = clean_user_request_envelope("USER_INPUT", raw);
    let first_line = cleaned
        .lines()
        .map(|s| s.trim())
        .find(|s| !s.is_empty())
        .unwrap_or("Yêu cầu từ người dùng");
    let chars: Vec<char> = first_line.chars().collect();
    if chars.len() > 95 {
        let truncated: String = chars.into_iter().take(92).collect();
        format!("{}...", truncated)
    } else {
        first_line.to_string()
    }
}

fn safe_truncate(s: &str, max_bytes: usize) -> &str {
    if s.len() <= max_bytes {
        s
    } else {
        let mut idx = max_bytes;
        while idx > 0 && !s.is_char_boundary(idx) {
            idx -= 1;
        }
        &s[..idx]
    }
}

fn clean_quoted_string(val: &str) -> String {
    let mut s = val.trim().to_string();
    if s.len() >= 2 && s.starts_with('"') && s.ends_with('"') {
        s = s[1..s.len() - 1].to_string();
    }
    s.replace(r#"\""#, "\"").replace(r"\n", "\n")
}

fn classify_repo_from_path(path: &str) -> String {
    if path.contains(".agents/") || path.ends_with("AGENTS.md") {
        return ".agents".to_string();
    }
    if path.contains("muop-erp-androidtv") {
        return "muop-erp-androidtv".to_string();
    }
    if path.contains("muop-erp-web") {
        return "muop-erp-web".to_string();
    }
    if path.contains("muop-erp-app") {
        return "muop-erp-app".to_string();
    }
    if path.contains("muop-erp-server") {
        return "muop-erp-server".to_string();
    }
    if path.contains("muop-agent") || path.contains("muop_agent") {
        return "muop-agent".to_string();
    }
    "system".to_string()
}

fn build_tool_summary_label(tool_name: &str, args: &HashMap<String, Value>) -> String {
    let path = args.get("Path").and_then(|v| v.as_str()).unwrap_or("");
    let basename = path.split('/').last().unwrap_or("");

    match tool_name {
        "read_file" => format!("Đọc tệp {}", basename),
        "write_file" => format!("Tạo/Ghi tệp {}", basename),
        "edit_file" => format!("Chỉnh sửa tệp {}", basename),
        "run_command" => {
            let sum = args
                .get("toolSummary")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .trim();
            if !sum.is_empty() {
                sum.to_string()
            } else {
                let cmd = args
                    .get("CommandLine")
                    .and_then(|v| v.as_str())
                    .unwrap_or("");
                format!("Chạy lệnh: {}", cmd)
            }
        }
        "invoke_subagent" => {
            let role = args
                .get("Role")
                .or_else(|| args.get("TypeName"))
                .and_then(|v| v.as_str())
                .unwrap_or("");
            format!("Chạy Subagent: {}", role)
        }
        "define_subagent" => {
            let name = args.get("Name").and_then(|v| v.as_str()).unwrap_or("");
            format!("Đăng ký Subagent: {}", name)
        }
        "send_message" => {
            let rec = args
                .get("Recipient")
                .and_then(|v| v.as_str())
                .unwrap_or("Subagent");
            format!("Gửi message tới {}", rec)
        }
        "manage_subagents" => {
            let act = args
                .get("Action")
                .and_then(|v| v.as_str())
                .unwrap_or("list");
            format!("Quản lý Subagents ({})", act)
        }
        "grep_search" => {
            let q = args.get("Query").and_then(|v| v.as_str()).unwrap_or("");
            format!("Tìm chuỗi \"{}\"", q)
        }
        "find_by_name" => {
            let p = args.get("Pattern").and_then(|v| v.as_str()).unwrap_or("");
            format!("Tìm tệp \"{}\"", p)
        }
        _ => tool_name.to_string(),
    }
}

fn determine_step_phase(step_type: &str, tools: &[ToolCallInfo], content: &str) -> String {
    if step_type == "USER_INPUT" {
        return "contractDiscovery".to_string();
    }
    if tools.is_empty() && step_type == "PLANNER_RESPONSE" && !content.is_empty() {
        return "completed".to_string();
    }
    for t in tools {
        if t.name == "run_command" {
            let cmd = t
                .args
                .get("CommandLine")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_lowercase();
            let summary = t
                .args
                .get("toolSummary")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_lowercase();
            if cmd.contains("git commit") || summary.contains("commit") {
                return "gitCommit".to_string();
            }
            if cmd.contains("go build")
                || cmd.contains("flutter analyze")
                || cmd.contains("flutter test")
                || cmd.contains("go test")
                || cmd.contains("cargo build")
            {
                return "crossVerification".to_string();
            }
        }
        if t.name == "invoke_subagent"
            || t.name == "define_subagent"
            || t.name == "write_file"
            || t.name == "edit_file"
        {
            return "parallelExecution".to_string();
        }
    }
    "contractDiscovery".to_string()
}

fn describe_step_vietnamese(
    step_type: &str,
    tools: &[ToolCallInfo],
    content: &str,
    thinking: &str,
) -> (String, String) {
    if step_type == "USER_INPUT" {
        let req = extract_user_request(content);
        return ("Nhận yêu cầu từ người dùng".to_string(), req);
    }
    if step_type == "SYSTEM_MESSAGE" {
        if content.contains("finished with result") {
            return (
                "Tác vụ nền (Background Task) hoàn tất".to_string(),
                first_lines(content, 2),
            );
        }
        if content.contains("sender=") {
            return (
                "Nhận báo cáo đồng bộ từ Subagent".to_string(),
                first_lines(content, 3),
            );
        }
        return (
            "Thông báo hệ thống (System Wakeup)".to_string(),
            first_lines(content, 2),
        );
    }
    if step_type == "GENERIC" {
        if content.contains("Created the following subagent:") {
            return (
                "Đã khởi tạo phiên Subagent song song".to_string(),
                first_lines(content, 4),
            );
        }
        if content.contains("Created file") {
            return ("Đã tạo tệp mới thành công".to_string(), content.trim().to_string());
        }
        if content.contains("Made ") && content.contains("replacement") {
            return (
                "Đã cập nhật nội dung tệp".to_string(),
                content.trim().to_string(),
            );
        }
        return (
            "Kết quả thực thi công cụ".to_string(),
            first_lines(content, 2),
        );
    }
    if !tools.is_empty() {
        for t in tools {
            if t.name == "run_command" {
                let cmd = t.args.get("CommandLine").and_then(|v| v.as_str()).unwrap_or("");
                let cmd_lower = cmd.to_lowercase();
                let summary = t.args.get("toolSummary").and_then(|v| v.as_str()).unwrap_or("");
                if cmd_lower.contains("git commit") || summary.to_lowercase().contains("commit") {
                    let commit_msg = extract_commit_message(cmd, summary);
                    let title = if step_type == "PLANNER_RESPONSE" {
                        "Đang thực hiện Git Commit mã nguồn".to_string()
                    } else {
                        "Git Commit mã nguồn".to_string()
                    };
                    let detail = if !commit_msg.is_empty() {
                        format!("Nội dung commit: {}", commit_msg)
                    } else {
                        cmd.to_string()
                    };
                    return (title, detail);
                }
            }
        }

        let labels: Vec<String> = tools.iter().map(|t| t.summary_label.clone()).collect();
        let joined = labels.join(" • ");
        let detail = if !thinking.trim().is_empty() {
            first_lines(thinking.trim(), 2)
        } else {
            joined.clone()
        };
        return (joined, detail);
    }
    if !content.trim().is_empty() {
        return (
            "Phản hồi & Tổng hợp kết quả bàn giao".to_string(),
            first_lines(content, 2),
        );
    }
    (
        "Suy luận chiến lược (Thinking)".to_string(),
        first_lines(thinking, 2),
    )
}

fn extract_commit_message(cmd: &str, summary: &str) -> String {
    if let Some(pos) = cmd.find("-m ") {
        let rest = cmd[pos + 3..].trim_start();
        if rest.starts_with('"') {
            if let Some(end) = rest[1..].find('"') {
                return rest[1..1 + end].to_string();
            }
        } else if rest.starts_with('\'') {
            if let Some(end) = rest[1..].find('\'') {
                return rest[1..1 + end].to_string();
            }
        }
    }
    if !summary.trim().is_empty() && summary != "run_command" {
        return summary.trim().to_string();
    }
    cmd.trim().to_string()
}

fn first_lines(text: &str, max_lines: usize) -> String {
    let mut lines = Vec::new();
    for line in text.lines() {
        let trimmed = line.trim();
        if !trimmed.is_empty() && !trimmed.starts_with('<') {
            lines.push(trimmed);
            if lines.len() >= max_lines {
                break;
            }
        }
    }
    let joined = lines.join(" — ");
    let chars: Vec<char> = joined.chars().collect();
    if chars.len() > 160 {
        let truncated: String = chars.into_iter().take(157).collect();
        format!("{}...", truncated)
    } else {
        joined
    }
}

fn extract_tool_diff(tool_name: &str, args: &HashMap<String, Value>) -> (usize, usize, String) {
    match tool_name {
        "write_file" => {
            let content = args
                .get("Content")
                .and_then(|v| v.as_str())
                .unwrap_or("");
            let lines: Vec<&str> = content.lines().collect();
            let added = lines.len().max(1);
            let mut preview = String::new();
            for line in lines.into_iter().take(24) {
                preview.push_str("+ ");
                preview.push_str(line);
                preview.push('\n');
            }
            (added, 0, preview.trim_end().to_string())
        }
        "edit_file" => {
            let target = args
                .get("Target")
                .and_then(|v| v.as_str())
                .unwrap_or("");
            let replacement = args
                .get("Replacement")
                .and_then(|v| v.as_str())
                .unwrap_or("");
            let t_lines: Vec<&str> = target.lines().collect();
            let r_lines: Vec<&str> = replacement.lines().collect();
            let removed = t_lines.len().max(1);
            let added = r_lines.len().max(1);
            let mut preview = String::new();
            for line in t_lines.into_iter().take(14) {
                preview.push_str("- ");
                preview.push_str(line);
                preview.push('\n');
            }
            for line in r_lines.into_iter().take(14) {
                preview.push_str("+ ");
                preview.push_str(line);
                preview.push('\n');
            }
            (added, removed, preview.trim_end().to_string())
        }
        _ => (0, 0, String::new()),
    }
}
