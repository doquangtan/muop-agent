//! Thông tin tài khoản agy (email, gói, quota) lấy từ hub do server tự khởi động, lưu vào DB.
//!
//! Watcher chạy nền khi agy đã đăng nhập: khởi động hub (`agy --hub`) rồi hỏi `GetUserStatus` và
//! `RetrieveUserQuotaSummary`, ghi vào bảng `agy_account`. Client chỉ đọc DB, không hỏi hub.
//! Đăng xuất: xóa dữ liệu trong DB và dừng hub. Đăng nhập lại: watcher lấy thông tin của tài khoản mới.

use crate::agy_auth::tui::{self, Session};
use crate::chat::context_window::rpc_post;
use crate::infra::store;
use crate::models::ModelQuotaGroup;
use serde_json::Value;
use std::io::Read;
use std::net::TcpListener;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, MutexGuard};
use std::thread;
use std::time::{Duration, Instant};

/// Chu kỳ kiểm tra của watcher
const TICK: Duration = Duration::from_secs(5);
/// Lấy lại thông tin sau khoảng này (khi vẫn đăng nhập)
const REFRESH_EVERY: Duration = Duration::from_secs(300);
/// Sau lỗi thì chờ trước khi thử lại
const RETRY_AFTER: Duration = Duration::from_secs(60);
/// Thời gian tối đa chờ hub trả lời sau khi khởi động
const HUB_READY_TIMEOUT: Duration = Duration::from_secs(60);
const USER_STATUS: &str = "/exa.language_server_pb.LanguageServerService/GetUserStatus";
const AUTH_LOGOUT: &str = "/exa.language_server_pb.LanguageServerService/AuthLogout";

/// Hub do server khởi động: phiên PTY đang chạy agy `--hub`, cổng và token CSRF
struct OwnedHub {
    session: Session,
    port: u16,
    token: String,
}

static HUB: Mutex<Option<OwnedHub>> = Mutex::new(None);
/// Yêu cầu lấy lại thông tin ngay (sau khi đăng nhập, hoặc khi server vừa khởi động)
static FORCE: AtomicBool = AtomicBool::new(true);

/// Thông tin tài khoản đã lưu
pub struct AccountSnapshot {
    pub email: String,
    pub plan: String,
    pub quota: Vec<ModelQuotaGroup>,
}

fn hub_slot() -> MutexGuard<'static, Option<OwnedHub>> {
    HUB.lock().unwrap_or_else(|e| e.into_inner())
}

/// Thông tin tài khoản từ DB (không hỏi hub)
pub fn snapshot() -> Option<AccountSnapshot> {
    let row = store::load_agy_account()?;
    let quota = serde_json::from_str(&row.quota_json).unwrap_or_default();
    Some(AccountSnapshot {
        email: row.email,
        plan: row.plan,
        quota,
    })
}

/// Khởi động watcher nền. Gọi một lần khi khởi tạo socket.
pub fn start() {
    thread::spawn(watch);
}

/// Gọi khi trạng thái đăng nhập agy đổi. Dừng hub cũ (giữ token của tài khoản trước), và:
/// - đăng xuất: xóa thông tin trong DB;
/// - đăng nhập: watcher lấy thông tin của tài khoản mới ở lượt kế tiếp.
pub fn on_login_changed(logged_in: bool) {
    stop_hub();
    if logged_in {
        FORCE.store(true, Ordering::SeqCst);
    } else {
        store::clear_agy_account();
    }
}

fn watch() {
    let mut last_ok: Option<Instant> = None;
    let mut last_try: Option<Instant> = None;
    loop {
        thread::sleep(TICK);
        if !crate::agy_auth::current().logged_in {
            continue;
        }
        let forced = FORCE.swap(false, Ordering::SeqCst);
        let fresh = last_ok.is_some_and(|t| t.elapsed() < REFRESH_EVERY);
        let retry_ok = last_try.is_none_or(|t| t.elapsed() >= RETRY_AFTER);
        if !(forced || (!fresh && retry_ok)) {
            continue;
        }
        last_try = Some(Instant::now());
        match refresh() {
            Ok(()) => {
                last_ok = Some(Instant::now());
                // Client tải lại email/gói và quota của tài khoản mới
                crate::agy_auth::republish_logged_in();
                crate::agy_auth::push_quotas();
            }
            Err(e) => {
                eprintln!("agy_account: lấy thông tin tài khoản thất bại: {e}");
                // Lỗi mà còn yêu cầu bắt buộc thì giữ yêu cầu để thử lại sau RETRY_AFTER
                if forced {
                    FORCE.store(true, Ordering::SeqCst);
                }
            }
        }
    }
}

/// Đăng xuất agy qua RPC `AuthLogout` của hub do server mở (không dùng TUI). Chỉ gửi lệnh: việc agy đã xóa token
/// được kiểm tra ở `agy_auth::logout` bằng `agy models`. Lỗi của hub (dạng `code`/`message`) được trả về nguyên văn.
pub fn logout_via_hub() -> Result<(), String> {
    let (port, token) = ensure_hub()?;
    let value = rpc_post(port, &token, AUTH_LOGOUT, "{}")
        .map_err(|_| "Không gọi được hub để đăng xuất".to_string())?;
    if value.get("code").is_some() {
        let message = value
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or("hub từ chối đăng xuất");
        return Err(message.to_string());
    }
    Ok(())
}

/// Lấy email, gói và quota từ hub rồi ghi vào DB
fn refresh() -> Result<(), String> {
    let (port, token) = ensure_hub()?;
    let value = rpc_post(port, &token, USER_STATUS, "{}")
        .map_err(|_| "Không đọc được tài khoản từ hub".to_string())?;
    let status = value
        .get("userStatus")
        .ok_or("Hub chưa có thông tin tài khoản")?;
    let email = status
        .get("email")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    if email.is_empty() {
        return Err("Hub chưa có email tài khoản".into());
    }
    let plan = status
        .pointer("/planStatus/planInfo/planName")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    let quota = crate::scanner::call_retrieve_user_quota_summary(port, &token).unwrap_or_default();
    let quota_json = serde_json::to_string(&quota).unwrap_or_else(|_| "[]".to_string());
    if store::save_agy_account(&email, &plan, &quota_json) {
        Ok(())
    } else {
        Err("Không ghi được thông tin tài khoản vào DB".into())
    }
}

/// Hub đang sống thì dùng lại; không thì khởi động hub mới và chờ nó trả lời
fn ensure_hub() -> Result<(u16, String), String> {
    {
        let mut slot = hub_slot();
        if let Some(hub) = slot.as_ref() {
            if tui::session_alive(&hub.session) {
                return Ok((hub.port, hub.token.clone()));
            }
        }
        if let Some(dead) = slot.take() {
            tui::close_session(dead.session);
        }
    }
    let port = free_port()?;
    let token = random_token()?;
    // AGY_ENABLE_HUB=1: chế độ hub cho phép xác thực tương tác (AuthLogout). Thiếu biến này RPC báo
    // failed_precondition ("unavailable in cli, standalone, or stubby-auth modes").
    let session = tui::spawn_agy(
        &[
            "--hub",
            &format!("--hub-port={port}"),
            "--app_data_dir=antigravity",
            &format!("--csrf_token={token}"),
        ],
        &[("AGY_ENABLE_HUB", "1")],
    )?;
    *hub_slot() = Some(OwnedHub {
        session,
        port,
        token: token.clone(),
    });
    // Chờ ngoài khóa: dừng hub từ luồng khác không bị treo trong lúc chờ
    let deadline = Instant::now() + HUB_READY_TIMEOUT;
    loop {
        if rpc_post(port, &token, USER_STATUS, "{}").is_ok() {
            return Ok((port, token));
        }
        if Instant::now() >= deadline {
            stop_hub();
            return Err("Hub agy không sẵn sàng".into());
        }
        thread::sleep(Duration::from_secs(1));
    }
}

/// Dừng hub do server khởi động (nếu có)
fn stop_hub() {
    if let Some(hub) = hub_slot().take() {
        tui::close_session(hub.session);
    }
}

/// Cổng TCP trống trên loopback (hub nghe trên đó)
fn free_port() -> Result<u16, String> {
    let listener =
        TcpListener::bind("127.0.0.1:0").map_err(|e| format!("Không chọn được cổng: {e}"))?;
    let port = listener
        .local_addr()
        .map_err(|e| format!("Không đọc được cổng: {e}"))?
        .port();
    Ok(port)
}

/// Token CSRF ngẫu nhiên (hex) cho RPC của hub
fn random_token() -> Result<String, String> {
    let mut bytes = [0u8; 16];
    std::fs::File::open("/dev/urandom")
        .and_then(|mut f| f.read_exact(&mut bytes))
        .map_err(|e| format!("Không đọc được bộ sinh số ngẫu nhiên: {e}"))?;
    Ok(bytes.iter().map(|b| format!("{b:02x}")).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn token_is_32_hex_chars() {
        let token = random_token().expect("đọc /dev/urandom");
        assert_eq!(token.len(), 32);
        assert!(token.chars().all(|c| c.is_ascii_hexdigit()));
        assert_ne!(token, random_token().unwrap());
    }

    #[test]
    fn free_port_is_a_real_port() {
        assert!(free_port().expect("chọn cổng") > 0);
    }
}
