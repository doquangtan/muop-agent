use super::*;

/// Kiểm tra tệp có phải thực thi được không (dùng chung với `infra::tools`)
pub fn is_executable(p: &Path) -> bool {
    crate::infra::tools::is_executable(p)
}

/// Các đường dẫn ứng viên của tiến trình LSP: binary dò bằng `which` (hoặc người dùng chọn trong Khởi tạo),
/// và với rust-analyzer thì thêm bản đi kèm extension VSCode/Cursor.
pub(super) fn candidate_paths(lang: Lang) -> Vec<PathBuf> {
    let mut out: Vec<PathBuf> = Vec::new();
    if let Some(p) = crate::infra::tools::resolve(lang.binary_name()) {
        out.push(p);
    }
    if lang == Lang::Rust {
        let home = crate::infra::paths::home_dir();
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
