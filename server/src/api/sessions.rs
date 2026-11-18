use crate::chat::AppState;
use crate::scanner;
use axum::{
    extract::{Query, State},
    http::StatusCode,
    response::IntoResponse,
    Json,
};
use serde_json::json;
use std::collections::HashMap;

/// Tóm tắt toàn bộ conversation (không kèm steps): `GET /api/sessions`
pub async fn handle_sessions_list(State(state): State<AppState>) -> impl IntoResponse {
    let streams = state
        .active_streams
        .lock()
        .map(|g| g.clone())
        .unwrap_or_default();
    let list = tokio::task::spawn_blocking(move || {
        let sessions = scanner::scan_all_sessions(&streams, None, 500);
        scanner::summarize_sessions(&sessions, &streams)
    })
    .await
    .unwrap_or_default();
    Json(json!({ "sessions": list }))
}

pub async fn handle_session_detail(
    State(state): State<AppState>,
    Query(params): Query<HashMap<String, String>>,
) -> impl IntoResponse {
    let session_id = match params.get("id").map(|s| s.trim()).filter(|s| !s.is_empty()) {
        Some(id) => id,
        None => {
            return (
                StatusCode::BAD_REQUEST,
                Json(serde_json::json!({"error": "Missing session id"})),
            );
        }
    };

    // Phải truyền stream hiện tại: không có nó, lượt đang chạy (agy/claude) bị hiện là gián đoạn
    let streams = state
        .active_streams
        .lock()
        .map(|g| g.clone())
        .unwrap_or_default();
    if let Some(sess) = scanner::get_single_session_with_streams(session_id, &streams) {
        (
            StatusCode::OK,
            Json(serde_json::to_value(&sess).unwrap_or_default()),
        )
    } else {
        (
            StatusCode::NOT_FOUND,
            Json(serde_json::json!({"error": "Session not found"})),
        )
    }
}

pub async fn handle_session_steps(
    Query(params): Query<HashMap<String, String>>,
) -> impl IntoResponse {
    let session_id = match params.get("id").map(|s| s.trim()).filter(|s| !s.is_empty()) {
        Some(id) => id,
        None => {
            return (
                StatusCode::BAD_REQUEST,
                Json(serde_json::json!({"error": "Missing session id"})),
            );
        }
    };

    let before_step = params
        .get("before_step")
        .or_else(|| params.get("beforeStep"))
        .or_else(|| params.get("before_step_index"))
        .and_then(|s| s.parse::<usize>().ok());

    let limit = params
        .get("limit")
        .and_then(|s| s.parse::<usize>().ok())
        .unwrap_or(50)
        .clamp(1, 200);

    if let Some(page) = scanner::get_session_steps_page(session_id, before_step, limit) {
        (
            StatusCode::OK,
            Json(serde_json::to_value(&page).unwrap_or_default()),
        )
    } else {
        (
            StatusCode::NOT_FOUND,
            Json(serde_json::json!({"error": "Session not found"})),
        )
    }
}
