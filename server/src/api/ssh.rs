use crate::models::*;
use axum::{http::StatusCode, response::IntoResponse, Json};
use serde_json::json;

/// Danh sách máy SSH đã lưu (không kèm bí mật)
pub async fn handle_ssh_hosts_list() -> impl IntoResponse {
    // "Máy này" luôn có và đứng đầu danh sách
    crate::setup::ssh::ensure_local_host();
    let mut rows = crate::infra::store::list_ssh_hosts();
    rows.sort_by_key(|r| !crate::ssh::hosts::is_builtin(r));
    let hosts: Vec<_> = rows.iter().map(crate::ssh::hosts::to_dto).collect();
    Json(hosts)
}

/// Mục mặc định không sửa/xóa được
fn builtin_refused() -> (StatusCode, Json<serde_json::Value>) {
    (
        StatusCode::FORBIDDEN,
        Json(json!({"ok": false, "error": "Máy này là mục mặc định, không sửa hay xóa được"})),
    )
}

/// Phiên terminal SSH đang chạy (REST, không cần socket)
pub async fn handle_ssh_sessions_list() -> impl IntoResponse {
    Json(crate::ssh::terminal::list())
}

/// Thêm hoặc sửa máy SSH
pub async fn handle_ssh_host_save(Json(req): Json<SshHostSaveRequest>) -> impl IntoResponse {
    if req.id > 0 && crate::setup::ssh::local_host_id() == Some(req.id) {
        return builtin_refused();
    }
    let existing = if req.id > 0 {
        match crate::infra::store::get_ssh_host(req.id) {
            Some(row) => Some(row),
            None => {
                return (
                    StatusCode::NOT_FOUND,
                    Json(json!({"ok": false, "error": "Không tìm thấy máy SSH"})),
                )
            }
        }
    } else {
        None
    };
    let auth_type = req.auth_type.trim().to_string();
    let prev = existing.clone().unwrap_or_default();
    // Để trống bí mật nghĩa là giữ nguyên giá trị đã lưu
    let mut row = crate::infra::store::SshHostRow {
        id: req.id,
        name: req.name.trim().to_string(),
        host: req.host.trim().to_string(),
        port: req.port,
        username: req.username.trim().to_string(),
        password: if req.password.is_empty() {
            prev.password.clone()
        } else {
            req.password.clone()
        },
        private_key: if req.private_key.trim().is_empty() {
            prev.private_key.clone()
        } else {
            req.private_key.trim_end().to_string()
        },
    };
    if row.name.is_empty() {
        row.name = row.host.clone();
    }
    // Chỉ giữ bí mật của kiểu xác thực đang chọn
    match auth_type.as_str() {
        "password" => row.private_key.clear(),
        "key" => row.password.clear(),
        _ => {}
    }
    if let Err(e) = crate::ssh::hosts::validate(&row, &auth_type) {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({"ok": false, "error": e})),
        );
    }
    match crate::infra::store::save_ssh_host(&row) {
        Some(id) => (StatusCode::OK, Json(json!({"ok": true, "id": id}))),
        None => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"ok": false, "error": "Không lưu được máy SSH"})),
        ),
    }
}

/// Xóa máy SSH đã lưu
pub async fn handle_ssh_host_delete(Json(req): Json<SshHostIdRequest>) -> impl IntoResponse {
    if crate::setup::ssh::local_host_id() == Some(req.id) {
        return builtin_refused();
    }
    let ok = crate::infra::store::delete_ssh_host(req.id);
    (
        if ok {
            StatusCode::OK
        } else {
            StatusCode::NOT_FOUND
        },
        Json(json!({"ok": ok})),
    )
}

/// Chạy một lệnh trên máy SSH đã lưu
pub async fn handle_ssh_exec(Json(req): Json<SshExecRequest>) -> impl IntoResponse {
    let Some(row) = crate::infra::store::get_ssh_host(req.host_id) else {
        return (
            StatusCode::NOT_FOUND,
            Json(SshExecResponse {
                ok: false,
                exit_code: None,
                stdout: String::new(),
                stderr: String::new(),
                error: "Không tìm thấy máy SSH".into(),
            }),
        );
    };
    let res = crate::ssh::hosts::exec(&row, &req.command, req.timeout_secs).await;
    (StatusCode::OK, Json(res))
}
