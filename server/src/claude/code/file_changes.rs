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
    // --no-optional-locks: không giành khóa index với git khác (tránh index.lock làm lệnh thất bại)
    let mut ok = false;
    if let Ok(out) = Command::new("git")
        .args([
            "--no-optional-locks",
            "-C",
            repo,
            "status",
            "--porcelain",
            "--untracked-files=all",
        ])
        .output()
    {
        if out.status.success() {
            ok = true;
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
    // Chỉ cache kết quả thành công: lỗi tạm thời không được giữ 5 giây
    if ok {
        if let Ok(mut map) = cache.lock() {
            map.insert(repo.to_string(), (Instant::now(), result.clone()));
        }
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

/// Bổ sung thay đổi file do lệnh Bash tạo ra (sed -i, python, cat >, ...) cho MỘT bước Bash: các file đã
/// thay đổi trong repo (git status) có mtime nằm trong khoảng từ bước đó đến bước kế tiếp (`end`).
/// Các lệnh này không có tool Edit/Write nên không được ghi nhận khi duyệt tool call.
pub(super) fn detect_bash_window(
    repo: &str,
    step_index: usize,
    start: chrono::DateTime<chrono::Utc>,
    end: chrono::DateTime<chrono::Utc>,
    files: &mut Vec<FileTouchRecord>,
) {
    if repo.is_empty() {
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
        if !(mtime >= start && mtime <= end + chrono::Duration::seconds(1)) {
            continue;
        }
        let path = abs.to_string_lossy().to_string();
        if files
            .iter()
            .any(|f| f.step_index == step_index && f.path == path)
        {
            continue;
        }
        files.push(FileTouchRecord {
            path,
            action: if is_new { "created" } else { "modified" }.to_string(),
            repo: String::new(),
            agent_name: "Coordinator".to_string(),
            step_index,
            timestamp: start.to_rfc3339(),
            added_lines: 0,
            removed_lines: 0,
            diff_preview: String::new(),
            source: "bash".to_string(),
        });
    }
}

/// Đường dẫn bị xóa bởi `rm`, `unlink` hoặc `git rm` trong một lệnh Bash. Chỉ xét lệnh đứng đầu
/// mỗi đoạn (sau `&&`, `;`, `|`...). Bỏ qua flag, glob, biến shell và chuyển hướng vì không biết
/// chính xác file nào bị xóa.
pub(super) fn rm_targets(command: &str) -> Vec<String> {
    let mut out = Vec::new();
    for segment in command.split(['\n', ';', '|', '&']) {
        let tokens: Vec<&str> = segment.split_whitespace().collect();
        let rest: &[&str] = match tokens.first() {
            Some(&"sudo") => &tokens[1..],
            _ => &tokens[..],
        };
        let args: &[&str] = match rest {
            ["rm", args @ ..] | ["unlink", args @ ..] => args,
            ["git", "rm", args @ ..] => args,
            _ => continue,
        };
        for arg in args {
            let arg = arg.trim_matches(|c| c == '"' || c == '\'');
            if arg.is_empty()
                || arg.starts_with('-')
                || arg.starts_with('~')
                || arg.contains(['*', '?', '[', '$', '`', '>', '<'])
            {
                continue;
            }
            out.push(arg.to_string());
        }
    }
    out
}

/// Có ghi nhận file là bị xóa không: phải còn bị thiếu, và phải đã biết trước đó (agent đã tạo/sửa
/// trong session hoặc git đang theo dõi). Tránh ghi nhận nhầm khi `rm` gõ sai tên file.
pub(super) fn is_deletion_candidate(exists_now: bool, known: bool, tracked_in_git: bool) -> bool {
    !exists_now && (known || tracked_in_git)
}

/// File có đang được git theo dõi (có trong index) không
fn git_tracked(repo: &str, rel: &str) -> bool {
    Command::new("git")
        .args(["-C", repo, "ls-files", "--error-unmatch", "--", rel])
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

/// Bổ sung file bị xóa bằng lệnh Bash (`rm`, `git rm`...) cho MỘT bước. `git status` không đủ vì file đã xóa
/// không có mtime để gắn vào bước, nên đọc trực tiếp đường dẫn trong lệnh.
pub(super) fn detect_bash_deletions_in_step(
    repo: &str,
    step: &AgentStep,
    files: &mut Vec<FileTouchRecord>,
) {
    if repo.is_empty() {
        return;
    }
    let repo_path = Path::new(repo);
    for call in step.tool_calls.iter().filter(|t| t.name == "Bash") {
        let Some(command) = call.args.get("command").and_then(|v| v.as_str()) else {
            continue;
        };
        for arg in rm_targets(command) {
            let rel = arg.strip_prefix("./").unwrap_or(&arg);
            let abs = if rel.starts_with('/') {
                PathBuf::from(rel)
            } else {
                repo_path.join(rel)
            };
            let path = abs.to_string_lossy().to_string();
            let known = files
                .iter()
                .any(|f| f.path == path && f.action != "deleted");
            let tracked = !rel.starts_with('/') && git_tracked(repo, rel);
            if !is_deletion_candidate(abs.exists(), known, tracked) {
                continue;
            }
            if files
                .iter()
                .any(|f| f.step_index == step.step_index && f.path == path)
            {
                continue;
            }
            files.push(FileTouchRecord {
                path,
                action: "deleted".to_string(),
                repo: String::new(),
                agent_name: step.agent_name.clone(),
                step_index: step.step_index,
                timestamp: step.created_at.clone(),
                added_lines: 0,
                removed_lines: 0,
                diff_preview: String::new(),
                source: "bash".to_string(),
            });
        }
    }
}

#[cfg(test)]
mod deletion_tests {
    use super::*;

    #[test]
    fn rm_targets_skips_flags_globs_and_redirects() {
        assert_eq!(
            rm_targets("cd x && rm -rf build a.txt; ls -la"),
            vec!["build".to_string(), "a.txt".to_string()]
        );
        assert_eq!(
            rm_targets("rm *.txt && rm b.txt 2>/dev/null"),
            vec!["b.txt".to_string()]
        );
    }

    #[test]
    fn rm_targets_handles_sudo_git_rm_and_ignores_other_commands() {
        assert_eq!(rm_targets("sudo rm a"), vec!["a".to_string()]);
        assert_eq!(
            rm_targets("git rm -r --cached dir"),
            vec!["dir".to_string()]
        );
        assert!(rm_targets("echo rm a").is_empty());
        assert!(rm_targets("cat a.txt | wc -l").is_empty());
    }

    #[test]
    fn deletion_needs_known_or_tracked_and_missing_file() {
        assert!(is_deletion_candidate(false, true, false));
        assert!(is_deletion_candidate(false, false, true));
        assert!(
            !is_deletion_candidate(false, false, false),
            "typo: never existed"
        );
        assert!(
            !is_deletion_candidate(true, true, true),
            "rm failed, file still there"
        );
    }
}
