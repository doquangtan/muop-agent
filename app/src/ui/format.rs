//! Định dạng hiển thị thuần (không phụ thuộc Dioxus).

use chrono::{DateTime, Local};

/// `230186` → `230.2K`, `1200000` → `1.2M`.
pub fn format_tokens(n: u64) -> String {
    if n < 1_000 {
        n.to_string()
    } else if n < 1_000_000 {
        format!("{:.1}K", n as f64 / 1_000.0)
    } else {
        format!("{:.1}M", n as f64 / 1_000_000.0)
    }
}

/// Thời gian RFC 3339 của server → giờ địa phương `dd/mm HH:MM`.
/// Trả chuỗi rỗng nếu không parse được.
pub fn short_local_time(iso: &str) -> String {
    DateTime::parse_from_rfc3339(iso)
        .map(|t| t.with_timezone(&Local).format("%d/%m %H:%M").to_string())
        .unwrap_or_default()
}

/// Nhãn tiếng Việt cho `currentPhase`/`status` của conversation.
pub fn status_label(status: &str, is_running: bool, is_interrupted: bool) -> &'static str {
    if is_running || status == "running" {
        "Đang chạy"
    } else if is_interrupted || status == "interrupted" {
        "Bị gián đoạn"
    } else if status == "completed" {
        "Hoàn tất"
    } else {
        "Không rõ"
    }
}

/// Tên hiển thị của model: bỏ tiền tố provider (`agy:`, `claude-cli:`).
pub fn model_label(model: &str) -> String {
    model
        .split_once(':')
        .map(|(_, name)| name.to_string())
        .unwrap_or_else(|| model.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tokens_are_compacted() {
        assert_eq!(format_tokens(0), "0");
        assert_eq!(format_tokens(999), "999");
        assert_eq!(format_tokens(1_500), "1.5K");
        assert_eq!(format_tokens(230_186), "230.2K");
        assert_eq!(format_tokens(1_200_000), "1.2M");
    }

    #[test]
    fn local_time_has_fixed_shape_or_is_empty() {
        let t = short_local_time("2026-11-27T14:41:28.455171648+00:00");
        assert_eq!(t.len(), 11, "got {t:?}");
        assert_eq!(&t[2..3], "/");
        assert_eq!(&t[5..6], " ");
        assert_eq!(short_local_time("không phải ngày"), "");
    }

    #[test]
    fn status_labels_cover_known_states() {
        assert_eq!(status_label("running", true, false), "Đang chạy");
        assert_eq!(status_label("completed", false, false), "Hoàn tất");
        assert_eq!(status_label("", false, true), "Bị gián đoạn");
        assert_eq!(status_label("weird", false, false), "Không rõ");
    }

    #[test]
    fn model_label_strips_provider() {
        assert_eq!(
            model_label("agy:gemini-4-hydrogen-high"),
            "gemini-4-hydrogen-high"
        );
        assert_eq!(model_label("plain"), "plain");
    }
}
