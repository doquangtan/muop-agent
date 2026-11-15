//! Trạng thái git của project (so với HEAD đang checkout) để tô màu explorer.

use std::collections::HashMap;
use std::path::Path;
use std::process::Command;

use axum::extract::Query;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;
use serde::Serialize;

/// Số mục tối đa trả về (repo rất lớn với nhiều file mới thì cắt bớt)
const MAX_ENTRIES: usize = 5000;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GitStatusResponse {
    pub ok: bool,
    /// false nếu thư mục không nằm trong git repository
    pub is_repo: bool,
    /// Đường dẫn tuyệt đối → "created" | "modified" | "deleted"
    pub kinds: HashMap<String, String>,
    pub truncated: bool,
    pub error: String,
}

impl GitStatusResponse {
    fn not_repo() -> Self {
        Self {
            ok: true,
            is_repo: false,
            kinds: HashMap::new(),
            truncated: false,
            error: String::new(),
        }
    }

    fn failure(message: &str) -> Self {
        Self {
            ok: false,
            is_repo: false,
            kinds: HashMap::new(),
            truncated: false,
            error: message.to_string(),
        }
    }
}

/// Phân loại một cặp ký tự trạng thái của `git status --porcelain`
fn classify(x: char, y: char) -> &'static str {
    if x == '?' || y == '?' || x == 'A' {
        "created"
    } else if x == 'D' || y == 'D' {
        "deleted"
    } else {
        "modified"
    }
}

fn run_git(dir: &Path, args: &[&str]) -> Option<std::process::Output> {
    Command::new("git")
        .args(args)
        .current_dir(dir)
        .output()
        .ok()
}

/// Trạng thái git của project. Chạy trong spawn_blocking vì gọi tiến trình git.
pub fn compute_git_status(project_path: &str) -> GitStatusResponse {
    let dir = Path::new(project_path);
    if !dir.is_dir() {
        return GitStatusResponse::failure("Thư mục project không tồn tại");
    }

    let top = match run_git(dir, &["rev-parse", "--show-toplevel"]) {
        Some(out) if out.status.success() => {
            String::from_utf8_lossy(&out.stdout).trim().to_string()
        }
        _ => return GitStatusResponse::not_repo(),
    };

    let Some(out) = run_git(
        dir,
        &["status", "--porcelain=v1", "-z", "--untracked-files=all"],
    ) else {
        return GitStatusResponse::failure("Không chạy được git status");
    };
    if !out.status.success() {
        return GitStatusResponse::failure("git status trả lỗi");
    }

    let mut kinds = HashMap::new();
    let mut truncated = false;
    // Định dạng -z: "XY <path>\0"; với đổi tên/sao chép còn thêm "<path cũ>\0"
    let mut tokens = out.stdout.split(|b| *b == 0).filter(|t| !t.is_empty());
    while let Some(token) = tokens.next() {
        if token.len() < 4 {
            continue;
        }
        let x = token[0] as char;
        let y = token[1] as char;
        let rel = String::from_utf8_lossy(&token[3..]).into_owned();
        if x == 'R' || x == 'C' {
            // Bỏ qua đường dẫn cũ của mục đổi tên; file mới được coi là đã sửa
            tokens.next();
        }
        if kinds.len() >= MAX_ENTRIES {
            truncated = true;
            break;
        }
        let abs = format!(
            "{}/{}",
            top.trim_end_matches('/'),
            rel.trim_end_matches('/')
        );
        kinds.insert(abs, classify(x, y).to_string());
    }

    GitStatusResponse {
        ok: true,
        is_repo: true,
        kinds,
        truncated,
        error: String::new(),
    }
}

/// `GET /api/git/status?projectPath=<đường dẫn project>`
pub async fn handle_git_status(Query(params): Query<HashMap<String, String>>) -> Response {
    let project = params
        .get("projectPath")
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());
    let Some(project) = project else {
        return (
            StatusCode::BAD_REQUEST,
            Json(GitStatusResponse::failure("Thiếu projectPath")),
        )
            .into_response();
    };
    let result = tokio::task::spawn_blocking(move || compute_git_status(&project))
        .await
        .unwrap_or_else(|e| GitStatusResponse::failure(&format!("Lỗi nội bộ: {e}")));
    (StatusCode::OK, Json(result)).into_response()
}

#[cfg(test)]
mod tests {
    use super::classify;

    #[test]
    fn maps_porcelain_codes() {
        assert_eq!(classify('?', '?'), "created");
        assert_eq!(classify('A', 'M'), "created");
        assert_eq!(classify(' ', 'M'), "modified");
        assert_eq!(classify('M', ' '), "modified");
        assert_eq!(classify(' ', 'D'), "deleted");
    }
}
