use super::*;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Provider {
    /// Antigravity CLI (`agy`)
    Agy,
    /// Claude Code CLI (`claude`)
    ClaudeCli,
}

/// Tách provider và tên model thực tế từ id model do UI gửi lên.
/// Id không có tiền tố được coi là id cũ: alias `sonnet/opus/haiku` → Claude, còn lại → agy.
pub fn resolve_model(raw: &str) -> (Provider, String) {
    let m = raw.trim();
    if let Some(rest) = m.strip_prefix(CLAUDE_PREFIX) {
        return (
            Provider::ClaudeCli,
            crate::claude::code::normalize_model(rest),
        );
    }
    if let Some(rest) = m.strip_prefix(AGY_PREFIX) {
        return (Provider::Agy, agy_model(rest));
    }
    if matches!(m, "sonnet" | "opus" | "haiku") {
        return (Provider::ClaudeCli, crate::claude::code::normalize_model(m));
    }
    (Provider::Agy, agy_model(m))
}

pub(super) fn agy_model(raw: &str) -> String {
    let m = raw.trim();
    if m.is_empty() || m == "default" {
        // Chưa chọn model: dùng model đầu tiên trong danh sách `agy models` (không còn danh sách cố định)
        crate::scanner::agy_model_ids()
            .into_iter()
            .next()
            .map(|id| id.trim_start_matches(AGY_PREFIX).to_string())
            .unwrap_or_default()
    } else {
        m.to_string()
    }
}

/// Lệnh `agy`: dò bằng `which` hoặc đường dẫn người dùng đã chọn trong Khởi tạo
pub(crate) fn agy_bin() -> Result<String, String> {
    crate::infra::tools::require("agy")
}
