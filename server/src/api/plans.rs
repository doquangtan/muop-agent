use crate::chat::AppState;
use crate::models::*;
use crate::{chat, scanner};
use axum::{
    extract::{Query, State},
    http::StatusCode,
    response::IntoResponse,
    Json,
};
use serde_json::json;
use std::collections::HashMap;
use std::fs;

pub async fn handle_plan_pending(
    Query(params): Query<HashMap<String, String>>,
) -> impl IntoResponse {
    let session_id = params
        .get("id")
        .or_else(|| params.get("conversationId"))
        .map(|s| s.trim())
        .unwrap_or("");
    if session_id.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({ "ok": false, "error": "Thiếu id phiên hội thoại (id / conversationId)" })),
        );
    }
    let plans = scanner::scan_pending_plans(session_id);
    (StatusCode::OK, Json(json!({ "ok": true, "plans": plans })))
}

pub async fn handle_plan_action(
    State(state): State<AppState>,
    Json(req): Json<crate::models::PlanActionRequest>,
) -> impl IntoResponse {
    let conv_id = req.conversation_id.trim();
    if conv_id.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({ "ok": false, "error": "Thiếu conversation_id" })),
        );
    }

    // Lượt phê duyệt/góp ý chạy trong đúng project của conversation (không dùng đường dẫn cố định)
    let cid_for_lookup = conv_id.to_string();
    let project_path = tokio::task::spawn_blocking(move || {
        scanner::get_single_session_with_streams(&cid_for_lookup, &HashMap::new())
            .map(|s| s.project_path)
            .filter(|p| !p.is_empty())
    })
    .await
    .ok()
    .flatten();
    let Some(project_path) = project_path else {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({ "ok": false, "error": "Không xác định được project của conversation" })),
        );
    };

    let brain_dir = scanner::brain_root().join(conv_id);
    let meta_file = brain_dir.join(format!("{}.metadata.json", req.file_name));

    if req.action == "approve" || req.action == "cancel" {
        // Cập nhật metadata: requestFeedback = false
        if meta_file.exists() {
            if let Ok(content) = fs::read_to_string(&meta_file) {
                if let Ok(mut val) = serde_json::from_str::<serde_json::Value>(&content) {
                    if let Some(map) = val.as_object_mut() {
                        map.insert(
                            "requestFeedback".to_string(),
                            serde_json::Value::Bool(false),
                        );
                        let _ = fs::write(
                            &meta_file,
                            serde_json::to_string_pretty(&val).unwrap_or_default(),
                        );
                    }
                }
            }
        }

        let (prompt, action_label, message) = if req.action == "cancel" {
            ("cancel plan", "cancelled", "Đã hủy kế hoạch.")
        } else {
            (
                "approved",
                "approved",
                "Đã phê duyệt kế hoạch thành công! Đang kích hoạt chạy tác vụ song song...",
            )
        };
        let send_req = ChatSendRequest {
            prompt: prompt.to_string(),
            project_path: project_path.clone(),
            conversation_id: conv_id.to_string(),
            agent_name: "Coordinator".to_string(),
            model: req.model.clone(),
            images: Vec::new(),
            remote_project: None,
        };

        let result = chat::start_chat_turn(state.clone(), send_req).await;
        state.broadcast_session_update(conv_id);
        state.emit_session_files_to_room(conv_id);

        (
            StatusCode::OK,
            Json(json!({
                "ok": true,
                "action": action_label,
                "message": message,
                "chatResult": result
            })),
        )
    } else {
        let feedback_msg = if req.feedback.trim().is_empty() {
            format!(
                "Tôi chưa duyệt kế hoạch [{}]. Vui lòng tạm dừng hoặc điều chỉnh thêm.",
                req.file_name
            )
        } else {
            format!(
                "Tôi yêu cầu điều chỉnh kế hoạch [{}]: {}",
                req.file_name,
                req.feedback.trim()
            )
        };

        let send_req = ChatSendRequest {
            prompt: feedback_msg,
            project_path: project_path.clone(),
            conversation_id: conv_id.to_string(),
            agent_name: "Coordinator".to_string(),
            model: req.model.clone(),
            images: Vec::new(),
            remote_project: None,
        };

        let result = chat::start_chat_turn(state.clone(), send_req).await;
        state.broadcast_session_update(conv_id);
        state.emit_session_files_to_room(conv_id);

        (
            StatusCode::OK,
            Json(json!({
                "ok": true,
                "action": "rejected",
                "message": "Đã gửi phản hồi yêu cầu điều chỉnh kế hoạch.",
                "chatResult": result
            })),
        )
    }
}
