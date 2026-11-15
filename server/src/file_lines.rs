//! Đọc file văn bản theo từng đoạn dòng, không nạp toàn bộ file vào bộ nhớ.
//!
//! Với mỗi phiên bản file (theo mtime + kích thước) server đánh chỉ mục byte offset của từng dòng
//! một lần, rồi chỉ đọc đúng đoạn dòng được yêu cầu.

use std::collections::HashMap;
use std::fs::{self, File};
use std::io::{BufRead, BufReader, Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::{Mutex, OnceLock};
use std::time::UNIX_EPOCH;

use axum::extract::Query;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;
use serde::Serialize;

/// Số dòng tối đa trả về trong một yêu cầu
pub const MAX_LINES_PER_REQUEST: usize = 400;
/// Độ dài tối đa của một dòng hiển thị (ký tự); dòng dài hơn được cắt
const MAX_LINE_CHARS: usize = 2000;
/// Git diff quá lớn thì cắt bớt
const MAX_DIFF_BYTES: usize = 200 * 1024;
/// Không chạy git diff cho file lớn hơn mức này
const MAX_SIZE_FOR_DIFF: u64 = 20 * 1024 * 1024;
/// Số phiên bản file được giữ chỉ mục trong bộ nhớ
const MAX_INDEX_ENTRIES: usize = 6;

#[derive(Clone)]
struct LineIndex {
    key: (u64, u64),
    /// offsets[i] là byte bắt đầu của dòng i (0-based)
    offsets: Vec<u64>,
}

static INDEX: OnceLock<Mutex<HashMap<PathBuf, LineIndex>>> = OnceLock::new();

fn index_cache() -> &'static Mutex<HashMap<PathBuf, LineIndex>> {
    INDEX.get_or_init(|| Mutex::new(HashMap::new()))
}

fn file_key(meta: &fs::Metadata) -> (u64, u64) {
    let mtime = meta
        .modified()
        .ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(0);
    (mtime, meta.len())
}

/// Quét file một lần, ghi lại vị trí bắt đầu của từng dòng. Chỉ giữ một dòng trong bộ nhớ tại một thời điểm.
fn build_offsets(path: &Path) -> std::io::Result<Vec<u64>> {
    let file = File::open(path)?;
    let mut reader = BufReader::with_capacity(256 * 1024, file);
    let mut offsets = Vec::new();
    let mut pos: u64 = 0;
    let mut buf = Vec::new();
    loop {
        buf.clear();
        let n = reader.read_until(b'\n', &mut buf)?;
        if n == 0 {
            break;
        }
        offsets.push(pos);
        pos += n as u64;
    }
    Ok(offsets)
}

/// Lấy chỉ mục dòng của file, dùng cache nếu file không đổi
fn line_offsets(path: &Path, meta: &fs::Metadata) -> std::io::Result<Vec<u64>> {
    let key = file_key(meta);
    if let Ok(cache) = index_cache().lock() {
        if let Some(entry) = cache.get(path) {
            if entry.key == key {
                return Ok(entry.offsets.clone());
            }
        }
    }
    let offsets = build_offsets(path)?;
    if let Ok(mut cache) = index_cache().lock() {
        if cache.len() >= MAX_INDEX_ENTRIES && !cache.contains_key(path) {
            if let Some(victim) = cache.keys().next().cloned() {
                cache.remove(&victim);
            }
        }
        cache.insert(
            path.to_path_buf(),
            LineIndex {
                key,
                offsets: offsets.clone(),
            },
        );
    }
    Ok(offsets)
}

/// Đọc `count` dòng bắt đầu từ dòng `start` (đã biết offset)
fn read_line_range(
    path: &Path,
    offsets: &[u64],
    start: usize,
    count: usize,
) -> std::io::Result<Vec<String>> {
    if start >= offsets.len() || count == 0 {
        return Ok(Vec::new());
    }
    let end = (start + count).min(offsets.len());
    let mut file = File::open(path)?;
    file.seek(SeekFrom::Start(offsets[start]))?;
    let mut reader = BufReader::new(file);
    let mut out = Vec::with_capacity(end - start);
    let mut buf = Vec::new();
    for _ in start..end {
        buf.clear();
        reader.read_until(b'\n', &mut buf)?;
        while matches!(buf.last(), Some(b'\n') | Some(b'\r')) {
            buf.pop();
        }
        let text = String::from_utf8_lossy(&buf);
        let line: String = if text.chars().count() > MAX_LINE_CHARS {
            let mut cut: String = text.chars().take(MAX_LINE_CHARS).collect();
            cut.push('…');
            cut
        } else {
            text.into_owned()
        };
        out.push(line);
    }
    Ok(out)
}

/// File nhị phân nếu có byte NUL trong 8KB đầu
fn looks_binary(path: &Path) -> bool {
    let mut head = [0u8; 8192];
    match File::open(path).and_then(|mut f| f.read(&mut head)) {
        Ok(n) => head[..n].contains(&0),
        Err(_) => false,
    }
}

fn git_diff_for(path: &Path, size: u64) -> String {
    if size > MAX_SIZE_FOR_DIFF {
        return String::new();
    }
    let Some(parent) = path.parent() else {
        return String::new();
    };
    let Ok(out) = Command::new("git")
        .args(["diff", "HEAD", "--"])
        .arg(path)
        .current_dir(parent)
        .output()
    else {
        return String::new();
    };
    if !out.status.success() {
        return String::new();
    }
    let mut diff = String::from_utf8_lossy(&out.stdout).into_owned();
    if diff.len() > MAX_DIFF_BYTES {
        let mut cut = MAX_DIFF_BYTES;
        while !diff.is_char_boundary(cut) {
            cut -= 1;
        }
        diff.truncate(cut);
        diff.push_str("\n… (diff đã được cắt bớt)");
    }
    diff
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FileLinesResponse {
    pub ok: bool,
    pub path: String,
    pub name: String,
    pub size: u64,
    pub is_binary: bool,
    /// Tổng số dòng của file (0 nếu nhị phân)
    pub total_lines: usize,
    /// Dòng bắt đầu của đoạn trả về (0-based)
    pub offset: usize,
    pub lines: Vec<String>,
    pub has_more: bool,
    /// Git diff HEAD, chỉ trả về khi offset = 0
    pub git_diff: String,
    pub error: String,
}

impl FileLinesResponse {
    fn failure(path: &str, status_error: &str) -> Self {
        Self {
            ok: false,
            path: path.to_string(),
            name: Path::new(path)
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or("")
                .to_string(),
            size: 0,
            is_binary: false,
            total_lines: 0,
            offset: 0,
            lines: Vec::new(),
            has_more: false,
            git_diff: String::new(),
            error: status_error.to_string(),
        }
    }
}

/// `GET /api/files/lines?path=<file>&offset=<dòng bắt đầu>&limit=<số dòng>`
pub async fn handle_file_lines(Query(params): Query<HashMap<String, String>>) -> Response {
    let raw_path = params
        .get("path")
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());
    let Some(raw_path) = raw_path else {
        return (
            StatusCode::BAD_REQUEST,
            Json(FileLinesResponse::failure("", "Thiếu đường dẫn tệp (path)")),
        )
            .into_response();
    };
    let offset = params
        .get("offset")
        .and_then(|s| s.parse::<usize>().ok())
        .unwrap_or(0);
    let limit = params
        .get("limit")
        .and_then(|s| s.parse::<usize>().ok())
        .unwrap_or(200)
        .clamp(1, MAX_LINES_PER_REQUEST);

    let path_for_task = raw_path.clone();
    let result =
        tokio::task::spawn_blocking(move || read_file_lines(&path_for_task, offset, limit))
            .await
            .unwrap_or_else(|e| {
                Err((
                    StatusCode::INTERNAL_SERVER_ERROR,
                    format!("Lỗi nội bộ: {e}"),
                ))
            });

    match result {
        Ok(resp) => (StatusCode::OK, Json(resp)).into_response(),
        Err((status, message)) => (
            status,
            Json(FileLinesResponse::failure(&raw_path, &message)),
        )
            .into_response(),
    }
}

fn read_file_lines(
    raw_path: &str,
    offset: usize,
    limit: usize,
) -> Result<FileLinesResponse, (StatusCode, String)> {
    let path = Path::new(raw_path);
    let meta = match fs::metadata(path) {
        Ok(m) if m.is_file() => m,
        _ => {
            return Err((
                StatusCode::NOT_FOUND,
                "Tệp không tồn tại trên server".to_string(),
            ))
        }
    };
    let size = meta.len();
    let name = path
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("file")
        .to_string();

    if looks_binary(path) {
        return Ok(FileLinesResponse {
            ok: true,
            path: raw_path.to_string(),
            name,
            size,
            is_binary: true,
            total_lines: 0,
            offset: 0,
            lines: Vec::new(),
            has_more: false,
            git_diff: String::new(),
            error: String::new(),
        });
    }

    let offsets = line_offsets(path, &meta).map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("Không đọc được tệp: {e}"),
        )
    })?;
    let total = offsets.len();
    let start = offset.min(total);
    let lines = read_line_range(path, &offsets, start, limit).map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("Không đọc được tệp: {e}"),
        )
    })?;
    let has_more = start + lines.len() < total;
    let git_diff = if start == 0 {
        git_diff_for(path, size)
    } else {
        String::new()
    };

    Ok(FileLinesResponse {
        ok: true,
        path: raw_path.to_string(),
        name,
        size,
        is_binary: false,
        total_lines: total,
        offset: start,
        lines,
        has_more,
        git_diff,
        error: String::new(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_file(name: &str, body: &[u8]) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("muop-lines-{}", name));
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("f.txt");
        fs::write(&path, body).unwrap();
        path
    }

    #[test]
    fn counts_lines_with_and_without_trailing_newline() {
        assert_eq!(
            build_offsets(&temp_file("a", b"one\ntwo\n")).unwrap().len(),
            2
        );
        assert_eq!(
            build_offsets(&temp_file("b", b"one\ntwo")).unwrap().len(),
            2
        );
        assert_eq!(build_offsets(&temp_file("c", b"")).unwrap().len(), 0);
    }

    #[test]
    fn reads_a_middle_range_without_loading_whole_file() {
        let path = temp_file("d", b"l0\nl1\nl2\nl3\r\nl4");
        let offsets = build_offsets(&path).unwrap();
        let lines = read_line_range(&path, &offsets, 1, 3).unwrap();
        assert_eq!(lines, vec!["l1", "l2", "l3"]);
        let tail = read_line_range(&path, &offsets, 4, 10).unwrap();
        assert_eq!(tail, vec!["l4"]);
    }
}
