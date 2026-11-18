use super::*;

/// Cache kết quả `git status` theo repo (TTL ngắn) để khi quét nhiều session không gọi git lặp lại
pub(super) static GIT_STATUS_CACHE: OnceLock<
    Mutex<HashMap<String, (Instant, Vec<(PathBuf, bool)>)>>,
> = OnceLock::new();

/// Danh sách file đã thay đổi trong repo (đường dẫn tuyệt đối, có phải file mới không)
pub(super) fn git_changed_files(repo: &str) -> Vec<(PathBuf, bool)> {
    let cache = GIT_STATUS_CACHE.get_or_init(|| Mutex::new(HashMap::new()));
    if let Ok(map) = cache.lock() {
        if let Some((at, list)) = map.get(repo) {
            if at.elapsed() < Duration::from_secs(5) {
                return list.clone();
            }
        }
    }
    let root = Command::new("git")
        .args(["-C", repo, "rev-parse", "--show-toplevel"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string());
    let Some(root) = root else {
        return Vec::new();
    };
    let mut result: Vec<(PathBuf, bool)> = Vec::new();
    if let Ok(out) = Command::new("git")
        .args(["-C", repo, "status", "--porcelain", "--untracked-files=all"])
        .output()
    {
        if out.status.success() {
            for line in String::from_utf8_lossy(&out.stdout).lines() {
                if line.len() < 4 {
                    continue;
                }
                let status = &line[..2];
                let mut rel = &line[3..];
                if let Some(pos) = rel.find(" -> ") {
                    rel = &rel[pos + 4..];
                }
                let rel = rel.trim_matches('"');
                let is_new = status == "??" || status.starts_with('A');
                result.push((PathBuf::from(&root).join(rel), is_new));
            }
        }
    }
    if let Ok(mut map) = cache.lock() {
        map.insert(repo.to_string(), (Instant::now(), result.clone()));
    }
    result
}

/// Thư mục build/cache và đuôi file nhị phân: không liệt kê khi suy ra thay đổi từ Bash
pub(super) const BUILD_DIR_NAMES: &[&str] = &[
    "build",
    ".dart_tool",
    "target",
    "node_modules",
    ".gradle",
    ".idea",
    "Pods",
    "DerivedData",
];
pub(super) const BINARY_EXTENSIONS: &[&str] = &[
    "apk", "aab", "ipa", "so", "exe", "dll", "dylib", "bin", "o", "a", "obj", "jar", "class",
    "zip", "tar", "gz", "7z", "png", "jpg", "jpeg", "gif", "webp", "ico", "bmp", "pdf", "ttf",
    "otf", "woff", "woff2", "db", "sqlite", "sqlite3", "wasm", "pyc",
];

pub(super) fn is_build_or_binary_path(path: &Path) -> bool {
    let in_build_dir = path.components().any(|c| {
        matches!(c, std::path::Component::Normal(n)
            if n.to_str().map_or(false, |s| BUILD_DIR_NAMES.contains(&s)))
    });
    if in_build_dir {
        return true;
    }
    path.extension()
        .and_then(|e| e.to_str())
        .map_or(false, |e| {
            BINARY_EXTENSIONS.contains(&e.to_ascii_lowercase().as_str())
        })
}

/// Bổ sung thay đổi file do lệnh Bash tạo ra (sed -i, python, cat >, ...). Các lệnh này không có
/// tool Edit/Write nên không được ghi nhận khi duyệt tool call. Lấy các file đã thay đổi trong repo
/// (git status) có mtime nằm trong khoảng từ bước gọi Bash đến bước kế tiếp.
pub(super) fn detect_bash_file_changes(
    repo: &str,
    steps: &[AgentStep],
    files: &mut Vec<FileTouchRecord>,
) {
    if repo.is_empty() {
        return;
    }
    let parse_ts = |s: &str| {
        chrono::DateTime::parse_from_rfc3339(s)
            .ok()
            .map(|d| d.with_timezone(&chrono::Utc))
    };
    let mut windows: Vec<(
        usize,
        chrono::DateTime<chrono::Utc>,
        chrono::DateTime<chrono::Utc>,
    )> = Vec::new();
    for (i, step) in steps.iter().enumerate() {
        if !step.tool_calls.iter().any(|t| t.name == "Bash") {
            continue;
        }
        let Some(start) = parse_ts(&step.created_at) else {
            continue;
        };
        let end = steps
            .get(i + 1)
            .and_then(|n| parse_ts(&n.created_at))
            .unwrap_or_else(chrono::Utc::now);
        windows.push((step.step_index, start, end));
    }
    if windows.is_empty() {
        return;
    }
    for (abs, is_new) in git_changed_files(repo) {
        let Some(mtime) = fs::metadata(&abs).ok().and_then(|m| m.modified().ok()) else {
            continue;
        };
        if is_build_or_binary_path(&abs) {
            continue;
        }
        let mtime = chrono::DateTime::<chrono::Utc>::from(mtime);
        let Some((step_index, start, _)) = windows.iter().find(|(_, start, end)| {
            mtime >= *start && mtime <= *end + chrono::Duration::seconds(1)
        }) else {
            continue;
        };
        let path = abs.to_string_lossy().to_string();
        if files
            .iter()
            .any(|f| f.step_index == *step_index && f.path == path)
        {
            continue;
        }
        files.push(FileTouchRecord {
            path,
            action: if is_new { "created" } else { "modified" }.to_string(),
            repo: String::new(),
            agent_name: "Coordinator".to_string(),
            step_index: *step_index,
            timestamp: start.to_rfc3339(),
            added_lines: 0,
            removed_lines: 0,
            diff_preview: String::new(),
            source: "bash".to_string(),
        });
    }
}
