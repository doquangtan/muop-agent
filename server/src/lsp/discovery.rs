use super::*;

pub(super) fn home_dir() -> Option<PathBuf> {
    std::env::var_os("HOME").map(PathBuf::from)
}

/// Tìm tệp thực thi trong PATH
pub(super) fn which(name: &str) -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path)
        .map(|dir| dir.join(name))
        .find(|p| is_executable(p))
}

pub fn is_executable(p: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    fs::metadata(p)
        .map(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
        .unwrap_or(false)
}

/// Các vị trí thường gặp của tiến trình LSP (khi không có trong PATH)
pub(super) fn candidate_paths(lang: Lang) -> Vec<PathBuf> {
    let mut out: Vec<PathBuf> = Vec::new();
    if let Some(p) = which(lang.binary_name()) {
        out.push(p);
    }
    let Some(home) = home_dir() else {
        return out;
    };
    match lang {
        Lang::Go => {
            out.push(home.join("go/bin/gopls"));
            if let Some(gopath) = std::env::var_os("GOPATH") {
                out.push(PathBuf::from(gopath).join("bin/gopls"));
            }
            out.push(PathBuf::from("/usr/local/go/bin/gopls"));
        }
        Lang::Dart => {
            out.push(home.join("flutter/bin/dart"));
            out.push(home.join("flutter/bin/cache/dart-sdk/bin/dart"));
            out.push(PathBuf::from("/usr/lib/dart/bin/dart"));
        }
        Lang::Rust => {
            out.push(home.join(".cargo/bin/rust-analyzer"));
            // rust-analyzer đi kèm extension VSCode: ~/.vscode*/extensions/rust-lang.rust-analyzer-*/server/
            for ext_root in [
                ".vscode/extensions",
                ".vscode-server/extensions",
                ".cursor/extensions",
            ] {
                let Ok(entries) = fs::read_dir(home.join(ext_root)) else {
                    continue;
                };
                let mut found: Vec<PathBuf> = entries
                    .flatten()
                    .filter(|e| {
                        e.file_name()
                            .to_string_lossy()
                            .starts_with("rust-lang.rust-analyzer-")
                    })
                    .map(|e| e.path().join("server/rust-analyzer"))
                    .collect();
                found.sort();
                found.reverse(); // phiên bản mới nhất trước
                out.extend(found);
            }
        }
    }
    out
}

/// Đối số để kiểm tra tệp thực thi có chạy được không (gopls dùng subcommand `version`)
pub(super) fn probe_args(lang: Lang) -> &'static [&'static str] {
    match lang {
        Lang::Go => &["version"],
        Lang::Dart | Lang::Rust => &["--version"],
    }
}

pub(super) static PROBE_CACHE: OnceLock<Mutex<HashMap<PathBuf, (bool, Instant)>>> = OnceLock::new();
pub(super) const PROBE_TTL: Duration = Duration::from_secs(300);

/// Chạy thử tệp thực thi (có thời hạn, kết quả được cache). Dùng để loại proxy hỏng như rustup
/// báo "Unknown binary" dù tệp tồn tại và có quyền chạy.
pub fn runs(lang: Lang, exe: &Path) -> bool {
    let cache = PROBE_CACHE.get_or_init(|| Mutex::new(HashMap::new()));
    if let Some((ok, at)) = lock(cache).get(exe).copied() {
        if at.elapsed() < PROBE_TTL {
            return ok;
        }
    }
    let ok = probe(lang, exe);
    lock(cache).insert(exe.to_path_buf(), (ok, Instant::now()));
    ok
}

pub(super) fn probe(lang: Lang, exe: &Path) -> bool {
    let child = std::process::Command::new(exe)
        .args(probe_args(lang))
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn();
    let Ok(mut child) = child else {
        return false;
    };
    let deadline = Instant::now() + Duration::from_secs(8);
    loop {
        match child.try_wait() {
            Ok(Some(status)) => return status.success(),
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(50)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return false;
            }
        }
    }
}
