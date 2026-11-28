//! Lưu trữ trạng thái của app trong một cơ sở dữ liệu SQLite duy nhất,
//! thay cho các file JSON/JSONL rời rạc.

use crate::models::RetryConfigDto;
use rusqlite::{params, Connection};
use serde_json::Value;
use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};

/// File JSONL cũ (trước khi chuyển sang SQLite), được import một lần rồi xóa
/// File JSONL cũ (trước khi chuyển vào SQLite), nằm trong thư mục dữ liệu của server
fn legacy_agy_turn_models() -> PathBuf {
    super::paths::app_data_dir().join("agy-turn-models.jsonl")
}

static DB: OnceLock<Option<Mutex<Connection>>> = OnceLock::new();

fn db_path() -> PathBuf {
    super::paths::db_path()
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
         CREATE TABLE IF NOT EXISTS conversation_projects (
             conversation_id TEXT PRIMARY KEY,
             project_name TEXT NOT NULL,
             project_path TEXT NOT NULL,
             updated_at TEXT NOT NULL
         );
         CREATE TABLE IF NOT EXISTS transcript_meta (
             kind TEXT NOT NULL,
             conversation_id TEXT NOT NULL,
             fingerprint TEXT NOT NULL,
             meta_json TEXT NOT NULL,
             updated_at TEXT NOT NULL,
             PRIMARY KEY (kind, conversation_id)
         );
         CREATE TABLE IF NOT EXISTS transcript_state (
             kind TEXT NOT NULL,
             conversation_id TEXT NOT NULL,
             state_json TEXT NOT NULL,
             PRIMARY KEY (kind, conversation_id)
         );
         CREATE TABLE IF NOT EXISTS claude_transcript_lines (
             conversation_id TEXT NOT NULL,
             step_index INTEGER NOT NULL,
             byte_offset INTEGER NOT NULL,
             byte_len INTEGER NOT NULL,
             input_tokens INTEGER NOT NULL,
             output_tokens INTEGER NOT NULL,
             cache_tokens INTEGER NOT NULL,
             PRIMARY KEY (conversation_id, step_index)
         );
         CREATE TABLE IF NOT EXISTS agy_transcript_lines (
             conversation_id TEXT NOT NULL,
             seq INTEGER NOT NULL,
             step_index INTEGER NOT NULL,
             byte_offset INTEGER NOT NULL,
             byte_len INTEGER NOT NULL,
             PRIMARY KEY (conversation_id, seq)
         );
         CREATE TABLE IF NOT EXISTS conversation_context (
             conversation_id TEXT PRIMARY KEY,
             model_id TEXT NOT NULL,
             context_tokens INTEGER NOT NULL,
             max_context_tokens INTEGER NOT NULL,
             conversation_updated_at TEXT NOT NULL,
             source TEXT NOT NULL,
             updated_at TEXT NOT NULL
         );
         CREATE TABLE IF NOT EXISTS ssh_hosts (
             id INTEGER PRIMARY KEY AUTOINCREMENT,
             name TEXT NOT NULL,
             host TEXT NOT NULL,
             port INTEGER NOT NULL DEFAULT 22,
             username TEXT NOT NULL,
             password TEXT NOT NULL DEFAULT '',
             private_key TEXT NOT NULL DEFAULT '',
             updated_at TEXT NOT NULL
         );
         CREATE TABLE IF NOT EXISTS lsp_settings (
             language TEXT PRIMARY KEY,
             path TEXT NOT NULL,
             updated_at TEXT NOT NULL
         );
         CREATE TABLE IF NOT EXISTS running_turns (
             conversation_id TEXT PRIMARY KEY,
             provider TEXT NOT NULL,
             pid INTEGER NOT NULL,
             start_ticks INTEGER NOT NULL,
             cwd TEXT NOT NULL,
             started_at TEXT NOT NULL
         );
         CREATE TABLE IF NOT EXISTS cut_short_turns (
             conversation_id TEXT PRIMARY KEY,
             detected_at TEXT NOT NULL
         );
         CREATE TABLE IF NOT EXISTS claude_muop_conversations (
             conversation_id TEXT PRIMARY KEY,
             first_seen_at TEXT NOT NULL
         );
         CREATE TABLE IF NOT EXISTS app_settings (
             key TEXT PRIMARY KEY,
             value TEXT NOT NULL,
             updated_at TEXT NOT NULL
         );
         CREATE TABLE IF NOT EXISTS agy_account (
             id INTEGER PRIMARY KEY CHECK (id = 1),
             email TEXT NOT NULL,
             plan TEXT NOT NULL,
             quota_json TEXT NOT NULL,
             updated_at TEXT NOT NULL
         );
         CREATE TABLE IF NOT EXISTS conversation_retry_config (
             conversation_id TEXT PRIMARY KEY,
             enabled INTEGER NOT NULL,
             prompt TEXT NOT NULL,
             max_attempts INTEGER NOT NULL,
             interval_minutes INTEGER NOT NULL,
             use_quota_reset INTEGER NOT NULL,
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
    // Database chứa mật khẩu và SSH key: chỉ người dùng hiện tại được đọc/ghi
    restrict_file_permissions(&path);
    Some(conn)
}

fn restrict_file_permissions(path: &std::path::Path) {
    use std::os::unix::fs::PermissionsExt;
    for p in [
        path.to_path_buf(),
        path.with_extension("db-wal"),
        path.with_extension("db-shm"),
    ] {
        if p.exists() {
            let _ = fs::set_permissions(&p, fs::Permissions::from_mode(0o600));
        }
    }
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
    let Ok(content) = fs::read_to_string(legacy_agy_turn_models()) else {
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
    let _ = fs::remove_file(legacy_agy_turn_models());
}

/// Chạy một truy vấn trên kết nối dùng chung. Trả None nếu DB không mở được hoặc truy vấn lỗi.
fn with_db<T>(f: impl FnOnce(&Connection) -> Option<T>) -> Option<T> {
    let cell = DB.get_or_init(|| open().map(Mutex::new));
    let guard = cell.as_ref()?.lock().ok()?;
    f(&guard)
}

/// Một lượt chat đang chạy do server này khởi chạy, để nhận lại sau khi server restart
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RunningTurnRow {
    pub conversation_id: String,
    pub provider: String,
    pub pid: u32,
    /// Thời điểm bắt đầu của tiến trình (`starttime` trong `/proc/<pid>/stat`), để nhận diện pid bị tái sử dụng
    pub start_ticks: u64,
    pub cwd: String,
    pub started_at: String,
}

/// Ghi (hoặc thay) bản ghi lượt đang chạy của một conversation
pub fn upsert_running_turn(row: &RunningTurnRow) {
    with_db(|c| {
        c.execute(
            "INSERT OR REPLACE INTO running_turns
                (conversation_id, provider, pid, start_ticks, cwd, started_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![
                row.conversation_id,
                row.provider,
                row.pid as i64,
                row.start_ticks as i64,
                row.cwd,
                row.started_at
            ],
        )
        .ok()
    });
}

/// Xóa bản ghi lượt đang chạy khi lượt kết thúc
pub fn delete_running_turn(conversation_id: &str) {
    with_db(|c| {
        c.execute(
            "DELETE FROM running_turns WHERE conversation_id = ?1",
            params![conversation_id],
        )
        .ok()
    });
}

/// Tất cả lượt đang được ghi nhận là chạy
pub fn list_running_turns() -> Vec<RunningTurnRow> {
    with_db(|c| {
        let mut stmt = c
            .prepare(
                "SELECT conversation_id, provider, pid, start_ticks, cwd, started_at FROM running_turns",
            )
            .ok()?;
        let rows = stmt
            .query_map([], |r| {
                Ok(RunningTurnRow {
                    conversation_id: r.get(0)?,
                    provider: r.get(1)?,
                    pid: r.get::<_, i64>(2)? as u32,
                    start_ticks: r.get::<_, i64>(3)? as u64,
                    cwd: r.get(4)?,
                    started_at: r.get(5)?,
                })
            })
            .ok()?;
        Some(rows.filter_map(Result::ok).collect())
    })
    .unwrap_or_default()
}

/// Đánh dấu lượt agy do server chạy đã bị cắt: tiến trình đã kết thúc khi server đang tắt
pub fn mark_cut_short_turn(conversation_id: &str) {
    with_db(|c| {
        c.execute(
            "INSERT OR REPLACE INTO cut_short_turns (conversation_id, detected_at) VALUES (?1, ?2)",
            params![conversation_id, chrono::Utc::now().to_rfc3339()],
        )
        .ok()
    });
}

/// Bỏ dấu "bị cắt" khi một lượt mới bắt đầu trên conversation đó
pub fn clear_cut_short_turn(conversation_id: &str) {
    with_db(|c| {
        c.execute(
            "DELETE FROM cut_short_turns WHERE conversation_id = ?1",
            params![conversation_id],
        )
        .ok()
    });
}

/// Các conversation có lượt agy bị cắt chưa được thay thế bằng lượt mới
pub fn cut_short_turns() -> std::collections::HashSet<String> {
    with_db(|c| {
        let mut stmt = c
            .prepare("SELECT conversation_id FROM cut_short_turns")
            .ok()?;
        let rows = stmt.query_map([], |r| r.get::<_, String>(0)).ok()?;
        Some(rows.filter_map(Result::ok).collect())
    })
    .unwrap_or_default()
}

/// Đánh dấu một conversation Claude do chính server này chạy. Chỉ các conversation này mới
/// có thể kết luận là lượt bị gián đoạn khi server khởi động lại; phiên tương tác thì không.
pub fn mark_claude_muop_conversation(conversation_id: &str) {
    if conversation_id.is_empty() {
        return;
    }
    with_db(|c| {
        c.execute(
            "INSERT OR IGNORE INTO claude_muop_conversations (conversation_id, first_seen_at) VALUES (?1, ?2)",
            params![conversation_id, chrono::Utc::now().to_rfc3339()],
        )
        .ok()
    });
}

/// Tập các conversation Claude do server này đã chạy
pub fn claude_muop_conversations() -> std::collections::HashSet<String> {
    with_db(|c| {
        let mut stmt = c
            .prepare("SELECT conversation_id FROM claude_muop_conversations")
            .ok()?;
        let rows = stmt.query_map([], |r| r.get::<_, String>(0)).ok()?;
        Some(rows.filter_map(Result::ok).collect())
    })
    .unwrap_or_default()
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

/// Ghi project mà lượt của conversation chạy: tên project gốc và đường dẫn nơi agent làm việc.
/// Dùng để nhóm conversation đúng project, kể cả khi agy không lưu thư mục làm việc hoặc lượt chạy qua mount.
pub fn set_conversation_project(
    conversation_id: &str,
    project_name: &str,
    project_path: &str,
) -> bool {
    with_db(|c| {
        c.execute(
            "INSERT INTO conversation_projects (conversation_id, project_name, project_path, updated_at)
             VALUES (?1, ?2, ?3, ?4)
             ON CONFLICT(conversation_id) DO UPDATE SET
                 project_name = excluded.project_name,
                 project_path = excluded.project_path,
                 updated_at = excluded.updated_at",
            params![
                conversation_id,
                project_name,
                project_path,
                chrono::Utc::now().to_rfc3339()
            ],
        )
        .ok()
    })
    .is_some()
}

/// Metadata transcript đã lưu của một conversation: (dấu vết file, JSON). None nếu chưa có.
pub fn transcript_meta_get(kind: &str, conversation_id: &str) -> Option<(String, String)> {
    with_db(|c| {
        c.query_row(
            "SELECT fingerprint, meta_json FROM transcript_meta WHERE kind = ?1 AND conversation_id = ?2",
            params![kind, conversation_id],
            |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)),
        )
        .ok()
    })
}

/// Ghi (hoặc thay) metadata transcript của một conversation
pub fn transcript_meta_set(
    kind: &str,
    conversation_id: &str,
    fingerprint: &str,
    meta_json: &str,
) -> bool {
    with_db(|c| {
        c.execute(
            "INSERT INTO transcript_meta (kind, conversation_id, fingerprint, meta_json, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5)
             ON CONFLICT(kind, conversation_id) DO UPDATE SET
                 fingerprint = excluded.fingerprint,
                 meta_json = excluded.meta_json,
                 updated_at = excluded.updated_at",
            params![
                kind,
                conversation_id,
                fingerprint,
                meta_json,
                chrono::Utc::now().to_rfc3339()
            ],
        )
        .ok()
    })
    .is_some()
}

/// Có trạng thái parser đã lưu cho conversation này không (không đọc nội dung)
pub fn transcript_state_exists(kind: &str, conversation_id: &str) -> bool {
    with_db(|c| {
        c.query_row(
            "SELECT 1 FROM transcript_state WHERE kind = ?1 AND conversation_id = ?2",
            params![kind, conversation_id],
            |_| Ok(()),
        )
        .ok()
    })
    .is_some()
}

/// Trạng thái parser đã lưu của một conversation (JSON), None nếu chưa có
pub fn transcript_state_get(kind: &str, conversation_id: &str) -> Option<String> {
    with_db(|c| {
        c.query_row(
            "SELECT state_json FROM transcript_state WHERE kind = ?1 AND conversation_id = ?2",
            params![kind, conversation_id],
            |r| r.get::<_, String>(0),
        )
        .ok()
    })
}

/// Ghi kết quả đồng bộ một transcript trong một transaction: metadata, trạng thái, và các dòng chỉ mục mới.
/// `reset`: xóa chỉ mục cũ của conversation trước (file đã được dựng lại từ đầu).
/// Chỉ mục dòng chỉ dành cho agy. Trả về false nếu ghi lỗi.
pub fn transcript_sync_write(
    kind: &str,
    conversation_id: &str,
    fingerprint: &str,
    meta_json: &str,
    state_json: &str,
    rows: &[(i64, i64, i64, i64)],
    reset: bool,
) -> bool {
    with_db(|c| {
        let tx = c.unchecked_transaction().ok()?;
        let now = chrono::Utc::now().to_rfc3339();
        if kind == "agy" {
            if reset {
                tx.execute(
                    "DELETE FROM agy_transcript_lines WHERE conversation_id = ?1",
                    params![conversation_id],
                )
                .ok()?;
            }
            for (seq, step_index, offset, len) in rows {
                tx.execute(
                    "INSERT OR REPLACE INTO agy_transcript_lines
                         (conversation_id, seq, step_index, byte_offset, byte_len)
                     VALUES (?1, ?2, ?3, ?4, ?5)",
                    params![conversation_id, seq, step_index, offset, len],
                )
                .ok()?;
            }
        }
        tx.execute(
            "INSERT INTO transcript_meta (kind, conversation_id, fingerprint, meta_json, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5)
             ON CONFLICT(kind, conversation_id) DO UPDATE SET
                 fingerprint = excluded.fingerprint,
                 meta_json = excluded.meta_json,
                 updated_at = excluded.updated_at",
            params![kind, conversation_id, fingerprint, meta_json, now],
        )
        .ok()?;
        tx.execute(
            "INSERT INTO transcript_state (kind, conversation_id, state_json) VALUES (?1, ?2, ?3)
             ON CONFLICT(kind, conversation_id) DO UPDATE SET state_json = excluded.state_json",
            params![kind, conversation_id, state_json],
        )
        .ok()?;
        tx.commit().ok()?;
        Some(())
    })
    .is_some()
}

/// Các dòng cuối của chỉ mục agy: (step_index, offset, độ dài), theo thứ tự tăng dần của seq
pub fn agy_tail_rows(conversation_id: &str, n: usize) -> Vec<(i64, i64, i64)> {
    with_db(|c| {
        let mut stmt = c
            .prepare(
                "SELECT step_index, byte_offset, byte_len FROM (
                     SELECT seq, step_index, byte_offset, byte_len FROM agy_transcript_lines
                     WHERE conversation_id = ?1 ORDER BY seq DESC LIMIT ?2
                 ) ORDER BY seq ASC",
            )
            .ok()?;
        let rows = stmt
            .query_map(params![conversation_id, n as i64], |r| {
                Ok((
                    r.get::<_, i64>(0)?,
                    r.get::<_, i64>(1)?,
                    r.get::<_, i64>(2)?,
                ))
            })
            .ok()?
            .filter_map(Result::ok)
            .collect();
        Some(rows)
    })
    .unwrap_or_default()
}

/// Ghi kết quả đồng bộ một transcript Claude trong một transaction: metadata, trạng thái, và các dòng chỉ mục
/// mới. Mỗi dòng là (step_index, offset, độ dài, token input, output, cache). `reset`: xóa chỉ mục cũ trước.
pub fn claude_sync_write(
    conversation_id: &str,
    fingerprint: &str,
    meta_json: &str,
    state_json: &str,
    rows: &[(i64, i64, i64, i64, i64, i64)],
    reset: bool,
) -> bool {
    with_db(|c| {
        let tx = c.unchecked_transaction().ok()?;
        let now = chrono::Utc::now().to_rfc3339();
        if reset {
            tx.execute(
                "DELETE FROM claude_transcript_lines WHERE conversation_id = ?1",
                params![conversation_id],
            )
            .ok()?;
        }
        for (step_index, offset, len, input, output, cache) in rows {
            tx.execute(
                "INSERT OR REPLACE INTO claude_transcript_lines
                     (conversation_id, step_index, byte_offset, byte_len, input_tokens, output_tokens, cache_tokens)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                params![conversation_id, step_index, offset, len, input, output, cache],
            )
            .ok()?;
        }
        tx.execute(
            "INSERT INTO transcript_meta (kind, conversation_id, fingerprint, meta_json, updated_at)
             VALUES ('claude', ?1, ?2, ?3, ?4)
             ON CONFLICT(kind, conversation_id) DO UPDATE SET
                 fingerprint = excluded.fingerprint,
                 meta_json = excluded.meta_json,
                 updated_at = excluded.updated_at",
            params![conversation_id, fingerprint, meta_json, now],
        )
        .ok()?;
        tx.execute(
            "INSERT INTO transcript_state (kind, conversation_id, state_json) VALUES ('claude', ?1, ?2)
             ON CONFLICT(kind, conversation_id) DO UPDATE SET state_json = excluded.state_json",
            params![conversation_id, state_json],
        )
        .ok()?;
        tx.commit().ok()?;
        Some(())
    })
    .is_some()
}

/// Ghi lại metadata (không đổi trạng thái/chỉ mục), dùng khi file không đổi nhưng dấu vết khác
pub fn claude_meta_only_write(conversation_id: &str, fingerprint: &str, meta_json: &str) -> bool {
    crate::infra::store::transcript_meta_set("claude", conversation_id, fingerprint, meta_json)
}

/// Các dòng chỉ mục Claude có step_index < `before` (nếu có), lấy `limit` dòng cuối, theo thứ tự tăng dần
pub fn claude_line_rows(
    conversation_id: &str,
    before: Option<i64>,
    limit: usize,
) -> Vec<(i64, i64, i64, i64, i64, i64)> {
    with_db(|c| {
        let mut stmt = c
            .prepare(
                "SELECT step_index, byte_offset, byte_len, input_tokens, output_tokens, cache_tokens
                 FROM (
                     SELECT step_index, byte_offset, byte_len, input_tokens, output_tokens, cache_tokens
                     FROM claude_transcript_lines
                     WHERE conversation_id = ?1 AND step_index < ?2
                     ORDER BY step_index DESC LIMIT ?3
                 ) ORDER BY step_index ASC",
            )
            .ok()?;
        let rows = stmt
            .query_map(
                params![conversation_id, before.unwrap_or(i64::MAX), limit as i64],
                |r| {
                    Ok((
                        r.get::<_, i64>(0)?,
                        r.get::<_, i64>(1)?,
                        r.get::<_, i64>(2)?,
                        r.get::<_, i64>(3)?,
                        r.get::<_, i64>(4)?,
                        r.get::<_, i64>(5)?,
                    ))
                },
            )
            .ok()?
            .filter_map(Result::ok)
            .collect();
        Some(rows)
    })
    .unwrap_or_default()
}

/// Xóa metadata, trạng thái và chỉ mục của các conversation không còn trên đĩa. Trả về số conversation đã xóa.
pub fn transcript_meta_prune(kind: &str, keep: &std::collections::HashSet<String>) -> usize {
    with_db(|c| {
        let mut stmt = c
            .prepare("SELECT conversation_id FROM transcript_meta WHERE kind = ?1")
            .ok()?;
        let stored: Vec<String> = stmt
            .query_map(params![kind], |r| r.get::<_, String>(0))
            .ok()?
            .filter_map(Result::ok)
            .collect();
        drop(stmt);
        let mut removed = 0;
        for id in stored.iter().filter(|id| !keep.contains(*id)) {
            let _ = c.execute(
                "DELETE FROM transcript_meta WHERE kind = ?1 AND conversation_id = ?2",
                params![kind, id],
            );
            let _ = c.execute(
                "DELETE FROM transcript_state WHERE kind = ?1 AND conversation_id = ?2",
                params![kind, id],
            );
            if kind == "agy" {
                let _ = c.execute(
                    "DELETE FROM agy_transcript_lines WHERE conversation_id = ?1",
                    params![id],
                );
            }
            if kind == "claude" {
                let _ = c.execute(
                    "DELETE FROM claude_transcript_lines WHERE conversation_id = ?1",
                    params![id],
                );
            }
            removed += 1;
        }
        Some(removed)
    })
    .unwrap_or(0)
}

/// Project đã ghi cho một conversation: (tên, đường dẫn). None nếu chưa có.
pub fn conversation_project(conversation_id: &str) -> Option<(String, String)> {
    with_db(|c| {
        c.query_row(
            "SELECT project_name, project_path FROM conversation_projects WHERE conversation_id = ?1",
            params![conversation_id],
            |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)),
        )
        .ok()
    })
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

/// Context đã đọc được của một conversation agy, lưu để dùng khi không gọi được RPC
#[derive(Debug, Clone)]
pub struct StoredConversationContext {
    /// Model id (`agy:<id>`), rỗng nếu chưa xác định
    pub model_id: String,
    pub context_tokens: u64,
    pub max_context_tokens: u64,
    /// `updated_at` của conversation tại thời điểm đọc. Nếu conversation đổi sau mốc này thì cần đọc lại.
    pub conversation_updated_at: String,
    /// Nguồn đọc: `agy-rpc` hoặc `agy-gen-metadata`
    pub source: String,
}

/// Ghi context của conversation (ghi đè bản cũ)
pub fn save_conversation_context(conversation_id: &str, ctx: &StoredConversationContext) -> bool {
    with_db(|c| {
        c.execute(
            "INSERT INTO conversation_context
                 (conversation_id, model_id, context_tokens, max_context_tokens,
                  conversation_updated_at, source, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
             ON CONFLICT(conversation_id) DO UPDATE SET
                 model_id = excluded.model_id,
                 context_tokens = excluded.context_tokens,
                 max_context_tokens = excluded.max_context_tokens,
                 conversation_updated_at = excluded.conversation_updated_at,
                 source = excluded.source,
                 updated_at = excluded.updated_at",
            params![
                conversation_id,
                ctx.model_id,
                ctx.context_tokens as i64,
                ctx.max_context_tokens as i64,
                ctx.conversation_updated_at,
                ctx.source,
                chrono::Utc::now().to_rfc3339(),
            ],
        )
        .ok()
    })
    .is_some()
}

/// Context đã lưu của conversation, None nếu chưa từng đọc được
pub fn load_conversation_context(conversation_id: &str) -> Option<StoredConversationContext> {
    with_db(|c| {
        c.query_row(
            "SELECT model_id, context_tokens, max_context_tokens, conversation_updated_at, source
             FROM conversation_context WHERE conversation_id = ?1",
            params![conversation_id],
            |r| {
                Ok(StoredConversationContext {
                    model_id: r.get(0)?,
                    context_tokens: r.get::<_, i64>(1)?.max(0) as u64,
                    max_context_tokens: r.get::<_, i64>(2)?.max(0) as u64,
                    conversation_updated_at: r.get(3)?,
                    source: r.get(4)?,
                })
            },
        )
        .ok()
    })
}

/// Một máy SSH đã lưu (có cả bí mật, chỉ dùng phía server)
#[derive(Debug, Clone, Default)]
pub struct SshHostRow {
    pub id: i64,
    pub name: String,
    pub host: String,
    pub port: u16,
    pub username: String,
    pub password: String,
    pub private_key: String,
}

/// Giá trị cấu hình chung của server (trạng thái khởi tạo, CLI đã chọn...)
pub fn get_app_setting(key: &str) -> Option<String> {
    with_db(|c| {
        c.query_row(
            "SELECT value FROM app_settings WHERE key = ?1",
            params![key],
            |r| r.get::<_, String>(0),
        )
        .ok()
    })
}

pub fn set_app_setting(key: &str, value: &str) -> bool {
    with_db(|c| {
        c.execute(
            "INSERT INTO app_settings (key, value, updated_at) VALUES (?1, ?2, ?3)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at",
            params![key, value, chrono::Utc::now().to_rfc3339()],
        )
        .ok()
    })
    .is_some()
}

pub fn list_ssh_hosts() -> Vec<SshHostRow> {
    with_db(|c| {
        let mut stmt = c
            .prepare(
                "SELECT id, name, host, port, username, password, private_key
                 FROM ssh_hosts ORDER BY name COLLATE NOCASE, id",
            )
            .ok()?;
        let rows = stmt
            .query_map([], ssh_row_from)
            .ok()?
            .filter_map(Result::ok)
            .collect();
        Some(rows)
    })
    .unwrap_or_default()
}

pub fn get_ssh_host(id: i64) -> Option<SshHostRow> {
    with_db(|c| {
        c.query_row(
            "SELECT id, name, host, port, username, password, private_key
             FROM ssh_hosts WHERE id = ?1",
            params![id],
            ssh_row_from,
        )
        .ok()
    })
}

fn ssh_row_from(r: &rusqlite::Row) -> rusqlite::Result<SshHostRow> {
    Ok(SshHostRow {
        id: r.get(0)?,
        name: r.get(1)?,
        host: r.get(2)?,
        port: r.get::<_, i64>(3)?.clamp(1, 65535) as u16,
        username: r.get(4)?,
        password: r.get(5)?,
        private_key: r.get(6)?,
    })
}

/// Thêm mới (id = 0) hoặc cập nhật. Trả về id đã lưu.
pub fn save_ssh_host(row: &SshHostRow) -> Option<i64> {
    with_db(|c| {
        let now = chrono::Utc::now().to_rfc3339();
        if row.id > 0 {
            c.execute(
                "UPDATE ssh_hosts SET name=?2, host=?3, port=?4, username=?5,
                     password=?6, private_key=?7, updated_at=?8 WHERE id=?1",
                params![
                    row.id,
                    row.name,
                    row.host,
                    row.port as i64,
                    row.username,
                    row.password,
                    row.private_key,
                    now
                ],
            )
            .ok()?;
            Some(row.id)
        } else {
            c.execute(
                "INSERT INTO ssh_hosts (name, host, port, username, password, private_key, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                params![
                    row.name,
                    row.host,
                    row.port as i64,
                    row.username,
                    row.password,
                    row.private_key,
                    now
                ],
            )
            .ok()?;
            Some(c.last_insert_rowid())
        }
    })
}

/// Cập nhật mật khẩu đã lưu của máy SSH (chuỗi rỗng = xóa). Trả về false nếu lỗi DB.
pub fn set_ssh_password(id: i64, password: &str) -> bool {
    with_db(|c| {
        c.execute(
            "UPDATE ssh_hosts SET password = ?2, updated_at = ?3 WHERE id = ?1",
            params![id, password, chrono::Utc::now().to_rfc3339()],
        )
        .ok()
    })
    .is_some()
}

pub fn delete_ssh_host(id: i64) -> bool {
    with_db(|c| {
        c.execute("DELETE FROM ssh_hosts WHERE id = ?1", params![id])
            .ok()
    })
    .map(|n| n > 0)
    .unwrap_or(false)
}

/// Đường dẫn LSP người dùng đã đặt cho một ngôn ngữ (`go`, `dart`, `rust`). None nếu chưa đặt.
pub fn get_lsp_path(language: &str) -> Option<String> {
    with_db(|c| {
        c.query_row(
            "SELECT path FROM lsp_settings WHERE language = ?1",
            params![language],
            |r| r.get::<_, String>(0),
        )
        .ok()
    })
}

/// Lưu (hoặc đổi) đường dẫn LSP của một ngôn ngữ
pub fn set_lsp_path(language: &str, path: &str) -> bool {
    with_db(|c| {
        c.execute(
            "INSERT INTO lsp_settings (language, path, updated_at) VALUES (?1, ?2, ?3)
             ON CONFLICT(language) DO UPDATE SET path = excluded.path, updated_at = excluded.updated_at",
            params![language, path, chrono::Utc::now().to_rfc3339()],
        )
        .ok()
    })
    .is_some()
}

/// Xóa đường dẫn đã lưu, để dùng lại đường dẫn tự dò
pub fn delete_lsp_path(language: &str) -> bool {
    with_db(|c| {
        c.execute(
            "DELETE FROM lsp_settings WHERE language = ?1",
            params![language],
        )
        .ok()
    })
    .is_some()
}

/// Thông tin tài khoản agy đang đăng nhập (một dòng): email, gói, quota (JSON)
#[derive(Debug, Clone)]
pub struct AgyAccountRow {
    pub email: String,
    pub plan: String,
    pub quota_json: String,
}

pub fn save_agy_account(email: &str, plan: &str, quota_json: &str) -> bool {
    with_db(|c| {
        c.execute(
            "INSERT OR REPLACE INTO agy_account (id, email, plan, quota_json, updated_at)
             VALUES (1, ?1, ?2, ?3, ?4)",
            params![email, plan, quota_json, chrono::Utc::now().to_rfc3339()],
        )
        .ok()
    })
    .is_some()
}

pub fn load_agy_account() -> Option<AgyAccountRow> {
    with_db(|c| {
        c.query_row(
            "SELECT email, plan, quota_json FROM agy_account WHERE id = 1",
            [],
            |r| {
                Ok(AgyAccountRow {
                    email: r.get(0)?,
                    plan: r.get(1)?,
                    quota_json: r.get(2)?,
                })
            },
        )
        .ok()
    })
}

/// Xóa thông tin tài khoản agy (khi đăng xuất)
pub fn clear_agy_account() -> bool {
    with_db(|c| c.execute("DELETE FROM agy_account", []).ok()).is_some()
}

/// Cấu hình tự gửi lại đã lưu của một conversation, None nếu chưa từng đặt
pub fn conversation_retry_config(conversation_id: &str) -> Option<RetryConfigDto> {
    with_db(|c| {
        c.query_row(
            "SELECT enabled, prompt, max_attempts, interval_minutes, use_quota_reset
             FROM conversation_retry_config WHERE conversation_id = ?1",
            params![conversation_id],
            |r| {
                Ok(RetryConfigDto {
                    conversation_id: conversation_id.to_string(),
                    enabled: r.get::<_, i64>(0)? != 0,
                    prompt: r.get(1)?,
                    max_attempts: r.get::<_, i64>(2)?.clamp(0, i64::from(u32::MAX)) as u32,
                    interval_minutes: r.get::<_, i64>(3)?.clamp(1, i64::from(u32::MAX)) as u32,
                    use_quota_reset: r.get::<_, i64>(4)? != 0,
                })
            },
        )
        .ok()
    })
}

/// Lưu cấu hình tự gửi lại của một conversation (ghi đè)
pub fn set_conversation_retry_config(cfg: &RetryConfigDto) -> bool {
    with_db(|c| {
        c.execute(
            "INSERT INTO conversation_retry_config
                 (conversation_id, enabled, prompt, max_attempts, interval_minutes, use_quota_reset, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
             ON CONFLICT(conversation_id) DO UPDATE SET
                 enabled = excluded.enabled,
                 prompt = excluded.prompt,
                 max_attempts = excluded.max_attempts,
                 interval_minutes = excluded.interval_minutes,
                 use_quota_reset = excluded.use_quota_reset,
                 updated_at = excluded.updated_at",
            params![
                cfg.conversation_id,
                cfg.enabled as i64,
                cfg.prompt,
                i64::from(cfg.max_attempts),
                i64::from(cfg.interval_minutes),
                cfg.use_quota_reset as i64,
                chrono::Utc::now().to_rfc3339(),
            ],
        )
        .ok()
    })
    .is_some()
}
