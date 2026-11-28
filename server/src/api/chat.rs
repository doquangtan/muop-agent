use crate::chat;
use crate::chat::AppState;
use crate::models::*;
use axum::{
    extract::{Query, State},
    http::{header, StatusCode},
    response::IntoResponse,
    Json,
};
use serde_json::json;
use std::collections::HashMap;

/// Ảnh đính kèm của một bước người dùng, dùng để hiển thị trong bong bóng chat.
/// - `?path=<file>`: ảnh agy đã lưu trong thư mục uploads (chỉ đọc trong thư mục đó)
/// - `?cid=<session>&uuid=<dòng user>&i=<n>`: ảnh base64 trong transcript Claude
pub async fn handle_chat_attachment(Query(q): Query<HashMap<String, String>>) -> impl IntoResponse {
    let result = tokio::task::spawn_blocking(move || -> Result<(Vec<u8>, String), String> {
        if let Some(path) = q.get("path") {
            let (bytes, mime) = crate::chat::attachments::read_uploaded_image(path)?;
            return Ok((bytes, mime.to_string()));
        }
        let cid = q.get("cid").map(String::as_str).unwrap_or("");
        let uuid = q.get("uuid").map(String::as_str).unwrap_or("");
        let valid = |s: &str| {
            !s.is_empty()
                && s.chars()
                    .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
        };
        if !valid(cid) || !valid(uuid) {
            return Err("thiếu hoặc sai conversation/uuid".to_string());
        }
        let index: usize = q
            .get("i")
            .and_then(|i| i.parse().ok())
            .ok_or_else(|| "thiếu chỉ số ảnh".to_string())?;
        let file = crate::claude::code::find_session_file(cid)
            .ok_or_else(|| "không tìm thấy conversation".to_string())?;
        crate::chat::attachments::read_transcript_image(&file, uuid, index)
    })
    .await;

    match result {
        Ok(Ok((bytes, mime))) => ([(header::CONTENT_TYPE, mime)], bytes).into_response(),
        Ok(Err(error)) => (
            StatusCode::NOT_FOUND,
            Json(json!({"ok": false, "error": error})),
        )
            .into_response(),
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"ok": false, "error": format!("{e}")})),
        )
            .into_response(),
    }
}

pub async fn handle_chat_send(
    State(state): State<AppState>,
    Json(req): Json<ChatSendRequest>,
) -> impl IntoResponse {
    let result = chat::start_chat_turn(state.clone(), req).await;
    state.broadcast_session_update(&result.conversation_id);
    state.emit_session_files_to_room(&result.conversation_id);
    let status = if result.ok {
        StatusCode::OK
    } else {
        StatusCode::BAD_REQUEST
    };
    (status, Json(result))
}

/// Hủy lịch tự gửi lại sau rate limit của một conversation
pub async fn handle_chat_retry_cancel(
    State(state): State<AppState>,
    Json(req): Json<CancelRetryRequest>,
) -> impl IntoResponse {
    let cid = req.conversation_id.trim();
    if cid.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({"ok": false, "error": "Thiếu conversationId"})),
        );
    }
    let cancelled = crate::chat::retry::cancel(&state, cid);
    (
        StatusCode::OK,
        Json(json!({"ok": true, "cancelled": cancelled, "conversationId": cid})),
    )
}

/// Cấu hình tự gửi lại của conversation: `GET /api/chat/retry/config?id=<cid>` (mặc định nếu chưa đặt)
pub async fn handle_chat_retry_config_get(
    Query(q): Query<HashMap<String, String>>,
) -> impl IntoResponse {
    let cid = q
        .get("id")
        .map(|s| s.trim().to_string())
        .unwrap_or_default();
    if cid.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({"ok": false, "error": "Thiếu conversationId"})),
        );
    }
    let config =
        crate::infra::store::conversation_retry_config(&cid).unwrap_or_else(|| RetryConfigDto {
            conversation_id: cid.clone(),
            ..RetryConfigDto::default()
        });
    (StatusCode::OK, Json(json!({"ok": true, "config": config})))
}

/// Lưu cấu hình tự gửi lại: `POST /api/chat/retry/config`. Áp dụng ngay cho lịch đang chờ của conversation.
pub async fn handle_chat_retry_config_save(
    State(state): State<AppState>,
    Json(mut cfg): Json<RetryConfigDto>,
) -> impl IntoResponse {
    cfg.conversation_id = cfg.conversation_id.trim().to_string();
    cfg.prompt = cfg.prompt.trim().to_string();
    if cfg.conversation_id.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({"ok": false, "error": "Thiếu conversationId"})),
        );
    }
    if let Err(error) = crate::chat::retry::validate(&cfg) {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({"ok": false, "error": error})),
        );
    }
    if !crate::infra::store::set_conversation_retry_config(&cfg) {
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"ok": false, "error": "Không lưu được cấu hình tự gửi lại"})),
        );
    }
    crate::chat::retry::apply_config(&state, &cfg);
    (StatusCode::OK, Json(json!({"ok": true, "config": cfg})))
}

pub async fn handle_chat_stop(
    State(state): State<AppState>,
    Json(req): Json<ChatStopRequest>,
) -> impl IntoResponse {
    let stopped = chat::stop_chat_turn(&state, &req.conversation_id);
    Json(json!({
        "ok": true,
        "stopped": stopped,
    }))
}
