use crate::models::*;
use axum::{http::StatusCode, response::IntoResponse, Json};
use serde_json::json;

/// Danh sách phiên Docker đang chạy (REST, dùng để đồng bộ giữa các app)
pub async fn handle_docker_sessions_list() -> impl IntoResponse {
    Json(crate::docker::sessions::list())
}

pub fn docker_response(
    status: StatusCode,
    result: Result<crate::models::DockerSessionDto, String>,
) -> (StatusCode, Json<DockerSessionResponse>) {
    match result {
        Ok(session) => {
            let ok = session.error.is_empty();
            (
                status,
                Json(DockerSessionResponse {
                    ok,
                    error: session.error.clone(),
                    session: Some(session),
                }),
            )
        }
        Err(e) => (
            StatusCode::BAD_REQUEST,
            Json(DockerSessionResponse {
                ok: false,
                error: e,
                session: None,
            }),
        ),
    }
}

/// Mở phiên Docker cho một máy SSH đã lưu (gắn vào phiên đang chạy nếu có)
pub async fn handle_docker_session_open(Json(req): Json<DockerOpenRequest>) -> impl IntoResponse {
    let Some(row) = crate::infra::store::get_ssh_host(req.host_id) else {
        return docker_response(
            StatusCode::NOT_FOUND,
            Err("Không tìm thấy máy SSH".to_string()),
        );
    };
    docker_response(StatusCode::OK, crate::docker::sessions::open(row).await)
}

/// Quét lại container đang chạy của phiên
pub async fn handle_docker_session_scan(
    Json(req): Json<DockerSessionIdRequest>,
) -> impl IntoResponse {
    match crate::docker::sessions::scan_session(&req.session_id).await {
        Some(session) => docker_response(StatusCode::OK, Ok(session)),
        None => docker_response(
            StatusCode::NOT_FOUND,
            Err("Phiên Docker đã kết thúc".to_string()),
        ),
    }
}

/// Dừng hoặc khởi động lại container (hoặc cả compose project) trong phiên
pub async fn handle_docker_session_action(
    Json(req): Json<DockerActionRequest>,
) -> impl IntoResponse {
    let res =
        crate::docker::sessions::run_action(&req.session_id, &req.action, &req.container_ids).await;
    let status = if res.is_ok() {
        StatusCode::OK
    } else {
        StatusCode::BAD_REQUEST
    };
    docker_response(status, res)
}

/// Kết thúc phiên Docker (lần mở sau sẽ kết nối lại)
pub async fn handle_docker_session_close(
    Json(req): Json<DockerSessionIdRequest>,
) -> impl IntoResponse {
    let ok = crate::docker::sessions::close(&req.session_id).await;
    (
        if ok {
            StatusCode::OK
        } else {
            StatusCode::NOT_FOUND
        },
        Json(json!({"ok": ok})),
    )
}
