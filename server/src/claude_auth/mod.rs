//! Đăng nhập / đăng xuất tài khoản Claude Code CLI (`claude`).
//!
//! - Đăng nhập: Chạy `claude auth login` trong PTY, trích xuất link OAuth, chờ người dùng gửi mã xác thực.
//! - Đăng xuất: Chạy `claude auth logout`, kiểm tra `claude auth status`.
//! - Trạng thái được giữ trong [`CURRENT`] và đẩy cho client qua Socket.IO `claude:auth:update`
//!   mỗi khi thay đổi. Client không cần hỏi lại theo chu kỳ.

mod login;
pub mod socket;

pub use login::{
    cancel as login_cancel, cli_auth_status, pending_url, start as login_start,
    submit as login_submit,
};

use crate::models::ClaudeAuthEvent;
use socketioxide::SocketIo;
use std::sync::{Mutex, OnceLock};

/// Socket.IO để phát `claude:auth:update`. Gắn một lần khi khởi tạo socket.
static IO: OnceLock<SocketIo> = OnceLock::new();
/// Trạng thái gần nhất, client kết nối sau vẫn nhận được ngay
static CURRENT: Mutex<Option<ClaudeAuthEvent>> = Mutex::new(None);

/// Trạng thái đăng nhập và phiên đăng nhập đang chờ (nếu có)
#[derive(Debug, Clone, Default)]
pub struct AuthView {
    pub logged_in: bool,
    pub email: String,
    pub subscription_type: String,
    pub login_url: String,
}

/// Gắn Socket.IO để phát event. Gọi một lần khi khởi tạo socket.
pub fn init(io: SocketIo) {
    let _ = IO.set(io);
}

/// Trạng thái gần nhất đã biết (idle nếu chưa có gì xảy ra)
pub fn current() -> ClaudeAuthEvent {
    let stored = CURRENT.lock().ok().and_then(|g| g.clone());
    stored.unwrap_or_else(|| make("idle", false, "", "", "", ""))
}

fn make(
    phase: &str,
    logged_in: bool,
    email: &str,
    subscription_type: &str,
    login_url: &str,
    error: &str,
) -> ClaudeAuthEvent {
    ClaudeAuthEvent {
        ok: !matches!(phase, "failed" | "expired"),
        phase: phase.to_string(),
        logged_in,
        email: email.to_string(),
        subscription_type: subscription_type.to_string(),
        login_url: login_url.to_string(),
        error: error.to_string(),
    }
}

/// Ghi trạng thái gần nhất mà không phát event
fn store(ev: &ClaudeAuthEvent) {
    if let Ok(mut cur) = CURRENT.lock() {
        *cur = Some(ev.clone());
    }
}

/// Đổi trạng thái và phát `claude:auth:update` cho mọi client đang kết nối
pub(crate) fn publish(
    phase: &str,
    logged_in: bool,
    email: &str,
    subscription_type: &str,
    login_url: &str,
    error: &str,
) {
    let ev = make(phase, logged_in, email, subscription_type, login_url, error);
    store(&ev);
    if let Some(io) = IO.get() {
        if let Some(ns) = io.of("/") {
            let _ = ns.emit("claude:auth:update", &ev);
        }
    }
}

/// Trạng thái hiện tại: đã đăng nhập chưa, thông tin tài khoản và link đang chờ (nếu có)
pub fn status() -> Result<AuthView, String> {
    let info = login::cli_auth_status().unwrap_or_default();
    Ok(AuthView {
        logged_in: info.logged_in,
        email: info.email,
        subscription_type: info.subscription_type,
        login_url: pending_url().unwrap_or_default(),
    })
}

/// Trạng thái từ CLI, kết hợp với giai đoạn server đang giữ.
/// Dùng cho client hỏi bằng `claude:auth:status`.
pub fn query() -> ClaudeAuthEvent {
    let cur = current();
    let ev = match login::cli_auth_status() {
        Ok(info) if info.logged_in => make(
            "logged_in",
            true,
            &info.email,
            &info.subscription_type,
            "",
            "",
        ),
        Ok(_) if matches!(cur.phase.as_str(), "waiting_code" | "verifying") => cur,
        Ok(info) => make(
            "logged_out",
            false,
            &info.email,
            &info.subscription_type,
            "",
            "",
        ),
        Err(e) => make("failed", false, "", "", "", &e),
    };
    store(&ev);
    ev
}

/// Đăng xuất khỏi Claude CLI. Hủy phiên đăng nhập đang chờ (nếu có).
pub fn logout() -> Result<AuthView, String> {
    let res = logout_inner();
    match &res {
        Ok(_) => publish("logged_out", false, "", "", "", ""),
        Err(e) => {
            let info = login::cli_auth_status().unwrap_or_default();
            publish(
                "failed",
                info.logged_in,
                &info.email,
                &info.subscription_type,
                &pending_url().unwrap_or_default(),
                e,
            );
        }
    }
    res
}

fn logout_inner() -> Result<AuthView, String> {
    login_cancel();
    login::cli_logout()?;
    let info = login::cli_auth_status().unwrap_or_default();
    if info.logged_in {
        return Err("Claude CLI vẫn báo đang đăng nhập sau khi đăng xuất".to_string());
    }
    Ok(AuthView {
        logged_in: false,
        email: String::new(),
        subscription_type: String::new(),
        login_url: String::new(),
    })
}

/// Bắt đầu đăng nhập: trả về link Anthropic OAuth.
pub fn begin_login() -> Result<AuthView, String> {
    let res = begin_login_inner();
    match &res {
        Ok(view) => publish("waiting_code", false, "", "", &view.login_url, ""),
        Err(e) => {
            let info = login::cli_auth_status().unwrap_or_default();
            publish(
                "failed",
                info.logged_in,
                &info.email,
                &info.subscription_type,
                &pending_url().unwrap_or_default(),
                e,
            );
        }
    }
    res
}

fn begin_login_inner() -> Result<AuthView, String> {
    if let Ok(info) = login::cli_auth_status() {
        if info.logged_in {
            return Err(
                "Claude CLI đang đăng nhập. Hãy đăng xuất trước khi đăng nhập lại.".to_string(),
            );
        }
    }
    let login_url = login_start()?;
    Ok(AuthView {
        logged_in: false,
        email: String::new(),
        subscription_type: String::new(),
        login_url,
    })
}

/// Gửi mã xác thực. Trả về ngay; kết quả đi qua `claude:auth:update`.
pub fn submit_code(code: &str) -> Result<(), String> {
    login_submit(code).map_err(|e| {
        publish(
            "failed",
            false,
            "",
            "",
            &pending_url().unwrap_or_default(),
            &e,
        );
        e
    })
}
