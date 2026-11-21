use crate::setup::{self, ssh, InstallRequest, SelectRequest};
use axum::{http::StatusCode, response::IntoResponse, Json};

/// Đổi user SSH của máy này (REST, tương đương `setup:ssh:configure`)
pub async fn handle_setup_ssh_configure(
    Json(req): Json<ssh::SshConfigureRequest>,
) -> impl IntoResponse {
    match ssh::configure(&req.username) {
        Ok(()) => (StatusCode::OK, Json(setup::status(true, ""))),
        Err(e) => (StatusCode::BAD_REQUEST, Json(setup::status(false, e))),
    }
}

/// Tự thiết lập khóa SSH và thử đăng nhập (REST, tương đương `setup:ssh:auto`)
pub async fn handle_setup_ssh_auto() -> impl IntoResponse {
    let res = match tokio::task::spawn_blocking(ssh::auto_setup).await {
        Ok(Ok(())) => setup::status(true, ""),
        Ok(Err(e)) => setup::status(false, e),
        Err(e) => setup::status(false, e.to_string()),
    };
    let code = if res.ok {
        StatusCode::OK
    } else {
        StatusCode::BAD_REQUEST
    };
    (code, Json(res))
}

/// Xác nhận dòng public key người dùng đã publish (REST, tương đương `setup:ssh:verify`)
pub async fn handle_setup_ssh_verify(Json(req): Json<ssh::SshVerifyRequest>) -> impl IntoResponse {
    let res = match tokio::task::spawn_blocking(move || ssh::verify_pasted(&req.public_key)).await {
        Ok(Ok(())) => setup::status(true, ""),
        Ok(Err(e)) => setup::status(false, e),
        Err(e) => setup::status(false, e.to_string()),
    };
    let code = if res.ok {
        StatusCode::OK
    } else {
        StatusCode::BAD_REQUEST
    };
    (code, Json(res))
}

/// Trạng thái khởi tạo và tool (REST, tương đương `setup:status`)
pub async fn handle_setup_status() -> impl IntoResponse {
    Json(setup::status(true, ""))
}

/// Bắt đầu cài một CLI (REST, tương đương `setup:install`)
pub async fn handle_setup_install(Json(req): Json<InstallRequest>) -> impl IntoResponse {
    let res = match setup::install::start(req.tool.trim()) {
        Ok(()) => setup::status(true, ""),
        Err(e) => setup::status(false, e),
    };
    let code = if res.ok {
        StatusCode::OK
    } else {
        StatusCode::BAD_REQUEST
    };
    (code, Json(res))
}

/// Lưu CLI đã chọn (REST, tương đương `setup:select`)
pub async fn handle_setup_select(Json(req): Json<SelectRequest>) -> impl IntoResponse {
    match setup::select_clis(&req.clis) {
        Ok(s) => (StatusCode::OK, Json(s)),
        Err(e) => (StatusCode::BAD_REQUEST, Json(setup::status(false, e))),
    }
}

/// Đánh dấu đã khởi tạo xong (REST, tương đương `setup:complete`)
pub async fn handle_setup_complete() -> impl IntoResponse {
    match setup::complete() {
        Ok(s) => (StatusCode::OK, Json(s)),
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(setup::status(false, e)),
        ),
    }
}
