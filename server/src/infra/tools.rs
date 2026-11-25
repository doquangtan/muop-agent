//! Dò đường dẫn các công cụ bên ngoài (agy, claude, python3, systemd-run, ...) bằng lệnh `which`.
//!
//! Thứ tự tìm:
//! 1. Đường dẫn người dùng đã chọn trong màn Khởi tạo (`app_settings`, khóa `tool_path.<tên>`).
//! 2. `which <tên>` chạy với PATH mở rộng: PATH của server, PATH của shell đăng nhập của user
//!    (nvm, rc...) và các thư mục cài công cụ phổ biến suy ra từ HOME.
//!
//! Không tìm thấy thì báo lỗi yêu cầu người dùng chọn đường dẫn trong Khởi tạo.
//! Không có đường dẫn mặc định cứng trong code.

use super::paths::home_dir;
use super::store;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

const OVERRIDE_PREFIX: &str = "tool_path.";
/// Kết quả tìm thấy được giữ ngắn để không gọi `which` ở mỗi lượt chat
const FOUND_TTL: Duration = Duration::from_secs(30);
/// Kết quả không tìm thấy giữ rất ngắn: vừa cài xong công cụ thì lần sau thấy ngay
const MISSING_TTL: Duration = Duration::from_secs(3);
/// Thư mục tương đối tới bản build Linux trong repo dev (dùng cho tray khi chưa cài .deb)
const DEV_BUNDLE_REL: &str = "build/linux/x64/release/bundle/muop_agent";

type Cache = Mutex<HashMap<String, (Option<PathBuf>, Instant)>>;
static CACHE: OnceLock<Cache> = OnceLock::new();

/// Tên công cụ hợp lệ: chữ, số, `-`, `_`, `.`. Không có `/` nên không trỏ ra ngoài PATH.
pub fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'))
}

/// Tệp thường và có quyền thực thi
pub fn is_executable(p: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(p)
        .map(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
        .unwrap_or(false)
}

/// PATH dùng khi gọi `which`: PATH của server, PATH của shell user, rồi thư mục cài công cụ của user.
pub fn search_path() -> std::ffi::OsString {
    let mut dirs: Vec<PathBuf> = Vec::new();
    if let Some(p) = std::env::var_os("PATH") {
        dirs.extend(std::env::split_paths(&p));
    }
    dirs.extend(
        crate::setup::install::user_shell_path_dirs()
            .iter()
            .cloned(),
    );
    let home = home_dir();
    dirs.push(home.join(".local/bin"));
    dirs.push(home.join(".cargo/bin"));
    dirs.push(home.join("go/bin"));
    dirs.push(home.join(".gemini/bin"));
    dirs.push(home.join("flutter/bin"));
    if let Some(gopath) = std::env::var_os("GOPATH") {
        dirs.push(PathBuf::from(gopath).join("bin"));
    }
    dirs.push(PathBuf::from("/usr/local/bin"));
    if crate::infra::platform::IS_MACOS {
        // Homebrew trên Apple Silicon đặt công cụ ở /opt/homebrew/bin
        dirs.push(PathBuf::from("/opt/homebrew/bin"));
    }
    let mut unique: Vec<PathBuf> = Vec::new();
    for d in dirs {
        if !d.as_os_str().is_empty() && !unique.contains(&d) {
            unique.push(d);
        }
    }
    std::env::join_paths(unique).unwrap_or_default()
}

/// Chạy `which <name>` với PATH mở rộng. Chỉ nhận kết quả là tệp thực thi.
fn which_raw(name: &str) -> Option<PathBuf> {
    let out = Command::new("which")
        .arg(name)
        .env("PATH", search_path())
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let line = String::from_utf8_lossy(&out.stdout)
        .lines()
        .next()?
        .trim()
        .to_string();
    if line.is_empty() {
        return None;
    }
    let path = PathBuf::from(line);
    is_executable(&path).then_some(path)
}

fn which_cached(name: &str) -> Option<PathBuf> {
    let cache = CACHE.get_or_init(|| Mutex::new(HashMap::new()));
    if let Ok(guard) = cache.lock() {
        if let Some((found, at)) = guard.get(name) {
            let ttl = if found.is_some() {
                FOUND_TTL
            } else {
                MISSING_TTL
            };
            if at.elapsed() < ttl {
                return found.clone();
            }
        }
    }
    let found = which_raw(name);
    if let Ok(mut guard) = cache.lock() {
        guard.insert(name.to_string(), (found.clone(), Instant::now()));
    }
    found
}

/// Như `locate` nhưng dò lại trên đĩa, không dùng cache. Dùng ngay sau khi cài xong:
/// cache "không tìm thấy" (3 giây) được ghi bởi các lần cập nhật trạng thái trong lúc cài.
pub fn locate_uncached(name: &str) -> Option<PathBuf> {
    if !valid_name(name) {
        return None;
    }
    if let Some(p) = override_path(name) {
        if is_executable(&p) {
            return Some(p);
        }
    }
    which_raw(name)
}

/// Bỏ kết quả đã cache của `name` để lần dò kế tiếp đọc lại đĩa
pub fn forget(name: &str) {
    if let Some(cache) = CACHE.get() {
        if let Ok(mut guard) = cache.lock() {
            guard.remove(name);
        }
    }
}

/// Đường dẫn người dùng đã lưu cho `name` (chuỗi rỗng coi như chưa chọn)
pub fn override_path(name: &str) -> Option<PathBuf> {
    store::get_app_setting(&format!("{OVERRIDE_PREFIX}{name}"))
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .map(PathBuf::from)
}

/// Nguồn tìm thấy công cụ: `override` (người dùng chọn), `which`, hoặc `""` (không có)
pub fn locate(name: &str) -> (Option<PathBuf>, &'static str) {
    if !valid_name(name) {
        return (None, "");
    }
    if let Some(p) = override_path(name) {
        if is_executable(&p) {
            return (Some(p), "override");
        }
    }
    match which_cached(name) {
        Some(p) => (Some(p), "which"),
        None => (None, ""),
    }
}

/// Đường dẫn thực thi của công cụ `name`. None nếu không dò được và người dùng chưa chọn.
pub fn resolve(name: &str) -> Option<PathBuf> {
    locate(name).0
}

/// Như `resolve` nhưng trả lỗi tiếng Việt hướng dẫn người dùng chọn đường dẫn trong Khởi tạo.
pub fn require(name: &str) -> Result<String, String> {
    resolve(name)
        .map(|p| p.to_string_lossy().into_owned())
        .ok_or_else(|| missing_message(name))
}

pub fn missing_message(name: &str) -> String {
    format!("Không tìm thấy `{name}`. Vào Khởi tạo, mục Công cụ, và chọn đường dẫn tới `{name}`.")
}

/// Lưu đường dẫn do người dùng chọn cho công cụ `name`. Chuỗi rỗng = xóa, quay về dò bằng `which`.
pub fn set_override(name: &str, raw: &str) -> Result<(), String> {
    if !valid_name(name) {
        return Err(format!("Tên công cụ không hợp lệ: {name}"));
    }
    let trimmed = raw.trim();
    let value = if trimmed.is_empty() {
        String::new()
    } else {
        let path = Path::new(trimmed);
        if !path.is_absolute() {
            return Err("Đường dẫn công cụ phải là đường dẫn tuyệt đối".into());
        }
        let canonical = path
            .canonicalize()
            .map_err(|e| format!("Không mở được {trimmed}: {e}"))?;
        if !is_executable(&canonical) {
            return Err(format!("{trimmed} không phải tệp thực thi"));
        }
        canonical.to_string_lossy().into_owned()
    };
    if !store::set_app_setting(&format!("{OVERRIDE_PREFIX}{name}"), &value) {
        return Err("Không lưu được đường dẫn công cụ".into());
    }
    forget(name);
    Ok(())
}

/// Bản build Linux trong repo dev: đi ngược từ đường dẫn của server để tìm `build/linux/.../muop_agent`.
/// Bản cài bằng .deb không có repo nên trả None.
pub fn dev_bundle_from_exe() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?;
    find_bundle_upwards(exe.parent()?, 6, &|p| is_executable(p))
}

/// Đi ngược các thư mục cha (tối đa `max_depth`) tìm bản build dev. Tách riêng để test.
pub fn find_bundle_upwards(
    start: &Path,
    max_depth: usize,
    exists: &dyn Fn(&Path) -> bool,
) -> Option<PathBuf> {
    start
        .ancestors()
        .take(max_depth)
        .map(|dir| dir.join(DEV_BUNDLE_REL))
        .find(|candidate| exists(candidate))
}

/// Ứng dụng Linux Desktop để mở từ tray: `muop-agent` trong PATH (bản .deb), rồi bản build dev.
/// Người dùng cũng có thể chọn đường dẫn trong Khởi tạo (khóa `muop-agent`).
pub fn app_launcher() -> Option<PathBuf> {
    resolve("muop-agent").or_else(dev_bundle_from_exe)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_with_separators_are_rejected() {
        assert!(valid_name("agy"));
        assert!(valid_name("rust-analyzer"));
        assert!(!valid_name(""));
        assert!(!valid_name("../agy"));
        assert!(!valid_name("bin/agy"));
        assert!(!valid_name("agy;rm"));
    }

    #[test]
    fn which_finds_a_system_binary() {
        assert!(resolve("sh").is_some());
    }

    #[test]
    fn missing_binary_is_not_found_and_message_asks_for_setup() {
        assert!(resolve("muop-no-such-binary-xyz").is_none());
        let err = require("muop-no-such-binary-xyz").unwrap_err();
        assert!(err.contains("Khởi tạo"));
    }

    #[test]
    fn bundle_search_goes_up_from_exe_dir() {
        let start = Path::new("/repo/server/target/release");
        let hit = PathBuf::from("/repo").join(DEV_BUNDLE_REL);
        let found = find_bundle_upwards(start, 6, &|p| p == hit);
        assert_eq!(found, Some(hit));
    }

    #[test]
    fn bundle_search_is_none_for_installed_layout() {
        let start = Path::new("/usr/bin");
        assert_eq!(find_bundle_upwards(start, 6, &|_| false), None);
    }

    #[test]
    fn set_override_rejects_relative_and_non_executable() {
        assert!(set_override("agy", "relative/agy").is_err());
        assert!(set_override("agy", "/etc/hostname").is_err());
        assert!(set_override("../x", "/bin/sh").is_err());
    }
}
