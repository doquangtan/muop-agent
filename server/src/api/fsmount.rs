//! Mount project của máy khác về máy này (cùng bước tự chạy khi nhận lượt chat có `remoteProject`).

use axum::{http::StatusCode, response::IntoResponse, Json};
use serde_json::json;

use crate::fsmount;
use crate::models::RemoteProject;

/// Mount `remoteProject` về máy này và trả về điểm mount. Dùng để kiểm tra thủ công.
pub async fn handle_ensure(Json(req): Json<RemoteProject>) -> impl IntoResponse {
    match fsmount::resolve_chat_project(&req).await {
        Ok(m) => (
            StatusCode::OK,
            Json(json!({
                "ok": true,
                "mountPoint": m.mount_point.to_string_lossy(),
                "origin": m.origin,
            })),
        ),
        Err(e) => (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(json!({ "ok": false, "error": e })),
        ),
    }
}

/// Máy chính đăng ký khi được thêm vào cầu nối: kiểm tra FUSE và kết nối tới máy chính (không mount).
pub async fn handle_register(Json(req): Json<RemoteProject>) -> impl IntoResponse {
    match tokio::task::spawn_blocking(move || fsmount::register_origin(&req)).await {
        Ok(Ok(origin)) => (
            StatusCode::OK,
            Json(json!({ "ok": true, "origin": origin })),
        ),
        Ok(Err(e)) => (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(json!({ "ok": false, "error": e })),
        ),
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "ok": false, "error": format!("lỗi nội bộ: {e}") })),
        ),
    }
}
