use crate::models::*;
use crate::scanner;
use axum::{
    body::Body,
    extract::Query,
    http::{header, StatusCode},
    response::{IntoResponse, Response},
    Json,
};
use chrono::{DateTime, Utc};
use serde_json::json;
use std::collections::HashMap;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::SystemTime;

pub async fn handle_files_list(Query(params): Query<HashMap<String, String>>) -> impl IntoResponse {
    let raw_path = params
        .get("path")
        .map(|s| s.trim())
        .filter(|s| !s.is_empty())
        .unwrap_or(scanner::ECOSYSTEM_DIR_PATH);
    let show_hidden = params
        .get("showHidden")
        .map(|s| s == "true" || s == "1")
        .unwrap_or(false);

    let target_path = PathBuf::from(raw_path);
    let canonical = fs::canonicalize(&target_path).unwrap_or(target_path);

    if !canonical.exists() || !canonical.is_dir() {
        return (
            StatusCode::BAD_REQUEST,
            Json(ServerDirListResponse {
                ok: false,
                current_path: canonical.to_string_lossy().to_string(),
                parent_path: String::new(),
                entries: Vec::new(),
                error: "Thư mục không tồn tại hoặc không hợp lệ".to_string(),
            }),
        );
    }

    let parent_path = canonical
        .parent()
        .map(|p| p.to_string_lossy().to_string())
        .unwrap_or_default();

    let mut entries = Vec::new();
    if let Ok(read_dir) = fs::read_dir(&canonical) {
        for item in read_dir.flatten() {
            let p = item.path();
            let name = match p.file_name().and_then(|n| n.to_str()) {
                Some(s) => s.to_string(),
                None => continue,
            };
            if !show_hidden && name.starts_with('.') {
                continue;
            }
            if name == ".git" || name == "target" || name == ".dart_tool" || name == "node_modules"
            {
                continue;
            }
            if let Ok(meta) = fs::metadata(&p) {
                let modified: DateTime<Utc> =
                    meta.modified().unwrap_or(SystemTime::UNIX_EPOCH).into();
                let mode = meta.permissions().mode();
                let perms = format_unix_mode(mode, meta.is_dir());
                entries.push(ServerFileEntry {
                    name,
                    path: p.to_string_lossy().to_string(),
                    is_dir: meta.is_dir(),
                    size: if meta.is_dir() { 0 } else { meta.len() },
                    modified_at: modified.to_rfc3339(),
                    permissions: perms,
                });
            }
        }
    }

    entries.sort_by(|a, b| {
        b.is_dir
            .cmp(&a.is_dir)
            .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
    });

    (
        StatusCode::OK,
        Json(ServerDirListResponse {
            ok: true,
            current_path: canonical.to_string_lossy().to_string(),
            parent_path,
            entries,
            error: String::new(),
        }),
    )
}

pub fn format_unix_mode(mode: u32, is_dir: bool) -> String {
    let mut s = String::with_capacity(10);
    s.push(if is_dir { 'd' } else { '-' });
    let flags = [
        (0o400, 'r'),
        (0o200, 'w'),
        (0o100, 'x'),
        (0o040, 'r'),
        (0o020, 'w'),
        (0o010, 'x'),
        (0o004, 'r'),
        (0o002, 'w'),
        (0o001, 'x'),
    ];
    for (bit, ch) in flags {
        s.push(if mode & bit != 0 { ch } else { '-' });
    }
    s
}

pub async fn handle_file_read(Query(params): Query<HashMap<String, String>>) -> impl IntoResponse {
    let raw_path = match params
        .get("path")
        .map(|s| s.trim())
        .filter(|s| !s.is_empty())
    {
        Some(p) => p,
        None => {
            return (
                StatusCode::BAD_REQUEST,
                Json(ServerFileReadResponse {
                    ok: false,
                    path: String::new(),
                    name: String::new(),
                    size: 0,
                    is_binary: false,
                    is_image: false,
                    content: String::new(),
                    git_diff: String::new(),
                    error: "Thiếu đường dẫn tệp (path)".to_string(),
                }),
            );
        }
    };

    let file_path = Path::new(raw_path);
    if !file_path.exists() || !file_path.is_file() {
        return (
            StatusCode::NOT_FOUND,
            Json(ServerFileReadResponse {
                ok: false,
                path: raw_path.to_string(),
                name: String::new(),
                size: 0,
                is_binary: false,
                is_image: false,
                content: String::new(),
                git_diff: String::new(),
                error: "Tệp không tồn tại trên server".to_string(),
            }),
        );
    }

    let name = file_path
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("file")
        .to_string();
    let size = fs::metadata(file_path).map(|m| m.len()).unwrap_or(0);

    let ext = file_path
        .extension()
        .and_then(|s| s.to_str())
        .unwrap_or("")
        .to_lowercase();
    let is_image = matches!(
        ext.as_str(),
        "png" | "jpg" | "jpeg" | "gif" | "webp" | "bmp" | "ico" | "svg"
    );

    // Chạy git diff nếu file nằm trong git repository
    let mut git_diff = String::new();
    if let Some(parent_dir) = file_path.parent() {
        if let Ok(out) = Command::new("git")
            .args(["diff", "HEAD", "--", raw_path])
            .current_dir(parent_dir)
            .output()
        {
            if out.status.success() {
                git_diff = String::from_utf8_lossy(&out.stdout).to_string();
            }
        }
    }

    match fs::read(file_path) {
        Ok(bytes) => {
            let max_preview = 5 * 1024 * 1024; // Hỗ trợ xem các file lớn đến 5MB
            let slice = if bytes.len() > max_preview {
                &bytes[..max_preview]
            } else {
                &bytes[..]
            };
            let is_binary = if is_image && ext != "svg" {
                true
            } else {
                slice.iter().take(512).any(|&b| b == 0)
            };
            let content = if is_binary {
                String::new()
            } else {
                String::from_utf8_lossy(slice).to_string()
            };
            (
                StatusCode::OK,
                Json(ServerFileReadResponse {
                    ok: true,
                    path: raw_path.to_string(),
                    name,
                    size,
                    is_binary,
                    is_image,
                    content,
                    git_diff,
                    error: String::new(),
                }),
            )
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ServerFileReadResponse {
                ok: false,
                path: raw_path.to_string(),
                name,
                size,
                is_binary: false,
                is_image,
                content: String::new(),
                git_diff,
                error: format!("Không thể đọc tệp: {}", e),
            }),
        ),
    }
}

pub async fn handle_file_download(Query(params): Query<HashMap<String, String>>) -> Response {
    let raw_path = match params
        .get("path")
        .map(|s| s.trim())
        .filter(|s| !s.is_empty())
    {
        Some(p) => p,
        None => {
            return (
                StatusCode::BAD_REQUEST,
                Json(json!({ "ok": false, "error": "Thiếu đường dẫn file (path)" })),
            )
                .into_response();
        }
    };

    let file_path = Path::new(raw_path);
    if !file_path.exists() || !file_path.is_file() {
        return (
            StatusCode::NOT_FOUND,
            Json(json!({ "ok": false, "error": "Tệp không tồn tại trên server" })),
        )
            .into_response();
    }

    let filename = file_path
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("download.bin")
        .replace('"', "");

    let ext = file_path
        .extension()
        .and_then(|s| s.to_str())
        .unwrap_or("")
        .to_lowercase();
    let mime = match ext.as_str() {
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "svg" => "image/svg+xml",
        "bmp" => "image/bmp",
        "ico" => "image/x-icon",
        "md" | "markdown" => "text/markdown; charset=utf-8",
        "json" => "application/json",
        "txt" | "log" => "text/plain; charset=utf-8",
        _ => "application/octet-stream",
    };

    // Lấy kích thước file để gửi Content-Length (giúp client hiển thị progress đúng)
    let file_size = match tokio::fs::metadata(file_path).await {
        Ok(m) => m.len(),
        Err(e) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({ "ok": false, "error": format!("Không đọc được metadata: {}", e) })),
            )
                .into_response();
        }
    };

    // Mở file và stream trực tiếp ra response — không load toàn bộ vào RAM
    match tokio::fs::File::open(file_path).await {
        Ok(file) => {
            let stream = tokio_util::io::ReaderStream::new(file);
            let body = Body::from_stream(stream);
            Response::builder()
                .status(StatusCode::OK)
                .header(header::CONTENT_TYPE, mime)
                .header(
                    header::CONTENT_DISPOSITION,
                    format!("inline; filename=\"{}\"", filename),
                )
                .header(header::CONTENT_LENGTH, file_size.to_string())
                .header(header::CACHE_CONTROL, "no-cache")
                .body(body)
                .unwrap_or_else(|_| StatusCode::INTERNAL_SERVER_ERROR.into_response())
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "ok": false, "error": format!("Không thể mở tệp: {}", e) })),
        )
            .into_response(),
    }
}
