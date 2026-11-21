//! Kiểm tra và cài các tool mà muop-agent-server cần, trên chính máy đang chạy server.
//!
//! - Danh sách tool và lệnh cài cố định trong code. Client chỉ được chọn tool theo `id`, không gửi lệnh shell.
//! - Chỉ các CLI (`agy`, `claude`) cài tự động bằng installer chính thức. Git/ssh/curl cần quyền root nên
//!   server chỉ kiểm tra và báo lệnh cài thủ công.
//! - Một job cài đặt chạy tại một thời điểm. Tiến trình đẩy ra qua `setup:update` (xem `super::publish`).

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
}

const TOOLS: &[ToolSpec] = &[
    ToolSpec {
        id: "git",
        label: "Git",
        group: "base",
        bin: "git",
        install_script: None,
        hint: "sudo apt install git",
    },
    ToolSpec {
        id: "ssh",
        label: "OpenSSH client",
        group: "base",
        bin: "ssh",
        install_script: None,
        hint: "sudo apt install openssh-client",
    },
    ToolSpec {
        id: "curl",
        label: "curl",
        group: "base",
        bin: "curl",
        install_script: None,
        hint: "sudo apt install curl",
    },
    ToolSpec {
        id: "agy",
        label: "Antigravity CLI (agy)",
        group: "cli",
        bin: "agy",
        install_script: Some("curl -fsSL https://antigravity.google/cli/install.sh | bash"),
        hint: "",
    },
    ToolSpec {
        id: "claude",
        label: "Claude Code CLI",
        group: "cli",
        bin: "claude",
        install_script: Some("curl -fsSL https://claude.ai/install.sh | bash"),
        hint: "",
    },
    ToolSpec {
        id: "docker",
        label: "Docker (tùy chọn)",
        group: "optional",
        bin: "docker",
        install_script: None,
        hint: "sudo apt install docker.io, để quản lý container qua SSH",
    },
    ToolSpec {
        id: "gopls",
        label: "gopls (tùy chọn)",
        group: "optional",
        bin: "gopls",
        install_script: None,
        hint: "go install golang.org/x/tools/gopls@latest",
    },
    ToolSpec {
        id: "rust-analyzer",
        label: "rust-analyzer (tùy chọn)",
        group: "optional",
        bin: "rust-analyzer",
        install_script: None,
        hint: "rustup component add rust-analyzer",
    },
    ToolSpec {
        id: "dart",
        label: "Dart SDK (tùy chọn)",
        group: "optional",
        bin: "dart",
        install_script: None,
        hint: "Cài Flutter SDK rồi thêm flutter/bin vào PATH",
    },
];

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ToolStatus {
    pub id: &'static str,
    pub label: &'static str,
    pub group: &'static str,
    pub installed: bool,
    pub path: String,
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

/// Tìm file thực thi `name` trong ~/.local/bin, ~/.cargo/bin, /usr/local/bin, PATH của server
/// và PATH của shell tương tác của user. Không chạy binary; chỉ kiểm tra file tồn tại và có quyền thực thi.
pub fn find_bin(name: &str) -> Option<PathBuf> {
    let mut dirs: Vec<PathBuf> = Vec::new();
    if let Some(home) = std::env::var_os("HOME") {
        let home = PathBuf::from(home);
        dirs.push(home.join(".local/bin"));
        dirs.push(home.join(".cargo/bin"));
    }
    dirs.push(PathBuf::from("/usr/local/bin"));
    if let Some(path) = std::env::var_os("PATH") {
        dirs.extend(std::env::split_paths(&path));
    }
    dirs.extend(user_shell_path_dirs().iter().cloned());
    dirs.into_iter()
        .map(|d| d.join(name))
        .find(|p| is_executable(p))
}

fn is_executable(p: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(p)
        .map(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
        .unwrap_or(false)
}

pub fn probe_all() -> Vec<ToolStatus> {
    TOOLS
        .iter()
        .map(|t| {
            let path = find_bin(t.bin);
            ToolStatus {
                id: t.id,
                label: t.label,
                group: t.group,
                installed: path.is_some(),
                path: path.map(|p| p.display().to_string()).unwrap_or_default(),
                installable: t.install_script.is_some(),
                hint: t.hint,
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

    let (state, error) = match result {
        Ok(0) if find_bin(bin).is_some() => ("done", String::new()),
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
