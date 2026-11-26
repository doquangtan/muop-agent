//! Chạy lệnh trên máy SSH đã lưu bằng `ssh` của hệ thống.
//!
//! - Mật khẩu: không ghi ra đĩa ngoài DB đã lưu. Được đưa qua biến môi trường cho một script
//!   `SSH_ASKPASS` (script nằm trong thư mục tạm 0700, chỉ in biến môi trường).
//! - Khi `ssh` hỏi mật khẩu mà server chưa có, script ghi file đánh dấu và `ssh` thất bại; kết quả
//!   trả về `needsPassword` để app hỏi người dùng rồi gửi lại lệnh kèm mật khẩu.
//! - Private key: ghi vào file tạm 0600, xóa ngay sau khi lệnh kết thúc.
//! - `StrictHostKeyChecking=accept-new`: lần đầu lưu host key, sau đó đổi host key sẽ bị từ chối.

use crate::infra::store;
use crate::infra::store::SshHostRow;
use crate::models::{SshExecResponse, SshHostDto};
use crate::ssh::prompt::{self, PromptKind};
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;
use tokio::process::Command;

const MAX_OUTPUT_BYTES: usize = 200 * 1024;
/// File đánh dấu do askpass tạo khi `ssh` hỏi mật khẩu nhưng server chưa có
const ASKED_FILE: &str = "asked";

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
        // Máy này cũng có thể có mật khẩu đã lưu (dùng cho sudo); chỉ báo có/không, không lộ giá trị
        has_password: !row.password.is_empty(),
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
        // Mật khẩu có thể để trống: khi ssh hỏi, app sẽ hiện hộp thoại nhập (và tùy chọn lưu)
        "password" => Ok(()),
        "key" if row.private_key.trim().is_empty() => Err("Thiếu private key".into()),
        "key" => Ok(()),
        _ => Err("Kiểu xác thực phải là password hoặc key".into()),
    }
}

pub struct TempDir(PathBuf);

impl TempDir {
    pub fn create() -> Option<Self> {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .ok()?
            .as_nanos();
        let dir = std::env::temp_dir().join(format!("muop-ssh-{}-{}", std::process::id(), nanos));
        fs::create_dir(&dir).ok()?;
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).ok()?;
        Some(Self(dir))
    }
    pub fn path(&self) -> &Path {
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
        needs_password: false,
        password_kind: String::new(),
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
///
/// `typed_password` là mật khẩu người dùng vừa nhập (rỗng = dùng mật khẩu đã lưu). Nếu `save_password`
/// thì mật khẩu gõ vào được lưu trước khi chạy. Mật khẩu dùng để xác thực sai thì xóa khỏi DB
/// (nếu nó đến từ DB) và trả `needsPassword` với thông báo.
pub async fn exec(
    row: &SshHostRow,
    command: &str,
    timeout_secs: u64,
    typed_password: &str,
    save_password: bool,
) -> SshExecResponse {
    let command = command.trim();
    if command.is_empty() {
        return error_response("Lệnh trống");
    }
    let local = is_local(row);
    // Thư mục tạm giữ khóa/askpass và đánh dấu; còn sống tới khi lệnh xong
    let Some(tmp) = TempDir::create() else {
        return error_response("Không tạo được thư mục tạm");
    };
    let typed = !typed_password.is_empty();
    // Mật khẩu gõ vào + chọn lưu: lưu trước; nếu sai thì xóa (cùng quy tắc với terminal)
    let stored_used = if typed {
        save_password
    } else {
        !row.password.is_empty()
    };
    if typed && save_password && !store::set_ssh_password(row.id, typed_password) {
        return error_response("Không lưu được mật khẩu");
    }
    let password = if typed {
        typed_password
    } else {
        row.password.as_str()
    };
    let password_given = !password.is_empty();

    let kind = if local {
        PromptKind::Sudo
    } else {
        PromptKind::Ssh
    };
    let mut cmd = if local {
        // Máy này: shell của server chạy trực tiếp; sudo trong lệnh dùng mật khẩu đã lưu (nếu có)
        let mut c = Command::new(local_shell());
        c.args(["-l", "-i", "-c", command]);
        if let Some(home) = std::env::var_os("HOME")
            .map(PathBuf::from)
            .filter(|p| p.is_dir())
        {
            c.current_dir(home);
        }
        if let Err(e) = apply_sudo_auth(&mut c, tmp.path(), password) {
            return error_response(e);
        }
        c
    } else {
        let mut c = Command::new("ssh");
        c.arg("-T")
            .arg("-p")
            .arg(row.port.to_string())
            .args(["-o", "StrictHostKeyChecking=accept-new"])
            .args(["-o", "ConnectTimeout=10"])
            .args(["-o", "NumberOfPasswordPrompts=1"]);
        if let Err(e) = apply_exec_auth(&mut c, row, tmp.path(), password) {
            return error_response(e);
        }
        // Chạy lệnh bằng shell tương tác của user (đọc .bashrc) để PATH giống khi mở terminal
        c.arg(format!("{}@{}", row.username, row.host))
            .arg(remote_interactive_command(command));
        c
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

    // Askpass được gọi mà chưa có mật khẩu: lệnh cần mật khẩu
    let asked = tmp.path().join(ASKED_FILE).exists();
    let raw_stderr = String::from_utf8_lossy(&output.stderr);
    let rejected = !asked && password_given && prompt::is_rejected_output(kind, &raw_stderr);
    if rejected && stored_used {
        store::set_ssh_password(row.id, "");
    }
    let needs_password = asked || rejected;

    let stdout = truncate(&String::from_utf8_lossy(&output.stdout));
    let stderr = truncate(&strip_shell_noise(&raw_stderr));
    let ok = output.status.success() && !needs_password;
    let error = if asked {
        "Máy yêu cầu mật khẩu".to_string()
    } else if rejected {
        "Sai mật khẩu".to_string()
    } else if ok {
        String::new()
    } else {
        format!("Lệnh kết thúc với mã {:?}", output.status.code())
    };
    SshExecResponse {
        ok,
        exit_code: output.status.code(),
        stdout,
        stderr,
        error,
        needs_password,
        password_kind: kind.label().into(),
    }
}

/// Script `SUDO_ASKPASS` của lệnh một lần trên máy này: in mật khẩu đã lưu, hoặc đánh dấu rồi từ chối.
const SUDO_ASKPASS_SCRIPT: &str = r#"#!/bin/sh
if [ -n "$MUOP_SUDO_PASSWORD" ]; then
  printf '%s\n' "$MUOP_SUDO_PASSWORD"
  exit 0
fi
: > "$MUOP_ASKED_FILE"
exit 1
"#;

/// Xác thực sudo cho lệnh một lần trên máy này. Một shim `sudo` đặt đầu PATH gọi sudo với `-A`
/// để mật khẩu lấy từ `SUDO_ASKPASS` (không có tty trong lệnh một lần).
pub fn apply_sudo_auth(cmd: &mut Command, dir: &Path, password: &str) -> Result<(), String> {
    let real = crate::infra::tools::resolve("sudo").ok_or("Không tìm thấy lệnh sudo")?;
    let bin = dir.join("bin");
    let shim = bin.join("sudo");
    let askpass = dir.join("sudo-askpass.sh");
    let shim_body = format!(
        "#!/bin/sh\nexec {} -A \"$@\"\n",
        shell_quote(&real.to_string_lossy())
    );
    if fs::create_dir(&bin).is_err()
        || fs::write(&shim, shim_body).is_err()
        || fs::set_permissions(&shim, fs::Permissions::from_mode(0o700)).is_err()
        || fs::write(&askpass, SUDO_ASKPASS_SCRIPT).is_err()
        || fs::set_permissions(&askpass, fs::Permissions::from_mode(0o700)).is_err()
    {
        return Err("Không tạo được script sudo tạm".into());
    }
    let path = format!(
        "{}:{}",
        bin.display(),
        std::env::var("PATH").unwrap_or_default()
    );
    cmd.env("PATH", path)
        .env("SUDO_ASKPASS", &askpass)
        .env("MUOP_SUDO_PASSWORD", password)
        .env("MUOP_ASKED_FILE", dir.join(ASKED_FILE));
    Ok(())
}

/// Script `SSH_ASKPASS` của lệnh một lần. `ssh` gọi nó với prompt làm `$1`.
/// Có mật khẩu và prompt là mật khẩu thì in ra; chưa có thì tạo file đánh dấu rồi từ chối.
/// Prompt khác (passphrase, mã OTP...) bị từ chối luôn.
const ASKPASS_SCRIPT: &str = r#"#!/bin/sh
case "$1" in
  *[Pp]assword*)
    if [ -n "$MUOP_SSH_PASSWORD" ]; then
      printf '%s\n' "$MUOP_SSH_PASSWORD"
      exit 0
    fi
    : > "$MUOP_ASKED_FILE"
    ;;
esac
exit 1
"#;

/// Xác thực cho lệnh một lần (`exec`). `password` rỗng = chưa có mật khẩu: nếu `ssh` hỏi thì
/// script askpass đánh dấu `asked` trong `dir`.
pub fn apply_exec_auth(
    cmd: &mut Command,
    row: &SshHostRow,
    dir: &Path,
    password: &str,
) -> Result<(), String> {
    if row.private_key.trim().is_empty() {
        cmd.args(["-o", "PubkeyAuthentication=no"]).args([
            "-o",
            "PreferredAuthentications=password,keyboard-interactive",
        ]);
    } else {
        let key_path = dir.join("key");
        let mut key = row.private_key.trim_end().to_string();
        key.push('\n');
        if write_private(&key_path, &key).is_none() {
            return Err("Không ghi được private key tạm".into());
        }
        cmd.arg("-i")
            .arg(&key_path)
            .args(["-o", "IdentitiesOnly=yes"]);
    }
    let askpass = dir.join("askpass.sh");
    if fs::write(&askpass, ASKPASS_SCRIPT).is_err()
        || fs::set_permissions(&askpass, fs::Permissions::from_mode(0o700)).is_err()
    {
        return Err("Không tạo được script xác thực tạm".into());
    }
    cmd.env("SSH_ASKPASS", &askpass)
        .env("SSH_ASKPASS_REQUIRE", "force")
        .env("MUOP_SSH_PASSWORD", password)
        .env("MUOP_ASKED_FILE", dir.join(ASKED_FILE));
    Ok(())
}

/// Gắn tham số xác thực vào lệnh `ssh` của Docker (phiên ControlMaster, không hỏi mật khẩu tương tác):
/// private key (file 0600) hoặc mật khẩu đã lưu qua `SSH_ASKPASS`.
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

/// Lệnh gửi lên máy đích: chạy `$SHELL -l -i -c <lệnh>` để nạp profile và rc của user (PATH của brew, alias...)
pub fn remote_interactive_command(command: &str) -> String {
    format!("\"${{SHELL:-/bin/sh}}\" -l -i -c {}", shell_quote(command))
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
        assert!(validate(&row("10.0.0.1", "john", "", ""), "password").is_ok());
        assert!(validate(&row("10.0.0.1", "john", "", "KEY"), "key").is_ok());
        assert!(validate(&row("10.0.0.1", "john", "", ""), "key").is_err());
        assert!(validate(&row("10.0.0.1", "john", "x", ""), "other").is_err());
    }

    #[test]
    fn builds_interactive_remote_command() {
        assert_eq!(shell_quote("uptime"), "'uptime'");
        assert_eq!(
            remote_interactive_command("uptime"),
            "\"${SHELL:-/bin/sh}\" -l -i -c 'uptime'"
        );
    }

    #[test]
    fn dto_never_contains_secrets() {
        // Id riêng: `is_builtin` tra DB thật (máy mặc định có thể mang id 1 trên một số máy)
        let mut r = row("10.0.0.1", "john", "secret", "-----KEY");
        r.id = 987_654;
        let dto = to_dto(&r);
        let json = serde_json::to_string(&dto).unwrap();
        assert!(!json.contains("secret"));
        assert!(!json.contains("KEY"));
        assert!(dto.has_password && dto.has_key);
    }

    #[test]
    fn askpass_supplies_password_or_marks_missing() {
        let dir = TempDir::create().expect("thư mục tạm");
        let script = dir.path().join("askpass.sh");
        fs::write(&script, ASKPASS_SCRIPT).unwrap();
        fs::set_permissions(&script, fs::Permissions::from_mode(0o700)).unwrap();
        let marker = dir.path().join(ASKED_FILE);

        // Có mật khẩu: in ra, không tạo đánh dấu
        let out = std::process::Command::new(&script)
            .arg("john@h's password: ")
            .env("MUOP_SSH_PASSWORD", "s3cret")
            .env("MUOP_ASKED_FILE", &marker)
            .output()
            .unwrap();
        assert!(out.status.success());
        assert_eq!(String::from_utf8_lossy(&out.stdout), "s3cret\n");
        assert!(!marker.exists());

        // Không có mật khẩu: từ chối và đánh dấu
        let out = std::process::Command::new(&script)
            .arg("john@h's password: ")
            .env("MUOP_SSH_PASSWORD", "")
            .env("MUOP_ASKED_FILE", &marker)
            .output()
            .unwrap();
        assert!(!out.status.success());
        assert!(marker.exists());

        // Prompt không phải mật khẩu (passphrase): từ chối, không đánh dấu
        fs::remove_file(&marker).unwrap();
        let out = std::process::Command::new(&script)
            .arg("Enter passphrase for key: ")
            .env("MUOP_SSH_PASSWORD", "s3cret")
            .env("MUOP_ASKED_FILE", &marker)
            .output()
            .unwrap();
        assert!(!out.status.success());
        assert!(!marker.exists());
    }
}

#[cfg(test)]
mod sudo_tests {
    use super::*;

    #[test]
    fn sudo_askpass_supplies_saved_password_or_marks_missing() {
        let dir = TempDir::create().expect("thư mục tạm");
        let script = dir.path().join("sudo-askpass.sh");
        fs::write(&script, SUDO_ASKPASS_SCRIPT).unwrap();
        fs::set_permissions(&script, fs::Permissions::from_mode(0o700)).unwrap();
        let marker = dir.path().join(ASKED_FILE);

        let out = std::process::Command::new(&script)
            .arg("[sudo] password for john: ")
            .env("MUOP_SUDO_PASSWORD", "s3cret")
            .env("MUOP_ASKED_FILE", &marker)
            .output()
            .unwrap();
        assert!(out.status.success());
        assert_eq!(String::from_utf8_lossy(&out.stdout), "s3cret\n");
        assert!(!marker.exists());

        let out = std::process::Command::new(&script)
            .arg("[sudo] password for john: ")
            .env("MUOP_SUDO_PASSWORD", "")
            .env("MUOP_ASKED_FILE", &marker)
            .output()
            .unwrap();
        assert!(!out.status.success());
        assert!(marker.exists());
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
