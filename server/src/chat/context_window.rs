//! Cửa sổ ngữ cảnh (context window) của conversation Antigravity (agy).
//!
//! Thứ tự nguồn dữ liệu:
//! 1. **RPC của hub agy** (`GetCascadeTrajectoryGeneratorMetadata` trên language server cục bộ):
//!    cho `estimatedTokensUsed` và `maxContextTokens` của lượt gọi model gần nhất. Kết quả được
//!    lưu vào bảng `conversation_context`.
//! 2. **DB** (`conversation_context`): khi hub không chạy được thì dùng giá trị đã lưu lần đọc trước.
//! 3. **`gen_metadata`** trong `conversations/<cid>.db` (protobuf không có schema): chỉ dùng cho
//!    conversation chưa từng đọc được qua RPC.
//!
//! Snapshot không bao giờ chờ RPC: khi DB đã cũ, conversation được đưa vào hàng đợi và một worker
//! nền gọi RPC rồi ghi DB. RPC chỉ được gọi lại khi conversation đổi sau lần đọc gần nhất.
//! Sau một lần lỗi, conversation đó không gọi lại trong `RPC_BACKOFF`.

use crate::infra::store::StoredConversationContext;
use chrono::{DateTime, FixedOffset};
use rusqlite::{Connection, OpenFlags};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

/// Kết quả đọc context của một conversation agy
#[derive(Debug, Clone, Default)]
pub struct AgyContextUsage {
    /// Số token context đang dùng ở lượt gọi model gần nhất
    pub tokens: u64,
    /// Id đầy đủ của model (`agy:<id>`), rỗng nếu không xác định được
    pub model: String,
    /// Giới hạn context agy báo cho model (0 nếu không rõ)
    pub max_context_tokens: u64,
}

const RPC_PATH: &str =
    "/exa.language_server_pb.LanguageServerService/GetCascadeTrajectoryGeneratorMetadata";
const RPC_BACKOFF: Duration = Duration::from_secs(30);
/// Response của conversation dài có thể tới ~12MB, nên cho thời gian đủ lớn
const RPC_TIMEOUT_SECS: &str = "120";
const RPC_SOURCE: &str = "agy-rpc";
const GEN_METADATA_SOURCE: &str = "agy-gen-metadata";

/// Cache của đường đọc `gen_metadata`: (idx bản ghi mới nhất đã đọc, kết quả)
type GenCache = HashMap<String, (i64, Option<AgyContextUsage>)>;
static GEN_CACHE: OnceLock<Mutex<GenCache>> = OnceLock::new();
/// Thời điểm RPC lỗi gần nhất của mỗi conversation
static RPC_FAILED_AT: OnceLock<Mutex<HashMap<String, Instant>>> = OnceLock::new();
/// Hàng đợi conversation cần đọc qua RPC: id → (updated_at của session, ánh xạ nhãn → id)
type RefreshJob = (String, HashMap<String, String>);
static RPC_QUEUE: OnceLock<Mutex<HashMap<String, RefreshJob>>> = OnceLock::new();
static RPC_WORKER_RUNNING: OnceLock<Mutex<bool>> = OnceLock::new();

/// Đọc context của một conversation agy, không chờ RPC.
/// - `label_to_id`: ánh xạ nhãn model → `agy:<id>`
/// - `conversation_updated_at`: `updated_at` của session, dùng để biết DB đã cũ chưa
///
/// Nếu DB chưa mới, conversation được xếp vào hàng đợi để worker nền đọc qua RPC và ghi DB.
/// Lần snapshot này trả về giá trị đang có trong DB (hoặc gen_metadata nếu DB chưa có).
pub fn agy_context_usage(
    conversation_id: &str,
    label_to_id: &HashMap<String, String>,
    conversation_updated_at: &str,
) -> Option<AgyContextUsage> {
    if !is_valid_conversation_id(conversation_id) {
        return None;
    }
    let stored = crate::infra::store::load_conversation_context(conversation_id);
    if let Some(s) = &stored {
        if is_fresh(&s.conversation_updated_at, conversation_updated_at) {
            return Some(from_stored(s));
        }
    }
    enqueue_refresh(conversation_id, conversation_updated_at, label_to_id);

    if let Some(s) = &stored {
        return Some(from_stored(s));
    }
    read_gen_metadata_usage(conversation_id, label_to_id)
}

/// Đưa conversation vào hàng đợi và khởi động worker nếu chưa chạy
fn enqueue_refresh(
    conversation_id: &str,
    conversation_updated_at: &str,
    label_to_id: &HashMap<String, String>,
) {
    if rpc_in_backoff(conversation_id) {
        return;
    }
    let queue = RPC_QUEUE.get_or_init(|| Mutex::new(HashMap::new()));
    let Ok(mut q) = queue.lock() else {
        return;
    };
    // Đã có trong hàng đợi thì không xếp lại
    if q.contains_key(conversation_id) {
        return;
    }
    q.insert(
        conversation_id.to_string(),
        (conversation_updated_at.to_string(), label_to_id.clone()),
    );
    drop(q);

    let running = RPC_WORKER_RUNNING.get_or_init(|| Mutex::new(false));
    if let Ok(mut flag) = running.lock() {
        if !*flag {
            *flag = true;
            std::thread::spawn(run_refresh_worker);
        }
    }
}

/// Worker nền: lấy từng conversation trong hàng đợi, gọi RPC và ghi DB. Thoát khi hàng đợi rỗng.
fn run_refresh_worker() {
    loop {
        let next = RPC_QUEUE.get().and_then(|q| {
            let mut q = q.lock().ok()?;
            let key = q.keys().next()?.clone();
            let job = q.remove(&key)?;
            Some((key, job))
        });
        let Some((conversation_id, (conversation_updated_at, label_to_id))) = next else {
            break;
        };
        refresh_from_rpc(&conversation_id, &conversation_updated_at, &label_to_id);
    }
    if let Some(running) = RPC_WORKER_RUNNING.get() {
        if let Ok(mut flag) = running.lock() {
            *flag = false;
        }
    }
    // Có job được xếp trong lúc worker đang thoát thì khởi động lại
    let pending = RPC_QUEUE
        .get()
        .and_then(|q| q.lock().ok().map(|q| !q.is_empty()))
        .unwrap_or(false);
    if pending {
        if let Some(running) = RPC_WORKER_RUNNING.get() {
            if let Ok(mut flag) = running.lock() {
                if !*flag {
                    *flag = true;
                    std::thread::spawn(run_refresh_worker);
                }
            }
        }
    }
}

fn refresh_from_rpc(
    conversation_id: &str,
    conversation_updated_at: &str,
    label_to_id: &HashMap<String, String>,
) {
    match fetch_latest_generation(conversation_id, label_to_id) {
        Ok(latest) => {
            rpc_clear_failure(conversation_id);
            let usage = latest.unwrap_or_default();
            let saved = StoredConversationContext {
                model_id: usage.model.clone(),
                context_tokens: usage.tokens,
                max_context_tokens: usage.max_context_tokens,
                conversation_updated_at: conversation_updated_at.to_string(),
                source: RPC_SOURCE.to_string(),
            };
            crate::infra::store::save_conversation_context(conversation_id, &saved);
            if !usage.model.is_empty() && usage.max_context_tokens > 0 {
                crate::infra::store::upsert_context_limit(
                    &usage.model,
                    usage.max_context_tokens,
                    RPC_SOURCE,
                );
            }
        }
        Err(()) => rpc_mark_failure(conversation_id),
    }
}

fn from_stored(s: &StoredConversationContext) -> AgyContextUsage {
    AgyContextUsage {
        tokens: s.context_tokens,
        model: s.model_id.clone(),
        max_context_tokens: s.max_context_tokens,
    }
}

fn is_valid_conversation_id(conversation_id: &str) -> bool {
    // Chỉ chấp nhận id dạng UUID/chữ-số-gạch: id này được đưa vào đường dẫn file và JSON
    !conversation_id.is_empty()
        && conversation_id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-')
}

/// `stored` có mới hơn hoặc bằng `session` không (cả hai là RFC3339)
fn is_fresh(stored: &str, session: &str) -> bool {
    match (
        DateTime::<FixedOffset>::parse_from_rfc3339(stored),
        DateTime::<FixedOffset>::parse_from_rfc3339(session),
    ) {
        (Ok(a), Ok(b)) => a >= b,
        _ => false,
    }
}

fn rpc_in_backoff(conversation_id: &str) -> bool {
    let map = RPC_FAILED_AT.get_or_init(|| Mutex::new(HashMap::new()));
    map.lock()
        .ok()
        .and_then(|m| m.get(conversation_id).map(|t| t.elapsed() < RPC_BACKOFF))
        .unwrap_or(false)
}

fn rpc_mark_failure(conversation_id: &str) {
    let map = RPC_FAILED_AT.get_or_init(|| Mutex::new(HashMap::new()));
    if let Ok(mut m) = map.lock() {
        m.insert(conversation_id.to_string(), Instant::now());
    }
}

fn rpc_clear_failure(conversation_id: &str) {
    let map = RPC_FAILED_AT.get_or_init(|| Mutex::new(HashMap::new()));
    if let Ok(mut m) = map.lock() {
        m.remove(conversation_id);
    }
}

// ---------------------------------------------------------------------------
// RPC tới hub agy
// ---------------------------------------------------------------------------

/// Lượt gọi model gần nhất của một conversation. `Ok(None)` nghĩa là conversation chưa có lượt nào.
fn fetch_latest_generation(
    conversation_id: &str,
    label_to_id: &HashMap<String, String>,
) -> Result<Option<AgyContextUsage>, ()> {
    let (port, token) = discover_hub().ok_or(())?;
    let body = json!({ "cascadeId": conversation_id }).to_string();
    let response = rpc_post(port, &token, &body)?;
    let generations = response
        .get("generatorMetadata")
        .and_then(Value::as_array)
        .ok_or(())?;

    // Lấy lượt có chỉ số bước lớn nhất
    let latest = generations
        .iter()
        .filter_map(|g| {
            let step = g
                .get("stepIndices")?
                .as_array()?
                .iter()
                .filter_map(json_u64)
                .max()?;
            Some((step, g))
        })
        .max_by_key(|(step, _)| *step)
        .map(|(_, g)| g);
    let Some(g) = latest else {
        return Ok(None);
    };

    let chat = g.get("chatModel").ok_or(())?;
    let window = chat
        .get("chatStartMetadata")
        .and_then(|c| c.get("contextWindowMetadata"));
    let tokens = window
        .and_then(|w| w.get("estimatedTokensUsed"))
        .and_then(json_u64)
        .unwrap_or(0);
    let max_context_tokens = window
        .and_then(|w| w.get("maxContextTokens"))
        .and_then(json_u64)
        .unwrap_or(0);
    let model = chat
        .get("modelDisplayName")
        .and_then(Value::as_str)
        .and_then(|label| label_to_id.get(label).cloned())
        .unwrap_or_default();

    Ok(Some(AgyContextUsage {
        tokens,
        model,
        max_context_tokens,
    }))
}

/// protobuf JSON trả số dưới dạng số hoặc chuỗi tùy trường
fn json_u64(v: &Value) -> Option<u64> {
    v.as_u64().or_else(|| v.as_str()?.parse().ok())
}

/// Đọc file discovery `daemon/hub_<port>.json` của hub đang chạy (pid còn sống).
/// Trả về (cổng HTTP, CSRF token).
fn discover_hub() -> Option<(u16, String)> {
    let home = PathBuf::from(std::env::var("HOME").ok()?);
    let dir = home.join(".gemini/antigravity/daemon");
    for entry in fs::read_dir(dir).ok()?.flatten() {
        let name = entry.file_name().to_string_lossy().to_string();
        if !(name.starts_with("hub_") && name.ends_with(".json")) {
            continue;
        }
        let Ok(raw) = fs::read_to_string(entry.path()) else {
            continue;
        };
        let Ok(v) = serde_json::from_str::<Value>(&raw) else {
            continue;
        };
        let (Some(pid), Some(port), Some(token)) = (
            v.get("pid").and_then(Value::as_u64),
            v.get("httpPort").and_then(Value::as_u64),
            v.get("csrfToken").and_then(Value::as_str),
        ) else {
            continue;
        };
        // Token được ghép vào file cấu hình của curl: chỉ nhận ký tự an toàn
        let token_ok = !token.is_empty()
            && token
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_');
        if !token_ok || port == 0 || port > u64::from(u16::MAX) {
            continue;
        }
        if !Path::new("/proc").join(pid.to_string()).exists() {
            continue;
        }
        return Some((port as u16, token.to_string()));
    }
    None
}

/// Gọi RPC bằng curl. Token và body đi qua stdin (`-K -`) để không lộ trên dòng lệnh.
fn rpc_post(port: u16, token: &str, body: &str) -> Result<Value, ()> {
    let escaped_body = body.replace('\\', "\\\\").replace('"', "\\\"");
    let config = format!(
        "url = \"http://127.0.0.1:{port}{RPC_PATH}\"\n\
         header = \"Content-Type: application/json\"\n\
         header = \"x-codeium-csrf-token: {token}\"\n\
         data = \"{escaped_body}\"\n"
    );
    let mut child = Command::new("curl")
        .args(["-s", "-m", RPC_TIMEOUT_SECS, "-K", "-"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|_| ())?;
    if let Some(mut stdin) = child.stdin.take() {
        let _ = stdin.write_all(config.as_bytes());
    }
    let out = child.wait_with_output().map_err(|_| ())?;
    if !out.status.success() {
        return Err(());
    }
    serde_json::from_slice::<Value>(&out.stdout).map_err(|_| ())
}

// ---------------------------------------------------------------------------
// Đường đọc gen_metadata (dự phòng cho conversation chưa từng đọc được qua RPC)
// ---------------------------------------------------------------------------

fn read_gen_metadata_usage(
    conversation_id: &str,
    label_to_id: &HashMap<String, String>,
) -> Option<AgyContextUsage> {
    let db = conversation_db_path(conversation_id)?;
    let conn = Connection::open_with_flags(&db, OpenFlags::SQLITE_OPEN_READ_ONLY).ok()?;

    let latest_idx: i64 = conn
        .query_row(
            "SELECT idx FROM gen_metadata ORDER BY idx DESC LIMIT 1",
            [],
            |r| r.get(0),
        )
        .ok()?;

    let cache = GEN_CACHE.get_or_init(|| Mutex::new(HashMap::new()));
    if let Ok(map) = cache.lock() {
        if let Some((idx, usage)) = map.get(conversation_id) {
            if *idx == latest_idx {
                return usage.clone();
            }
        }
    }

    let usage = read_latest_gen_metadata(&conn, label_to_id);
    if let Ok(mut map) = cache.lock() {
        map.insert(conversation_id.to_string(), (latest_idx, usage.clone()));
    }
    usage
}

fn read_latest_gen_metadata(
    conn: &Connection,
    label_to_id: &HashMap<String, String>,
) -> Option<AgyContextUsage> {
    let mut stmt = conn
        .prepare("SELECT data FROM gen_metadata ORDER BY idx DESC LIMIT 5")
        .ok()?;
    let blobs = stmt
        .query_map([], |r| r.get::<_, Vec<u8>>(0))
        .ok()?
        .filter_map(Result::ok);

    for data in blobs {
        // Bản ghi không có giới hạn thì thử bản ghi cũ hơn
        let Some(limit) = pb_varint(&data, &[1, 9, 10, 4]) else {
            continue;
        };
        let tokens = pb_varint(&data, &[1, 9, 10, 1]).unwrap_or(0);
        let model = resolve_model_id(&data, label_to_id);
        if !model.is_empty() {
            crate::infra::store::upsert_context_limit(&model, limit, GEN_METADATA_SOURCE);
        }
        return Some(AgyContextUsage {
            tokens,
            model,
            max_context_tokens: limit,
        });
    }
    None
}

fn resolve_model_id(data: &[u8], label_to_id: &HashMap<String, String>) -> String {
    if let Some(id) = pb_bytes(data, &[3, 28]).filter(|s| !s.is_empty()) {
        return format!("agy:{id}");
    }
    pb_bytes(data, &[1, 21])
        .and_then(|label| label_to_id.get(&label).cloned())
        .unwrap_or_default()
}

fn conversation_db_path(conversation_id: &str) -> Option<PathBuf> {
    let home = PathBuf::from(std::env::var("HOME").ok()?);
    ["antigravity", "antigravity-cli"]
        .iter()
        .map(|dir| home.join(".gemini").join(dir).join("conversations"))
        .map(|dir| dir.join(format!("{conversation_id}.db")))
        .find(|p| p.is_file())
}

// ---------------------------------------------------------------------------
// Bộ giải mã protobuf tối thiểu: chỉ tìm giá trị theo đường dẫn số thứ tự trường
// ---------------------------------------------------------------------------

enum PbValue<'a> {
    Varint(u64),
    Bytes(&'a [u8]),
}

fn read_varint(buf: &[u8], i: &mut usize) -> Option<u64> {
    let mut result = 0u64;
    let mut shift = 0u32;
    loop {
        let byte = *buf.get(*i)?;
        *i += 1;
        if shift >= 64 {
            return None;
        }
        result |= u64::from(byte & 0x7f) << shift;
        if byte & 0x80 == 0 {
            return Some(result);
        }
        shift += 7;
    }
}

/// Tìm giá trị tại đường dẫn `path` (số thứ tự trường lồng nhau). Lấy lần xuất hiện đầu tiên.
fn pb_get<'a>(buf: &'a [u8], path: &[u64]) -> Option<PbValue<'a>> {
    let (first, rest) = path.split_first()?;
    let mut i = 0usize;
    while i < buf.len() {
        let key = read_varint(buf, &mut i)?;
        let field = key >> 3;
        match key & 7 {
            0 => {
                let v = read_varint(buf, &mut i)?;
                if field == *first && rest.is_empty() {
                    return Some(PbValue::Varint(v));
                }
            }
            2 => {
                let len = usize::try_from(read_varint(buf, &mut i)?).ok()?;
                let end = i.checked_add(len)?;
                let sub = buf.get(i..end)?;
                i = end;
                if field == *first {
                    if rest.is_empty() {
                        return Some(PbValue::Bytes(sub));
                    }
                    if let Some(found) = pb_get(sub, rest) {
                        return Some(found);
                    }
                }
            }
            1 => i = i.checked_add(8)?,
            5 => i = i.checked_add(4)?,
            _ => return None,
        }
    }
    None
}

fn pb_varint(buf: &[u8], path: &[u64]) -> Option<u64> {
    match pb_get(buf, path)? {
        PbValue::Varint(v) => Some(v),
        PbValue::Bytes(_) => None,
    }
}

fn pb_bytes(buf: &[u8], path: &[u64]) -> Option<String> {
    match pb_get(buf, path)? {
        PbValue::Bytes(b) => Some(String::from_utf8_lossy(b).to_string()),
        PbValue::Varint(_) => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn varint(mut v: u64) -> Vec<u8> {
        let mut out = Vec::new();
        loop {
            let b = (v & 0x7f) as u8;
            v >>= 7;
            if v == 0 {
                out.push(b);
                return out;
            }
            out.push(b | 0x80);
        }
    }

    fn field_varint(f: u64, v: u64) -> Vec<u8> {
        [varint(f << 3), varint(v)].concat()
    }

    fn field_bytes(f: u64, b: &[u8]) -> Vec<u8> {
        [varint((f << 3) | 2), varint(b.len() as u64), b.to_vec()].concat()
    }

    #[test]
    fn decodes_nested_varint_and_bytes() {
        let counters = [field_varint(1, 88444), field_varint(4, 256000)].concat();
        let rec = [
            field_bytes(1, &field_bytes(9, &field_bytes(10, &counters))),
            field_bytes(1, &field_bytes(21, b"Gemini 4 Argon (Medium)")),
        ]
        .concat();
        assert_eq!(pb_varint(&rec, &[1, 9, 10, 1]), Some(88444));
        assert_eq!(pb_varint(&rec, &[1, 9, 10, 4]), Some(256000));
        assert_eq!(pb_varint(&rec, &[1, 9, 10, 2]), None);
        assert_eq!(
            pb_bytes(&rec, &[1, 21]).as_deref(),
            Some("Gemini 4 Argon (Medium)")
        );
    }
}
