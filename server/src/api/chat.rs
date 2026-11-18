use crate::chat;
use crate::chat::AppState;
use crate::models::*;
use axum::{extract::State, http::StatusCode, response::IntoResponse, Json};
use serde_json::json;

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
