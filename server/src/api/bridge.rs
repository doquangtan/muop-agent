//! REST của bridge trên máy B: cấu hình máy A và chuyển lệnh sang A.

use axum::{extract::Query, http::StatusCode, response::IntoResponse, Json};
use serde::Deserialize;
use serde_json::{json, Value};

use crate::bridge;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PendingQuery {
    pub conversation_id: Option<String>,
}

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

/// Đặt địa chỉ máy A và kết nối lại. Khi thêm máy phụ, máy này đăng ký với máy phụ (kiểm tra FUSE và
/// kết nối tới máy này). `registered` / `registerError` báo kết quả đăng ký; không mount gì ở bước này.
pub async fn handle_set_peer(Json(req): Json<PeerRequest>) -> impl IntoResponse {
    match bridge::set_peer(&req.url) {
        Ok(status) => {
            let mut body = json!(status);
            let url = status.url.clone();
            if url.is_empty() {
                body["registered"] = json!(false);
                body["registerError"] = json!("");
            } else {
                match bridge::register_on_peer(&url).await {
                    Ok(_) => {
                        body["registered"] = json!(true);
                        body["registerError"] = json!("");
                    }
                    Err(e) => {
                        body["registered"] = json!(false);
                        body["registerError"] = json!(e);
                    }
                }
            }
            (StatusCode::OK, Json(body))
        }
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

/// Tương tác Claude đang chờ phản hồi trên máy A (proxy `GET /api/claude/pending?id=`).
/// Query: `conversationId`. Chỉ nhận id gồm chữ, số, `-`, `_` để không ghép chuỗi lạ vào URL.
pub async fn handle_pending(Query(query): Query<PendingQuery>) -> impl IntoResponse {
    let cid = query.conversation_id.unwrap_or_default();
    if !is_safe_conversation_id(&cid) {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({ "ok": false, "error": "conversationId không hợp lệ" })),
        );
    }
    match bridge::get_peer(&format!("/api/claude/pending?id={cid}")).await {
        Ok(body) => (StatusCode::OK, Json(body)),
        Err(e) => (
            StatusCode::BAD_GATEWAY,
            Json(json!({ "ok": false, "error": e })),
        ),
    }
}

/// Model và tên máy của máy A (proxy `GET /api/meta`). Dùng để thêm model máy A vào màn chat.
pub async fn handle_peer_meta() -> impl IntoResponse {
    peer_get("/api/meta").await
}

/// Danh sách conversation máy phụ đã chạy cho project của máy này (proxy `GET /api/sessions` của máy phụ).
/// Mỗi conversation được chuyển về đúng project (xem `bridge::map_peer_session`); conversation khác bị bỏ.
pub async fn handle_peer_sessions() -> impl IntoResponse {
    match bridge::get_peer("/api/sessions").await {
        Ok(mut body) => {
            let projects = bridge::local_projects();
            if let Some(list) = body.get_mut("sessions").and_then(Value::as_array_mut) {
                let mapped: Vec<Value> = list
                    .iter()
                    .filter_map(|s| bridge::map_peer_session_in(s, &projects))
                    .collect();
                *list = mapped;
            }
            (StatusCode::OK, Json(body))
        }
        Err(e) => (
            StatusCode::BAD_GATEWAY,
            Json(json!({ "ok": false, "error": e })),
        ),
    }
}

#[derive(Deserialize)]
pub struct PeerSessionQuery {
    pub id: Option<String>,
}

/// Chi tiết một conversation của máy phụ (proxy `GET /api/session?id=`), đã chuyển về project của máy này nếu thuộc về nó.
/// Id kiểm tra như `pending`.
pub async fn handle_peer_session(Query(query): Query<PeerSessionQuery>) -> impl IntoResponse {
    let id = query.id.unwrap_or_default();
    if !is_safe_conversation_id(&id) {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({ "ok": false, "error": "id không hợp lệ" })),
        );
    }
    match bridge::get_peer(&format!("/api/session?id={id}")).await {
        Ok(body) => {
            let mapped = bridge::map_peer_session(&body);
            (StatusCode::OK, Json(mapped.unwrap_or(body)))
        }
        Err(e) => (
            StatusCode::BAD_GATEWAY,
            Json(json!({ "ok": false, "error": e })),
        ),
    }
}

async fn peer_get(path: &str) -> (StatusCode, Json<Value>) {
    match bridge::get_peer(path).await {
        Ok(body) => (StatusCode::OK, Json(body)),
        Err(e) => (
            StatusCode::BAD_GATEWAY,
            Json(json!({ "ok": false, "error": e })),
        ),
    }
}

fn is_safe_conversation_id(cid: &str) -> bool {
    !cid.is_empty()
        && cid.len() <= 128
        && cid
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
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

#[cfg(test)]
mod tests {
    use super::is_safe_conversation_id;

    #[test]
    fn accepts_uuid_like_ids_only() {
        assert!(is_safe_conversation_id(
            "0e4665a9-0f56-4e36-ae19-d8165d0aee88"
        ));
        assert!(is_safe_conversation_id("fake_recovery-cid"));
        assert!(!is_safe_conversation_id(""));
        assert!(!is_safe_conversation_id("a&b=c"));
        assert!(!is_safe_conversation_id("x/../../etc"));
        assert!(!is_safe_conversation_id(&"a".repeat(129)));
    }
}
