//! Các bước của luồng đăng nhập agy trong terminal SSH, đánh giá từ đầu ra của TUI.
//!
//! 1. `waiting_link`: chỉ có terminal. Người dùng làm theo agy (đồng ý điều khoản nếu có) cho tới khi link hiện ra.
//! 2. `awaiting_token`: có link. Client hiện nút Mở link, Sao chép và ô nhập mã.
//! 3. `verifying`: đã gửi mã, agy chưa đổi màn hình.
//! 4. `awaiting_terms`: agy nhận mã nhưng hỏi điều khoản. Người dùng xác nhận trong terminal, SSH vẫn mở.
//! 5. `done`: agy vào màn chat (đã đăng nhập). Server đóng SSH và báo thành công.
//!    `failed`: agy in lỗi xác thực.
//!
//! Mã đã gửi nhưng màn nhập mã vẫn còn (agy chưa nhận) thì quay về `awaiting_token`.

use super::tui;

/// Bước hiện tại của luồng đăng nhập
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum Stage {
    WaitingLink,
    AwaitingToken,
    Verifying,
    AwaitingTerms,
    Done,
    Failed(String),
}

impl Stage {
    /// Tên gửi cho client (`loginStage`)
    pub(super) fn name(&self) -> &'static str {
        match self {
            Stage::WaitingLink => "waiting_link",
            Stage::AwaitingToken => "awaiting_token",
            Stage::Verifying => "verifying",
            Stage::AwaitingTerms => "awaiting_terms",
            Stage::Done => "done",
            Stage::Failed(_) => "failed",
        }
    }
}

/// Màn nhập mã của agy (so sánh chữ thường). Còn hiện sau khi gửi thì agy chưa nhận mã.
const CODE_PAGE_MARKS: [&str; 2] = ["open the url", "paste this code"];

/// Đánh giá bước từ chữ đã bỏ ANSI của terminal.
/// - `has_url`: đã thấy link Google OAuth trong đầu ra.
/// - `submitted`: độ dài chữ đã có khi gửi mã (None nếu chưa gửi). Chỉ xét chữ mới sau mốc này.
pub(super) fn assess(text: &str, has_url: bool, submitted: Option<usize>) -> Stage {
    let Some(from) = submitted else {
        // Chưa gửi mã: đã vào màn chat thì đã đăng nhập từ trước
        if tui::chat_ready(text) || tui::auth_succeeded(text) {
            return Stage::Done;
        }
        return if has_url {
            Stage::AwaitingToken
        } else {
            Stage::WaitingLink
        };
    };
    // Mốc không khớp (đầu ra bị cắt bớt) thì xét toàn bộ chữ
    let after = text.get(from..).unwrap_or(text);
    if let Some(message) = tui::auth_error(after) {
        return Stage::Failed(message);
    }
    if tui::auth_succeeded(after) || tui::chat_ready(after) {
        return Stage::Done;
    }
    let low = after.to_lowercase();
    if low.contains("terms of service") {
        return Stage::AwaitingTerms;
    }
    if CODE_PAGE_MARKS.iter().any(|m| low.contains(m)) {
        return Stage::AwaitingToken;
    }
    Stage::Verifying
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn waits_for_link_before_link_appears() {
        let menu = "Welcome to the Antigravity CLI. Select login method: > 1. Google OAuth";
        assert_eq!(assess(menu, false, None), Stage::WaitingLink);
    }

    #[test]
    fn shows_token_step_once_link_is_known() {
        let text = "Open the URL below in your browser: https://accounts.google.com/o/oauth2/auth";
        assert_eq!(assess(text, true, None), Stage::AwaitingToken);
    }

    #[test]
    fn already_signed_in_is_done_without_submit() {
        assert_eq!(
            assess("? for shortcuts auto · Gemini 3.8 Flash", false, None),
            Stage::Done
        );
    }

    #[test]
    fn verifying_while_agy_has_not_changed_screen() {
        let before = "Paste this code into your application";
        assert_eq!(assess(before, true, Some(before.len())), Stage::Verifying);
    }

    #[test]
    fn code_page_still_visible_means_token_not_taken() {
        let before = "xxxx";
        let text = "xxxx Open the URL below in your browser:";
        assert_eq!(assess(text, true, Some(before.len())), Stage::AwaitingToken);
    }

    #[test]
    fn terms_after_token_waits_for_user_in_terminal() {
        let before = "code page";
        let text = "code page Terms of Service & Data Use [done]";
        assert_eq!(assess(text, true, Some(before.len())), Stage::AwaitingTerms);
    }

    #[test]
    fn chat_after_token_is_done() {
        let before = "code page";
        let text = "code page ? for shortcuts auto";
        assert_eq!(assess(text, true, Some(before.len())), Stage::Done);
    }

    #[test]
    fn error_after_token_is_failed_with_message() {
        let before = "code page";
        let text = "code page Got an error: token exchange failed. Press any key to go back.";
        assert_eq!(
            assess(text, true, Some(before.len())),
            Stage::Failed("token exchange failed.".to_string())
        );
    }
}
