//! REST của SFTP cho máy SSH đã lưu (xem `sftp/mod.rs`). Lỗi nghiệp vụ trả HTTP 200 với `ok: false`.

use crate::infra::store;
use crate::models::*;
use crate::sftp::{self, Failure};
use axum::{
    body::Body,
    extract::Path,
    http::{header, StatusCode},
    response::{IntoResponse, Response},
    Json,
};
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use serde_json::{json, Value};

/// Lỗi thành JSON. `needsPassword` báo app hỏi mật khẩu rồi mở lại phiên; `sessionGone` báo phiên đã mất.
fn fail(f: Failure) -> Json<Value> {
    Json(json!({
        "ok": false,
        "error": f.message,
        "needsPassword": f.needs_password,
        "passwordKind": "ssh",
        "passwordWrong": f.password_wrong,
        "exists": f.exists,
        "sessionGone": f.gone,
    }))
}

fn ok_empty() -> Json<Value> {
    Json(json!({"ok": true, "error": "", "needsPassword": false}))
}

pub async fn handle_sftp_open(Json(req): Json<SftpOpenRequest>) -> impl IntoResponse {
    let Some(row) = store::get_ssh_host(req.host_id) else {
        return fail(Failure {
            message: "Không tìm thấy máy SSH".into(),
            ..Default::default()
        });
    };
    match sftp::open(row, &req.password, req.save_password).await {
        Ok(info) => Json(json!({
            "ok": true,
            "error": "",
            "needsPassword": false,
            "session": {
                "sessionId": info.session_id,
                "hostId": info.host_id,
                "hostName": info.host_name,
                "home": info.home,
                "startedAt": info.started_at,
            },
        })),
        Err(f) => fail(f),
    }
}

/// Mở (hoặc gắn lại) phiên SFTP của "Máy này". Đây là đường duy nhất để app truy cập file của máy server:
/// không cần chọn máy trong danh sách, cùng API với máy SSH.
pub async fn handle_sftp_local_open() -> impl IntoResponse {
    let Some(id) = crate::setup::ssh::ensure_local_host() else {
        return fail(Failure {
            message: "Không xác định được máy này".into(),
            ..Default::default()
        });
    };
    let Some(row) = store::get_ssh_host(id) else {
        return fail(Failure {
            message: "Không tìm thấy máy này".into(),
            ..Default::default()
        });
    };
    match sftp::open(row, "", false).await {
        Ok(info) => Json(json!({
            "ok": true,
            "error": "",
            "needsPassword": false,
            "session": {
                "sessionId": info.session_id,
                "hostId": info.host_id,
                "hostName": info.host_name,
                "home": info.home,
                "startedAt": info.started_at,
            },
        })),
        Err(f) => fail(f),
    }
}

pub async fn handle_sftp_close(Json(req): Json<SftpSessionRequest>) -> impl IntoResponse {
    Json(json!({"ok": sftp::close(&req.session_id).await}))
}

pub async fn handle_sftp_list(Json(req): Json<SftpPathRequest>) -> impl IntoResponse {
    match sftp::list(&req.session_id, &req.path).await {
        Ok(entries) => {
            let dtos: Vec<SftpEntryDto> = entries
                .into_iter()
                .map(|e| SftpEntryDto {
                    path: listing_join(&req.path, &e.name),
                    name: e.name,
                    is_dir: e.is_dir,
                    is_link: e.is_link,
                    size: e.size,
                    modified: e.modified,
                    mode: e.mode,
                    modified_unix: e.modified_unix,
                })
                .collect();
            Json(json!({
                "ok": true,
                "error": "",
                "needsPassword": false,
                "path": req.path,
                "entries": dtos,
            }))
        }
        Err(f) => fail(f),
    }
}

fn listing_join(dir: &str, name: &str) -> String {
    crate::sftp::listing::join(dir, name)
}

pub async fn handle_sftp_op(Json(req): Json<SftpOpRequest>) -> impl IntoResponse {
    let res = match req.action.as_str() {
        "mkdir" => sftp::mkdir(&req.session_id, &req.path).await,
        "rename" => sftp::rename(&req.session_id, &req.path, &req.target).await,
        "delete" => sftp::delete(&req.session_id, &req.path, req.is_dir).await,
        _ => Err(Failure {
            message: "Thao tác không hợp lệ".into(),
            ..Default::default()
        }),
    };
    match res {
        Ok(()) => ok_empty(),
        Err(f) => fail(f),
    }
}

pub async fn handle_sftp_upload(Json(req): Json<SftpUploadRequest>) -> impl IntoResponse {
    let data = match B64.decode(req.data_base64.as_bytes()) {
        Ok(d) => d,
        Err(_) => {
            return fail(Failure {
                message: "Dữ liệu tải lên không hợp lệ".into(),
                ..Default::default()
            })
        }
    };
    match sftp::upload(&req.session_id, &req.path, &data, req.overwrite).await {
        Ok(()) => ok_empty(),
        Err(f) => fail(f),
    }
}

pub async fn handle_sftp_read(Json(req): Json<SftpPathRequest>) -> impl IntoResponse {
    match sftp::read(&req.session_id, &req.path).await {
        Ok((bytes, binary)) => {
            let content = if binary {
                String::new()
            } else {
                String::from_utf8_lossy(&bytes).into_owned()
            };
            Json(json!({
                "ok": true,
                "error": "",
                "needsPassword": false,
                "content": content,
                "binary": binary,
                "size": bytes.len(),
            }))
        }
        Err(f) => fail(f),
    }
}

/// Chuẩn bị tải xuống: trả `downloadId` để app lấy file qua `GET /api/sftp/download/{id}`
pub async fn handle_sftp_download_prepare(
    Json(req): Json<SftpDownloadRequest>,
) -> impl IntoResponse {
    match sftp::download::prepare(&req.session_id, &req.paths).await {
        Ok(p) => Json(json!({
            "ok": true,
            "error": "",
            "needsPassword": false,
            "downloadId": p.id,
            "name": p.name,
            "size": p.size,
        })),
        Err(f) => fail(f),
    }
}

/// Phục vụ file tải xuống dạng stream (không đọc cả file vào bộ nhớ)
pub async fn handle_sftp_download_get(Path(id): Path<String>) -> Response {
    let Some(served) = sftp::download::lookup(&id) else {
        return (
            StatusCode::NOT_FOUND,
            Json(json!({"ok": false, "error": "Liên kết tải đã hết hạn, hãy tải lại"})),
        )
            .into_response();
    };
    let file = match tokio::fs::File::open(&served.path).await {
        Ok(f) => f,
        Err(_) => {
            return (
                StatusCode::NOT_FOUND,
                Json(json!({"ok": false, "error": "File tải xuống không còn"})),
            )
                .into_response()
        }
    };
    let body = Body::from_stream(tokio_util::io::ReaderStream::new(file));
    Response::builder()
        .status(StatusCode::OK)
        .header(header::CONTENT_TYPE, "application/octet-stream")
        .header(header::CONTENT_LENGTH, served.size)
        .header(
            header::CONTENT_DISPOSITION,
            content_disposition(&served.name),
        )
        .body(body)
        .unwrap_or_else(|_| StatusCode::INTERNAL_SERVER_ERROR.into_response())
}

/// Header Content-Disposition: tên ASCII dự phòng và tên UTF-8 (RFC 5987) cho tên có dấu
fn content_disposition(name: &str) -> String {
    let ascii: String = name
        .chars()
        .map(|c| {
            if c.is_ascii() && c != '"' && c != '\\' && !c.is_control() {
                c
            } else {
                '_'
            }
        })
        .collect();
    format!(
        "attachment; filename=\"{ascii}\"; filename*=UTF-8''{}",
        percent_encode(name)
    )
}

fn percent_encode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        if b.is_ascii_alphanumeric() || matches!(b, b'-' | b'.' | b'_' | b'~') {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}
