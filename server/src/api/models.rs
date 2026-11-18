use crate::models::*;
use axum::{extract::Query, http::StatusCode, response::IntoResponse, Json};
use serde_json::json;
use std::collections::HashMap;

/// Model đã lưu của một conversation (`model` = null nếu chưa có)
pub async fn handle_conversation_model_get(
    Query(params): Query<HashMap<String, String>>,
) -> impl IntoResponse {
    let cid = params
        .get("id")
        .map(|s| s.trim().to_string())
        .unwrap_or_default();
    if cid.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({"error": "Missing conversation id"})),
        );
    }
    let model = crate::infra::store::conversation_model(&cid);
    (
        StatusCode::OK,
        Json(json!({"conversationId": cid, "model": model})),
    )
}

/// Lưu model đã chọn cho một conversation
pub async fn handle_conversation_model_set(
    Json(req): Json<ConversationModelRequest>,
) -> impl IntoResponse {
    let cid = req.conversation_id.trim();
    let model = req.model.trim();
    if cid.is_empty() || model.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({"ok": false, "error": "Thiếu conversationId hoặc model"})),
        );
    }
    let saved = crate::infra::store::set_conversation_model(cid, model);
    let status = if saved {
        StatusCode::OK
    } else {
        StatusCode::INTERNAL_SERVER_ERROR
    };
    (
        status,
        Json(json!({"ok": saved, "conversationId": cid, "model": model})),
    )
}

/// Sửa tay giới hạn context của một model (ghi nhận là `manual`, không bị quét ghi đè)
pub async fn handle_model_context_limit_set(
    Json(req): Json<ModelContextLimitRequest>,
) -> impl IntoResponse {
    let model = req.model.trim();
    if model.is_empty() || req.limit == 0 {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({"ok": false, "error": "Thiếu model hoặc limit > 0"})),
        );
    }
    let saved = crate::infra::store::set_manual_context_limit(model, req.limit);
    let status = if saved {
        StatusCode::OK
    } else {
        StatusCode::INTERNAL_SERVER_ERROR
    };
    (
        status,
        Json(json!({"ok": saved, "model": model, "limit": req.limit})),
    )
}
