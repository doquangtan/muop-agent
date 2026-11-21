use crate::claude_auth::{self, AuthView};
use crate::models::{ClaudeAuthResponse, ClaudeLoginSubmitRequest};
use axum::Json;

/// Lỗi nghiệp vụ trả HTTP 200 với `ok: false` để client hiển thị
fn to_response(res: Result<AuthView, String>) -> Json<ClaudeAuthResponse> {
    Json(match res {
        Ok(view) => ClaudeAuthResponse {
            ok: true,
            logged_in: view.logged_in,
            email: view.email,
            subscription_type: view.subscription_type,
            login_url: view.login_url,
            error: String::new(),
        },
        Err(error) => {
            let status = claude_auth::status().unwrap_or_default();
            ClaudeAuthResponse {
                ok: false,
                logged_in: status.logged_in,
                email: status.email,
                subscription_type: status.subscription_type,
                login_url: claude_auth::pending_url().unwrap_or_default(),
                error,
            }
        }
    })
}

async fn blocking<T, F>(job: F) -> Result<T, String>
where
    F: FnOnce() -> Result<T, String> + Send + 'static,
    T: Send + 'static,
{
    tokio::task::spawn_blocking(job)
        .await
        .unwrap_or_else(|e| Err(format!("Lỗi nội bộ: {e}")))
}

/// Trạng thái đăng nhập claude và link đang chờ (nếu có)
pub async fn handle_claude_auth_status() -> Json<ClaudeAuthResponse> {
    to_response(blocking(claude_auth::status).await)
}

/// Đăng xuất claude (`claude auth logout`)
pub async fn handle_claude_auth_logout() -> Json<ClaudeAuthResponse> {
    to_response(blocking(claude_auth::logout).await)
}

/// Bắt đầu đăng nhập: trả về link Anthropic OAuth để người dùng mở trong trình duyệt
pub async fn handle_claude_login_start() -> Json<ClaudeAuthResponse> {
    to_response(blocking(claude_auth::begin_login).await)
}

/// Gửi mã xác thực người dùng dán vào (hoặc URL trang callback). Trả về ngay, kết quả đi qua socket.
pub async fn handle_claude_login_submit(
    Json(req): Json<ClaudeLoginSubmitRequest>,
) -> Json<ClaudeAuthResponse> {
    let res = blocking(move || {
        claude_auth::submit_code(&req.code)?;
        Ok(AuthView {
            logged_in: false,
            email: String::new(),
            subscription_type: String::new(),
            login_url: String::new(),
        })
    })
    .await;
    to_response(res)
}

/// Hủy phiên đăng nhập đang chờ
pub async fn handle_claude_login_cancel() -> Json<ClaudeAuthResponse> {
    let res = blocking(|| {
        claude_auth::login_cancel();
        claude_auth::status()
    })
    .await;
    to_response(res)
}
