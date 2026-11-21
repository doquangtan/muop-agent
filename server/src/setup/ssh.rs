//! SSH của máy này: điều kiện bắt buộc của màn cài đặt, và đường để agy mở terminal đồng ý điều khoản.
//!
//! - Server có khóa riêng `~/.ssh/muop_agent_ed25519` và một user SSH (mặc định là user đang chạy server).
//! - Server tự sinh khóa, publish public key vào `~/.ssh/authorized_keys` của user (không cần root), rồi thử
//!   đăng nhập. OpenSSH server (sshd) phải do người dùng cài và bật (cần sudo, server không tự làm được).
//! - Nếu tự làm không được, UI hiện lệnh để người dùng copy vào terminal, rồi dán lại dòng public key để xác nhận.
//! - Máy này được lưu thành một máy trong `ssh_hosts` (khóa riêng lưu trong DB như các máy khác) để mở terminal.

use crate::infra::store;
use serde::{Deserialize, Serialize};
use std::fs;
use std::net::{SocketAddr, TcpStream};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::Duration;

const KEY_USER: &str = "ssh_local_user";
const KEY_LOGIN_OK: &str = "ssh_local_login_ok";
const KEY_HOST_ID: &str = "ssh_local_host_id";
const LOCAL_HOST: &str = "127.0.0.1";
const LOCAL_PORT: u16 = 22;
const HOST_NAME: &str = "Máy này (muop-agent)";

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SshStatus {
    /// Có lệnh `ssh` (OpenSSH client)
    pub client: bool,
    /// sshd đang nghe cổng 22 trên máy này
    pub sshd_running: bool,
    pub username: String,
    pub key_path: String,
    pub key_exists: bool,
    pub public_key: String,
    /// Public key đã có trong `authorized_keys` của user
    pub key_authorized: bool,
    /// Lần thử đăng nhập gần nhất thành công
    pub login_ok: bool,
    /// Đủ điều kiện: OpenSSH client, sshd, khóa đã publish, đăng nhập được
    pub ready: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SshConfigureRequest {
    pub username: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SshVerifyRequest {
    pub public_key: String,
}

fn home() -> PathBuf {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/"))
}

fn ssh_dir() -> PathBuf {
    home().join(".ssh")
}

pub fn key_path() -> PathBuf {
    ssh_dir().join("muop_agent_ed25519")
}

fn pub_key_path() -> PathBuf {
    PathBuf::from(format!("{}.pub", key_path().display()))
}

fn default_user() -> String {
    std::env::var("USER")
        .or_else(|_| std::env::var("LOGNAME"))
        .unwrap_or_default()
}

pub fn username() -> String {
    store::get_app_setting(KEY_USER)
        .filter(|s| !s.is_empty())
        .unwrap_or_else(default_user)
}

/// Username hợp lệ cho lệnh ssh (chữ, số, `.`, `-`, `_`)
pub fn valid_user(s: &str) -> bool {
    !s.is_empty()
        && s.chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '_'))
}

/// Phần khóa base64 của một dòng public key (bỏ qua comment), dùng để so khớp
pub fn key_body(line: &str) -> Option<String> {
    let mut parts = line.split_whitespace();
    let kind = parts.next()?;
    if !(kind.starts_with("ssh-") || kind.starts_with("ecdsa-")) {
        return None;
    }
    parts.next().map(str::to_string)
}

fn sshd_listening() -> bool {
    let addr: SocketAddr = format!("{LOCAL_HOST}:{LOCAL_PORT}")
        .parse()
        .unwrap_or_else(|_| SocketAddr::from(([127, 0, 0, 1], LOCAL_PORT)));
    TcpStream::connect_timeout(&addr, Duration::from_millis(300)).is_ok()
}

fn read_public_key() -> String {
    fs::read_to_string(pub_key_path())
        .map(|s| s.trim().to_string())
        .unwrap_or_default()
}

fn authorized_has(path: &Path, body: &str) -> bool {
    fs::read_to_string(path)
        .map(|c| c.lines().any(|l| key_body(l).as_deref() == Some(body)))
        .unwrap_or(false)
}

fn ssh_bin() -> PathBuf {
    crate::setup::install::find_bin("ssh").unwrap_or_else(|| PathBuf::from("ssh"))
}

/// Trạng thái hiện tại (chỉ đọc file và kiểm tra cổng, không đăng nhập thử)
pub fn status() -> SshStatus {
    let public_key = read_public_key();
    let key_authorized = key_body(&public_key)
        .is_some_and(|body| authorized_has(&ssh_dir().join("authorized_keys"), &body));
    let client = crate::setup::install::find_bin("ssh").is_some();
    let sshd_running = sshd_listening();
    let user = username();
    let key_exists = key_path().exists();
    let login_ok = store::get_app_setting(KEY_LOGIN_OK).as_deref() == Some("1");
    let ready =
        client && sshd_running && key_exists && key_authorized && valid_user(&user) && login_ok;
    SshStatus {
        client,
        sshd_running,
        username: user,
        key_path: key_path().display().to_string(),
        key_exists,
        public_key,
        key_authorized,
        login_ok,
        ready,
    }
}

/// Lưu user SSH. Đổi user thì phải thử đăng nhập lại.
pub fn configure(user: &str) -> Result<(), String> {
    let user = user.trim();
    if !valid_user(user) {
        return Err("Username không hợp lệ (chỉ gồm chữ, số, . - _)".into());
    }
    if !store::set_app_setting(KEY_USER, user) {
        return Err("Không lưu được username".into());
    }
    store::set_app_setting(KEY_LOGIN_OK, "0");
    Ok(())
}

/// Thử đăng nhập SSH tới máy này bằng khóa của server (không hỏi mật khẩu)
fn test_login() -> bool {
    let user = username();
    if !valid_user(&user) || !sshd_listening() || !key_path().exists() {
        return false;
    }
    Command::new(ssh_bin())
        .arg("-i")
        .arg(key_path())
        .args([
            "-o",
            "IdentitiesOnly=yes",
            "-o",
            "BatchMode=yes",
            "-o",
            "StrictHostKeyChecking=accept-new",
            "-o",
            "ConnectTimeout=5",
            "-p",
            &LOCAL_PORT.to_string(),
        ])
        .arg(format!("{user}@{LOCAL_HOST}"))
        .arg("true")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

/// Thêm public key vào `authorized_keys` (nếu chưa có) với quyền 600
fn publish_key(public_key: &str, body: &str) -> Result<(), String> {
    let path = ssh_dir().join("authorized_keys");
    let current = fs::read_to_string(&path).unwrap_or_default();
    if !current
        .lines()
        .any(|l| key_body(l).as_deref() == Some(body))
    {
        let mut next = current;
        if !next.is_empty() && !next.ends_with('\n') {
            next.push('\n');
        }
        next.push_str(public_key.trim());
        next.push('\n');
        fs::write(&path, next).map_err(|e| format!("Không ghi được authorized_keys: {e}"))?;
    }
    fs::set_permissions(&path, fs::Permissions::from_mode(0o600))
        .map_err(|e| format!("Không đặt được quyền authorized_keys: {e}"))
}

/// Tự thiết lập: sinh khóa nếu chưa có, publish public key, rồi thử đăng nhập.
/// Không tự bật sshd (cần root). Lỗi không tự xử lý được thì trạng thái vẫn trả về để UI hướng dẫn.
pub fn auto_setup() -> Result<(), String> {
    let dir = ssh_dir();
    fs::create_dir_all(&dir).map_err(|e| format!("Không tạo được ~/.ssh: {e}"))?;
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o700))
        .map_err(|e| format!("Không đặt được quyền ~/.ssh: {e}"))?;
    if !key_path().exists() {
        let out = Command::new("ssh-keygen")
            .args(["-q", "-t", "ed25519", "-N", "", "-C", "muop-agent", "-f"])
            .arg(key_path())
            .stdin(Stdio::null())
            .output()
            .map_err(|e| format!("Không chạy được ssh-keygen: {e}"))?;
        if !out.status.success() {
            return Err(format!(
                "ssh-keygen lỗi: {}",
                String::from_utf8_lossy(&out.stderr).trim()
            ));
        }
    }
    let public_key = read_public_key();
    let body = key_body(&public_key).ok_or("Không đọc được public key của server")?;
    publish_key(&public_key, &body)?;
    let ok = test_login();
    store::set_app_setting(KEY_LOGIN_OK, if ok { "1" } else { "0" });
    if ok {
        ensure_local_host();
    }
    Ok(())
}

/// Người dùng đã tự publish public key bằng lệnh hướng dẫn rồi dán lại dòng khóa:
/// kiểm tra khóa khớp và đã có trong `authorized_keys`, rồi thử đăng nhập.
pub fn verify_pasted(pasted: &str) -> Result<(), String> {
    let body =
        key_body(pasted).ok_or("Dòng dán vào không phải public key (bắt đầu bằng ssh-ed25519)")?;
    let own = key_body(&read_public_key()).ok_or("Server chưa có khóa, hãy bấm Tự thiết lập")?;
    if body != own {
        return Err("Public key dán vào không khớp với khóa của server".into());
    }
    if !authorized_has(&ssh_dir().join("authorized_keys"), &own) {
        return Err(
            "Chưa thấy khóa trong ~/.ssh/authorized_keys. Hãy chạy lại lệnh hướng dẫn rồi dán lại."
                .into(),
        );
    }
    if !sshd_listening() {
        store::set_app_setting(KEY_LOGIN_OK, "0");
        return Err("sshd chưa chạy trên máy này (cổng 22 đóng)".into());
    }
    let ok = test_login();
    store::set_app_setting(KEY_LOGIN_OK, if ok { "1" } else { "0" });
    if !ok {
        return Err("Đã có khóa nhưng chưa đăng nhập được bằng khóa. Kiểm tra sshd cho phép đăng nhập bằng public key.".into());
    }
    ensure_local_host();
    Ok(())
}

/// Lưu máy này vào danh sách máy SSH để mở terminal. Trả về id máy đã lưu.
/// Id của "Máy này" (mục mặc định, không sửa/xóa được), nếu đã lưu
pub fn local_host_id() -> Option<i64> {
    store::get_app_setting(KEY_HOST_ID).and_then(|s| s.parse::<i64>().ok())
}

/// Đảm bảo "Máy này" luôn có trong `ssh_hosts`: loopback, đúng user đang chạy server, không khóa.
/// Mục mặc định của màn SSH: gọi khi khởi động và mỗi lần liệt kê máy.
pub fn ensure_local_host() -> Option<i64> {
    let existing_id = local_host_id()
        .filter(|id| store::get_ssh_host(*id).is_some())
        .unwrap_or(0);
    let row = store::SshHostRow {
        id: existing_id,
        name: HOST_NAME.into(),
        host: LOCAL_HOST.into(),
        port: LOCAL_PORT,
        username: crate::ssh::hosts::server_user(),
        password: String::new(),
        private_key: String::new(),
    };
    let id = store::save_ssh_host(&row)?;
    store::set_app_setting(KEY_HOST_ID, &id.to_string());
    Some(id)
}

/// Mở terminal SSH tới máy này và chạy `agy` để người dùng đồng ý điều khoản trên màn hình SSH.
/// Trả về (id phiên, id máy đã lưu).
/// Mở terminal SSH tới máy này chạy `agy` (đăng nhập, hoặc đồng ý điều khoản) trong màn hình SSH của app.
/// Trả về (id phiên, id máy đã lưu).
pub fn open_agy_terminal() -> Result<(String, i64), String> {
    // Không qua ssh: agy chạy trực tiếp trong PTY của server ("SSH ảo"), nên không cần sshd,
    // khóa SSH hay máy SSH đã lưu. Cùng môi trường với các lệnh agy khác của server.
    let agy = crate::setup::install::find_bin("agy").ok_or("không tìm thấy lệnh agy")?;
    let io = crate::setup::io().ok_or("server chưa sẵn sàng")?;
    let sid = crate::ssh::terminal::new_session_id();
    crate::ssh::terminal::open_local(io, &sid, &agy, &[], 120, 40, 0, "Agy (máy chủ)")?;
    Ok((sid, 0))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_key_body_and_ignores_comment() {
        assert_eq!(
            key_body("ssh-ed25519 AAAAC3Nza abc@host").as_deref(),
            Some("AAAAC3Nza")
        );
        assert_eq!(key_body("# comment"), None);
        assert_eq!(key_body("   "), None);
    }

    #[test]
    fn validates_usernames() {
        assert!(valid_user("john"));
        assert!(valid_user("john.doe-1_x"));
        assert!(!valid_user(""));
        assert!(!valid_user("jo hn"));
        assert!(!valid_user("john;rm"));
    }

    #[test]
    fn authorized_match_ignores_comment_differences() {
        let dir = std::env::temp_dir().join(format!("muop-ssh-test-{}", std::process::id()));
        let _ = fs::create_dir_all(&dir);
        let path = dir.join("authorized_keys");
        fs::write(
            &path,
            "ssh-ed25519 AAAAB other\nssh-ed25519 AAAAC3Nza old-comment\n",
        )
        .unwrap();
        assert!(authorized_has(&path, "AAAAC3Nza"));
        assert!(!authorized_has(&path, "AAAAmissing"));
        let _ = fs::remove_dir_all(&dir);
    }
}
