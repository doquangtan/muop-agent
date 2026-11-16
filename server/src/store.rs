//! Lưu trữ trạng thái của app trong một cơ sở dữ liệu SQLite duy nhất,
//! thay cho các file JSON/JSONL rời rạc.

use rusqlite::{params, Connection};
use serde_json::Value;
use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};

/// File JSONL cũ (trước khi chuyển sang SQLite), được import một lần rồi xóa
const LEGACY_AGY_TURN_MODELS: &str = "/home/john/.local/share/muop-agent/agy-turn-models.jsonl";

static DB: OnceLock<Option<Mutex<Connection>>> = OnceLock::new();

fn db_path() -> PathBuf {
    let home = std::env::var("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("/home/john"));
    home.join(".local/share/muop-agent/muop-agent.db")
}

fn open() -> Option<Connection> {
    let path = db_path();
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).ok()?;
    }
    let conn = Connection::open(&path).ok()?;
    conn.execute_batch(
        "PRAGMA journal_mode=WAL;
         CREATE TABLE IF NOT EXISTS agy_turn_models (
             id INTEGER PRIMARY KEY AUTOINCREMENT,
             conversation_id TEXT NOT NULL,
             started_at TEXT NOT NULL,
             model TEXT NOT NULL
         );
         CREATE INDEX IF NOT EXISTS idx_agy_turn_models_conv
             ON agy_turn_models (conversation_id);
         CREATE TABLE IF NOT EXISTS conversation_models (
             conversation_id TEXT PRIMARY KEY,
             model TEXT NOT NULL,
             updated_at TEXT NOT NULL
         );
         CREATE TABLE IF NOT EXISTS model_context_limits (
             model_id TEXT PRIMARY KEY,
             limit_tokens INTEGER NOT NULL,
             source TEXT NOT NULL,
             updated_at TEXT NOT NULL
         );",
    )
    .ok()?;
    import_legacy_agy_turn_models(&conn);
    seed_claude_context_limits(&conn);
    Some(conn)
}

/// Giới hạn context mặc định của model Claude CLI (tài liệu Anthropic: Opus/Sonnet/Haiku 5.5 đều 1M).
/// Chỉ thêm nếu chưa có, nên giá trị sửa tay (`manual`) không bị ghi đè.
fn seed_claude_context_limits(conn: &Connection) {
    let now = chrono::Utc::now().to_rfc3339();
    for id in ["claude-sonnet-5-5", "claude-opus-5-5", "claude-haiku-5-5"] {
        let _ = conn.execute(
            "INSERT OR IGNORE INTO model_context_limits (model_id, limit_tokens, source, updated_at)
             VALUES (?1, ?2, 'seed', ?3)",
            params![format!("claude-cli:{id}"), 1_000_000i64, now],
        );
    }
}

/// Import file JSONL cũ vào bảng rồi xóa file (chỉ chạy khi file còn tồn tại)
fn import_legacy_agy_turn_models(conn: &Connection) {
    let Ok(content) = fs::read_to_string(LEGACY_AGY_TURN_MODELS) else {
        return;
    };
    for line in content.lines() {
        let Ok(v) = serde_json::from_str::<Value>(line) else {
            continue;
        };
        let (Some(cid), Some(started), Some(model)) = (
            v.get("conversation_id").and_then(Value::as_str),
            v.get("started_at").and_then(Value::as_str),
            v.get("model").and_then(Value::as_str),
        ) else {
            continue;
        };
        let _ = conn.execute(
            "INSERT INTO agy_turn_models (conversation_id, started_at, model) VALUES (?1, ?2, ?3)",
            params![cid, started, model],
        );
    }
    let _ = fs::remove_file(LEGACY_AGY_TURN_MODELS);
}

/// Chạy một truy vấn trên kết nối dùng chung. Trả None nếu DB không mở được hoặc truy vấn lỗi.
fn with_db<T>(f: impl FnOnce(&Connection) -> Option<T>) -> Option<T> {
    let cell = DB.get_or_init(|| open().map(Mutex::new));
    let guard = cell.as_ref()?.lock().ok()?;
    f(&guard)
}

/// Ghi model đã dùng cho một lượt agy (transcript của agy không lưu model)
pub fn record_agy_turn_model(conversation_id: &str, started_at: &str, model: &str) {
    if model.is_empty() {
        return;
    }
    with_db(|c| {
        c.execute(
            "INSERT INTO agy_turn_models (conversation_id, started_at, model) VALUES (?1, ?2, ?3)",
            params![conversation_id, started_at, model],
        )
        .ok()
    });
}

/// Các lượt agy của một conversation: (thời điểm bắt đầu RFC3339, model)
pub fn agy_turn_models(conversation_id: &str) -> Vec<(String, String)> {
    with_db(|c| {
        let mut stmt = c
            .prepare("SELECT started_at, model FROM agy_turn_models WHERE conversation_id = ?1")
            .ok()?;
        let rows = stmt
            .query_map(params![conversation_id], |r| {
                Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
            })
            .ok()?;
        Some(rows.filter_map(Result::ok).collect())
    })
    .unwrap_or_default()
}

/// Lưu model người dùng đã chọn cho một conversation (ghi đè nếu đã có)
pub fn set_conversation_model(conversation_id: &str, model: &str) -> bool {
    with_db(|c| {
        c.execute(
            "INSERT INTO conversation_models (conversation_id, model, updated_at)
             VALUES (?1, ?2, ?3)
             ON CONFLICT(conversation_id) DO UPDATE SET
                 model = excluded.model,
                 updated_at = excluded.updated_at",
            params![conversation_id, model, chrono::Utc::now().to_rfc3339()],
        )
        .ok()
    })
    .is_some()
}

/// Model đã lưu cho một conversation, None nếu chưa có
pub fn conversation_model(conversation_id: &str) -> Option<String> {
    with_db(|c| {
        c.query_row(
            "SELECT model FROM conversation_models WHERE conversation_id = ?1",
            params![conversation_id],
            |r| r.get::<_, String>(0),
        )
        .ok()
    })
}

/// Cập nhật giới hạn context của một model từ nguồn quét được (agy `gen_metadata`).
/// Không ghi đè giá trị `manual` do người dùng nhập.
pub fn upsert_context_limit(model_id: &str, limit: u64, source: &str) {
    if limit == 0 {
        return;
    }
    with_db(|c| {
        c.execute(
            "INSERT INTO model_context_limits (model_id, limit_tokens, source, updated_at)
             VALUES (?1, ?2, ?3, ?4)
             ON CONFLICT(model_id) DO UPDATE SET
                 limit_tokens = excluded.limit_tokens,
                 source = excluded.source,
                 updated_at = excluded.updated_at
             WHERE model_context_limits.source <> 'manual'",
            params![
                model_id,
                limit as i64,
                source,
                chrono::Utc::now().to_rfc3339()
            ],
        )
        .ok()
    });
}

/// Sửa tay giới hạn context (source = `manual`, sẽ không bị quét ghi đè)
pub fn set_manual_context_limit(model_id: &str, limit: u64) -> bool {
    if limit == 0 {
        return false;
    }
    with_db(|c| {
        c.execute(
            "INSERT INTO model_context_limits (model_id, limit_tokens, source, updated_at)
             VALUES (?1, ?2, 'manual', ?3)
             ON CONFLICT(model_id) DO UPDATE SET
                 limit_tokens = excluded.limit_tokens,
                 source = 'manual',
                 updated_at = excluded.updated_at",
            params![model_id, limit as i64, chrono::Utc::now().to_rfc3339()],
        )
        .ok()
    })
    .is_some()
}

/// Toàn bộ giới hạn context đã biết: model id (có tiền tố provider) → số token
pub fn context_limits() -> HashMap<String, u64> {
    with_db(|c| {
        let mut stmt = c
            .prepare("SELECT model_id, limit_tokens FROM model_context_limits")
            .ok()?;
        let rows = stmt
            .query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?)))
            .ok()?;
        Some(
            rows.filter_map(Result::ok)
                .map(|(k, v)| (k, v.max(0) as u64))
                .collect(),
        )
    })
    .unwrap_or_default()
}
