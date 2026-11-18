use crate::chat::AppState;
use axum::{
    extract::{Query, State},
    http::StatusCode,
    response::IntoResponse,
    Json,
};
use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;
use std::process::Command;

pub async fn handle_git_push(
    State(state): State<AppState>,
    Json(req): Json<crate::models::GitPushRequest>,
) -> impl IntoResponse {
    let p = PathBuf::from(&req.project_path);
    if !p.exists() || !p.is_dir() {
        return (
            StatusCode::BAD_REQUEST,
            Json(crate::models::GitPushResponse {
                ok: false,
                message: format!("Thư mục dự án không tồn tại: {}", req.project_path),
                output: String::new(),
                error: Some("PathNotFound".to_string()),
            }),
        );
    }

    let mut cmd = tokio::process::Command::new("git");
    cmd.current_dir(&p);
    if !req.branch.trim().is_empty() {
        cmd.args(["push", "origin", req.branch.trim()]);
    } else {
        cmd.arg("push");
    }

    match cmd.output().await {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout).to_string();
            let stderr = String::from_utf8_lossy(&out.stderr).to_string();
            let combined = format!("{}\n{}", stdout, stderr).trim().to_string();
            if out.status.success() {
                state.broadcast_projects_update();
                (
                    StatusCode::OK,
                    Json(crate::models::GitPushResponse {
                        ok: true,
                        message: "Đã push thành công lên máy chủ từ xa (remote git repository)!"
                            .to_string(),
                        output: combined,
                        error: None,
                    }),
                )
            } else {
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(crate::models::GitPushResponse {
                        ok: false,
                        message: format!("Lỗi khi chạy git push: {}", combined),
                        output: combined,
                        error: Some("GitPushFailed".to_string()),
                    }),
                )
            }
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(crate::models::GitPushResponse {
                ok: false,
                message: format!("Không thể khởi chạy git push: {}", e),
                output: String::new(),
                error: Some(e.to_string()),
            }),
        ),
    }
}

#[derive(serde::Deserialize)]
pub struct GitHistoryQuery {
    project_path: String,
    branch: Option<String>,
    limit: Option<usize>,
}

pub async fn handle_git_history(Query(params): Query<GitHistoryQuery>) -> impl IntoResponse {
    let project_path = params.project_path.trim().to_string();
    let branch_filter = params
        .branch
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());
    let limit = params.limit.unwrap_or(100).clamp(1, 500);

    let res = tokio::task::spawn_blocking(move || {
        let p = PathBuf::from(&project_path);
        let mut canonical = fs::canonicalize(&p).unwrap_or(p);

        // Tự động tìm kiếm ngược lên thư mục cha nếu path truyền vào là thư mục con bên trong Git repo
        while !canonical.join(".git").exists() {
            if let Some(parent) = canonical.parent() {
                canonical = parent.to_path_buf();
            } else {
                break;
            }
        }

        let project_name = canonical
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("project")
            .to_string();

        if !canonical.exists() || !canonical.is_dir() {
            return crate::models::GitHistoryResponse {
                ok: false,
                project_path: canonical.to_string_lossy().to_string(),
                project_name,
                current_branch: String::new(),
                branches: vec![],
                total_commits: 0,
                commits: vec![],
                error: Some(format!(
                    "Thư mục không tồn tại: {}",
                    canonical.to_string_lossy()
                )),
            };
        }

        if !canonical.join(".git").exists() {
            return crate::models::GitHistoryResponse {
                ok: false,
                project_path: canonical.to_string_lossy().to_string(),
                project_name,
                current_branch: String::new(),
                branches: vec![],
                total_commits: 0,
                commits: vec![],
                error: Some(
                    "Thư mục này không phải là một kho lưu trữ Git (.git không tồn tại)"
                        .to_string(),
                ),
            };
        }

        // Lấy tên branch hiện tại
        let current_branch = Command::new("git")
            .current_dir(&canonical)
            .args(["rev-parse", "--abbrev-ref", "HEAD"])
            .output()
            .ok()
            .and_then(|o| {
                if o.status.success() {
                    Some(String::from_utf8_lossy(&o.stdout).trim().to_string())
                } else {
                    None
                }
            })
            .unwrap_or_else(|| "HEAD".to_string());

        // Lấy danh sách tất cả các branch (cả local và remote)
        let branches = Command::new("git")
            .current_dir(&canonical)
            .args(["branch", "-a", "--format=%(refname:short)"])
            .output()
            .ok()
            .map(|o| {
                let out = String::from_utf8_lossy(&o.stdout);
                let mut list: Vec<String> = out
                    .lines()
                    .map(|l| l.trim().to_string())
                    .filter(|l| !l.is_empty())
                    .collect();
                list.sort();
                list.dedup();
                list
            })
            .unwrap_or_default();

        let target_branch = branch_filter.unwrap_or_else(|| "HEAD".to_string());

        // Chạy git log với định dạng chuẩn phân cách ký tự điều khiển ASCII
        let log_res = Command::new("git")
            .current_dir(&canonical)
            .args([
                "log",
                &format!("-n{}", limit),
                &target_branch,
                "--pretty=format:%H\x1f%h\x1f%an\x1f%ae\x1f%aI\x1f%ar\x1f%s\x1f%b\x1f%P\x1f%D\x1e",
            ])
            .output();

        match log_res {
            Ok(out) => {
                let stdout = String::from_utf8_lossy(&out.stdout);
                let mut commits = Vec::new();
                for record in stdout.split('\x1e') {
                    let rec = record.trim();
                    if rec.is_empty() {
                        continue;
                    }
                    let fields: Vec<&str> = rec.split('\x1f').collect();
                    if fields.len() < 7 {
                        continue;
                    }

                    let hash = fields.get(0).unwrap_or(&"").trim().to_string();
                    let short_hash = fields.get(1).unwrap_or(&"").trim().to_string();
                    let author_name = fields.get(2).unwrap_or(&"").trim().to_string();
                    let author_email = fields.get(3).unwrap_or(&"").trim().to_string();
                    let committed_at = fields.get(4).unwrap_or(&"").trim().to_string();
                    let relative_time = fields.get(5).unwrap_or(&"").trim().to_string();
                    let subject = fields.get(6).unwrap_or(&"").trim().to_string();
                    let body = fields.get(7).unwrap_or(&"").trim().to_string();
                    let parent_hashes: Vec<String> = fields
                        .get(8)
                        .unwrap_or(&"")
                        .split_whitespace()
                        .map(|s| s.trim().to_string())
                        .filter(|s| !s.is_empty())
                        .collect();
                    let refs_raw = fields.get(9).unwrap_or(&"").trim();
                    let refs: Vec<String> = if !refs_raw.is_empty() {
                        refs_raw
                            .split(',')
                            .map(|s| s.trim().to_string())
                            .filter(|s| !s.is_empty())
                            .collect()
                    } else {
                        vec![]
                    };
                    let is_head = refs.iter().any(|r| r.contains("HEAD"));

                    commits.push(crate::models::GitCommitSummary {
                        hash,
                        short_hash,
                        author_name,
                        author_email,
                        committed_at,
                        relative_time,
                        subject,
                        body,
                        parent_hashes,
                        refs,
                        is_head,
                        files_count: 0,
                    });
                }

                crate::models::GitHistoryResponse {
                    ok: true,
                    project_path: canonical.to_string_lossy().to_string(),
                    project_name,
                    current_branch,
                    branches,
                    total_commits: commits.len(),
                    commits,
                    error: None,
                }
            }
            Err(e) => crate::models::GitHistoryResponse {
                ok: false,
                project_path: canonical.to_string_lossy().to_string(),
                project_name,
                current_branch,
                branches,
                total_commits: 0,
                commits: vec![],
                error: Some(format!("Lỗi khi thực thi lệnh git log: {}", e)),
            },
        }
    })
    .await
    .unwrap_or_else(|e| crate::models::GitHistoryResponse {
        ok: false,
        project_path: String::new(),
        project_name: String::new(),
        current_branch: String::new(),
        branches: vec![],
        total_commits: 0,
        commits: vec![],
        error: Some(format!("Lỗi hệ thống khi quét lịch sử git: {}", e)),
    });

    Json(res)
}

#[derive(serde::Deserialize)]
pub struct GitCommitQuery {
    project_path: String,
    hash: String,
}

pub async fn handle_git_commit(Query(params): Query<GitCommitQuery>) -> impl IntoResponse {
    let project_path = params.project_path.trim().to_string();
    let hash = params.hash.trim().to_string();

    if !hash.chars().all(|c| c.is_ascii_hexdigit()) || hash.len() < 4 || hash.len() > 40 {
        return (
            StatusCode::BAD_REQUEST,
            Json(crate::models::GitCommitDetailResponse {
                ok: false,
                project_path,
                hash,
                short_hash: String::new(),
                author_name: String::new(),
                author_email: String::new(),
                committed_at: String::new(),
                relative_time: String::new(),
                subject: String::new(),
                body: String::new(),
                parent_hashes: vec![],
                refs: vec![],
                files: vec![],
                diff: String::new(),
                error: Some("Mã băm commit không hợp lệ".to_string()),
            }),
        );
    }

    let res = tokio::task::spawn_blocking(move || {
        let p = PathBuf::from(&project_path);
        let mut canonical = fs::canonicalize(&p).unwrap_or(p);

        // Tự động tìm kiếm ngược lên thư mục cha nếu path truyền vào là thư mục con bên trong Git repo
        while !canonical.join(".git").exists() {
            if let Some(parent) = canonical.parent() {
                canonical = parent.to_path_buf();
            } else {
                break;
            }
        }

        if !canonical.exists() || !canonical.join(".git").exists() {
            return crate::models::GitCommitDetailResponse {
                ok: false,
                project_path: canonical.to_string_lossy().to_string(),
                hash: hash.clone(),
                short_hash: String::new(),
                author_name: String::new(),
                author_email: String::new(),
                committed_at: String::new(),
                relative_time: String::new(),
                subject: String::new(),
                body: String::new(),
                parent_hashes: vec![],
                refs: vec![],
                files: vec![],
                diff: String::new(),
                error: Some("Thư mục dự án không phải là kho lưu trữ Git".to_string()),
            };
        }

        // Lấy metadata của commit
        let meta_res = Command::new("git")
            .current_dir(&canonical)
            .args([
                "show",
                "-s",
                "--pretty=format:%H\x1f%h\x1f%an\x1f%ae\x1f%aI\x1f%ar\x1f%s\x1f%b\x1f%P\x1f%D",
                &hash,
            ])
            .output();

        let mut short_hash = hash.chars().take(7).collect::<String>();
        let mut author_name = String::new();
        let mut author_email = String::new();
        let mut committed_at = String::new();
        let mut relative_time = String::new();
        let mut subject = String::new();
        let mut body = String::new();
        let mut parent_hashes = Vec::new();
        let mut refs = Vec::new();

        if let Ok(meta_out) = meta_res {
            let meta_str = String::from_utf8_lossy(&meta_out.stdout);
            let fields: Vec<&str> = meta_str.split('\x1f').collect();
            if fields.len() >= 7 {
                short_hash = fields.get(1).unwrap_or(&"").trim().to_string();
                author_name = fields.get(2).unwrap_or(&"").trim().to_string();
                author_email = fields.get(3).unwrap_or(&"").trim().to_string();
                committed_at = fields.get(4).unwrap_or(&"").trim().to_string();
                relative_time = fields.get(5).unwrap_or(&"").trim().to_string();
                subject = fields.get(6).unwrap_or(&"").trim().to_string();
                body = fields.get(7).unwrap_or(&"").trim().to_string();
                parent_hashes = fields
                    .get(8)
                    .unwrap_or(&"")
                    .split_whitespace()
                    .map(|s| s.trim().to_string())
                    .filter(|s| !s.is_empty())
                    .collect();
                let refs_raw = fields.get(9).unwrap_or(&"").trim();
                if !refs_raw.is_empty() {
                    refs = refs_raw
                        .split(',')
                        .map(|s| s.trim().to_string())
                        .filter(|s| !s.is_empty())
                        .collect();
                }
            }
        }

        // Lấy danh sách files và số dòng thêm/bớt qua numstat
        let mut files_map: HashMap<String, (usize, usize, String)> = HashMap::new();
        if let Ok(numstat_out) = Command::new("git")
            .current_dir(&canonical)
            .args(["show", "--numstat", "--format=", &hash])
            .output()
        {
            let numstat_str = String::from_utf8_lossy(&numstat_out.stdout);
            for line in numstat_str.lines() {
                let parts: Vec<&str> = line.split('\t').collect();
                if parts.len() >= 3 {
                    let additions = parts[0].trim().parse::<usize>().unwrap_or(0);
                    let deletions = parts[1].trim().parse::<usize>().unwrap_or(0);
                    let file_path = parts[2].trim().to_string();
                    files_map.insert(file_path, (additions, deletions, "M".to_string()));
                }
            }
        }

        // Lấy trạng thái A, M, D, R qua name-status
        if let Ok(status_out) = Command::new("git")
            .current_dir(&canonical)
            .args(["diff-tree", "--no-commit-id", "--name-status", "-r", &hash])
            .output()
        {
            let status_str = String::from_utf8_lossy(&status_out.stdout);
            for line in status_str.lines() {
                let parts: Vec<&str> = line.split_whitespace().collect();
                if parts.len() >= 2 {
                    let status = parts[0].chars().next().unwrap_or('M').to_string();
                    let file_path = parts.last().unwrap_or(&"").to_string();
                    if let Some(entry) = files_map.get_mut(&file_path) {
                        entry.2 = status;
                    } else {
                        files_map.insert(file_path, (0, 0, status));
                    }
                }
            }
        }

        let mut files: Vec<crate::models::GitCommitFileChange> = files_map
            .into_iter()
            .map(
                |(path, (additions, deletions, status))| crate::models::GitCommitFileChange {
                    path,
                    status,
                    additions,
                    deletions,
                },
            )
            .collect();
        files.sort_by(|a, b| a.path.cmp(&b.path));

        // Lấy diff chi tiết của commit
        let diff = Command::new("git")
            .current_dir(&canonical)
            .args(["show", "--stat", "-p", &hash])
            .output()
            .ok()
            .map(|o| {
                let out = String::from_utf8_lossy(&o.stdout).to_string();
                if out.len() > 300_000 {
                    let mut truncated = out[..300_000].to_string();
                    truncated.push_str("\n\n... [Diff quá lớn đã được cắt bớt] ...");
                    truncated
                } else {
                    out
                }
            })
            .unwrap_or_default();

        crate::models::GitCommitDetailResponse {
            ok: true,
            project_path: canonical.to_string_lossy().to_string(),
            hash,
            short_hash,
            author_name,
            author_email,
            committed_at,
            relative_time,
            subject,
            body,
            parent_hashes,
            refs,
            files,
            diff,
            error: None,
        }
    })
    .await
    .unwrap_or_else(|e| crate::models::GitCommitDetailResponse {
        ok: false,
        project_path: String::new(),
        hash: String::new(),
        short_hash: String::new(),
        author_name: String::new(),
        author_email: String::new(),
        committed_at: String::new(),
        relative_time: String::new(),
        subject: String::new(),
        body: String::new(),
        parent_hashes: vec![],
        refs: vec![],
        files: vec![],
        diff: String::new(),
        error: Some(format!("Lỗi khi lấy thông tin commit: {}", e)),
    });

    (StatusCode::OK, Json(res))
}
