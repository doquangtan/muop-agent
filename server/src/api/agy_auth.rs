use crate::agy_auth;
use crate::models::{AgyAuthEvent, AgyLoginSubmitRequest};
use axum::Json;

/// Chạy việc chặn luồng (curl, SSH, chờ) ngoài event loop của Axum, rồi trả trạng thái hiện tại.
/// Cùng quy ước với socket: lỗi nghiệp vụ nằm trong `phase` / `error`, HTTP vẫn 200.
async fn run<F: FnOnce() + Send + 'static>(job: F) -> Json<AgyAuthEvent> {
    let _ = tokio::task::spawn_blocking(job).await;
    Json(agy_auth::current())
}

/// Trạng thái đăng nhập agy (cùng logic với socket `agy:auth:status`)
pub async fn handle_agy_auth_status() -> Json<AgyAuthEvent> {
    let ev = match tokio::task::spawn_blocking(agy_auth::query).await {
        Ok(ev) => ev,
        Err(_) => agy_auth::current(),
    };
    Json(ev)
}

/// Kiểm tra agy đã đăng nhập chưa (cùng logic với socket `agy:auth:check`)
pub async fn handle_agy_auth_check() -> Json<AgyAuthEvent> {
    let ev = match tokio::task::spawn_blocking(agy_auth::check).await {
        Ok(ev) => ev,
        Err(_) => agy_auth::current(),
    };
    Json(ev)
}

/// Đăng xuất agy (ACP `logout`)
pub async fn handle_agy_auth_logout() -> Json<AgyAuthEvent> {
    run(|| {
        let _ = agy_auth::logout();
    })
    .await
}

/// Mở terminal SSH chạy `agy` để người dùng tự đăng nhập. Kết quả đến qua `agy:auth:update`.
pub async fn handle_agy_login_start() -> Json<AgyAuthEvent> {
    run(|| {
        let _ = agy_auth::begin_login();
    })
    .await
}

/// Gửi mã xác thực người dùng dán vào app vào terminal đăng nhập (lỗi nằm trong `error`)
pub async fn handle_agy_login_submit(Json(req): Json<AgyLoginSubmitRequest>) -> Json<AgyAuthEvent> {
    let ev = match tokio::task::spawn_blocking(move || agy_auth::submit_code(&req.code)).await {
        Ok(ev) => ev,
        Err(_) => agy_auth::current(),
    };
    Json(ev)
}

/// Hủy đăng nhập đang chờ (đóng terminal)
pub async fn handle_agy_login_cancel() -> Json<AgyAuthEvent> {
    run(agy_auth::cancel_login).await
}
