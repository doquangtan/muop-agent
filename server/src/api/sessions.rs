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

/// Lịch sử chia sẻ theo trang, đi từ `from_step` tới tin mới nhất: `GET /api/session/share`
/// Tham số: `id`, `from_step` (mặc định 0), `page` (mặc định 0), `limit` (mặc định 50, tối đa 100).
pub async fn handle_session_share(
    Query(params): Query<HashMap<String, String>>,
) -> impl IntoResponse {
    let session_id = match params.get("id").map(|s| s.trim()).filter(|s| !s.is_empty()) {
        Some(id) => id.to_string(),
        None => {
            return (
                StatusCode::BAD_REQUEST,
                Json(serde_json::json!({"error": "Missing session id"})),
            );
        }
    };
    let num = |keys: &[&str], default: usize| {
        keys.iter()
            .find_map(|k| params.get(*k))
            .and_then(|s| s.parse::<usize>().ok())
            .unwrap_or(default)
    };
    let from_step = num(&["from_step", "fromStep"], 0);
    let page = num(&["page"], 0);
    let limit = num(&["limit"], 50).clamp(1, 100);

    let result = tokio::task::spawn_blocking(move || {
        scanner::get_session_share_page(&session_id, from_step, page, limit)
    })
    .await
    .ok()
    .flatten();
    match result {
        Some(page) => (
            StatusCode::OK,
            Json(serde_json::to_value(&page).unwrap_or_default()),
        ),
        None => (
            StatusCode::NOT_FOUND,
            Json(serde_json::json!({"error": "Session not found"})),
        ),
    }
}
