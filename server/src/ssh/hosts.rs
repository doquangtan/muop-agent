//! Chạy lệnh trên máy SSH đã lưu bằng `ssh` của hệ thống.
//!
//! - Mật khẩu: không ghi ra đĩa. Được đưa qua biến môi trường cho một script `SSH_ASKPASS`
//!   (script nằm trong thư mục tạm 0700, chỉ in biến môi trường).
//! - Private key: ghi vào file tạm 0600, xóa ngay sau khi lệnh kết thúc.
//! - `StrictHostKeyChecking=accept-new`: lần đầu lưu host key, sau đó đổi host key sẽ bị từ chối.

use crate::infra::store::SshHostRow;
use crate::models::{SshExecResponse, SshHostDto};
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;
use tokio::process::Command;

const MAX_OUTPUT_BYTES: usize = 200 * 1024;

/// "Máy này" là mục mặc định: luôn có, không sửa hay xóa được (xem `setup::ssh::ensure_local_host`)
pub fn is_builtin(row: &SshHostRow) -> bool {
    crate::setup::ssh::local_host_id() == Some(row.id)
}

pub fn to_dto(row: &SshHostRow) -> SshHostDto {
    let builtin = is_builtin(row);
    SshHostDto {
        id: row.id,
        name: row.name.clone(),
        host: row.host.clone(),
        port: row.port,
        username: row.username.clone(),
        // Mục mặc định không dùng mật khẩu/khóa; các máy khác: có mật khẩu thì dùng mật khẩu, không thì key
        auth_type: if builtin {
            "local".into()
        } else if row.password.is_empty() && !row.private_key.is_empty() {
            "key".into()
        } else {
            "password".into()
        },
        has_password: !builtin && !row.password.is_empty(),
        has_key: !builtin && !row.private_key.is_empty(),
        builtin,
    }
}

fn is_safe_token(s: &str, allow_colon: bool) -> bool {
    !s.is_empty()
        && s.chars().all(|c| {
            c.is_ascii_alphanumeric()
                || c == '.'
                || c == '-'
                || c == '_'
                || (allow_colon && c == ':')
        })
}

/// Kiểm tra dữ liệu trước khi lưu. Trả về thông báo lỗi tiếng Việt nếu không hợp lệ.
pub fn validate(row: &SshHostRow, auth_type: &str) -> Result<(), String> {
    if !is_safe_token(&row.host, true) {
        return Err("Địa chỉ host không hợp lệ (chỉ gồm chữ, số, . - _ :)".into());
    }
    if !is_safe_token(&row.username, false) {
        return Err("Username không hợp lệ (chỉ gồm chữ, số, . - _)".into());
    }
    if row.port == 0 {
        return Err("Port phải từ 1 đến 65535".into());
    }
    match auth_type {
        "password" if row.password.is_empty() => Err("Thiếu mật khẩu".into()),
        "key" if row.private_key.trim().is_empty() => Err("Thiếu private key".into()),
        "password" | "key" => Ok(()),
        _ => Err("Kiểu xác thực phải là password hoặc key".into()),
    }
}

struct TempDir(PathBuf);

impl TempDir {
    fn create() -> Option<Self> {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .ok()?
            .as_nanos();
        let dir = std::env::temp_dir().join(format!("muop-ssh-{}-{}", std::process::id(), nanos));
        fs::create_dir(&dir).ok()?;
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).ok()?;
        Some(Self(dir))
    }
    fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn write_private(path: &Path, content: &str) -> Option<()> {
    fs::write(path, content).ok()?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o600)).ok()
}

fn error_response(msg: impl Into<String>) -> SshExecResponse {
    SshExecResponse {
        ok: false,
        exit_code: None,
        stdout: String::new(),
        stderr: String::new(),
        error: msg.into(),
    }
}

/// Máy trỏ về chính server (loopback, đúng user đang chạy server): mở shell và chạy lệnh trực tiếp,
/// không qua `ssh` (không cần sshd hay khóa).
pub fn is_local(row: &SshHostRow) -> bool {
    is_local_with(&row.host, &row.username, &server_user())
}

pub fn is_local_with(host: &str, username: &str, server_user: &str) -> bool {
    matches!(host.trim(), "127.0.0.1" | "localhost" | "::1")
        && !username.is_empty()
        && username == server_user
}

/// User đang chạy server
pub fn server_user() -> String {
    std::env::var("USER")
        .or_else(|_| std::env::var("LOGNAME"))
        .unwrap_or_default()
}

/// Shell của user trên máy server (`$SHELL`, hoặc `/bin/sh`)
pub fn local_shell() -> PathBuf {
    std::env::var_os("SHELL")
        .map(PathBuf::from)
        .filter(|p| p.is_absolute() && p.exists())
        .unwrap_or_else(|| PathBuf::from("/bin/sh"))
}

/// Chạy `command` trên máy `row` và trả về stdout/stderr/exit code.
pub async fn exec(row: &SshHostRow, command: &str, timeout_secs: u64) -> SshExecResponse {
    let command = command.trim();
    if command.is_empty() {
        return error_response("Lệnh trống");
    }
    // Máy này: shell của server chạy trực tiếp (giữ tmp để khóa tạm còn sống tới khi xong)
    let (mut cmd, _tmp): (Command, Option<TempDir>) = if is_local(row) {
        let mut c = Command::new(local_shell());
        c.args(["-i", "-c", command]);
        if let Some(home) = std::env::var_os("HOME")
            .map(PathBuf::from)
            .filter(|p| p.is_dir())
        {
            c.current_dir(home);
        }
        (c, None)
    } else {
        let Some(tmp) = TempDir::create() else {
            return error_response("Không tạo được thư mục tạm");
        };
        let mut c = Command::new("ssh");
        c.arg("-T")
            .arg("-p")
            .arg(row.port.to_string())
            .args(["-o", "StrictHostKeyChecking=accept-new"])
            .args(["-o", "ConnectTimeout=10"])
            .args(["-o", "NumberOfPasswordPrompts=1"]);
        if let Err(e) = apply_auth(&mut c, row, tmp.path()) {
            return error_response(e);
        }
        // Chạy lệnh bằng shell tương tác của user (đọc .bashrc) để PATH giống khi mở terminal
        c.arg(format!("{}@{}", row.username, row.host))
            .arg(remote_interactive_command(command));
        (c, Some(tmp))
    };
    cmd.stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);

    let child = match cmd.spawn() {
        Ok(c) => c,
        Err(e) => return error_response(format!("Không chạy được lệnh: {e}")),
    };
    let output = match tokio::time::timeout(
        Duration::from_secs(timeout_secs.clamp(5, 300)),
        child.wait_with_output(),
    )
    .await
    {
        Ok(Ok(out)) => out,
        Ok(Err(e)) => return error_response(format!("Lỗi khi chạy ssh: {e}")),
        Err(_) => return error_response("Hết thời gian chờ"),
    };

    let stdout = truncate(&String::from_utf8_lossy(&output.stdout));
    let stderr = truncate(&strip_shell_noise(&String::from_utf8_lossy(&output.stderr)));
    let ok = output.status.success();
    SshExecResponse {
        ok,
        exit_code: output.status.code(),
        stdout,
        stderr,
        error: if ok {
            String::new()
        } else {
            format!("Lệnh kết thúc với mã {:?}", output.status.code())
        },
    }
}

/// Gắn tham số xác thực vào lệnh `ssh`: private key (file 0600) hoặc mật khẩu qua `SSH_ASKPASS`.
/// File tạm nằm trong `dir` (phải là thư mục 0700). Sau khi đã đăng nhập xong, gọi [`remove_auth_files`].
pub fn apply_auth(cmd: &mut Command, row: &SshHostRow, dir: &Path) -> Result<(), String> {
    let use_key = !row.private_key.trim().is_empty() && row.password.is_empty();
    if use_key {
        let key_path = dir.join("key");
        let mut key = row.private_key.trim_end().to_string();
        key.push('\n');
        if write_private(&key_path, &key).is_none() {
            return Err("Không ghi được private key tạm".into());
        }
        cmd.arg("-i")
            .arg(&key_path)
            .args(["-o", "IdentitiesOnly=yes"])
            .args(["-o", "BatchMode=yes"]);
    } else {
        let askpass = dir.join("askpass.sh");
        if fs::write(
            &askpass,
            "#!/bin/sh\nprintf '%s\\n' \"$MUOP_SSH_PASSWORD\"\n",
        )
        .is_err()
            || fs::set_permissions(&askpass, fs::Permissions::from_mode(0o700)).is_err()
        {
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
    Ok(())
}

/// Xóa file bí mật do [`apply_auth`] tạo trong `dir`
pub fn remove_auth_files(dir: &Path) {
    let _ = fs::remove_file(dir.join("key"));
    let _ = fs::remove_file(dir.join("askpass.sh"));
}

/// Lệnh gửi lên máy đích: chạy `$SHELL -i -c <lệnh>` để nạp rc của user (PATH, alias...)
pub fn remote_interactive_command(command: &str) -> String {
    format!("\"${{SHELL:-/bin/sh}}\" -i -c {}", shell_quote(command))
}

/// Bọc chuỗi thành một đối số shell an toàn (dấu nháy đơn được escape)
pub fn shell_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}

/// Bỏ cảnh báo vô hại của bash tương tác khi không có TTY (không ảnh hưởng kết quả lệnh)
pub fn strip_shell_noise(s: &str) -> String {
    s.lines()
        .filter(|l| {
            !l.starts_with("bash: cannot set terminal process group")
                && !l.starts_with("bash: no job control in this shell")
        })
        .collect::<Vec<_>>()
        .join("\n")
}

fn truncate(s: &str) -> String {
    if s.len() <= MAX_OUTPUT_BYTES {
        return s.to_string();
    }
    let mut end = MAX_OUTPUT_BYTES;
    while !s.is_char_boundary(end) {
        end -= 1;
    }
    format!("{}\n… (đã cắt bớt)", &s[..end])
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(host: &str, user: &str, pw: &str, key: &str) -> SshHostRow {
        SshHostRow {
            id: 1,
            name: "t".into(),
            host: host.into(),
            port: 22,
            username: user.into(),
            password: pw.into(),
            private_key: key.into(),
        }
    }

    #[test]
    fn validates_inputs() {
        assert!(validate(&row("192.168.1.10", "john", "x", ""), "password").is_ok());
        assert!(validate(&row("host name", "john", "x", ""), "password").is_err());
        assert!(validate(&row("10.0.0.1", "jo hn", "x", ""), "password").is_err());
        assert!(validate(&row("10.0.0.1", "john", "", ""), "password").is_err());
        assert!(validate(&row("10.0.0.1", "john", "", "KEY"), "key").is_ok());
        assert!(validate(&row("10.0.0.1", "john", "", ""), "key").is_err());
        assert!(validate(&row("10.0.0.1", "john", "x", ""), "other").is_err());
    }

    #[test]
    fn builds_interactive_remote_command() {
        assert_eq!(shell_quote("uptime"), "'uptime'");
        assert_eq!(
            remote_interactive_command("uptime"),
            "\"${SHELL:-/bin/sh}\" -i -c 'uptime'"
        );
    }

    #[test]
    fn dto_never_contains_secrets() {
        let dto = to_dto(&row("10.0.0.1", "john", "secret", "-----KEY"));
        let json = serde_json::to_string(&dto).unwrap();
        assert!(!json.contains("secret"));
        assert!(!json.contains("KEY"));
        assert!(dto.has_password && dto.has_key);
    }
}

#[cfg(test)]
mod local_tests {
    use super::*;

    #[test]
    fn loopback_with_server_user_is_local() {
        assert!(is_local_with("127.0.0.1", "john", "john"));
        assert!(is_local_with("localhost", "john", "john"));
        assert!(!is_local_with("192.168.31.216", "john", "john"));
        assert!(!is_local_with("127.0.0.1", "root", "john"));
        assert!(!is_local_with("127.0.0.1", "", ""));
    }
}
