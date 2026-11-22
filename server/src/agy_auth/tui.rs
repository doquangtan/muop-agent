//! PTY của TUI agy do server mở để đọc màn hình khi không có IDE (xem [`host`](super::host)).
//!
//! Đăng nhập không đi qua đây: người dùng tự đăng nhập trong terminal SSH chạy `agy`
//! (xem `open_login_terminal` trong `mod.rs`). Ở đây chỉ có PTY, đọc đầu ra và gửi phím.

use std::fs::{self, File};
use std::io::{Read, Write};
use std::os::fd::{FromRawFd, OwnedFd};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::process::CommandExt;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use super::host;

const COLS: u16 = 120;
const ROWS: u16 = 45;
/// Số byte đầu ra giữ lại để đọc màn hình
const OUTPUT_KEEP: usize = 512 * 1024;
/// Màn chọn màu lần đầu của agy (so sánh chữ thường): chặn TUI nên phải nhấn Enter
/// Màn lần đầu chạy agy chặn TUI: chọn màu, rồi hộp hướng dẫn "[Next] … enter Confirm" (nhiều bước).
/// Đo được trên laptop sạch: chỉ nhấn Enter cho màn chọn màu thì host kẹt ở hướng dẫn.
const FIRST_RUN_MARKS: [&str; 3] = [
    "choose your color scheme",
    "enter confirm",
    "press enter to continue",
];
/// Số lần nhấn Enter tối đa cho các màn lần đầu chạy
const NUDGE_MAX: u32 = 12;

#[derive(Default)]
struct Output {
    buf: Vec<u8>,
    /// Tổng số byte đã nhận từ lúc mở PTY (để đánh dấu vị trí tuyệt đối)
    total: usize,
    closed: bool,
}

impl Output {
    /// Dữ liệu từ vị trí tuyệt đối `abs` trở đi (phần đã bị cắt bớt thì bắt đầu từ đầu bộ đệm)
    fn since(&self, abs: usize) -> &[u8] {
        let start = self.total - self.buf.len();
        let from = abs.saturating_sub(start).min(self.buf.len());
        &self.buf[from..]
    }
}

pub(crate) struct Session {
    child: Child,
    writer: File,
    out: Arc<Mutex<Output>>,
    dir: PathBuf,
    nudge: Nudge,
}

/// Theo dõi lần nhấn Enter cho màn chọn màu (xem [`Session::nudge_first_run`])
#[derive(Default)]
pub(super) struct Nudge {
    mark: usize,
    count: u32,
    last: Option<Instant>,
}

static NEXT_ID: AtomicU64 = AtomicU64::new(1);

fn is_closed(out: &Arc<Mutex<Output>>) -> bool {
    out.lock().map(|o| o.closed).unwrap_or(true)
}

/// TUI của phiên còn chạy (chưa thoát)
pub(crate) fn session_alive(session: &Session) -> bool {
    !is_closed(&session.out)
}

/// Đóng TUI của một phiên
pub(crate) fn close_session(session: Session) {
    session.close();
}

/// Chữ TUI đã in ra từ lúc mở (đã bỏ ANSI), để đọc màn hình trạng thái
pub(super) fn screen_text(session: &Session) -> String {
    snapshot_text(&session.out, 0).0
}

/// Gõ một dòng vào TUI rồi nhấn Enter, như người dùng tự gõ. Enter gửi riêng sau một khoảng ngắn để
/// TUI kịp nhận chữ và đóng menu gợi ý lệnh (`/...`) trước khi Enter chọn lệnh.
pub(super) fn type_line(session: &mut Session, text: &str) -> Result<(), String> {
    session.write(text)?;
    thread::sleep(Duration::from_millis(400));
    session.write("\r")
}

/// Vị trí hiện tại của đầu ra TUI, để đọc chữ in ra sau đó
pub(super) fn output_mark(session: &Session) -> usize {
    total(&session.out)
}

/// Chữ TUI đã in ra từ vị trí `mark` (đã bỏ ANSI)
pub(super) fn text_since(session: &Session, mark: usize) -> String {
    snapshot_text(&session.out, mark).0
}

/// Gửi dữ liệu thô tới TUI (ví dụ phím Escape `\u{1b}`)
pub(super) fn send_raw(session: &mut Session, data: &str) -> Result<(), String> {
    session.write(data)
}

fn total(out: &Arc<Mutex<Output>>) -> usize {
    out.lock().map(|o| o.total).unwrap_or(0)
}

/// Text đã bỏ ANSI của output từ vị trí `from`, kèm cờ đã thoát hay chưa
fn snapshot_text(out: &Arc<Mutex<Output>>, from: usize) -> (String, bool) {
    match out.lock() {
        Ok(o) => (strip_ansi(o.since(from)), o.closed),
        Err(_) => (String::new(), true),
    }
}

impl Session {
    /// Nhấn Enter nếu màn chọn màu lần đầu vừa được vẽ. Màn đó chặn TUI: không có nó thì hub không lên.
    pub(super) fn nudge_first_run(&mut self) {
        if self.nudge.count >= NUDGE_MAX {
            return;
        }
        if self
            .nudge
            .last
            .is_some_and(|t| t.elapsed() < Duration::from_secs(2))
        {
            return;
        }
        let (text, _) = snapshot_text(&self.out, self.nudge.mark);
        let low = text.to_lowercase();
        if !FIRST_RUN_MARKS.iter().any(|m| low.contains(m)) {
            return;
        }
        let _ = self.write("\r");
        self.nudge.count += 1;
        self.nudge.last = Some(Instant::now());
        self.nudge.mark = total(&self.out);
    }

    fn write(&mut self, data: &str) -> Result<(), String> {
        self.writer
            .write_all(data.as_bytes())
            .and_then(|_| self.writer.flush())
            .map_err(|e| format!("Không gửi được dữ liệu tới agy: {e}"))
    }

    /// Dừng TUI (SIGTERM, sau 2 giây thì SIGKILL) và xóa thư mục tạm
    fn close(mut self) {
        let pid = self.child.id() as libc::pid_t;
        unsafe {
            libc::kill(pid, libc::SIGTERM);
        }
        let deadline = Instant::now() + Duration::from_secs(2);
        loop {
            match self.child.try_wait() {
                Ok(Some(_)) => break,
                _ if Instant::now() >= deadline => {
                    let _ = self.child.kill();
                    let _ = self.child.wait();
                    break;
                }
                _ => thread::sleep(Duration::from_millis(50)),
            }
        }
        let _ = fs::remove_dir_all(&self.dir);
    }
}

pub(super) fn spawn_tui() -> Result<Session, String> {
    spawn_agy(&[], &[])
}

/// Chạy agy trong PTY với tham số và biến môi trường thêm (ví dụ `--hub` với `AGY_ENABLE_HUB=1`)
pub(crate) fn spawn_agy(args: &[&str], envs: &[(&str, &str)]) -> Result<Session, String> {
    let id = NEXT_ID.fetch_add(1, Ordering::Relaxed);
    let dir = std::env::temp_dir().join(format!("muop-agy-tui-{}-{id}", std::process::id()));
    fs::create_dir_all(&dir).map_err(|_| "Không tạo được thư mục tạm cho agy".to_string())?;
    let _ = fs::set_permissions(&dir, fs::Permissions::from_mode(0o700));

    // PTY: agy là TUI nên cần terminal thật (print mode không đăng nhập được)
    let mut ws = libc::winsize {
        ws_row: ROWS,
        ws_col: COLS,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    let mut master_fd: libc::c_int = -1;
    let mut slave_fd: libc::c_int = -1;
    let rc = unsafe {
        libc::openpty(
            &mut master_fd,
            &mut slave_fd,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            &mut ws,
        )
    };
    if rc != 0 {
        let _ = fs::remove_dir_all(&dir);
        return Err("Không mở được PTY".into());
    }
    let master = unsafe { OwnedFd::from_raw_fd(master_fd) };
    let slave = unsafe { OwnedFd::from_raw_fd(slave_fd) };
    let (slave_out, slave_err) = match (slave.try_clone(), slave.try_clone()) {
        (Ok(a), Ok(b)) => (a, b),
        _ => {
            let _ = fs::remove_dir_all(&dir);
            return Err("Không nhân được PTY".into());
        }
    };

    // Chạy agy từ thư mục home, không phải thư mục tạm: trong /tmp agy kẹt ở "not signed in" và không vào màn chat
    // (đã đo: cùng agy, cwd=/home/john vào màn chat, cwd=/tmp không vào)
    let workdir = std::env::var_os("HOME")
        .map(PathBuf::from)
        .filter(|p| p.is_dir())
        .unwrap_or_else(|| dir.clone());
    let agy = crate::chat::agy_bin()?;
    let mut cmd = Command::new(agy);
    cmd.args(args);
    cmd.envs(envs.iter().copied());
    cmd.current_dir(&workdir)
        .env("TERM", "xterm-256color")
        // Đánh dấu TUI do server tạo để lần khởi động sau tắt được tiến trình còn sót (xem `host::cleanup_stale`)
        .env(host::MARK_ENV, "1")
        .stdin(Stdio::from(slave))
        .stdout(Stdio::from(slave_out))
        .stderr(Stdio::from(slave_err));
    // Trong tiến trình con: tạo phiên mới và đặt PTY làm controlling terminal
    unsafe {
        cmd.pre_exec(|| {
            if libc::setsid() < 0 {
                return Err(std::io::Error::last_os_error());
            }
            if libc::ioctl(0, libc::TIOCSCTTY as _, 0) < 0 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }

    let child = match cmd.spawn() {
        Ok(child) => child,
        Err(e) => {
            let _ = fs::remove_dir_all(&dir);
            return Err(format!("Không chạy được agy: {e}"));
        }
    };
    let master = File::from(master);
    let reader = match master.try_clone() {
        Ok(reader) => reader,
        Err(_) => {
            let mut child = child;
            let _ = child.kill();
            let _ = child.wait();
            let _ = fs::remove_dir_all(&dir);
            return Err("Không đọc được PTY của agy".into());
        }
    };
    let out = Arc::new(Mutex::new(Output::default()));
    spawn_reader(reader, Arc::clone(&out));

    Ok(Session {
        child,
        writer: master,
        out,
        dir,
        nudge: Nudge::default(),
    })
}

fn spawn_reader(mut reader: File, out: Arc<Mutex<Output>>) {
    thread::spawn(move || {
        let mut chunk = [0u8; 8192];
        loop {
            match reader.read(&mut chunk) {
                Ok(0) => break,
                Ok(n) => {
                    if let Ok(mut o) = out.lock() {
                        o.buf.extend_from_slice(&chunk[..n]);
                        o.total += n;
                        if o.buf.len() > OUTPUT_KEEP {
                            let drop_len = o.buf.len() - OUTPUT_KEEP;
                            o.buf.drain(..drop_len);
                        }
                    }
                }
                Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
                // EIO khi tiến trình con đã thoát
                Err(_) => break,
            }
        }
        if let Ok(mut o) = out.lock() {
            o.closed = true;
        }
    });
}

/// Bỏ escape sequence của terminal. Cursor-forward (CUF) đổi thành khoảng trắng,
/// cursor-position (CUP) đổi thành xuống dòng để các chữ TUI vẽ rời vẫn ghép được.
pub(super) fn strip_ansi(raw: &[u8]) -> String {
    let mut out: Vec<u8> = Vec::with_capacity(raw.len());
    let mut i = 0;
    while i < raw.len() {
        if raw[i] == 0x1b {
            match raw.get(i + 1) {
                Some(b'[') => {
                    let mut j = i + 2;
                    while j < raw.len() && !(0x40..=0x7e).contains(&raw[j]) {
                        j += 1;
                    }
                    match raw.get(j) {
                        Some(b'C') => out.push(b' '),
                        Some(b'H') | Some(b'f') => out.push(b'\n'),
                        _ => {}
                    }
                    i = j + 1;
                }
                Some(b']') => {
                    let mut j = i + 2;
                    while j < raw.len()
                        && raw[j] != 0x07
                        && !(raw[j] == 0x1b && raw.get(j + 1) == Some(&b'\\'))
                    {
                        j += 1;
                    }
                    i = if raw.get(j) == Some(&0x1b) {
                        j + 2
                    } else {
                        j + 1
                    };
                }
                _ => i += 2,
            }
        } else {
            if raw[i] != b'\r' {
                out.push(raw[i]);
            }
            i += 1;
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// Tiền tố URL đăng nhập Google mà agy in ra
const LOGIN_URL_PREFIX: &str = "https://accounts.google.com/";
/// Dòng agy in ra khi xác thực xong
const SUCCESS_MARK: &str = "Authentication successful";
/// Chữ của màn chat, chỉ hiện khi agy đã đăng nhập (sau bước OAuth agy vào thẳng màn chat, không in
/// "Authentication successful"). Đã kiểm chứng: không có trong màn chọn phương thức, màn link, hay màn lỗi.
const CHAT_READY_MARK: &str = "for shortcuts";
/// Dòng lỗi xác thực: nội dung lỗi nằm sau mốc này và kết thúc bằng [`ERROR_END_MARK`]
const ERROR_MARK: &str = "Got an error:";
const ERROR_END_MARK: &str = "Press any key";

/// Mọi link Google trong đầu ra, theo thứ tự xuất hiện. Mỗi link kèm phần chữ in ra sau nó.
/// Ưu tiên OSC 8 hyperlink: URL trong đó còn nguyên, còn chữ hiển thị bị TUI ngắt dòng nên không dùng được.
fn login_url_spans(raw: &[u8]) -> Vec<(String, String)> {
    const OSC8: &[u8] = b"\x1b]8;";
    let mut spans = Vec::new();
    let mut from = 0;
    while let Some(rel) = find_bytes(&raw[from..], OSC8) {
        let params_start = from + rel + OSC8.len();
        let Some(semi) = raw[params_start..].iter().position(|&b| b == b';') else {
            break;
        };
        let url_start = params_start + semi + 1;
        let url_end = raw[url_start..]
            .iter()
            .position(|&b| b == 0x1b || b == 0x07)
            .map_or(raw.len(), |p| url_start + p);
        let url = String::from_utf8_lossy(&raw[url_start..url_end]).into_owned();
        if url.starts_with(LOGIN_URL_PREFIX) {
            spans.push((url, String::from_utf8_lossy(&raw[url_end..]).into_owned()));
        }
        from = url_end;
    }
    if !spans.is_empty() {
        return spans;
    }
    // Không có OSC 8: lấy chuỗi liền từ tiền tố đến khoảng trắng hoặc ký tự điều khiển
    let text = String::from_utf8_lossy(raw).into_owned();
    for (start, _) in text.match_indices(LOGIN_URL_PREFIX) {
        let url: String = text[start..]
            .chars()
            .take_while(|c| !c.is_whitespace() && !c.is_control())
            .collect();
        let end = start + url.len();
        spans.push((url, text[end..].to_string()));
    }
    spans
}

/// Mốc màn hình đã đổi (đã bỏ khoảng trắng, viết thường). Link in ra trước các mốc này không còn trên màn hình.
const SCREEN_CHANGE_MARKS: [&str; 6] = [
    "selectloginmethod",
    "gotanerror",
    "authenticationsuccessful",
    "forshortcuts",
    "termsofservice",
    "notsignedin",
];

/// Link đăng nhập đang hiện trên màn hình. Agy vẽ lại màn hình nên link cũ vẫn nằm trong bộ đệm:
/// chỉ tính là còn hiện khi link in ra sau cùng không bị màn khác (menu, lỗi, điều khoản, màn chat) thay.
pub(super) fn link_on_screen(raw: &[u8]) -> Option<String> {
    let (url, after) = login_url_spans(raw).pop()?;
    let compact: String = strip_ansi(after.as_bytes())
        .chars()
        .filter(|c| !c.is_whitespace())
        .flat_map(char::to_lowercase)
        .collect();
    if SCREEN_CHANGE_MARKS.iter().any(|m| compact.contains(m)) {
        None
    } else {
        Some(url)
    }
}

/// agy đã báo xác thực thành công (đã bỏ ANSI)
pub(super) fn auth_succeeded(text: &str) -> bool {
    text.contains(SUCCESS_MARK)
}

/// Màn chat của agy đã hiện (đã đăng nhập). So khớp bỏ khoảng trắng: `strip_ansi` có thể làm mất
/// khoảng trắng giữa các từ tùy cách TUI vẽ.
pub(super) fn chat_ready(text: &str) -> bool {
    let compact: String = text.chars().filter(|c| !c.is_whitespace()).collect();
    compact.contains(&CHAT_READY_MARK.replace(' ', ""))
}

/// Menu chọn cách đăng nhập đang hiện, có mục "Google OAuth" (so khớp bỏ khoảng trắng, không phân biệt hoa thường).
/// Chỉ dùng khi chưa có link: đầu ra là toàn bộ lịch sử, nên menu cũ vẫn còn sau khi đã chuyển màn
/// (khi đó caller đã có link hoặc đã gửi mã và không hỏi lại).
pub(super) fn google_menu_on_screen(text: &str) -> bool {
    let compact: String = text
        .chars()
        .filter(|c| !c.is_whitespace())
        .collect::<String>()
        .to_lowercase();
    compact.contains("selectloginmethod") && compact.contains("googleoauth")
}

/// Nội dung lỗi xác thực agy in ra, chỉ khi TUI đã vẽ xong thông báo (có "Press any key")
pub(super) fn auth_error(text: &str) -> Option<String> {
    let rest = text.split(ERROR_MARK).nth(1)?;
    let (message, _) = rest.split_once(ERROR_END_MARK)?;
    let message = message.split_whitespace().collect::<Vec<_>>().join(" ");
    if message.is_empty() {
        None
    } else {
        Some(message)
    }
}

fn find_bytes(hay: &[u8], needle: &[u8]) -> Option<usize> {
    hay.windows(needle.len()).position(|w| w == needle)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Link Google đầu tiên trong đầu ra (kiểm thử)
    fn login_url(raw: &[u8]) -> Option<String> {
        login_url_spans(raw).into_iter().next().map(|(url, _)| url)
    }

    #[test]
    fn strip_ansi_keeps_words_split_by_cursor_forward() {
        let raw = b"\x1b[1;5HSelect\x1b[1Clogin\x1b[1Cmethod:\x1b[31m red\x1b[0m";
        assert_eq!(strip_ansi(raw), "\nSelect login method: red");
    }

    #[test]
    fn finds_full_login_url_inside_osc8_hyperlink() {
        let raw = b"Copy the URL: https://accounts.google.com/o/oauth2/auth?wrapped\r\n\
            \x1b]8;;https://accounts.google.com/o/oauth2/auth?client_id=abc&state=xyz\x1b\\\
            Click here\x1b]8;;\x1b\\";
        assert_eq!(
            login_url(raw).as_deref(),
            Some("https://accounts.google.com/o/oauth2/auth?client_id=abc&state=xyz")
        );
    }

    #[test]
    fn link_stays_on_screen_until_another_screen_is_drawn() {
        let link =
            b"Open the URL below in your browser:\r\nhttps://accounts.google.com/o/oauth2/auth?a=1";
        assert_eq!(
            link_on_screen(link).as_deref(),
            Some("https://accounts.google.com/o/oauth2/auth?a=1")
        );
        // Màn menu vẽ lại sau link: link không còn trên màn hình
        let menu_after = b"Open the URL below in your browser:\r\nhttps://accounts.google.com/o/oauth2/auth?a=1\r\nSelect login method\r\n1. Google OAuth";
        assert_eq!(link_on_screen(menu_after), None);
        // Link vẽ lại sau menu: link đang hiện
        let link_again = b"Select login method\r\nhttps://accounts.google.com/o/oauth2/auth?a=2";
        assert_eq!(
            link_on_screen(link_again).as_deref(),
            Some("https://accounts.google.com/o/oauth2/auth?a=2")
        );
        // Lỗi sau link (có khoảng trắng do TUI vẽ): không còn link
        let error_after =
            b"https://accounts.google.com/o/oauth2/auth?a=1\x1b[1CGot\x1b[1Can\x1b[1Cerror: x";
        assert_eq!(link_on_screen(error_after), None);
        assert_eq!(link_on_screen(b"no link here"), None);
    }

    #[test]
    fn finds_plain_login_url_until_whitespace() {
        let raw = b"Open the URL below:\r\nhttps://accounts.google.com/o/oauth2/auth?a=1&b=2\r\n(1-10 of 32 lines)";
        assert_eq!(
            login_url(raw).as_deref(),
            Some("https://accounts.google.com/o/oauth2/auth?a=1&b=2")
        );
        assert_eq!(login_url(b"no url here"), None);
    }

    #[test]
    fn error_text_waits_for_full_message() {
        assert_eq!(auth_error("Got an error: partial"), None);
        assert_eq!(
            auth_error("Got an error: token exchange failed: \"Malformed auth code.\"\n Press any key to go back."),
            Some("token exchange failed: \"Malformed auth code.\"".to_string())
        );
    }

    #[test]
    fn detects_chat_screen_after_login() {
        // Đầu ra thật: màn chat hiện sau màn đăng nhập; khoảng trắng có thể bị mất khi strip ANSI
        assert!(chat_ready(
            "? for shortcuts\nauto · Gemini 3.8 Flash · high"
        ));
        assert!(chat_ready("?forshortcuts"));
        assert!(!chat_ready(
            "Select login method\n1. Google OAuth\nOpen the URL below in your browser:"
        ));
    }

    #[test]
    fn detects_success_mark() {
        assert!(auth_succeeded("...Authentication successful\n"));
        assert!(!auth_succeeded("Select login method"));
    }

    #[test]
    fn detects_google_menu_with_or_without_spaces() {
        assert!(google_menu_on_screen(
            "Select login method\n> 1. Google OAuth\n2. API key"
        ));
        assert!(google_menu_on_screen("Selectloginmethod:>1.GoogleOAuth"));
        assert!(!google_menu_on_screen(
            "Open the URL below in your browser:"
        ));
        assert!(!google_menu_on_screen("Select login method only"));
    }
}
