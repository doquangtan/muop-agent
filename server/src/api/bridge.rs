//! REST của bridge trên máy B: cấu hình máy A và chuyển lệnh sang A.

use axum::{http::StatusCode, response::IntoResponse, Json};
use serde::Deserialize;
use serde_json::{json, Value};

use crate::bridge;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PeerRequest {
    /// `http://IP:8787`; chuỗi rỗng để ngắt kết nối
    pub url: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StopRequest {
    pub conversation_id: String,
}

/// Trạng thái kết nối tới máy A
pub async fn handle_status() -> impl IntoResponse {
    Json(json!(bridge::status()))
}

/// Đặt địa chỉ máy A và kết nối lại
pub async fn handle_set_peer(Json(req): Json<PeerRequest>) -> impl IntoResponse {
    match bridge::set_peer(&req.url) {
        Ok(status) => (StatusCode::OK, Json(json!(status))),
        Err(e) => (
            StatusCode::BAD_REQUEST,
            Json(json!({ "ok": false, "error": e })),
        ),
    }
}

/// Gửi lượt chat tới agent trên máy A. Body giống `POST /api/chat/send` của A.
pub async fn handle_send(Json(body): Json<Value>) -> impl IntoResponse {
    match bridge::send_chat(body).await {
        Ok(ack) => (StatusCode::OK, Json(ack)),
        Err(e) => (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(json!({ "ok": false, "error": e })),
        ),
    }
}

/// Dừng lượt đang chạy trên máy A
pub async fn handle_stop(Json(req): Json<StopRequest>) -> impl IntoResponse {
    match bridge::stop_chat(&req.conversation_id).await {
        Ok(ack) => (StatusCode::OK, Json(ack)),
        Err(e) => (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(json!({ "ok": false, "error": e })),
        ),
    }
}

/// Trả lời / duyệt plan của Claude trên máy A (proxy `POST /api/claude/respond`).
/// Server A tự dựng prompt và chạy lại lượt trong cùng conversation.
///
/// Với agy thì không có đường này: `POST /api/ai-questions/answer` của A chỉ cập nhật
/// trạng thái hiển thị, không gửi gì tới tiến trình agy. Trả lời agy = gửi lượt mới
/// bằng `POST /api/bridge/send` kèm `conversationId` của conversation đó.
pub async fn handle_respond(Json(body): Json<Value>) -> impl IntoResponse {
    proxy("/api/claude/respond", body).await
}

async fn proxy(path: &str, body: Value) -> (StatusCode, Json<Value>) {
    match bridge::post_peer(path, body).await {
        Ok(resp) => (StatusCode::OK, Json(resp)),
        Err(e) => (
            StatusCode::BAD_GATEWAY,
            Json(json!({ "ok": false, "error": e })),
        ),
    }
}
