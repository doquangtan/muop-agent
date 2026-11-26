//! SFTP cho máy SSH đã lưu.
//!
//! - Mỗi máy có tối đa một phiên: một kết nối ControlMaster (`ssh -MNf`) giữ socket trong thư mục tạm 0700.
//! - Mỗi thao tác là một lệnh batch `sftp -b -` chạy qua socket đó (không hỏi mật khẩu lần nữa).
//! - Mật khẩu xác thực dùng cùng luồng với "Chạy lệnh": mật khẩu đã lưu được dùng trước; thiếu hoặc sai
//!   thì trả `needsPassword` để app hỏi người dùng rồi mở lại phiên.
//! - "Máy này" (loopback, đúng user của server) không qua ssh: thao tác trực tiếp trên hệ thống file
//!   (`local.rs`), nên app khác kết nối tới server này cũng tải được file mà không cần sshd.
//! - Tải xuống (`download.rs`) và đóng gói zip (`zip.rs`) dùng chung cho cả hai loại phiên.

pub mod download;
pub mod listing;
pub mod local;
pub mod zip;

use crate::infra::store::{self, SshHostRow};
use crate::ssh::hosts::{apply_exec_auth, remove_auth_files};
use listing::{join, parse_ls, parse_pwd, quote, quote_local, sftp_error, RemoteEntry};
use std::collections::{HashMap, VecDeque};
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};
use std::time::{Duration, Instant};
use tokio::io::AsyncWriteExt;
use tokio::process::Command;
use tokio::sync::Mutex as AsyncMutex;

const MAX_SESSIONS: usize = 8;
/// Phiên không dùng quá lâu thì đóng (kết nối giữ sẵn trên máy đích)
pub const IDLE_TIMEOUT: Duration = Duration::from_secs(6 * 3600);
const CONNECT_TIMEOUT: Duration = Duration::from_secs(40);
const OP_TIMEOUT: Duration = Duration::from_secs(300);
/// Giới hạn đọc để sửa trong app
pub const MAX_READ_BYTES: u64 = 1024 * 1024;
/// Giới hạn một lần tải lên (dữ liệu base64 nằm trong body REST)
pub const MAX_UPLOAD_BYTES: usize = 50 * 1024 * 1024;
/// Số mục tối đa khi xóa đệ quy một lần
const MAX_TREE_ENTRIES: usize = 5000;
const DIR_PREFIX: &str = "muop-sftp-sess-";
const ASKED_FILE: &str = "asked";

/// Lỗi của một thao tác, kèm cờ để app biết phải làm gì tiếp
#[derive(Debug, Default)]
pub struct Failure {
    pub message: String,
    /// Máy yêu cầu mật khẩu (chưa có hoặc sai): app hỏi rồi mở lại phiên
    pub needs_password: bool,
    /// Lần nhập mật khẩu trước bị từ chối
    pub password_wrong: bool,
    /// Đích đã tồn tại (khi tải lên không ghi đè)
    pub exists: bool,
    /// Phiên không còn (đã đóng hoặc server khởi động lại): app mở lại phiên
    pub gone: bool,
}

impl Failure {
    fn msg(m: impl Into<String>) -> Self {
        Failure {
            message: m.into(),
            ..Default::default()
        }
    }

    fn gone() -> Self {
        Failure {
            message: "Phiên SFTP đã kết thúc, hãy mở lại".into(),
            gone: true,
            ..Default::default()
        }
    }
}

/// Thông tin phiên gửi cho app
#[derive(Debug, Clone)]
pub struct SessionInfo {
    pub session_id: String,
    pub host_id: i64,
    pub host_name: String,
    pub home: String,
    pub started_at: String,
}

struct Inner {
    last_active: Instant,
    home: String,
}

pub struct Session {
    id: String,
    host: SshHostRow,
    /// "Máy này": thao tác trực tiếp trên hệ thống file, không có kết nối ssh
    local: bool,
    started_at: String,
    /// Thư mục 0700: socket ControlMaster, file tạm khi tải lên, đánh dấu askpass
    dir: PathBuf,
    ctl: PathBuf,
    /// Giữ khi thiết lập/kết nối lại để hai thao tác không cùng tạo một socket
    connect_lock: AsyncMutex<()>,
    inner: Mutex<Inner>,
}

static SESSIONS: OnceLock<Mutex<HashMap<String, Arc<Session>>>> = OnceLock::new();
static OPEN_LOCK: OnceLock<AsyncMutex<()>> = OnceLock::new();

fn registry() -> &'static Mutex<HashMap<String, Arc<Session>>> {
    SESSIONS.get_or_init(|| Mutex::new(HashMap::new()))
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

fn get(id: &str) -> Result<Arc<Session>, Failure> {
    lock(registry()).get(id).cloned().ok_or_else(Failure::gone)
}

fn find_by_host(host_id: i64) -> Option<Arc<Session>> {
    lock(registry())
        .values()
        .find(|s| s.host.id == host_id)
        .cloned()
}

fn new_id() -> String {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    format!("sftp-{}-{}", std::process::id(), nanos)
}

fn target(row: &SshHostRow) -> String {
    format!("{}@{}", row.username, row.host)
}

fn touch(s: &Session) {
    lock(&s.inner).last_active = Instant::now();
}

fn home_of(s: &Session) -> String {
    lock(&s.inner).home.clone()
}

/// Thông báo ssh lỗi dịch sang tiếng Việt
fn connect_error(stderr: &str) -> String {
    let lower = stderr.to_lowercase();
    if lower.contains("permission denied") {
        "Sai tài khoản hoặc khóa SSH".into()
    } else if lower.contains("could not resolve") || lower.contains("name or service not known") {
        "Không tìm thấy địa chỉ máy".into()
    } else if lower.contains("connection refused") {
        "Máy từ chối kết nối (kiểm tra sshd và cổng)".into()
    } else if lower.contains("timed out") || lower.contains("no route") {
        "Không kết nối được tới máy".into()
    } else {
        stderr
            .lines()
            .rev()
            .find(|l| !l.trim().is_empty())
            .map(|l| l.trim().to_string())
            .unwrap_or_else(|| "Không kết nối được SSH".into())
    }
}

/// Kết nối ControlMaster còn sống không
async fn master_alive(s: &Session) -> bool {
    tokio::time::timeout(
        Duration::from_secs(5),
        Command::new("ssh")
            .arg("-S")
            .arg(&s.ctl)
            .args(["-O", "check"])
            .arg(target(&s.host))
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status(),
    )
    .await
    .ok()
    .and_then(|r| r.ok())
    .map(|st| st.success())
    .unwrap_or(false)
}

/// Thiết lập kết nối ControlMaster. Mật khẩu: `typed` nếu có, không thì mật khẩu đã lưu.
/// Với `save`, mật khẩu gõ vào được lưu trước; sai thì xóa mật khẩu đã lưu (cùng quy tắc với Chạy lệnh).
async fn connect(s: &Session, typed: &str, save: bool) -> Result<(), Failure> {
    // Đọc lại từ DB: mật khẩu đã lưu có thể vừa đổi
    let row = store::get_ssh_host(s.host.id).unwrap_or_else(|| s.host.clone());
    let typed_given = !typed.is_empty();
    if typed_given && save && !store::set_ssh_password(row.id, typed) {
        return Err(Failure::msg("Không lưu được mật khẩu"));
    }
    let stored_used = if typed_given {
        save
    } else {
        !row.password.is_empty()
    };
    let password = if typed_given {
        typed.to_string()
    } else {
        row.password.clone()
    };

    let _ = fs::remove_file(&s.ctl);
    let asked_path = s.dir.join(ASKED_FILE);
    let _ = fs::remove_file(&asked_path);
    let mut cmd = Command::new("ssh");
    cmd.arg("-M")
        .arg("-N")
        .arg("-f")
        .arg("-S")
        .arg(&s.ctl)
        .arg("-p")
        .arg(row.port.to_string())
        .args(["-o", "StrictHostKeyChecking=accept-new"])
        .args(["-o", "ConnectTimeout=10"])
        .args(["-o", "NumberOfPasswordPrompts=1"])
        // Phát hiện kết nối chết để lần sau kết nối lại
        .args(["-o", "ServerAliveInterval=30"])
        .args(["-o", "ServerAliveCountMax=3"])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    apply_exec_auth(&mut cmd, &row, &s.dir, &password).map_err(Failure::msg)?;
    cmd.arg(target(&row));

    let child = cmd
        .spawn()
        .map_err(|e| Failure::msg(format!("Không chạy được ssh: {e}")))?;
    let res = tokio::time::timeout(CONNECT_TIMEOUT, child.wait_with_output()).await;
    remove_auth_files(&s.dir);
    let asked = asked_path.exists();
    let _ = fs::remove_file(&asked_path);
    let out = match res {
        Ok(Ok(out)) => out,
        Ok(Err(e)) => return Err(Failure::msg(format!("Lỗi khi chạy ssh: {e}"))),
        Err(_) => return Err(Failure::msg("Hết thời gian kết nối SSH")),
    };
    if asked {
        return Err(Failure {
            message: "Máy yêu cầu mật khẩu".into(),
            needs_password: true,
            ..Default::default()
        });
    }
    if out.status.success() {
        return Ok(());
    }
    let stderr = String::from_utf8_lossy(&out.stderr).into_owned();
    let rejected = !password.is_empty() && stderr.contains("Permission denied");
    if rejected {
        if stored_used {
            store::set_ssh_password(row.id, "");
        }
        return Err(Failure {
            message: "Sai mật khẩu".into(),
            needs_password: true,
            password_wrong: true,
            ..Default::default()
        });
    }
    Err(Failure::msg(connect_error(&stderr)))
}

/// Bảo đảm kết nối đang sống; nếu rớt thì kết nối lại bằng mật khẩu đã lưu.
async fn ensure_connected(s: &Session) -> Result<(), Failure> {
    let _guard = s.connect_lock.lock().await;
    if master_alive(s).await {
        return Ok(());
    }
    connect(s, "", false).await
}

struct SftpOut {
    ok: bool,
    stdout: String,
    stderr: String,
}

/// Chạy một batch sftp qua socket của phiên
async fn sftp_once(s: &Session, batch: &str) -> Result<SftpOut, String> {
    let mut cmd = Command::new("sftp");
    cmd.args(["-q", "-b", "-"])
        .arg("-P")
        .arg(s.host.port.to_string())
        .args(["-o", "BatchMode=yes"])
        .args(["-o", "ControlMaster=no"])
        .arg("-o")
        .arg(format!("ControlPath={}", s.ctl.display()))
        .args(["-o", "ConnectTimeout=10"])
        .args(["-o", "StrictHostKeyChecking=accept-new"])
        .arg(target(&s.host))
        // Không bao giờ hỏi mật khẩu từ đây: nếu kết nối đã mất thì báo lỗi
        .env("SSH_ASKPASS_REQUIRE", "never")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    let mut child = cmd
        .spawn()
        .map_err(|e| format!("Không chạy được sftp: {e}"))?;
    if let Some(mut stdin) = child.stdin.take() {
        let _ = stdin.write_all(batch.as_bytes()).await;
        drop(stdin);
    }
    let out = tokio::time::timeout(OP_TIMEOUT, child.wait_with_output())
        .await
        .map_err(|_| "Hết thời gian chờ SFTP".to_string())?
        .map_err(|e| format!("Lỗi khi chạy sftp: {e}"))?;
    Ok(SftpOut {
        ok: out.status.success(),
        stdout: String::from_utf8_lossy(&out.stdout).into_owned(),
        stderr: String::from_utf8_lossy(&out.stderr).into_owned(),
    })
}

/// Chạy batch trên máy đích. Nếu kết nối rớt giữa chừng thì kết nối lại và chạy lại một lần.
async fn run(s: &Session, batch: &str) -> Result<String, Failure> {
    ensure_connected(s).await?;
    touch(s);
    let first = sftp_once(s, batch).await.map_err(Failure::msg)?;
    if first.ok {
        return Ok(first.stdout);
    }
    if master_alive(s).await {
        return Err(Failure::msg(sftp_error(&first.stderr)));
    }
    ensure_connected(s).await?;
    let second = sftp_once(s, batch).await.map_err(Failure::msg)?;
    if second.ok {
        return Ok(second.stdout);
    }
    Err(Failure::msg(sftp_error(&second.stderr)))
}

fn check_path(path: &str) -> Result<(), Failure> {
    listing::check_remote_path(path).map_err(Failure::msg)
}

/// Thư mục cha và tên mục của một đường dẫn tuyệt đối. None với "/".
fn split_parent(path: &str) -> Option<(String, String)> {
    let trimmed = if path.len() > 1 {
        path.trim_end_matches('/')
    } else {
        path
    };
    if trimmed == "/" || trimmed.is_empty() {
        return None;
    }
    let idx = trimmed.rfind('/')?;
    let parent = if idx == 0 {
        "/".to_string()
    } else {
        trimmed[..idx].to_string()
    };
    let name = trimmed[idx + 1..].to_string();
    if name.is_empty() {
        return None;
    }
    Some((parent, name))
}

/// Mục tại đường dẫn (liệt kê thư mục cha rồi tìm tên). None nếu không có.
async fn stat(s: &Session, path: &str) -> Result<Option<RemoteEntry>, Failure> {
    let Some((parent, name)) = split_parent(path) else {
        return Ok(None);
    };
    let entries = list_dir(s, &parent).await?;
    Ok(entries.into_iter().find(|e| e.name == name))
}

async fn list_dir(s: &Session, path: &str) -> Result<Vec<RemoteEntry>, Failure> {
    if s.local {
        return local::list(path).map_err(Failure::msg);
    }
    let q = quote(path).map_err(Failure::msg)?;
    let out = run(s, &format!("ls -la {q}\n")).await?;
    Ok(parse_ls(&out))
}

fn session_of(session_id: &str) -> Result<Arc<Session>, Failure> {
    get(session_id)
}

/// Thư mục đăng nhập của user chạy server (cho "Máy này")
fn local_home() -> String {
    std::env::var("HOME")
        .ok()
        .filter(|h| h.starts_with('/'))
        .unwrap_or_else(|| "/".into())
}

/// Mở (hoặc gắn lại) phiên SFTP cho máy đã lưu. "Máy này" không cần kết nối ssh.
pub async fn open(row: SshHostRow, typed: &str, save: bool) -> Result<SessionInfo, Failure> {
    if row.host.is_empty() || row.username.is_empty() {
        return Err(Failure::msg("Thiếu host hoặc username"));
    }
    let local_host = crate::ssh::hosts::is_local(&row);
    let open_lock = OPEN_LOCK.get_or_init(|| AsyncMutex::new(()));
    let _guard = open_lock.lock().await;

    let (session, is_new) = match find_by_host(row.id) {
        Some(s) => (s, false),
        None => {
            if lock(registry()).len() >= MAX_SESSIONS {
                return Err(Failure::msg("Đã đạt số phiên SFTP tối đa"));
            }
            let id = new_id();
            let dir = std::env::temp_dir().join(format!("{DIR_PREFIX}{id}"));
            if fs::create_dir(&dir).is_err()
                || fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).is_err()
            {
                return Err(Failure::msg("Không tạo được thư mục tạm"));
            }
            let s = Arc::new(Session {
                id: id.clone(),
                host: row.clone(),
                local: local_host,
                started_at: chrono::Utc::now().to_rfc3339(),
                ctl: dir.join("ctl"),
                dir,
                connect_lock: AsyncMutex::new(()),
                inner: Mutex::new(Inner {
                    last_active: Instant::now(),
                    home: String::new(),
                }),
            });
            (s, true)
        }
    };

    if session.local {
        lock(&session.inner).home = local_home();
    } else {
        let connected = {
            let _c = session.connect_lock.lock().await;
            if master_alive(&session).await {
                // Đã có kết nối: nếu người dùng vừa nhập mật khẩu để lưu thì cập nhật luôn
                if !typed.is_empty() && save {
                    store::set_ssh_password(session.host.id, typed);
                }
                Ok(())
            } else {
                connect(&session, typed, save).await
            }
        };
        if let Err(e) = connected {
            if is_new {
                let _ = fs::remove_dir_all(&session.dir);
            }
            return Err(e);
        }

        if home_of(&session).is_empty() {
            match run(&session, "pwd\n").await {
                Ok(out) => {
                    let home = parse_pwd(&out).unwrap_or_else(|| "/".into());
                    lock(&session.inner).home = home;
                }
                Err(f) => {
                    // Phiên mới chưa được đăng ký: đóng kết nối vừa mở để không để socket sót
                    if is_new {
                        shutdown(&session).await;
                    }
                    return Err(f);
                }
            }
        }
    }
    if is_new {
        lock(registry()).insert(session.id.clone(), session.clone());
    }
    touch(&session);
    Ok(SessionInfo {
        session_id: session.id.clone(),
        host_id: session.host.id,
        host_name: session.host.name.clone(),
        home: home_of(&session),
        started_at: session.started_at.clone(),
    })
}

/// Liệt kê thư mục
pub async fn list(session_id: &str, path: &str) -> Result<Vec<RemoteEntry>, Failure> {
    let s = session_of(session_id)?;
    check_path(path)?;
    list_dir(&s, path).await
}

/// Tạo thư mục
pub async fn mkdir(session_id: &str, path: &str) -> Result<(), Failure> {
    let s = session_of(session_id)?;
    check_path(path)?;
    if s.local {
        return local::mkdir(path).map_err(Failure::msg);
    }
    let q = quote(path).map_err(Failure::msg)?;
    run(&s, &format!("mkdir {q}\n")).await?;
    Ok(())
}

/// Đổi tên hoặc di chuyển
pub async fn rename(session_id: &str, from: &str, to: &str) -> Result<(), Failure> {
    let s = session_of(session_id)?;
    check_path(from)?;
    check_path(to)?;
    if split_parent(from).is_none() || split_parent(to).is_none() {
        return Err(Failure::msg("Không đổi tên thư mục gốc"));
    }
    if stat(&s, to).await?.is_some() {
        return Err(Failure {
            message: "Đã có mục cùng tên".into(),
            exists: true,
            ..Default::default()
        });
    }
    if s.local {
        return local::rename(from, to).map_err(Failure::msg);
    }
    let qf = quote(from).map_err(Failure::msg)?;
    let qt = quote(to).map_err(Failure::msg)?;
    run(&s, &format!("rename {qf} {qt}\n")).await?;
    Ok(())
}

/// Xóa file, hoặc thư mục và toàn bộ nội dung
pub async fn delete(session_id: &str, path: &str, is_dir: bool) -> Result<(), Failure> {
    let s = session_of(session_id)?;
    check_path(path)?;
    if split_parent(path).is_none() {
        return Err(Failure::msg("Không xóa thư mục gốc"));
    }
    if s.local {
        return local::delete(path, is_dir).map_err(Failure::msg);
    }
    let q = quote(path).map_err(Failure::msg)?;
    if !is_dir {
        run(&s, &format!("rm {q}\n")).await?;
        return Ok(());
    }
    // Thư mục: duyệt cây, xóa file trước, rồi thư mục từ sâu tới nông (một lần chạy sftp)
    let mut dirs = vec![path.to_string()];
    let mut files: Vec<String> = Vec::new();
    let mut queue = VecDeque::from([path.to_string()]);
    let mut count = 0usize;
    while let Some(d) = queue.pop_front() {
        for e in list_dir(&s, &d).await? {
            count += 1;
            if count > MAX_TREE_ENTRIES {
                return Err(Failure::msg(
                    "Thư mục quá lớn để xóa một lần (tối đa 5000 mục)",
                ));
            }
            let p = join(&d, &e.name);
            if e.is_dir && !e.is_link {
                dirs.push(p.clone());
                queue.push_back(p);
            } else {
                files.push(p);
            }
        }
    }
    let mut batch = String::new();
    for f in &files {
        batch.push_str(&format!("rm {}\n", quote(f).map_err(Failure::msg)?));
    }
    for d in dirs.iter().rev() {
        batch.push_str(&format!("rmdir {}\n", quote(d).map_err(Failure::msg)?));
    }
    run(&s, &batch).await?;
    Ok(())
}

/// Tải lên (ghi đè khi `overwrite`). Dữ liệu đi qua file tạm trong thư mục phiên.
pub async fn upload(
    session_id: &str,
    path: &str,
    data: &[u8],
    overwrite: bool,
) -> Result<(), Failure> {
    let s = session_of(session_id)?;
    check_path(path)?;
    if split_parent(path).is_none() {
        return Err(Failure::msg("Không ghi đè thư mục gốc"));
    }
    if data.len() > MAX_UPLOAD_BYTES {
        return Err(Failure::msg("File quá lớn để tải lên (tối đa 50MB)"));
    }
    if let Some(existing) = stat(&s, path).await? {
        if !overwrite || existing.is_dir {
            return Err(Failure {
                message: if existing.is_dir {
                    "Đã có thư mục cùng tên".into()
                } else {
                    "Đã có file cùng tên".into()
                },
                exists: true,
                ..Default::default()
            });
        }
    }
    if s.local {
        return local::write(path, data, overwrite).map_err(Failure::msg);
    }
    let local = write_temp(&s.dir, data)?;
    let result = async {
        let ql = quote_local(&local).map_err(Failure::msg)?;
        let qr = quote(path).map_err(Failure::msg)?;
        run(&s, &format!("put {ql} {qr}\n")).await.map(|_| ())
    }
    .await;
    let _ = fs::remove_file(&local);
    result
}

/// Đọc nội dung file để sửa (giới hạn 1MB). Trả về (nội dung, có phải nhị phân không).
pub async fn read(session_id: &str, path: &str) -> Result<(Vec<u8>, bool), Failure> {
    let s = session_of(session_id)?;
    check_path(path)?;
    if s.local {
        return local::read(path).map_err(Failure::msg);
    }
    let Some(entry) = stat(&s, path).await? else {
        return Err(Failure::msg("Không tìm thấy file"));
    };
    if entry.is_dir {
        return Err(Failure::msg("Đây là thư mục, không mở để sửa được"));
    }
    if entry.size > MAX_READ_BYTES {
        return Err(Failure::msg("File quá lớn để sửa (tối đa 1MB)"));
    }
    let local = s.dir.join(format!(
        "get-{}",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0)
    ));
    let result = async {
        let ql = quote_local(&local).map_err(Failure::msg)?;
        let qr = quote(path).map_err(Failure::msg)?;
        run(&s, &format!("get {qr} {ql}\n")).await?;
        fs::read(&local).map_err(|e| Failure::msg(format!("Không đọc được file tạm: {e}")))
    }
    .await;
    let _ = fs::remove_file(&local);
    let bytes = result?;
    let binary = bytes.contains(&0) || std::str::from_utf8(&bytes).is_err();
    Ok((bytes, binary))
}

fn write_temp(dir: &Path, data: &[u8]) -> Result<PathBuf, Failure> {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let path = dir.join(format!("up-{nanos}"));
    fs::write(&path, data)
        .and_then(|_| fs::set_permissions(&path, fs::Permissions::from_mode(0o600)))
        .map_err(|e| Failure::msg(format!("Không ghi được file tạm: {e}")))?;
    Ok(path)
}

/// Đóng phiên: thoát kết nối ControlMaster và xóa thư mục tạm
pub async fn close(session_id: &str) -> bool {
    let Some(s) = lock(registry()).remove(session_id) else {
        return false;
    };
    download::forget_session(session_id);
    shutdown(&s).await;
    true
}

async fn shutdown(s: &Session) {
    if s.local {
        let _ = fs::remove_dir_all(&s.dir);
        return;
    }
    let _ = tokio::time::timeout(
        Duration::from_secs(5),
        Command::new("ssh")
            .arg("-S")
            .arg(&s.ctl)
            .args(["-O", "exit"])
            .arg(target(&s.host))
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status(),
    )
    .await;
    let _ = fs::remove_dir_all(&s.dir);
}

/// Đóng các phiên không dùng quá [`IDLE_TIMEOUT`]. Trả về số phiên đã đóng.
pub async fn reap_idle() -> usize {
    let idle: Vec<String> = lock(registry())
        .values()
        .filter(|s| lock(&s.inner).last_active.elapsed() > IDLE_TIMEOUT)
        .map(|s| s.id.clone())
        .collect();
    for id in &idle {
        close(id).await;
    }
    download::reap_expired();
    idle.len()
}

/// Lúc khởi động: thoát các kết nối ControlMaster còn sót từ lần chạy trước và xóa thư mục tạm
pub fn cleanup_stale() {
    let Ok(entries) = fs::read_dir(std::env::temp_dir()) else {
        return;
    };
    for entry in entries.flatten() {
        let name = entry.file_name();
        if !name.to_string_lossy().starts_with(DIR_PREFIX) {
            continue;
        }
        let dir = entry.path();
        let _ = std::process::Command::new("ssh")
            .arg("-S")
            .arg(dir.join("ctl"))
            .args(["-O", "exit", "x"])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
        let _ = fs::remove_dir_all(&dir);
    }
}
