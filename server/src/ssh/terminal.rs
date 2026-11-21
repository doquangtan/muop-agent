//! Phiên terminal SSH tương tác: `ssh -tt` chạy trên một PTY của server.
//!
//! - Mỗi phiên có một PTY (master/slave). `ssh` nhận slave làm stdin/stdout/stderr và controlling terminal.
//! - Thread đọc master đẩy dữ liệu ra client qua Socket.IO (`ssh:data`), mã hóa base64.
//! - Client gửi phím (`ssh:input`), đổi kích thước (`ssh:resize`), đóng (`ssh:close`).
//! - Dữ liệu chỉ phát tới room `ssh:<sessionId>`, mà chỉ socket mở phiên mới join vào.
//! - Mật khẩu đi qua biến môi trường cho `SSH_ASKPASS`; key tạm nằm trong thư mục 0700 và bị xóa khi phiên kết thúc.

use crate::chat::AppState;
use crate::infra::store::SshHostRow;
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use serde::Serialize;
use serde_json::json;
use socketioxide::SocketIo;
use std::collections::{HashMap, VecDeque};
use std::fs::{self, File};
use std::io::{Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::process::CommandExt;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};
use tokio::sync::mpsc;

/// Số phiên tối đa cùng lúc
const MAX_SESSIONS: usize = 8;
/// Đầu ra giữ lại để gắn lại phiên (khi app đã thoát)
const SCROLLBACK_BYTES: usize = 256 * 1024;
/// Phiên không có tương tác quá lâu thì tự đóng
pub const IDLE_TIMEOUT: Duration = Duration::from_secs(6 * 3600);

struct TermSession {
    /// Đầu ghi vào PTY (cũng dùng cho ioctl đổi kích thước)
    master: File,
    pid: i32,
    tmp_dir: PathBuf,
    host_id: i64,
    host_name: String,
    started_at: String,
    last_active: Instant,
    /// Đầu ra gần nhất, gửi lại khi client gắn vào phiên
    scrollback: VecDeque<u8>,
}

/// Thông tin một phiên đang chạy (gửi xuống client)
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SshSessionInfo {
    pub session_id: String,
    pub host_id: i64,
    pub host_name: String,
    pub started_at: String,
}

/// Danh sách phiên đang chạy
pub fn list() -> Vec<SshSessionInfo> {
    let Ok(map) = sessions().lock() else {
        return Vec::new();
    };
    let mut items: Vec<SshSessionInfo> = map
        .iter()
        .map(|(id, s)| SshSessionInfo {
            session_id: id.clone(),
            host_id: s.host_id,
            host_name: s.host_name.clone(),
            started_at: s.started_at.clone(),
        })
        .collect();
    items.sort_by(|a, b| a.started_at.cmp(&b.started_at));
    items
}

/// Đầu ra đã đệm của phiên, để client vẽ lại màn hình khi gắn vào. Đánh dấu phiên còn được dùng.
pub fn attach(session_id: &str) -> Result<(String, Vec<u8>), String> {
    let mut map = sessions().lock().map_err(|_| "Lỗi khóa phiên")?;
    let s = map.get_mut(session_id).ok_or("Phiên đã kết thúc")?;
    s.last_active = Instant::now();
    Ok((s.host_name.clone(), s.scrollback.iter().copied().collect()))
}

/// Đóng các phiên không được dùng quá `IDLE_TIMEOUT`. Trả về số phiên đã yêu cầu đóng.
pub fn reap_idle() -> usize {
    let idle: Vec<String> = match sessions().lock() {
        Ok(map) => map
            .iter()
            .filter(|(_, s)| s.last_active.elapsed() > IDLE_TIMEOUT)
            .map(|(id, _)| id.clone())
            .collect(),
        Err(_) => return 0,
    };
    for id in &idle {
        close(id);
    }
    idle.len()
}

fn append_scrollback(session_id: &str, bytes: &[u8]) {
    if let Ok(mut map) = sessions().lock() {
        if let Some(s) = map.get_mut(session_id) {
            s.scrollback.extend(bytes.iter().copied());
            let overflow = s.scrollback.len().saturating_sub(SCROLLBACK_BYTES);
            if overflow > 0 {
                s.scrollback.drain(..overflow);
            }
        }
    }
}

static SESSIONS: OnceLock<Mutex<HashMap<String, TermSession>>> = OnceLock::new();

fn sessions() -> &'static Mutex<HashMap<String, TermSession>> {
    SESSIONS.get_or_init(|| Mutex::new(HashMap::new()))
}

enum Event {
    Data(Vec<u8>),
    Closed(Option<i32>),
}

pub fn new_session_id() -> String {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    format!("ssh-{}-{}", std::process::id(), nanos)
}

pub fn room_for(session_id: &str) -> String {
    format!("ssh:{session_id}")
}

fn clamp_size(cols: u16, rows: u16) -> (u16, u16) {
    (cols.clamp(10, 500), rows.clamp(4, 200))
}

fn make_private_dir() -> Option<PathBuf> {
    let dir = std::env::temp_dir().join(format!("muop-sshterm-{}", new_session_id()));
    fs::create_dir(&dir).ok()?;
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).ok()?;
    Some(dir)
}

fn winsize(cols: u16, rows: u16) -> libc::winsize {
    libc::winsize {
        ws_row: rows,
        ws_col: cols,
        ws_xpixel: 0,
        ws_ypixel: 0,
    }
}

/// Mở phiên `ssh -tt` chạy shell tương tác của user và chuyển tiếp dữ liệu tới room của phiên.
pub fn open(
    state: &AppState,
    session_id: &str,
    row: &SshHostRow,
    cols: u16,
    rows: u16,
) -> Result<(), String> {
    open_with(state.io.clone(), session_id, row, cols, rows, None)
}

/// Như [`open`], nhưng chạy `remote_command` trên máy đích thay cho shell (ví dụ `exec '/path/agy'`).
pub fn open_with(
    io: SocketIo,
    session_id: &str,
    row: &SshHostRow,
    cols: u16,
    rows: u16,
    remote_command: Option<String>,
) -> Result<(), String> {
    if row.username.is_empty() || row.host.is_empty() {
        return Err("Thiếu host hoặc username".into());
    }
    let use_key = row.password.is_empty() && !row.private_key.trim().is_empty();
    if !use_key && row.password.is_empty() {
        return Err("Máy này chưa có mật khẩu hoặc private key".into());
    }
    {
        let map = sessions().lock().map_err(|_| "Lỗi khóa phiên")?;
        if map.len() >= MAX_SESSIONS {
            return Err("Đã đạt số phiên SSH tối đa".into());
        }
    }

    let tmp_dir = make_private_dir().ok_or("Không tạo được thư mục tạm")?;
    let cleanup = |dir: &PathBuf| {
        let _ = fs::remove_dir_all(dir);
    };

    let mut cmd = Command::new("ssh");
    cmd.arg("-tt")
        .arg("-p")
        .arg(row.port.to_string())
        .args(["-o", "StrictHostKeyChecking=accept-new"])
        .args(["-o", "ConnectTimeout=10"])
        .args(["-o", "NumberOfPasswordPrompts=1"]);

    if use_key {
        let key_path = tmp_dir.join("key");
        let mut key = row.private_key.trim_end().to_string();
        key.push('\n');
        if fs::write(&key_path, key).is_err()
            || fs::set_permissions(&key_path, fs::Permissions::from_mode(0o600)).is_err()
        {
            cleanup(&tmp_dir);
            return Err("Không ghi được private key tạm".into());
        }
        cmd.arg("-i")
            .arg(&key_path)
            .args(["-o", "IdentitiesOnly=yes"]);
    } else {
        let askpass = tmp_dir.join("askpass.sh");
        if fs::write(
            &askpass,
            "#!/bin/sh\nprintf '%s\\n' \"$MUOP_SSH_PASSWORD\"\n",
        )
        .is_err()
            || fs::set_permissions(&askpass, fs::Permissions::from_mode(0o700)).is_err()
        {
            cleanup(&tmp_dir);
            return Err("Không tạo được script xác thực tạm".into());
        }
        cmd.env("SSH_ASKPASS", &askpass)
            .env("SSH_ASKPASS_REQUIRE", "force")
            .env("MUOP_SSH_PASSWORD", &row.password)
            .args(["-o", "PubkeyAuthentication=no"])
            .args([
                "-o",
                "PreferredAuthentications=password,keyboard-interactive",
            ]);
    }
    // Shell tương tác của user (đọc .bashrc) thay cho shell đăng nhập (chỉ đọc .bash_profile)
    cmd.arg(format!("{}@{}", row.username, row.host))
        .arg(remote_command.unwrap_or_else(|| "exec \"${SHELL:-/bin/sh}\" -i".to_string()))
        .env("TERM", "xterm-256color");

    spawn_pty(
        io,
        session_id,
        cmd,
        cols,
        rows,
        tmp_dir,
        row.id,
        row.name.clone(),
    )
}

/// PTY, tiến trình con, đăng ký phiên và luồng đẩy dữ liệu tới client.
/// Dùng chung cho `ssh` (máy đích) và chương trình chạy trực tiếp trên server ([`open_local`]).
#[allow(clippy::too_many_arguments)]
fn spawn_pty(
    io: SocketIo,
    session_id: &str,
    mut cmd: Command,
    cols: u16,
    rows: u16,
    tmp_dir: PathBuf,
    host_id: i64,
    host_name: String,
) -> Result<(), String> {
    let cleanup = |dir: &PathBuf| {
        let _ = fs::remove_dir_all(dir);
    };
    // PTY: master giữ ở server, slave làm stdio của ssh
    let (cols, rows) = clamp_size(cols, rows);
    let mut ws = winsize(cols, rows);
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
        cleanup(&tmp_dir);
        return Err("Không mở được PTY".into());
    }
    let master = unsafe { OwnedFd::from_raw_fd(master_fd) };
    let slave = unsafe { OwnedFd::from_raw_fd(slave_fd) };
    let (slave_out, slave_err) = match (slave.try_clone(), slave.try_clone()) {
        (Ok(a), Ok(b)) => (a, b),
        _ => {
            cleanup(&tmp_dir);
            return Err("Không nhân được PTY".into());
        }
    };
    cmd.stdin(Stdio::from(slave))
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

    let child: Child = match cmd.spawn() {
        Ok(c) => c,
        Err(e) => {
            cleanup(&tmp_dir);
            return Err(format!("Không chạy được ssh: {e}"));
        }
    };
    let pid = child.id() as i32;
    let master = File::from(master);
    let reader = match master.try_clone() {
        Ok(r) => r,
        Err(_) => {
            unsafe { libc::kill(pid, libc::SIGKILL) };
            cleanup(&tmp_dir);
            return Err("Không đọc được PTY".into());
        }
    };

    let room = room_for(session_id);
    if let Ok(mut map) = sessions().lock() {
        map.insert(
            session_id.to_string(),
            TermSession {
                master,
                pid,
                tmp_dir: tmp_dir.clone(),
                host_id,
                host_name,
                started_at: chrono::Utc::now().to_rfc3339(),
                last_active: Instant::now(),
                scrollback: VecDeque::new(),
            },
        );
    }

    // Chuyển dữ liệu PTY tới client qua kênh bất đồng bộ
    let (tx, mut rx) = mpsc::unbounded_channel::<Event>();
    let sid_for_thread = session_id.to_string();
    std::thread::spawn(move || read_loop(sid_for_thread, reader, child, tx));

    let io_task = io;
    let sid = session_id.to_string();
    tokio::spawn(async move {
        while let Some(ev) = rx.recv().await {
            let Some(ns) = io_task.of("/") else {
                continue;
            };
            match ev {
                Event::Data(bytes) => {
                    let _ = ns.to(room.clone()).emit(
                        "ssh:data",
                        &json!({"sessionId": sid, "data": B64.encode(&bytes)}),
                    );
                }
                Event::Closed(code) => {
                    let _ = ns
                        .to(room.clone())
                        .emit("ssh:closed", &json!({"sessionId": sid, "exitCode": code}));
                    break;
                }
            }
        }
    });

    Ok(())
}

/// "SSH ảo": chạy `program` trực tiếp trong PTY của server, không qua `ssh`.
/// Tiến trình kế thừa môi trường của server (cùng keyring với các lệnh agy khác). Biến `SSH_*`
/// bị gỡ để agy không chuyển sang lưu token vào file ("file-based token storage because SSH session
/// detected"), nên token đăng nhập nằm đúng chỗ server đọc.
pub fn open_local(
    io: SocketIo,
    session_id: &str,
    program: &std::path::Path,
    args: &[&str],
    cols: u16,
    rows: u16,
    host_name: &str,
) -> Result<(), String> {
    {
        let map = sessions().lock().map_err(|_| "Lỗi khóa phiên")?;
        if map.len() >= MAX_SESSIONS {
            return Err("Đã đạt số phiên SSH tối đa".into());
        }
    }
    let tmp_dir = make_private_dir().ok_or("Không tạo được thư mục tạm")?;
    let mut cmd = Command::new(program);
    cmd.args(args)
        .env("TERM", "xterm-256color")
        .env_remove("SSH_CLIENT")
        .env_remove("SSH_CONNECTION")
        .env_remove("SSH_TTY");
    if let Some(home) = std::env::var_os("HOME")
        .map(PathBuf::from)
        .filter(|p| p.is_dir())
    {
        cmd.current_dir(home);
    }
    spawn_pty(
        io,
        session_id,
        cmd,
        cols,
        rows,
        tmp_dir,
        0,
        host_name.to_string(),
    )
}

/// Đọc master cho tới khi PTY đóng, rồi thu hồi tiến trình và dọn phiên
fn read_loop(
    session_id: String,
    mut reader: File,
    mut child: Child,
    tx: mpsc::UnboundedSender<Event>,
) {
    let mut buf = [0u8; 8192];
    loop {
        match reader.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => {
                append_scrollback(&session_id, &buf[..n]);
                if tx.send(Event::Data(buf[..n].to_vec())).is_err() {
                    break;
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(_) => break,
        }
    }
    let code = child.wait().ok().and_then(|s| s.code());
    let finished = sessions()
        .lock()
        .ok()
        .and_then(|mut map| map.remove(&session_id));
    if let Some(s) = finished {
        let _ = fs::remove_dir_all(&s.tmp_dir);
    }
    let _ = tx.send(Event::Closed(code));
}

/// Ghi dữ liệu bàn phím vào PTY
pub fn write_input(session_id: &str, data_b64: &str) -> Result<(), String> {
    let bytes = B64.decode(data_b64).map_err(|_| "Dữ liệu không hợp lệ")?;
    let mut map = sessions().lock().map_err(|_| "Lỗi khóa phiên")?;
    let s = map.get_mut(session_id).ok_or("Phiên đã kết thúc")?;
    s.last_active = Instant::now();
    s.master
        .write_all(&bytes)
        .map_err(|e| format!("Không ghi được vào PTY: {e}"))
}

/// Đổi kích thước terminal (gửi SIGWINCH cho ssh qua ioctl)
pub fn resize(session_id: &str, cols: u16, rows: u16) -> Result<(), String> {
    let (cols, rows) = clamp_size(cols, rows);
    let map = sessions().lock().map_err(|_| "Lỗi khóa phiên")?;
    let s = map.get(session_id).ok_or("Phiên đã kết thúc")?;
    let ws = winsize(cols, rows);
    let rc = unsafe { libc::ioctl(s.master.as_raw_fd(), libc::TIOCSWINSZ as _, &ws) };
    if rc != 0 {
        return Err("Không đổi được kích thước".into());
    }
    Ok(())
}

/// Yêu cầu đóng phiên. Thread đọc sẽ tự dọn khi ssh thoát.
pub fn close(session_id: &str) -> bool {
    let pid = sessions()
        .lock()
        .ok()
        .and_then(|map| map.get(session_id).map(|s| s.pid));
    match pid {
        Some(pid) => {
            unsafe { libc::kill(pid, libc::SIGHUP) };
            true
        }
        None => false,
    }
}
