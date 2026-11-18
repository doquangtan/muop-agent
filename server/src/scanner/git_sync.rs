use super::*;

/// Kiểm tra trạng thái Git (nhánh hiện tại, commit mới nhất, số commit chưa push lên server)
pub fn check_git_sync_status(project_path_str: &str) -> Option<GitSyncStatus> {
    if project_path_str.trim().is_empty() {
        return None;
    }
    let p = Path::new(project_path_str);
    if !p.exists() || !p.is_dir() {
        return None;
    }
    if !p.join(".git").exists() {
        return None;
    }

    // 1. Lấy tên nhánh hiện tại (branch name)
    let branch_out = Command::new("git")
        .args(["rev-parse", "--abbrev-ref", "HEAD"])
        .current_dir(p)
        .output()
        .ok()?;
    if !branch_out.status.success() {
        return None;
    }
    let branch = String::from_utf8_lossy(&branch_out.stdout)
        .trim()
        .to_string();
    if branch.is_empty() || branch == "HEAD" {
        return None;
    }

    // 2. Kiểm tra số commit chưa push lên remote (ahead count)
    let mut ahead_count: usize = 0;
    let mut count_determined = false;

    // Cách 1: Thử git rev-list --count @{u}..HEAD (nếu upstream đã thiết lập)
    if let Ok(out) = Command::new("git")
        .args(["rev-list", "--count", "@{u}..HEAD"])
        .current_dir(p)
        .output()
    {
        if out.status.success() {
            let s = String::from_utf8_lossy(&out.stdout).trim().to_string();
            if let Ok(n) = s.parse::<usize>() {
                ahead_count = n;
                count_determined = true;
            }
        }
    }

    // Cách 2: Fallback thử origin/<branch>..HEAD
    if !count_determined {
        let origin_ref = format!("origin/{}..HEAD", branch);
        if let Ok(out) = Command::new("git")
            .args(["rev-list", "--count", &origin_ref])
            .current_dir(p)
            .output()
        {
            if out.status.success() {
                let s = String::from_utf8_lossy(&out.stdout).trim().to_string();
                if let Ok(n) = s.parse::<usize>() {
                    ahead_count = n;
                    count_determined = true;
                }
            }
        }
    }

    // Cách 3: Fallback phân tích cú pháp git status -sb (tìm chuỗi [ahead X])
    if !count_determined {
        if let Ok(out) = Command::new("git")
            .args(["status", "-sb"])
            .current_dir(p)
            .output()
        {
            let s = String::from_utf8_lossy(&out.stdout);
            if let Some(pos) = s.find("[ahead ") {
                let rest = &s[pos + 7..];
                if let Some(end_pos) = rest.find(']') {
                    let num_str = rest[..end_pos].trim();
                    if let Ok(n) = num_str.parse::<usize>() {
                        ahead_count = n;
                    }
                }
            }
        }
    }

    // 3. Lấy thông tin commit mới nhất
    let log_out = Command::new("git")
        .args(["log", "-1", "--pretty=format:%h\t%s\t%an\t%cI"])
        .current_dir(p)
        .output()
        .ok()?;
    let log_str = String::from_utf8_lossy(&log_out.stdout).trim().to_string();
    let parts: Vec<&str> = log_str.split('\t').collect();
    let last_commit_hash = parts.first().unwrap_or(&"").to_string();
    let last_commit_message = parts.get(1).unwrap_or(&"").to_string();
    let last_commit_author = parts.get(2).unwrap_or(&"").to_string();
    let last_commit_at = parts.get(3).unwrap_or(&"").to_string();

    let project_name = p
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("project")
        .to_string();

    Some(GitSyncStatus {
        project_path: project_path_str.to_string(),
        project_name,
        branch,
        ahead_count,
        last_commit_hash,
        last_commit_message,
        last_commit_author,
        last_commit_at,
        is_ahead: ahead_count > 0,
    })
}
