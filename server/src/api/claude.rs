use crate::chat;
use crate::chat::AppState;
use axum::{
    extract::{Query, State},
    http::StatusCode,
    response::IntoResponse,
    Json,
};
use chrono::Utc;
use serde_json::json;
use std::collections::HashMap;

/// Tương tác đang chờ (câu hỏi hoặc kế hoạch) của một phiên Claude Code; `pending` = null nếu không có
pub async fn handle_claude_pending(
    State(state): State<AppState>,
    Query(params): Query<HashMap<String, String>>,
) -> impl IntoResponse {
    let cid = params
        .get("id")
        .or_else(|| params.get("conversationId"))
        .map(|s| s.trim().to_string())
        .unwrap_or_default();
    if cid.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({ "ok": false, "error": "Thiếu id phiên hội thoại (id / conversationId)" })),
        )
            .into_response();
    }
    let running = state
        .active_streams
        .lock()
        .map(|s| s.get(&cid).map(|x| x.is_running).unwrap_or(false))
        .unwrap_or(false);
    let lookup = cid.clone();
    let pending = if running {
        None
    } else {
        tokio::task::spawn_blocking(move || crate::claude::questions::pending_for_session(&lookup))
            .await
            .ok()
            .flatten()
    };
    (
        StatusCode::OK,
        Json(json!({ "ok": true, "conversationId": cid, "pending": pending })),
    )
        .into_response()
}

/// Phản hồi tương tác đang chờ (trả lời câu hỏi / duyệt hoặc góp ý kế hoạch) bằng một lượt chat mới (`--resume`)
pub async fn handle_claude_respond(
    State(state): State<AppState>,
    Json(req): Json<crate::claude::questions::ClaudeInteractionResponse>,
) -> impl IntoResponse {
    let cid = req.conversation_id.trim().to_string();
    if cid.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({ "ok": false, "error": "Thiếu conversationId" })),
        )
            .into_response();
    }
    let lookup = cid.clone();
    let pending =
        tokio::task::spawn_blocking(move || crate::claude::questions::pending_for_session(&lookup))
            .await
            .ok()
            .flatten();
    let Some(pending) = pending.filter(|p| p.tool_use_id == req.tool_use_id) else {
        return (
            StatusCode::CONFLICT,
            Json(json!({ "ok": false, "error": "Tương tác này không còn chờ phản hồi" })),
        )
            .into_response();
    };
    let running = state
        .active_streams
        .lock()
        .map(|s| s.get(&cid).map(|x| x.is_running).unwrap_or(false))
        .unwrap_or(false);
    if running {
        return (
            StatusCode::CONFLICT,
            Json(
                json!({ "ok": false, "error": "Phiên đang chạy, hãy chờ lượt hiện tại kết thúc" }),
            ),
        )
            .into_response();
    }
    let prompt = match crate::claude::questions::build_response_prompt(&pending, &req) {
        Ok(prompt) => prompt,
        Err(message) => {
            return (
                StatusCode::BAD_REQUEST,
                Json(json!({ "ok": false, "error": message })),
            )
                .into_response();
        }
    };
    let result = chat::start_chat_turn(
        state.clone(),
        crate::models::ChatSendRequest {
            prompt,
            project_path: req.project_path,
            conversation_id: cid,
            agent_name: String::new(),
            model: req.model,
            images: Vec::new(),
            remote_project: None,
        },
    )
    .await;
    state.broadcast_session_update(&result.conversation_id);
    state.emit_session_files_to_room(&result.conversation_id);
    let status = if result.ok {
        StatusCode::OK
    } else {
        StatusCode::BAD_REQUEST
    };
    (status, Json(result)).into_response()
}

pub async fn handle_ai_questions(
    Query(params): Query<HashMap<String, String>>,
    State(state): State<AppState>,
) -> impl IntoResponse {
    let conversation_id = match params
        .get("conversationId")
        .map(|s| s.trim())
        .filter(|s| !s.is_empty())
    {
        Some(id) => id.to_string(),
        None => {
            return (
                StatusCode::BAD_REQUEST,
                Json(json!({ "ok": false, "error": "Thiếu conversationId" })),
            )
                .into_response();
        }
    };

    let questions = state
        .ai_questions
        .lock()
        .map(|g| g.get(&conversation_id).cloned().unwrap_or_default())
        .unwrap_or_default();

    (
        StatusCode::OK,
        Json(json!({
            "ok": true,
            "conversationId": conversation_id,
            "questions": questions
        })),
    )
        .into_response()
}

pub async fn handle_ai_question_answer(
    State(state): State<AppState>,
    body: axum::body::Body,
) -> impl IntoResponse {
    use axum::body::to_bytes;

    let bytes = match to_bytes(body, usize::MAX).await {
        Ok(b) => b,
        Err(_) => {
            return (
                StatusCode::BAD_REQUEST,
                Json(json!({ "ok": false, "error": "Không thể đọc body" })),
            )
                .into_response();
        }
    };

    let req: serde_json::Result<crate::models::AIQuestionResponse> = serde_json::from_slice(&bytes);
    let req = match req {
        Ok(r) => r,
        Err(_) => {
            return (
                StatusCode::BAD_REQUEST,
                Json(json!({ "ok": false, "error": "JSON không hợp lệ" })),
            )
                .into_response();
        }
    };

    let question_id = req.question_id.clone();
    let answer = req.answer.clone();

    // Cập nhật câu hỏi với câu trả lời
    if let Ok(mut questions_map) = state.ai_questions.lock() {
        for (_conv_id, questions) in questions_map.iter_mut() {
            for question in questions.iter_mut() {
                if question.id == question_id {
                    question.answer = Some(answer.clone());
                    question.answered_at = Some(Utc::now().to_rfc3339());
                    question.is_pending = false;

                    // Phát event socket để cập nhật UI
                    if let Ok(val) = serde_json::to_value(question) {
                        if let Some(ns) = state.io.of("/") {
                            let _ = ns.emit("ai-question:answered", &val);
                        }
                    }
                    break;
                }
            }
        }
    }

    (
        StatusCode::OK,
        Json(json!({
            "ok": true,
            "questionId": question_id,
            "answer": answer
        })),
    )
        .into_response()
}
