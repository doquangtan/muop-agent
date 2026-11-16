//! Cửa sổ ngữ cảnh (context window) của conversation Antigravity (agy).
//!
//! agy không có lệnh nào trả giới hạn context của model. Nhưng mỗi lượt gọi model,
//! agy ghi vào bảng `gen_metadata` của `conversations/<cid>.db` một bản ghi protobuf
//! không có schema công khai, trong đó:
//! - `1.9.10.1`: số token context đang dùng
//! - `1.9.10.4`: giới hạn context của model
//! - `1.21`: nhãn model (ví dụ "Gemini 4 Argon (Medium)")
//! - `3.28`: id model (ví dụ `gemini-4-argon-medium`), đôi khi trống
//!
//! Đây là định dạng nội bộ của agy nên có thể đổi khi agy cập nhật. Khi đọc thất bại,
//! hàm trả None và UI dùng giá trị đã lưu trong DB.

use crate::store;
use rusqlite::{Connection, OpenFlags};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};

/// Kết quả đọc context của một conversation agy
#[derive(Debug, Clone, Default)]
pub struct AgyContextUsage {
    /// Số token context đang dùng ở lượt gọi model gần nhất
    pub tokens: u64,
    /// Id đầy đủ của model (`agy:<id>`), rỗng nếu không xác định được
    pub model: String,
}

/// Cache theo conversation: (idx bản ghi mới nhất đã đọc, kết quả)
type ContextCache = HashMap<String, (i64, Option<AgyContextUsage>)>;
static CACHE: OnceLock<Mutex<ContextCache>> = OnceLock::new();

const SOURCE: &str = "agy-gen-metadata";

/// Đọc context của một conversation agy. `label_to_id` ánh xạ nhãn model → `agy:<id>`.
pub fn agy_context_usage(
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

    let cache = CACHE.get_or_init(|| Mutex::new(HashMap::new()));
    if let Ok(map) = cache.lock() {
        if let Some((idx, usage)) = map.get(conversation_id) {
            if *idx == latest_idx {
                return usage.clone();
            }
        }
    }

    let usage = read_latest_usage(&conn, label_to_id);
    if let Ok(mut map) = cache.lock() {
        map.insert(conversation_id.to_string(), (latest_idx, usage.clone()));
    }
    usage
}

fn read_latest_usage(
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
            store::upsert_context_limit(&model, limit, SOURCE);
        }
        return Some(AgyContextUsage { tokens, model });
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
    // Chỉ chấp nhận id dạng UUID/chữ-số-gạch để không đưa đường dẫn lạ vào SQLite
    if conversation_id.is_empty()
        || !conversation_id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-')
    {
        return None;
    }
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
