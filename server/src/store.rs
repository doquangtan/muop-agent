//! Lưu trữ trạng thái của app trong một cơ sở dữ liệu SQLite duy nhất,
//! thay cho các file JSON/JSONL rời rạc.

use rusqlite::{params, Connection};
use serde_json::Value;
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
         );",
    )
    .ok()?;
    import_legacy_agy_turn_models(&conn);
    Some(conn)
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
            .prepare(
                "SELECT started_at, model FROM agy_turn_models WHERE conversation_id = ?1",
            )
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
