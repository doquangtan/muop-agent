//! Thông tin tài khoản agy (email, gói, quota) lưu vào DB, watcher nền cập nhật định kỳ.
//!
//! Nguồn: trước hết là token OAuth trong thư mục dữ liệu agy + API quota của Google (`oauth.rs`, không cần
//! hub). Không có file token (ví dụ Linux, token trong keyring) thì hỏi hub do server tự khởi động
//! (`GetUserStatus`, `RetrieveUserQuotaSummary`). Client chỉ đọc DB, không hỏi hub hay API.
//! Đăng xuất: xóa dữ liệu trong DB và dừng hub. Đăng nhập lại: watcher lấy thông tin của tài khoản mới.

mod oauth;

use crate::agy_auth::tui::{self, Session};
use crate::chat::context_window::rpc_post;
use crate::infra::store;
use crate::models::ModelQuotaGroup;
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
/// Sau lỗi thì chờ trước khi thử lại (ngắn để màn Tài khoản có dữ liệu sớm sau khi đăng nhập)
const RETRY_AFTER: Duration = Duration::from_secs(15);
/// Thời gian tối đa chờ hub trả lời sau khi khởi động
const HUB_READY_TIMEOUT: Duration = Duration::from_secs(60);
const USER_STATUS: &str = "/exa.language_server_pb.LanguageServerService/GetUserStatus";

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

/// Gọi khi trạng thái đăng nhập agy đổi. Dừng hub cũ, và khi đăng nhập thì watcher lấy thông tin của tài khoản
/// mới ở lượt kế tiếp. KHÔNG xóa DB khi báo chưa đăng nhập: trạng thái tạm thời lúc khởi động (agy chưa sẵn sàng)
/// từng làm mất email và gói đã lưu. Xóa thông tin chỉ khi đăng xuất thành công (`clear_on_logout`).
pub fn on_login_changed(logged_in: bool) {
    stop_hub();
    if logged_in {
        FORCE.store(true, Ordering::SeqCst);
    }
}

/// Xóa thông tin tài khoản đã lưu sau khi đăng xuất thành công
pub fn clear_on_logout() {
    store::clear_agy_account();
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
                // Thử lại sau RETRY_AFTER (không đặt lại FORCE: nếu không sẽ thử lại mỗi nhịp và khởi động hub liên tục)
                eprintln!("agy_account: lấy thông tin tài khoản thất bại: {e}");
            }
        }
    }
}

/// Hub duy nhất của server (mở nếu chưa có). Mọi lời gọi RPC tới agy (tài khoản, quota, context, đăng xuất)
/// đều đi qua hub này, không mở thêm hub khác. `None` khi chưa đăng nhập hoặc hub không lên.
pub fn hub_endpoint() -> Option<(u16, String)> {
    if !crate::agy_auth::current().logged_in {
        return None;
    }
    ensure_hub().ok()
}

/// Lấy tài khoản và quota ngay (không chờ watcher), ghi DB. Dùng khi client cần quota mà DB chưa có.
pub fn refresh_now() -> Result<(), String> {
    refresh()
}

/// Yêu cầu watcher lấy lại thông tin tài khoản ở nhịp kế tiếp (khi màn Tài khoản thấy DB chưa có dữ liệu)
pub fn request_refresh() {
    FORCE.store(true, Ordering::SeqCst);
}

/// Lấy email, gói và quota rồi ghi DB. Email và gói lưu ngay (nhanh); quota lưu sau khi lấy được.
/// - gói: ACP `authenticate` (native);
/// - email: file token (macOS, qua SSH) hoặc log của CLI (Linux, token trong keyring);
/// - quota: API bằng token file, không có thì hub (chậm, có thể lỗi; khi lỗi thì quota để trống).
fn refresh() -> Result<(), String> {
    let state = crate::agy_auth::acp::account_state()?;
    if !state.logged_in {
        return Err("agy chưa đăng nhập".into());
    }
    let (email, quota) = match oauth::account() {
        Ok((email, quota)) => (email, Some(quota)),
        Err(_) => (oauth::email_from_logs().unwrap_or_default(), None),
    };
    if email.is_empty() {
        return Err("Chưa đọc được email tài khoản".into());
    }
    if let Some(quota) = quota {
        return save_account(&email, &state.tier, &quota);
    }
    // Email và gói có trước; quota chưa có (lần sau hoặc khi hub lên)
    save_account(&email, &state.tier, &[])?;
    let quota = hub_quota()?;
    save_account(&email, &state.tier, &quota)
}

fn save_account(email: &str, plan: &str, quota: &[ModelQuotaGroup]) -> Result<(), String> {
    let quota_json = serde_json::to_string(quota).unwrap_or_else(|_| "[]".to_string());
    if store::save_agy_account(email, plan, &quota_json) {
        Ok(())
    } else {
        Err("Không ghi được thông tin tài khoản vào DB".into())
    }
}

/// Quota từ hub do server mở (dùng khi không có token file)
fn hub_quota() -> Result<Vec<ModelQuotaGroup>, String> {
    let (port, token) = ensure_hub()?;
    crate::scanner::call_retrieve_user_quota_summary(port, &token)
        .ok_or_else(|| "Hub chưa trả quota".to_string())
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
    // AGY_ENABLE_HUB=1: chế độ hub cho phép xác thực tương tác (logout qua hub cũ, nay còn cho quota/context). Thiếu biến này RPC báo
    // failed_precondition ("unavailable in cli, standalone, or stubby-auth modes").
    let session = tui::spawn_agy(
        &[
            "--hub",
            &format!("--hub-port={port}"),
            crate::chat::AGY_APP_DATA_ARG,
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
