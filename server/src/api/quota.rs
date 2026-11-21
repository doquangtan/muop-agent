use crate::models::{QuotaReport, QuotaSnapshot};
use crate::scanner;
use axum::{response::IntoResponse, Json};

/// Báo cáo khi tác vụ lấy quota không chạy xong (lỗi thread): để client hiện "không có dữ liệu"
fn unavailable(provider: &str) -> QuotaReport {
    QuotaReport {
        provider: provider.to_string(),
        groups: Vec::new(),
        error: "Không lấy được dữ liệu quota".to_string(),
    }
}

/// Quota của cả hai provider: `GET /api/quota`.
/// Hai nguồn lấy song song; nguồn nào lỗi thì báo lỗi riêng, nguồn còn lại vẫn có dữ liệu.
/// Quota agy được phép mở TUI agy để đọc màn `/usage` khi không có hub (xem `agy_quota_report`).
pub async fn handle_quota_all() -> impl IntoResponse {
    let (agy, claude) = tokio::join!(
        tokio::task::spawn_blocking(|| scanner::agy_quota_report(true)),
        tokio::task::spawn_blocking(scanner::claude_quota_report),
    );
    Json(QuotaSnapshot {
        agy: agy.unwrap_or_else(|_| unavailable("agy")),
        claude: claude.unwrap_or_else(|_| unavailable("claude")),
    })
}

/// Quota Antigravity: `GET /api/quota/agy` (có thể mở TUI agy để đọc `/usage`, lần đầu mất ~30 giây)
pub async fn handle_quota_agy() -> impl IntoResponse {
    Json(
        tokio::task::spawn_blocking(|| scanner::agy_quota_report(true))
            .await
            .unwrap_or_else(|_| unavailable("agy")),
    )
}

/// Quota Claude Code CLI: `GET /api/quota/claude`
pub async fn handle_quota_claude() -> impl IntoResponse {
    Json(
        tokio::task::spawn_blocking(scanner::claude_quota_report)
            .await
            .unwrap_or_else(|_| unavailable("claude")),
    )
}
