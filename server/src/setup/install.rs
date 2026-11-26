//! Kiểm tra và cài các tool mà muop-agent-server cần, trên chính máy đang chạy server.
//!
//! - Danh sách tool và lệnh cài cố định trong code. Client chỉ được chọn tool theo `id`, không gửi lệnh shell.
//! - Chỉ các CLI (`agy`, `claude`) cài tự động bằng installer chính thức. Git/ssh/curl cần quyền root nên
//!   server chỉ kiểm tra và báo lệnh cài thủ công.
//! - Một job cài đặt chạy tại một thời điểm. Tiến trình đẩy ra qua `setup:update` (xem `super::publish`).

use crate::infra::tools;
use serde::Serialize;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncRead, BufReader};
use tokio::process::Command;

/// Thời gian tối đa cho một lần cài (installer của agy tải ~270MB)
pub const INSTALL_TIMEOUT: Duration = Duration::from_secs(20 * 60);
/// Số dòng log giữ lại để gửi xuống client
const MAX_LOG_LINES: usize = 300;
/// Các CLI người dùng có thể chọn trong wizard
pub const CLI_IDS: [&str; 2] = ["agy", "claude"];

struct ToolSpec {
    id: &'static str,
    label: &'static str,
    /// `base`: bắt buộc, chỉ kiểm tra. `cli`: chọn agy/claude. `optional`: tùy chọn.
    group: &'static str,
    bin: &'static str,
    install_script: Option<&'static str>,
    hint: &'static str,
    /// Điều kiện bổ sung ngoài việc có `bin` (ví dụ `/dev/fuse` của FUSE). None: không có.
    extra_check: Option<fn() -> bool>,
}

/// FUSE cần cả `/dev/fuse` (kernel) và `fusermount3` (gói fuse3) thì mount được thư mục project của máy khác
fn dev_fuse_present() -> bool {
    Path::new("/dev/fuse").exists()
}

/// Công cụ chỉ có ý nghĩa trên Linux (systemd, FUSE, bản Linux Desktop). Trên macOS không hiện trong Khởi tạo.
const LINUX_ONLY_TOOL_IDS: [&str; 3] = ["fuse", "systemd-run", "muop-agent"];

/// Công cụ `id` có áp dụng trên máy này không
pub fn tool_applies(id: &str) -> bool {
    crate::infra::platform::IS_LINUX || !LINUX_ONLY_TOOL_IDS.contains(&id)
}

/// Lệnh gợi ý cài theo nền tảng. macOS không dùng apt: git/ssh/curl/python3 đi kèm Xcode Command Line Tools.
fn hint_for(t: &ToolSpec) -> &'static str {
    if !crate::infra::platform::IS_MACOS {
        return t.hint;
    }
    match t.id {
        "git" | "ssh" | "curl" | "python3" => {
            "Cài Xcode Command Line Tools: xcode-select --install"
        }
        "docker" => "Cài Docker Desktop (cung cấp lệnh docker), để quản lý container qua SSH",
        _ => t.hint,
    }
}

const TOOLS: &[ToolSpec] = &[
    ToolSpec {
        id: "git",
        label: "Git",
        group: "base",
        bin: "git",
        install_script: None,
        hint: "sudo apt install git",
        extra_check: None,
    },
    ToolSpec {
        id: "ssh",
        label: "OpenSSH client",
        group: "base",
        bin: "ssh",
        install_script: None,
        hint: "sudo apt install openssh-client",
        extra_check: None,
    },
    ToolSpec {
        id: "curl",
        label: "curl",
        group: "base",
        bin: "curl",
        install_script: None,
        hint: "sudo apt install curl",
        extra_check: None,
    },
    ToolSpec {
        id: "agy",
        label: "Antigravity CLI (agy)",
        group: "cli",
        bin: "agy",
        install_script: Some("curl -fsSL https://antigravity.google/cli/install.sh | bash"),
        hint: "",
        extra_check: None,
    },
    ToolSpec {
        id: "claude",
        label: "Claude Code CLI",
        group: "cli",
        bin: "claude",
        install_script: Some("curl -fsSL https://claude.ai/install.sh | bash"),
        hint: "",
        extra_check: None,
    },
    ToolSpec {
        id: "docker",
        label: "Docker (tùy chọn, chỉ cần cho tính năng Docker)",
        group: "optional",
        bin: "docker",
        install_script: None,
        hint: "sudo apt install docker.io, để quản lý container qua SSH",
        extra_check: None,
    },
    ToolSpec {
        id: "gopls",
        label: "gopls (tùy chọn)",
        group: "optional",
        bin: "gopls",
        install_script: None,
        hint: "go install golang.org/x/tools/gopls@latest",
        extra_check: None,
    },
    ToolSpec {
        id: "rust-analyzer",
        label: "rust-analyzer (tùy chọn)",
        group: "optional",
        bin: "rust-analyzer",
        install_script: None,
        hint: "rustup component add rust-analyzer",
        extra_check: None,
    },
    ToolSpec {
        id: "dart",
        label: "Dart SDK (tùy chọn)",
        group: "optional",
        bin: "dart",
        install_script: None,
        hint: "Cài Flutter SDK rồi thêm flutter/bin vào PATH",
        extra_check: None,
    },
    ToolSpec {
        id: "python3",
        label: "Python 3 (tùy chọn)",
        group: "optional",
        bin: "python3",
        install_script: None,
        hint: "sudo apt install python3, để đồng bộ session Antigravity IDE",
        extra_check: None,
    },
    ToolSpec {
        id: "systemd-run",
        label: "systemd-run (tùy chọn)",
        group: "optional",
        bin: "systemd-run",
        install_script: None,
        hint: "Có sẵn trên Ubuntu (systemd). Không có thì agent chạy trực tiếp, không tách khỏi server",
        extra_check: None,
    },
    ToolSpec {
        id: "muop-agent",
        label: "Ứng dụng Linux Desktop (mở từ tray)",
        group: "optional",
        bin: "muop-agent",
        install_script: None,
        hint: "Cài file .deb (lệnh muop-agent), hoặc chọn tới tệp muop_agent của bản build dev",
        extra_check: None,
    },
    ToolSpec {
        id: "fuse",
        label: "FUSE (fuse3, /dev/fuse)",
        group: "base",
        bin: "fusermount3",
        install_script: None,
        hint: "sudo apt install fuse3 (và /dev/fuse: sudo modprobe fuse), để mount project của máy khác",
        extra_check: Some(dev_fuse_present),
    },
];

/// Gói apt mà server quản lý. Thêm gói mới: thêm một dòng vào `APT_PACKAGES`.
/// Gói được coi là có khi `bin` tìm thấy trên PATH và `extra_check` (nếu có) trả true.
/// Server không tự chạy apt (cần root): chỉ tạo lệnh `sudo apt-get install -y ...` để người dùng chạy.
pub struct AptPackage {
    pub package: &'static str,
    pub label: &'static str,
    /// Lý do cần gói, hiển thị cho người dùng
    pub note: &'static str,
    /// Bắt buộc: chưa cài thì wizard không cho đi tiếp
    pub required: bool,
    pub bin: &'static str,
    pub extra_check: Option<fn() -> bool>,
}

pub const APT_PACKAGES: &[AptPackage] = &[
    AptPackage {
        package: "git",
        label: "Git",
        note: "quản lý mã nguồn và xem thay đổi",
        required: true,
        bin: "git",
        extra_check: None,
    },
    AptPackage {
        package: "openssh-client",
        label: "OpenSSH client",
        note: "SSH tới các máy đã lưu",
        required: true,
        bin: "ssh",
        extra_check: None,
    },
    AptPackage {
        package: "curl",
        label: "curl",
        note: "tải installer của CLI",
        required: true,
        bin: "curl",
        extra_check: None,
    },
    AptPackage {
        package: "fuse3",
        label: "FUSE (fusermount3, /dev/fuse)",
        note: "mount project của máy khác để agent làm việc trên đó",
        required: true,
        bin: "fusermount3",
        extra_check: Some(dev_fuse_present),
    },
];

/// Trạng thái một gói apt
#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct AptPackageStatus {
    pub package: &'static str,
    pub label: &'static str,
    pub note: &'static str,
    pub required: bool,
    pub installed: bool,
}

/// Gói apt do server quản lý. Chỉ có trên Linux (Debian/Ubuntu); macOS trả về rỗng, không hiện mục apt.
pub fn probe_apt() -> Vec<AptPackageStatus> {
    if !crate::infra::platform::IS_LINUX {
        return Vec::new();
    }
    APT_PACKAGES
        .iter()
        .map(|p| AptPackageStatus {
            package: p.package,
            label: p.label,
            note: p.note,
            required: p.required,
            installed: find_bin(p.bin).is_some() && p.extra_check.is_none_or(|check| check()),
        })
        .collect()
}

/// Lệnh cài các gói còn thiếu, rỗng nếu đã đủ. Chạy trong terminal của người dùng để họ nhập mật khẩu sudo.
pub fn apt_install_command(packages: &[AptPackageStatus]) -> String {
    let missing: Vec<&str> = packages
        .iter()
        .filter(|p| !p.installed)
        .map(|p| p.package)
        .collect();
    if missing.is_empty() {
        String::new()
    } else {
        format!("sudo apt-get install -y {}", missing.join(" "))
    }
}

/// Gói Homebrew (cask) server quản lý trên macOS, hiển thị như danh sách apt bên Linux.
/// Thêm gói mới: thêm một dòng vào `BREW_PACKAGES`. Server không tự cài (cask cần quyền admin):
/// chỉ tạo lệnh `brew install --cask ...` để người dùng chạy trong terminal của máy.
pub struct BrewPackage {
    pub cask: &'static str,
    pub label: &'static str,
    /// Lý do cần gói, hiển thị cho người dùng
    pub note: &'static str,
    /// Bắt buộc: chưa cài thì wizard không cho đi tiếp
    pub required: bool,
    /// Dò đã cài (file cài của gói tồn tại)
    pub installed: fn() -> bool,
}

pub const BREW_PACKAGES: &[BrewPackage] = &[BrewPackage {
    cask: "fuse-t",
    label: "FUSE-T",
    note: "mount project của máy khác để agent làm việc trên đó (không cần kext)",
    required: true,
    installed: fuse_t_installed,
}];

/// FUSE-T cài `libfuse-t` vào thư mục lib của hệ thống (hoặc Homebrew)
pub(crate) fn fuse_t_installed() -> bool {
    [
        "/usr/local/lib/libfuse-t.dylib",
        "/opt/homebrew/lib/libfuse-t.dylib",
    ]
    .iter()
    .any(|p| Path::new(p).exists())
}

/// Trạng thái các cask Homebrew do server quản lý. Chỉ có trên macOS; nơi khác trả về rỗng.
pub fn probe_brew() -> Vec<AptPackageStatus> {
    if !crate::infra::platform::IS_MACOS {
        return Vec::new();
    }
    BREW_PACKAGES
        .iter()
        .map(|p| AptPackageStatus {
            package: p.cask,
            label: p.label,
            note: p.note,
            required: p.required,
            installed: (p.installed)(),
        })
        .collect()
}

/// Lệnh cài các cask còn thiếu, rỗng nếu đã đủ hoặc chưa có Homebrew (`brew_available`).
/// Chạy trong terminal của người dùng để họ nhập mật khẩu admin.
pub fn brew_install_command(packages: &[AptPackageStatus], brew_available: bool) -> String {
    let missing: Vec<&str> = packages
        .iter()
        .filter(|p| !p.installed)
        .map(|p| p.package)
        .collect();
    if missing.is_empty() || !brew_available {
        String::new()
    } else {
        format!("brew install --cask {}", missing.join(" "))
    }
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ToolStatus {
    pub id: &'static str,
    pub label: &'static str,
    pub group: &'static str,
    pub installed: bool,
    pub path: String,
    /// Nguồn đường dẫn: `override` (người dùng chọn), `which`, `dev` (bản build trong repo), hoặc rỗng
    pub source: &'static str,
    /// Đường dẫn người dùng đã lưu (rỗng nếu chưa chọn), để ô nhập hiển thị đúng giá trị
    pub overridden: String,
    /// Server cài tự động được (chỉ các CLI)
    pub installable: bool,
    pub hint: &'static str,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct JobStatus {
    pub tool: String,
    /// `running` | `done` | `failed`
    pub state: String,
    pub log: Vec<String>,
    pub error: String,
    pub started_at: String,
    pub finished_at: String,
}

static JOB: Mutex<Option<JobStatus>> = Mutex::new(None);

static USER_SHELL_PATH: OnceLock<Vec<PathBuf>> = OnceLock::new();

/// PATH của shell tương tác của user (đã nạp nvm, rc...). Server chạy qua systemd thường không có
/// các thư mục này, nên claude cài bằng npm trong nvm sẽ không được thấy nếu chỉ dùng PATH của server.
/// Chạy một lần rồi cache; có timeout để một rc bị treo không làm treo server.
pub fn user_shell_path_dirs() -> &'static [PathBuf] {
    USER_SHELL_PATH.get_or_init(|| {
        let shell = std::env::var("SHELL")
            .ok()
            .filter(|s| !s.trim().is_empty())
            .unwrap_or_else(|| "/bin/bash".into());
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let out = std::process::Command::new(shell)
                .args(["-ic", "printf 'MUOP_PATH=%s\\n' \"$PATH\""])
                .stdin(Stdio::null())
                .stderr(Stdio::null())
                .output();
            let _ = tx.send(out);
        });
        let stdout = match rx.recv_timeout(Duration::from_secs(10)) {
            Ok(Ok(out)) => String::from_utf8_lossy(&out.stdout).into_owned(),
            _ => return Vec::new(),
        };
        stdout
            .lines()
            .rev()
            .find_map(|l| l.strip_prefix("MUOP_PATH="))
            .map(|p| {
                p.split(':')
                    .filter(|s| !s.is_empty())
                    .map(PathBuf::from)
                    .collect()
            })
            .unwrap_or_default()
    })
}

/// Tìm công cụ `name` (xem `infra::tools`: đường dẫn người dùng chọn, rồi `which`).
/// Tên `muop-agent` có thêm nhánh bản build dev trong repo.
pub fn find_bin(name: &str) -> Option<PathBuf> {
    locate_tool(name).0
}

/// Vị trí công cụ và nguồn tìm thấy
pub fn locate_tool(bin: &str) -> (Option<PathBuf>, &'static str) {
    let (path, source) = tools::locate(bin);
    if path.is_some() || bin != "muop-agent" {
        return (path, source);
    }
    match tools::dev_bundle_from_exe() {
        Some(p) => (Some(p), "dev"),
        None => (None, ""),
    }
}

/// Tên binary của một công cụ theo `id` trong danh sách (dùng khi người dùng chọn đường dẫn)
pub fn tool_bin(id: &str) -> Option<&'static str> {
    TOOLS.iter().find(|t| t.id == id).map(|t| t.bin)
}

pub fn probe_all() -> Vec<ToolStatus> {
    TOOLS
        .iter()
        .filter(|t| tool_applies(t.id))
        .map(|t| {
            let (path, source) = locate_tool(t.bin);
            let extra_ok = t.extra_check.is_none_or(|check| check());
            ToolStatus {
                id: t.id,
                label: t.label,
                group: t.group,
                installed: path.is_some() && extra_ok,
                path: path.map(|p| p.display().to_string()).unwrap_or_default(),
                source,
                overridden: tools::override_path(t.bin)
                    .map(|p| p.display().to_string())
                    .unwrap_or_default(),
                installable: t.install_script.is_some(),
                hint: hint_for(t),
            }
        })
        .collect()
}

pub fn current() -> Option<JobStatus> {
    JOB.lock().ok().and_then(|g| g.clone())
}

fn update(f: impl FnOnce(&mut JobStatus)) {
    if let Ok(mut g) = JOB.lock() {
        if let Some(job) = g.as_mut() {
            f(job);
        }
    }
}

/// Installer in tiến trình bằng \r: chỉ giữ đoạn cuối của dòng
fn clean_line(line: &str) -> String {
    line.rsplit('\r')
        .next()
        .unwrap_or("")
        .trim_end()
        .to_string()
}

fn push_line(line: &str) {
    let text = clean_line(line);
    if text.is_empty() {
        return;
    }
    update(|job| {
        job.log.push(text);
        if job.log.len() > MAX_LOG_LINES {
            let excess = job.log.len() - MAX_LOG_LINES;
            job.log.drain(..excess);
        }
    });
}

fn now() -> String {
    chrono::Utc::now().to_rfc3339()
}

/// Bắt đầu cài một CLI. Trả về lỗi tiếng Việt nếu tool không hợp lệ hoặc đang có job khác.
pub fn start(tool: &str) -> Result<(), String> {
    let spec = TOOLS
        .iter()
        .find(|t| t.id == tool)
        .ok_or_else(|| "Tool không hợp lệ".to_string())?;
    let script = spec
        .install_script
        .ok_or_else(|| "Tool này không cài tự động được, hãy cài thủ công".to_string())?;
    {
        let mut g = JOB.lock().map_err(|_| "Lỗi khóa trạng thái cài đặt")?;
        if g.as_ref().is_some_and(|j| j.state == "running") {
            return Err("Đang cài một tool khác, hãy đợi xong".into());
        }
        *g = Some(JobStatus {
            tool: spec.id.into(),
            state: "running".into(),
            log: Vec::new(),
            error: String::new(),
            started_at: now(),
            finished_at: String::new(),
        });
    }
    tracing::info!("setup: bắt đầu cài {}", spec.id);
    super::publish();
    tokio::spawn(run(spec.id, spec.bin, script));
    Ok(())
}

async fn run(id: &'static str, bin: &'static str, script: &'static str) {
    // Đẩy trạng thái định kỳ trong lúc cài để app thấy log chạy
    let finished = std::sync::Arc::new(AtomicBool::new(false));
    let ticker_flag = finished.clone();
    tokio::spawn(async move {
        while !ticker_flag.load(Ordering::Relaxed) {
            tokio::time::sleep(Duration::from_millis(700)).await;
            super::publish();
        }
    });

    let result = run_script(script).await;
    finished.store(true, Ordering::Relaxed);

    // Kiểm tra bằng cách dò lại trên đĩa, không dùng cache (có thể còn ghi "không thấy" từ lúc đang cài)
    let installed = tools::locate_uncached(bin).is_some();
    tools::forget(bin);
    let (state, error) = match result {
        Ok(0) if installed => ("done", String::new()),
        Ok(0) => (
            "failed",
            format!("Cài xong nhưng không thấy `{bin}` trong ~/.local/bin hoặc PATH"),
        ),
        Ok(code) => ("failed", format!("Lệnh cài kết thúc với mã {code}")),
        Err(e) => ("failed", e),
    };
    tracing::info!("setup: cài {id} -> {state} {error}");
    update(|job| {
        job.state = state.into();
        job.error = error.clone();
        job.finished_at = now();
    });
    super::publish();
}

async fn run_script(script: &str) -> Result<i32, String> {
    let mut child = Command::new("bash")
        .arg("-c")
        .arg(format!("set -o pipefail; {script}"))
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .map_err(|e| format!("Không chạy được bash: {e}"))?;

    let mut readers = Vec::new();
    if let Some(out) = child.stdout.take() {
        readers.push(tokio::spawn(pump(out)));
    }
    if let Some(err) = child.stderr.take() {
        readers.push(tokio::spawn(pump(err)));
    }

    let status = match tokio::time::timeout(INSTALL_TIMEOUT, child.wait()).await {
        Ok(Ok(s)) => s,
        Ok(Err(e)) => return Err(format!("Lỗi khi chờ tiến trình cài đặt: {e}")),
        Err(_) => {
            let _ = child.kill().await;
            return Err("Hết thời gian cài đặt (20 phút)".into());
        }
    };
    for r in readers {
        let _ = r.await;
    }
    Ok(status.code().unwrap_or(-1))
}

async fn pump<R: AsyncRead + Unpin>(stream: R) {
    let mut lines = BufReader::new(stream).lines();
    while let Ok(Some(line)) = lines.next_line().await {
        push_line(&line);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fuse_is_a_required_base_tool_that_needs_dev_fuse() {
        let fuse = TOOLS.iter().find(|t| t.id == "fuse").expect("có mục fuse");
        assert_eq!(fuse.group, "base");
        assert_eq!(fuse.bin, "fusermount3");
        assert!(fuse.install_script.is_none(), "apt cần root, chỉ báo lệnh");
        assert!(fuse.hint.contains("apt install fuse3"));
        assert!(fuse.extra_check.is_some());
    }

    #[test]
    fn brew_command_lists_only_missing_casks() {
        let st = |package: &'static str, installed: bool| AptPackageStatus {
            package,
            label: "x",
            note: "",
            required: false,
            installed,
        };
        assert_eq!(brew_install_command(&[st("fuse-t", true)], true), "");
        assert_eq!(
            brew_install_command(&[st("fuse-t", false)], true),
            "brew install --cask fuse-t"
        );
        // Chưa có Homebrew thì không tạo lệnh (người dùng cần cài brew trước)
        assert_eq!(brew_install_command(&[st("fuse-t", false)], false), "");
    }

    #[test]
    fn apt_list_contains_required_packages_once() {
        let names: Vec<&str> = APT_PACKAGES.iter().map(|p| p.package).collect();
        for want in ["git", "openssh-client", "curl", "fuse3"] {
            assert_eq!(names.iter().filter(|n| **n == want).count(), 1, "{want}");
        }
        assert!(APT_PACKAGES
            .iter()
            .find(|p| p.package == "fuse3")
            .unwrap()
            .extra_check
            .is_some());
    }

    #[test]
    fn apt_command_lists_only_missing_packages() {
        let st = |package: &'static str, installed: bool| AptPackageStatus {
            package,
            label: "",
            note: "",
            required: true,
            installed,
        };
        assert_eq!(
            apt_install_command(&[st("git", true), st("fuse3", true)]),
            ""
        );
        assert_eq!(
            apt_install_command(&[st("git", true), st("curl", false), st("fuse3", false)]),
            "sudo apt-get install -y curl fuse3"
        );
    }

    #[test]
    fn only_cli_tools_are_installable() {
        for t in TOOLS {
            if t.install_script.is_some() {
                assert_eq!(t.group, "cli", "{} phải thuộc nhóm cli", t.id);
                assert!(CLI_IDS.contains(&t.id));
            }
        }
    }

    #[test]
    fn rejects_unknown_and_non_installable_tools() {
        assert!(start("rm -rf /").is_err());
        assert!(start("git").is_err());
    }

    #[test]
    fn finds_shell_on_path() {
        assert!(find_bin("sh").is_some());
        assert!(find_bin("muop-no-such-binary-xyz").is_none());
    }

    #[test]
    fn clean_line_keeps_last_progress_segment() {
        assert_eq!(clean_line("10%\r50%\r100%  "), "100%");
    }
}
