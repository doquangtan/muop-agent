//! Hỏi trạng thái agy khi không có IDE.
//!
//! Hub (language server nội bộ của CLI) chỉ tồn tại khi có một tiến trình agy đang chạy, và CLI xóa
//! `daemon/hub_<port>.json` khi thoát. Không có IDE thì không có tiến trình nào như vậy. Khi cần biết
//! trạng thái mà chưa có hub, server mở một TUI agy (cùng cách với luồng đăng nhập) và đọc màn hình:
//! TUI chưa đăng nhập in "You are currently not signed in". Nếu hub lên thì hỏi RPC như trước.
//!
//! Ba chế độ, theo ai đang hỏi:
//! - [`Need::User`]: thao tác người dùng bấm (trạng thái, đăng xuất): được mở host.
//! - [`Need::Background`]: quota: chỉ mở host khi người dùng vừa dùng màn tài khoản.
//!
//! Host bị tắt khi không còn thao tác người dùng, và khi đổi tài khoản (để lần sau đọc trạng thái mới).

use super::tui::{self, Session};
use crate::chat::context_window::discover_hub;
use std::sync::Mutex;
use std::time::{Duration, Instant};

/// Không có thao tác người dùng trong khoảng này thì tắt host
pub const HOST_IDLE: Duration = Duration::from_secs(30 * 60);
/// Thời gian tối đa chờ host cho ra hub hoặc màn hình trạng thái
/// Agy khởi động chậm trên máy yếu (đo được >20 giây trên laptop): chờ đủ lâu để host lên màn hình
const PROBE_WAIT: Duration = Duration::from_secs(40);
const POLL: Duration = Duration::from_millis(300);
/// Menu đăng nhập: chỉ hiện khi chưa đăng nhập (so sánh không phân biệt hoa thường)
const LOGIN_MENU_MARK: &str = "select login method";

/// Ai đang hỏi trạng thái, quyết định có được mở host hay không
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Need {
    User,
    Background,
}

/// Kết quả hỏi trạng thái
pub enum Probe {
    /// Hub đang chạy: hỏi được RPC (cổng HTTP, CSRF token)
    Hub(u16, String),
    /// Màn chat của agy hiện: đã đăng nhập. Không có hub để hỏi RPC (agy trong host không lên hub).
    LoggedIn,
    /// Menu đăng nhập hiện, chưa có màn chat
    SignedOut,
    /// Không biết (không mở được host, hoặc hết thời gian chờ)
    Unknown,
}

static HOST: Mutex<Option<Session>> = Mutex::new(None);
static LAST_USER: Mutex<Option<Instant>> = Mutex::new(None);

/// Ghi nhận thao tác của người dùng (trạng thái, đăng nhập, đăng xuất)
pub fn note_user_activity() {
    if let Ok(mut last) = LAST_USER.lock() {
        *last = Some(Instant::now());
    }
}

fn user_active_recently() -> bool {
    LAST_USER
        .lock()
        .ok()
        .and_then(|last| *last)
        .is_some_and(|t| t.elapsed() < HOST_IDLE)
}

/// Hỏi trạng thái agy theo chế độ [`Need`].
pub fn probe(need: Need) -> Probe {
    if let Some((port, token)) = discover_hub() {
        return Probe::Hub(port, token);
    }
    // Đang có terminal đăng nhập: không mở agy thứ hai (xem `super::login_active`)
    let may_spawn = !super::login_active()
        && match need {
            Need::User => true,
            Need::Background => user_active_recently(),
        };
    if !may_spawn {
        return Probe::Unknown;
    }
    let mut spawned_now = false;
    {
        let Ok(mut guard) = HOST.lock() else {
            return Probe::Unknown;
        };
        // Host cũ đã in "not signed in" có thể đã lỗi thời (vừa đăng nhập ở nơi khác): mở lại
        let stale = guard.as_ref().is_some_and(|s| !tui::session_alive(s)) && need == Need::User;
        if stale || !guard.as_ref().is_some_and(tui::session_alive) {
            if let Some(old) = guard.take() {
                tui::close_session(old);
            }
            match tui::spawn_tui() {
                Ok(session) => {
                    *guard = Some(session);
                    spawned_now = true;
                }
                Err(_) => return Probe::Unknown,
            }
        }
    }
    // Chỉ chờ khi vừa mở host; host đã sống từ trước mà chưa có hub thì không chờ lại
    let deadline = if spawned_now {
        Instant::now() + PROBE_WAIT
    } else {
        Instant::now()
    };
    loop {
        if let Some((port, token)) = discover_hub() {
            return Probe::Hub(port, token);
        }
        if let Ok(mut guard) = HOST.lock() {
            if let Some(session) = guard.as_mut() {
                // Màn chọn màu lần đầu chặn TUI, không có nó thì hub không lên
                session.nudge_first_run();
                match screen_logged_in(session) {
                    Some(true) => return Probe::LoggedIn,
                    Some(false) => return Probe::SignedOut,
                    None => {}
                }
            }
        }
        if Instant::now() >= deadline {
            return Probe::Unknown;
        }
        std::thread::sleep(POLL);
    }
}

/// Trạng thái theo màn hiện tại: `Some(true)` là màn chat, `Some(false)` là menu đăng nhập, `None` là chưa rõ.
/// Không dùng "not signed in": agy vẫn in dòng đó lúc khởi động cả khi đã đăng nhập.
fn screen_logged_in(session: &Session) -> Option<bool> {
    let text = tui::screen_text(session);
    if tui::chat_ready(&text) {
        Some(true)
    } else if text.to_lowercase().contains(LOGIN_MENU_MARK) {
        Some(false)
    } else {
        None
    }
}

/// Hub đang chạy (chỉ dùng cho RPC), hoặc `None` nếu chưa có
pub fn ensure_hub(need: Need) -> Option<(u16, String)> {
    match probe(need) {
        Probe::Hub(port, token) => Some((port, token)),
        _ => None,
    }
}

/// Thời gian tối đa chờ `agy models` báo đã đăng xuất sau khi gõ `/logout`
const LOGOUT_WAIT: Duration = Duration::from_secs(60);
/// Khoảng cách hỏi `agy models` sau `/logout` (mỗi lần là một tiến trình agy)
const LOGOUT_CHECK_EVERY: Duration = Duration::from_secs(2);
/// Lệnh đăng xuất gõ vào TUI (cùng thao tác người dùng tự làm)
const LOGOUT_COMMAND: &str = "/logout";

/// Đăng xuất agy đúng như người dùng làm: mở TUI `agy`, gõ `/logout` rồi Enter.
/// Trạng thái chỉ kiểm tra bằng `agy models` (không đọc chữ trên màn hình để kết luận):
/// đã đăng xuất sẵn thì không mở TUI; sau `/logout` thì chờ `agy models` báo "sign in".
/// Chặn luồng (có thể mất vài chục giây): gọi qua `spawn_blocking`.
pub fn logout_tui() -> Result<(), String> {
    // Giữ khóa HOST suốt lần đăng xuất: không để lần hỏi khác mở thêm một agy song song
    let mut guard = HOST
        .lock()
        .map_err(|_| "Không khóa được phiên agy".to_string())?;
    if let Some(old) = guard.take() {
        tui::close_session(old);
    }
    if matches!(super::signed_in_by_models(), Ok(false)) {
        return Ok(());
    }
    let mut session = tui::spawn_tui()?;

    // Chờ giao diện vẽ xong để nhận lệnh (chỉ là chờ TUI sẵn sàng, không dùng để xác định đăng nhập)
    let deadline = Instant::now() + PROBE_WAIT;
    loop {
        session.nudge_first_run();
        if screen_logged_in(&session).is_some() {
            break;
        }
        if Instant::now() >= deadline {
            tui::close_session(session);
            return Err("Không mở được giao diện agy để đăng xuất".to_string());
        }
        std::thread::sleep(POLL);
    }

    if let Err(e) = tui::type_line(&mut session, LOGOUT_COMMAND) {
        tui::close_session(session);
        return Err(e);
    }

    // Giữ TUI mở tới khi agy xóa token xong, rồi mới đóng
    let deadline = Instant::now() + LOGOUT_WAIT;
    let result = loop {
        if matches!(super::signed_in_by_models(), Ok(false)) {
            break Ok(());
        }
        if Instant::now() >= deadline {
            break Err("agy vẫn báo đã đăng nhập sau lệnh /logout".to_string());
        }
        std::thread::sleep(LOGOUT_CHECK_EVERY);
    };
    tui::close_session(session);
    result
}

/// Tắt host (sau khi đổi tài khoản). Lần hỏi sau sẽ mở host mới và đọc trạng thái mới.
pub fn restart() {
    if let Ok(mut guard) = HOST.lock() {
        if let Some(session) = guard.take() {
            tui::close_session(session);
        }
    }
}

/// Biến môi trường đánh dấu TUI do server mở (đặt khi spawn, đọc khi dọn)
pub const MARK_ENV: &str = "MUOP_AGY_HOST";

/// Tắt TUI do server mở ở lần chạy trước (đã mồ côi khi server thoát). Chỉ tiến trình cùng user
/// và có đánh dấu [`MARK_ENV`] mới bị tắt; agy do người dùng tự mở không có đánh dấu nên được giữ.
pub fn cleanup_stale() {
    use std::os::unix::fs::MetadataExt;
    // SAFETY: getuid không có điều kiện nào và không thể lỗi
    let me = unsafe { libc::getuid() };
    let needle = format!("{MARK_ENV}=1");
    let Ok(entries) = std::fs::read_dir("/proc") else {
        return;
    };
    for entry in entries.flatten() {
        let Some(pid) = entry
            .file_name()
            .to_str()
            .and_then(|s| s.parse::<libc::pid_t>().ok())
        else {
            continue;
        };
        let dir = entry.path();
        match std::fs::metadata(&dir) {
            Ok(meta) if meta.uid() == me => {}
            _ => continue,
        }
        let Ok(env) = std::fs::read(dir.join("environ")) else {
            continue;
        };
        if env.split(|b| *b == 0).any(|kv| kv == needle.as_bytes()) {
            // SAFETY: gửi SIGTERM tới tiến trình con do server tạo ra ở lần chạy trước
            unsafe {
                libc::kill(pid, libc::SIGTERM);
            }
        }
    }
}

/// Tắt host nếu người dùng không còn thao tác trong [`HOST_IDLE`] (gọi định kỳ)
pub fn reap_idle() {
    if !user_active_recently() {
        restart();
    }
}
