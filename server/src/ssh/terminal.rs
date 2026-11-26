//! Phiên terminal SSH tương tác: `ssh -tt` chạy trên một PTY của server.
//!
//! - Mỗi phiên có một PTY (master/slave). `ssh` nhận slave làm stdin/stdout/stderr và controlling terminal.
//! - Thread đọc master đẩy dữ liệu ra client qua Socket.IO (`ssh:data`), mã hóa base64.
//! - Client gửi phím (`ssh:input`), đổi kích thước (`ssh:resize`), đóng (`ssh:close`).
//! - Khi `ssh` hỏi mật khẩu trên PTY ([`super::prompt`]): mật khẩu đã lưu được gửi tự động; nếu chưa có,
//!   server phát `ssh:password:request` và chờ client gửi `ssh:password`.
//! - Dữ liệu chỉ phát tới room `ssh:<sessionId>`, mà chỉ socket mở phiên mới join vào.

use super::prompt::{PromptDetector, PromptKind, Signal, Source};
use crate::chat::AppState;
use crate::infra::store;
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
/// Số lần `ssh` được hỏi lại mật khẩu trong một phiên (lần sai thì ssh hỏi lại trên PTY)
const NUMBER_OF_PASSWORD_PROMPTS: u8 = 3;

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
    /// Theo dõi prompt mật khẩu. Không có với phiên không hỏi mật khẩu (agy đăng nhập...)
    detect_password: bool,
    prompt: PromptDetector,
    /// Đang chờ người dùng nhập mật khẩu (đã phát `ssh:password:request`)
    awaiting_password: bool,
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

/// Kết quả gắn lại phiên: đầu ra đã đệm và trạng thái mật khẩu
pub struct AttachInfo {
    pub host_name: String,
    pub buffer: Vec<u8>,
    /// Đang chờ mật khẩu: client phải hiện hộp thoại nhập
    pub awaiting_password: bool,
    /// Lần nhập trước bị từ chối
    pub password_wrong: bool,
    /// Loại prompt đang chờ (`ssh` | `sudo`)
    pub password_kind: &'static str,
}

/// Đầu ra đã đệm của phiên, để client vẽ lại màn hình khi gắn vào. Đánh dấu phiên còn được dùng.
pub fn attach(session_id: &str) -> Result<AttachInfo, String> {
    let mut map = sessions().lock().map_err(|_| "Lỗi khóa phiên")?;
    let s = map.get_mut(session_id).ok_or("Phiên đã kết thúc")?;
    s.last_active = Instant::now();
    Ok(AttachInfo {
        host_name: s.host_name.clone(),
        buffer: s.scrollback.iter().copied().collect(),
        awaiting_password: s.awaiting_password,
        password_wrong: s.prompt.rejected,
        password_kind: s.prompt.kind().label(),
    })
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

static SESSIONS: OnceLock<Mutex<HashMap<String, TermSession>>> = OnceLock::new();

fn sessions() -> &'static Mutex<HashMap<String, TermSession>> {
    SESSIONS.get_or_init(|| Mutex::new(HashMap::new()))
}

enum Event {
    Data(Vec<u8>),
    /// `ssh` cần mật khẩu mà server chưa có; `wrong`: lần trước bị từ chối
    PasswordRequest {
        wrong: bool,
        kind: PromptKind,
    },
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
    // Máy này: shell của server trong PTY, không qua ssh
    if crate::ssh::hosts::is_local(row) {
        return open_local(
            state.io.clone(),
            session_id,
            &crate::ssh::hosts::local_shell(),
            &["-l", "-i"],
            &[],
            cols,
            rows,
            row.id,
            &row.name,
        );
    }
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

    let number_of_prompts = format!("NumberOfPasswordPrompts={NUMBER_OF_PASSWORD_PROMPTS}");
    let mut cmd = Command::new("ssh");
    cmd.arg("-tt")
        .arg("-p")
        .arg(row.port.to_string())
        .args(["-o", "StrictHostKeyChecking=accept-new"])
        .args(["-o", "ConnectTimeout=10"])
        .args(["-o", number_of_prompts.as_str()])
        // Không dùng askpass: mật khẩu được trả lời trên PTY (xem `PromptDetector`)
        .env("SSH_ASKPASS_REQUIRE", "never");

    if !row.private_key.trim().is_empty() {
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
        // Không có khóa: ssh hỏi mật khẩu trên PTY, server (hoặc người dùng) trả lời
        cmd.args(["-o", "PubkeyAuthentication=no"]).args([
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
        Some(PromptKind::Ssh),
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
    prompt_kind: Option<PromptKind>,
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
    let host_label = host_name.clone();
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
                detect_password: prompt_kind.is_some(),
                prompt: PromptDetector::new(prompt_kind.unwrap_or_default()),
                awaiting_password: false,
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
                Event::PasswordRequest { wrong, kind } => {
                    let _ = ns.to(room.clone()).emit(
                        "ssh:password:request",
                        &json!({
                            "sessionId": sid,
                            "hostId": host_id,
                            "hostName": host_label,
                            "wrong": wrong,
                            "kind": kind.label(),
                        }),
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
    envs: &[(&str, &str)],
    cols: u16,
    rows: u16,
    host_id: i64,
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
        .envs(envs.iter().copied())
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
    // Shell của máy này không phải ssh: không theo dõi prompt mật khẩu (sudo, passwd...)
    spawn_pty(
        io,
        session_id,
        cmd,
        cols,
        rows,
        tmp_dir,
        host_id,
        host_name.to_string(),
        // Shell của máy này: hỏi mật khẩu sudo (không hỏi ssh/passwd)
        Some(PromptKind::Sudo),
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
                if tx.send(Event::Data(buf[..n].to_vec())).is_err() {
                    break;
                }
                for ev in ingest_output(&session_id, &buf[..n]) {
                    if tx.send(ev).is_err() {
                        break;
                    }
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

/// Đầu ra của PTY: lưu scrollback, theo dõi prompt mật khẩu, tự trả lời khi đã có mật khẩu lưu.
/// Trả về các sự kiện cần gửi tới client.
fn ingest_output(session_id: &str, bytes: &[u8]) -> Vec<Event> {
    let Ok(mut map) = sessions().lock() else {
        return Vec::new();
    };
    let Some(s) = map.get_mut(session_id) else {
        return Vec::new();
    };
    s.scrollback.extend(bytes.iter().copied());
    let overflow = s.scrollback.len().saturating_sub(SCROLLBACK_BYTES);
    if overflow > 0 {
        s.scrollback.drain(..overflow);
    }
    if !s.detect_password {
        return Vec::new();
    }
    let mut events = Vec::new();
    let kind = s.prompt.kind();
    for sig in s.prompt.feed(bytes) {
        match sig {
            Signal::Rejected(Source::Stored) => {
                // Mật khẩu đã lưu bị từ chối: xóa khỏi DB, không tự dùng lại
                store::set_ssh_password(s.host_id, "");
            }
            Signal::Rejected(Source::Typed) => {}
            Signal::Prompt => {
                // ssh và sudo: có mật khẩu đã lưu thì tự điền; chưa có hoặc đã bị từ chối thì hỏi lại
                let stored = store::get_ssh_host(s.host_id)
                    .map(|r| r.password)
                    .unwrap_or_default();
                let auto = !stored.is_empty()
                    && !s.prompt.rejected
                    && write_line(&mut s.master, &stored).is_ok();
                if auto {
                    s.prompt.on_submit(Source::Stored);
                } else {
                    s.awaiting_password = true;
                    events.push(Event::PasswordRequest {
                        wrong: s.prompt.rejected,
                        kind,
                    });
                }
            }
        }
    }
    events
}

/// Ghi một dòng (kèm ký tự xuống dòng) vào PTY
fn write_line(master: &mut File, text: &str) -> std::io::Result<()> {
    master.write_all(text.as_bytes())?;
    master.write_all(b"\n")
}

/// Mật khẩu người dùng nhập khi `ssh` hỏi. Gửi vào PTY; nếu `save` thì lưu vào DB của máy.
pub fn submit_password(session_id: &str, password: &str, save: bool) -> Result<(), String> {
    let pw = password.trim_end_matches(['\r', '\n']);
    if pw.is_empty() {
        return Err("Mật khẩu trống".into());
    }
    let mut map = sessions().lock().map_err(|_| "Lỗi khóa phiên")?;
    let s = map.get_mut(session_id).ok_or("Phiên đã kết thúc")?;
    if !s.awaiting_password {
        return Err("Phiên không đang chờ mật khẩu".into());
    }
    if save && !store::set_ssh_password(s.host_id, pw) {
        return Err("Không lưu được mật khẩu".into());
    }
    write_line(&mut s.master, pw).map_err(|e| format!("Không ghi được vào PTY: {e}"))?;
    s.awaiting_password = false;
    s.last_active = Instant::now();
    s.prompt
        .on_submit(if save { Source::Stored } else { Source::Typed });
    Ok(())
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
    // Terminal đăng nhập agy giữ kích thước rộng cố định: thu hẹp (màn điện thoại) làm TUI ngắt link OAuth
    if crate::agy_auth::is_login_session(session_id) {
        return Ok(());
    }
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
