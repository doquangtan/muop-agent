//! Phiên đăng nhập Claude Code CLI (`claude auth login`).
//!
//! Luồng:
//! 1. Chạy `claude auth login` trong PTY (với `BROWSER=echo`).
//! 2. Đọc URL đăng nhập từ output (https://claude.com/cai/oauth/authorize?...).
//! 3. Người dùng mở link, đăng nhập tài khoản Anthropic, sao chép mã (hoặc URL trang callback).
//! 4. [`submit`] gửi mã vào PTY qua stdin, theo dõi kết quả tới khi hoàn tất.
//!
//! Chỉ có một phiên tại một thời điểm. Phiên không được hoàn tất trong [`SESSION_TTL`] sẽ bị hủy.

use std::fs::{self, File};
use std::io::{Read, Write};
use std::os::fd::{FromRawFd, OwnedFd};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::process::CommandExt;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::thread;
use std::time::{Duration, Instant};

use super::publish;
use serde_json::Value;

const COLS: u16 = 120;
const ROWS: u16 = 45;
/// Thời gian chờ link OAuth sau khi khởi chạy
const URL_WAIT: Duration = Duration::from_secs(30);
/// Thời gian chờ kết quả sau khi gửi mã
const RESULT_WAIT: Duration = Duration::from_secs(90);
/// Khoảng cách kiểm tra trạng thái CLI
const STATUS_CHECK: Duration = Duration::from_secs(1);
/// Phiên không hoàn tất trong khoảng này thì bị hủy
const SESSION_TTL: Duration = Duration::from_secs(20 * 60);
const POLL: Duration = Duration::from_millis(150);
/// Số byte output giữ lại để tìm link và thông báo
const OUTPUT_KEEP: usize = 512 * 1024;
const MAX_CODE_LEN: usize = 4096;

#[derive(Debug, Clone, Default)]
pub struct ClaudeAuthInfo {
    pub logged_in: bool,
    pub email: String,
    pub subscription_type: String,
}

#[derive(Default)]
struct Output {
    buf: Vec<u8>,
    total: usize,
    closed: bool,
}

impl Output {
    fn since(&self, abs: usize) -> &[u8] {
        let start = self.total - self.buf.len();
        let from = abs.saturating_sub(start).min(self.buf.len());
        &self.buf[from..]
    }
}

struct Session {
    id: u64,
    child: Child,
    writer: File,
    out: Arc<Mutex<Output>>,
    login_url: String,
    dir: PathBuf,
}

impl Session {
    fn close(mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = fs::remove_dir_all(&self.dir);
    }

    fn write(&mut self, s: &str) -> Result<(), String> {
        self.writer
            .write_all(s.as_bytes())
            .map_err(|e| format!("Không ghi được vào Claude CLI: {e}"))?;
        let _ = self.writer.flush();
        Ok(())
    }
}

static NEXT_ID: AtomicU64 = AtomicU64::new(1);
static SESSION: Mutex<Option<Session>> = Mutex::new(None);
static OP: Mutex<()> = Mutex::new(());

fn lock_session() -> MutexGuard<'static, Option<Session>> {
    SESSION.lock().unwrap_or_else(|e| e.into_inner())
}

fn op_guard() -> MutexGuard<'static, ()> {
    OP.lock().unwrap_or_else(|e| e.into_inner())
}

fn is_closed(out: &Arc<Mutex<Output>>) -> bool {
    out.lock().map(|o| o.closed).unwrap_or(true)
}

fn total(out: &Arc<Mutex<Output>>) -> usize {
    out.lock().map(|o| o.total).unwrap_or(0)
}

fn snapshot_text(out: &Arc<Mutex<Output>>, from: usize) -> (String, bool) {
    match out.lock() {
        Ok(o) => (strip_ansi(o.since(from)), o.closed),
        Err(_) => (String::new(), true),
    }
}

/// Link đăng nhập đang chờ mã (nếu có phiên còn sống)
pub fn pending_url() -> Option<String> {
    let guard = lock_session();
    let session = guard.as_ref()?;
    if is_closed(&session.out) {
        return None;
    }
    Some(session.login_url.clone())
}

/// Kiểm tra trạng thái xác thực hiện tại của Claude Code CLI
pub fn cli_auth_status() -> Result<ClaudeAuthInfo, String> {
    let bin = crate::claude::code::claude_bin()?;
    let child = Command::new(&bin)
        .args(["auth", "status", "--json"])
        .output();

    if let Ok(output) = child {
        let stdout = String::from_utf8_lossy(&output.stdout);
        if let (Some(start), Some(end)) = (stdout.find('{'), stdout.rfind('}')) {
            if end >= start {
                if let Ok(v) = serde_json::from_str::<Value>(&stdout[start..=end]) {
                    let logged_in = v.get("loggedIn").and_then(Value::as_bool).unwrap_or(false);
                    let email = v
                        .get("email")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_string();
                    let sub = v
                        .get("subscriptionType")
                        .or_else(|| v.get("planTier"))
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_string();
                    return Ok(ClaudeAuthInfo {
                        logged_in,
                        email,
                        subscription_type: sub,
                    });
                }
            }
        }
    }

    // Dự phòng: đọc credentials từ file ~/.claude/.credentials.json và ~/.claude.json
    let home = match std::env::var("HOME") {
        Ok(h) => PathBuf::from(h),
        Err(_) => return Ok(ClaudeAuthInfo::default()),
    };
    let cred_path = home.join(".claude/.credentials.json");
    if let Ok(raw) = fs::read_to_string(&cred_path) {
        if let Ok(v) = serde_json::from_str::<Value>(&raw) {
            if let Some(oauth) = v.get("claudeAiOauth") {
                if let Some(token) = oauth.get("accessToken").and_then(Value::as_str) {
                    if !token.is_empty() {
                        let sub = oauth
                            .get("subscriptionType")
                            .and_then(Value::as_str)
                            .unwrap_or("")
                            .to_string();
                        let mut email = String::new();
                        let claude_json_path = home.join(".claude.json");
                        if let Ok(c_raw) = fs::read_to_string(&claude_json_path) {
                            if let Ok(cv) = serde_json::from_str::<Value>(&c_raw) {
                                if let Some(e) = cv
                                    .pointer("/oauthAccount/emailAddress")
                                    .and_then(Value::as_str)
                                {
                                    email = e.to_string();
                                }
                            }
                        }
                        return Ok(ClaudeAuthInfo {
                            logged_in: true,
                            email,
                            subscription_type: sub,
                        });
                    }
                }
            }
        }
    }

    Ok(ClaudeAuthInfo::default())
}

/// Đăng xuất khỏi Claude CLI
pub fn cli_logout() -> Result<(), String> {
    let bin = crate::claude::code::claude_bin()?;
    let output = Command::new(&bin)
        .args(["auth", "logout"])
        .output()
        .map_err(|e| format!("Không chạy được lệnh đăng xuất claude: {e}"))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!("Lỗi khi đăng xuất claude: {stderr}"));
    }
    Ok(())
}

/// Bắt đầu đăng nhập và trả về link OAuth
pub fn start() -> Result<String, String> {
    let _op = op_guard();
    if let Some(url) = pending_url() {
        return Ok(url);
    }
    let stale = {
        let mut guard = lock_session();
        if guard.as_ref().is_some_and(|s| is_closed(&s.out)) {
            guard.take()
        } else {
            None
        }
    };
    if let Some(stale) = stale {
        stale.close();
    }

    let mut session = spawn_tui()?;
    if let Err(e) = prepare_url(&mut session) {
        session.close();
        return Err(e);
    }
    let url = session.login_url.clone();
    let id = session.id;
    *lock_session() = Some(session);
    schedule_expiry(id);
    Ok(url)
}

/// Gửi mã xác thực vào phiên đang chờ
pub fn submit(raw_code: &str) -> Result<(), String> {
    let _op = op_guard();
    let code = validate_code(raw_code)?;
    let Some(mut session) = lock_session().take() else {
        return Err("Chưa có phiên đăng nhập đang chờ. Hãy bấm đăng nhập để lấy link mới.".into());
    };
    if is_closed(&session.out) {
        session.close();
        return Err("Phiên đăng nhập đã kết thúc. Hãy bấm đăng nhập để lấy link mới.".into());
    }
    let from = total(&session.out);
    if let Err(e) = session.write(&format!("{code}\r\n")) {
        session.close();
        return Err(e);
    }
    publish("verifying", false, "", "", &session.login_url, "");
    thread::spawn(move || finish_login(session, from));
    Ok(())
}

fn finish_login(mut session: Session, from: usize) {
    let outcome = wait_result(&mut session, from);
    session.close();
    match outcome {
        Ok(info) => {
            // Đăng nhập xong: lấy danh sách model từ API và lưu vào DB để UI dùng sau này
            crate::claude::code::save_claude_model_ids_from_api();
            publish(
                "logged_in",
                true,
                &info.email,
                &info.subscription_type,
                "",
                "",
            )
        }
        Err(e) => publish(
            "failed",
            false,
            "",
            "",
            "",
            &format!("{e} Hãy bấm đăng nhập để lấy link mới."),
        ),
    }
}

pub fn cancel() {
    let _op = op_guard();
    let taken = lock_session().take();
    if let Some(session) = taken {
        session.close();
        publish("cancelled", false, "", "", "", "");
    }
}

pub fn validate_code(raw: &str) -> Result<String, String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err("Thiếu mã xác thực.".into());
    }
    if trimmed.len() > MAX_CODE_LEN {
        return Err("Mã xác thực quá dài.".into());
    }
    let mut code = trimmed;
    // Nếu người dùng dán URL callback: https://platform.claude.com/oauth/code/callback?code=XXXX&state=YYYY
    if let Some(pos) = code.find("code=") {
        let after = &code[pos + 5..];
        let end = after
            .find('&')
            .or_else(|| after.find('#'))
            .unwrap_or(after.len());
        let extracted = &after[..end];
        if !extracted.is_empty() {
            code = extracted;
        }
    }
    if code.chars().any(|c| c.is_control() || c.is_whitespace()) {
        return Err("Mã xác thực không được chứa khoảng trắng hoặc ký tự điều khiển.".into());
    }
    Ok(code.to_string())
}

fn schedule_expiry(id: u64) {
    thread::spawn(move || {
        thread::sleep(SESSION_TTL);
        let _op = op_guard();
        let expired = {
            let mut guard = lock_session();
            if guard.as_ref().is_some_and(|s| s.id == id) {
                guard.take()
            } else {
                None
            }
        };
        if let Some(session) = expired {
            session.close();
            publish(
                "expired",
                false,
                "",
                "",
                "",
                "Phiên đăng nhập đã hết hạn. Bấm đăng nhập để lấy link mới.",
            );
        }
    });
}

fn prepare_url(session: &mut Session) -> Result<(), String> {
    session.login_url = wait_login_url(&session.out)?;
    Ok(())
}

fn wait_login_url(out: &Arc<Mutex<Output>>) -> Result<String, String> {
    let deadline = Instant::now() + URL_WAIT;
    loop {
        let (raw, closed) = match out.lock() {
            Ok(o) => (o.since(0).to_vec(), o.closed),
            Err(_) => (Vec::new(), true),
        };
        if let Some(url) = find_login_url(&raw) {
            return Ok(url);
        }
        if closed {
            return Err("Claude CLI đã thoát trước khi tạo link đăng nhập.".into());
        }
        if Instant::now() >= deadline {
            return Err("Hết thời gian chờ link đăng nhập của Claude CLI.".into());
        }
        thread::sleep(POLL);
    }
}

fn wait_result(session: &mut Session, from: usize) -> Result<ClaudeAuthInfo, String> {
    let deadline = Instant::now() + RESULT_WAIT;
    let mut next_check = Instant::now() + STATUS_CHECK;
    loop {
        let (text, closed) = snapshot_text(&session.out, from);
        if text.contains("Login successful")
            || text.contains("Logged in as")
            || text.contains("Authentication successful")
        {
            thread::sleep(Duration::from_millis(800));
            if let Ok(info) = cli_auth_status() {
                if info.logged_in {
                    return Ok(info);
                }
            }
            return Ok(ClaudeAuthInfo {
                logged_in: true,
                email: String::new(),
                subscription_type: String::new(),
            });
        }
        let now = Instant::now();
        if now >= next_check {
            next_check = now + STATUS_CHECK;
            if let Ok(info) = cli_auth_status() {
                if info.logged_in {
                    return Ok(info);
                }
            }
        }
        if closed {
            if let Ok(info) = cli_auth_status() {
                if info.logged_in {
                    return Ok(info);
                }
            }
            return Err("Claude CLI đã thoát khi đang xác thực.".into());
        }
        if now >= deadline {
            return Err("Hết thời gian chờ kết quả xác thực Claude.".into());
        }
        thread::sleep(POLL);
    }
}

pub fn find_login_url(raw: &[u8]) -> Option<String> {
    // 1. Kiểm tra OSC 8 hyperlink: ESC ] 8 ; params ; URL (ESC \ | BEL)
    const OSC8: &[u8] = b"\x1b]8;";
    let mut from = 0;
    while let Some(rel) = find_bytes(&raw[from..], OSC8) {
        let params_start = from + rel + OSC8.len();
        if let Some(semi) = raw[params_start..].iter().position(|&b| b == b';') {
            let url_start = params_start + semi + 1;
            let url_end = raw[url_start..]
                .iter()
                .position(|&b| b == 0x1b || b == 0x07)
                .map_or(raw.len(), |p| url_start + p);
            let url = String::from_utf8_lossy(&raw[url_start..url_end]);
            if url.starts_with("https://")
                && (url.contains("claude.com") || url.contains("anthropic.com"))
            {
                return Some(url.into_owned());
            }
            from = url_end;
        } else {
            break;
        }
    }

    // 2. Tìm kiếm trong văn bản thuần đã gỡ escape code
    let text = strip_ansi(raw);
    for word in text.split_whitespace() {
        if word.starts_with("https://")
            && (word.contains("cai/oauth/authorize")
                || word.contains("oauth/authorize")
                || (word.contains("claude.com") && word.contains("response_type=code")))
        {
            let clean = word.trim_matches(|c: char| {
                c == '\'' || c == '"' || c == '>' || c == '<' || c == '(' || c == ')' || c == ','
            });
            return Some(clean.to_string());
        }
    }
    None
}

fn find_bytes(hay: &[u8], needle: &[u8]) -> Option<usize> {
    hay.windows(needle.len()).position(|w| w == needle)
}

fn strip_ansi(raw: &[u8]) -> String {
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

fn spawn_tui() -> Result<Session, String> {
    let id = NEXT_ID.fetch_add(1, Ordering::Relaxed);
    let dir = std::env::temp_dir().join(format!("muop-claude-login-{}-{id}", std::process::id()));
    fs::create_dir_all(&dir).map_err(|_| "Không tạo được thư mục tạm cho Claude".to_string())?;
    let _ = fs::set_permissions(&dir, fs::Permissions::from_mode(0o700));

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

    let bin = crate::claude::code::claude_bin()?;
    let mut cmd = Command::new(bin);
    cmd.args(["auth", "login"])
        .current_dir(&dir)
        .env("TERM", "xterm-256color")
        .env("BROWSER", "echo")
        .stdin(Stdio::from(slave))
        .stdout(Stdio::from(slave_out))
        .stderr(Stdio::from(slave_err));

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
            return Err(format!("Không chạy được Claude CLI: {e}"));
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
            return Err("Không đọc được PTY của Claude CLI".into());
        }
    };
    let out = Arc::new(Mutex::new(Output::default()));
    spawn_reader(reader, Arc::clone(&out));

    Ok(Session {
        id,
        child,
        writer: master,
        out,
        login_url: String::new(),
        dir,
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
                Err(_) => break,
            }
        }
        if let Ok(mut o) = out.lock() {
            o.closed = true;
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extracts_claude_login_url_from_text() {
        let output = b"Opening browser to sign in\xe2\x80\xa6\n\
If the browser didn't open, visit: https://claude.com/cai/oauth/authorize?code=true&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e&response_type=code&redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback&scope=org%3Acreate_api_key\n\
Paste code here if prompted > ";
        let url = find_login_url(output);
        assert!(url.is_some());
        assert!(url
            .unwrap()
            .starts_with("https://claude.com/cai/oauth/authorize?code=true"));
    }

    #[test]
    fn extracts_code_from_callback_url() {
        let raw = "https://platform.claude.com/oauth/code/callback?code=auth_code_12345&state=xyz";
        let code = validate_code(raw).unwrap();
        assert_eq!(code, "auth_code_12345");
    }

    #[test]
    fn validates_plain_code() {
        let raw = "auth_code_plain_123";
        let code = validate_code(raw).unwrap();
        assert_eq!(code, "auth_code_plain_123");
    }
}
