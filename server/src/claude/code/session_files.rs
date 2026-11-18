use super::*;

pub(crate) fn fingerprint(path: &Path) -> Option<(u64, u64)> {
    let meta = fs::metadata(path).ok()?;
    let mtime = meta
        .modified()
        .ok()?
        .duration_since(UNIX_EPOCH)
        .ok()?
        .as_millis() as u64;
    Some((mtime, meta.len()))
}

/// Fingerprint của cả session, gồm transcript của sub-agent để cache làm mới khi sub-agent chạy
pub(super) fn session_fingerprint(path: &Path) -> Option<(u64, u64)> {
    let (mut mtime, mut size) = fingerprint(path)?;
    if let Ok(entries) = fs::read_dir(subagent_dir(path)) {
        for entry in entries.flatten() {
            if let Some((m, s)) = fingerprint(&entry.path()) {
                mtime = mtime.max(m);
                size += s;
            }
        }
    }
    Some((mtime, size))
}

pub(super) fn subagent_dir(session_path: &Path) -> PathBuf {
    session_path.with_extension("").join("subagents")
}

/// Liệt kê file session `.jsonl` mới nhất trong toàn bộ thư mục projects
pub(super) fn list_session_files() -> Vec<(PathBuf, (u64, u64))> {
    let mut files: Vec<(PathBuf, (u64, u64))> = Vec::new();
    let Ok(dirs) = fs::read_dir(projects_dir()) else {
        return files;
    };
    for dir in dirs.flatten() {
        let Ok(entries) = fs::read_dir(dir.path()) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().and_then(|e| e.to_str()) != Some("jsonl") {
                continue;
            }
            if let Some(fp) = session_fingerprint(&path) {
                files.push((path, fp));
            }
        }
    }
    files.sort_by(|a, b| b.1 .0.cmp(&a.1 .0));
    files.truncate(MAX_SESSION_FILES);
    files
}

/// Tìm file `<session-id>.jsonl` trong các thư mục project
pub(crate) fn find_session_file(session_id: &str) -> Option<PathBuf> {
    if session_id.is_empty()
        || session_id.contains('/')
        || session_id.contains('\\')
        || session_id.contains("..")
    {
        return None;
    }
    let file_name = format!("{}.jsonl", session_id);
    let dirs = fs::read_dir(projects_dir()).ok()?;
    for dir in dirs.flatten() {
        let candidate = dir.path().join(&file_name);
        if candidate.is_file() {
            return Some(candidate);
        }
    }
    None
}
