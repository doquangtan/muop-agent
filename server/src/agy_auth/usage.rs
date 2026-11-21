//! Đọc quota agy từ màn `/usage` của TUI, không cần hub.
//!
//! Hub chỉ có khi có tiến trình agy đang chạy. Màn `/usage` của TUI (do [`host`](super::host) mở)
//! liệt kê phần trăm còn lại của từng nhóm model và từng cửa sổ (tuần, 5 giờ), kèm thời gian reset
//! dạng "Refreshes in 95h 38m". Email tài khoản hiện trên màn đó không được đọc hay lưu.
//!
//! Màn có thể hiện "Loading quota summary..." trước; chữ in ra là bộ đệm vẽ lại nhiều lần, nên chỉ
//! lấy khối bắt đầu từ tiêu đề "Models & Quota" gần nhất.

use crate::models::{ModelQuotaBucket, ModelQuotaGroup};
use chrono::{DateTime, Duration as ChronoDuration, Utc};
use regex::Regex;
use std::sync::OnceLock;

/// Lệnh TUI mở màn quota
pub const USAGE_COMMAND: &str = "/usage";
/// Tiêu đề khối quota (chữ thường)
pub const USAGE_TITLE: &str = "models & quota";
/// Dòng hiện trong lúc server còn tải số liệu
const LOADING_MARK: &str = "loading quota summary";

/// Phần trăm còn lại ở cuối dòng: `1.29%` hoặc `[████] 99.08%`
fn percent_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"(\d+(?:\.\d+)?)%$").expect("regex hợp lệ"))
}

/// Khối quota từ tiêu đề "Models & Quota" gần nhất (so khớp không phân biệt hoa thường, giữ nguyên độ dài)
fn last_block(text: &str) -> &str {
    match text.to_ascii_lowercase().rfind(USAGE_TITLE) {
        Some(i) => &text[i..],
        None => text,
    }
}

/// Khối quota đã vẽ xong: có số liệu cửa sổ và không còn dòng đang tải
pub fn quota_block_ready(text: &str) -> bool {
    let block = last_block(text).to_ascii_lowercase();
    block.contains(USAGE_TITLE) && !block.contains(LOADING_MARK) && block.contains("remaining")
}

/// Màn quota vẫn đang tải số liệu
pub fn still_loading(text: &str) -> bool {
    last_block(text).to_ascii_lowercase().contains(LOADING_MARK)
}

/// Thời gian còn lại đến lần reset, ví dụ `Refreshes in 95h 38m` → now + 95h38m
fn reset_after(line: &str, now: DateTime<Utc>) -> Option<DateTime<Utc>> {
    let low = line.to_ascii_lowercase();
    let rest = low.strip_prefix("refreshes in")?;
    let mut secs: i64 = 0;
    for token in rest.split_whitespace() {
        let Some((idx, unit)) = token.char_indices().last() else {
            continue;
        };
        let Ok(n) = token[..idx].parse::<i64>() else {
            continue;
        };
        secs += n * match unit {
            'd' => 86_400,
            'h' => 3_600,
            'm' => 60,
            _ => 0,
        };
    }
    (secs > 0).then(|| now + ChronoDuration::seconds(secs))
}

/// Dòng có chữ, bỏ dòng chỉ gồm khung thanh tiến trình (`[`, `]`, `█`, `░`)
fn meaningful_lines(text: &str) -> impl Iterator<Item = &str> {
    text.lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && !l.chars().all(|c| matches!(c, '[' | ']' | '█' | '░' | ' ')))
}

/// Tiêu đề nhóm model viết hoa: "GEMINI MODELS", "CLAUDE AND GPT MODELS", "GEMINI 4 ARGON"
fn is_group_header(line: &str) -> bool {
    let letters: Vec<char> = line.chars().filter(|c| c.is_alphabetic()).collect();
    letters.len() >= 4 && letters.iter().all(|c| c.is_uppercase())
}

/// Đổi tiêu đề viết hoa thành dạng đọc được: "CLAUDE AND GPT MODELS" → "Claude and GPT Models"
fn title_case(line: &str) -> String {
    line.split_whitespace()
        .enumerate()
        .map(|(i, word)| {
            let lower = word.to_lowercase();
            if lower == "gpt" {
                return "GPT".to_string();
            }
            if i > 0 && lower == "and" {
                return lower;
            }
            let mut chars = lower.chars();
            match chars.next() {
                Some(first) => first.to_uppercase().collect::<String>() + chars.as_str(),
                None => String::new(),
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

/// Cửa sổ quota theo nhãn dòng: "Weekly Limit Remaining", "Gemini 4 Argon Weekly Limit",
/// "Five Hour Limit Remaining"
fn window_of(line: &str) -> Option<&'static str> {
    let low = line.to_ascii_lowercase();
    if low.contains("weekly limit") {
        Some("weekly")
    } else if low.contains("five hour limit") {
        Some("5h")
    } else {
        None
    }
}

/// Phân tích chữ của màn `/usage` thành các nhóm quota. Lỗi nếu không có cửa sổ nào.
pub fn parse_usage_screen(text: &str, now: DateTime<Utc>) -> Result<Vec<ModelQuotaGroup>, String> {
    let mut groups: Vec<ModelQuotaGroup> = Vec::new();
    let mut current: Option<ModelQuotaGroup> = None;
    // Nhãn cửa sổ đang chờ dòng phần trăm
    let mut pending: Option<(String, &'static str)> = None;
    // Vị trí cửa sổ vừa thêm, để gắn thời gian reset ở dòng ngay sau
    let mut last_bucket: Option<usize> = None;

    for line in meaningful_lines(last_block(text)) {
        if let Some(caps) = percent_re().captures(line) {
            let Some((label, window)) = pending.take() else {
                continue;
            };
            let pct = caps[1].parse::<f64>().unwrap_or(0.0).clamp(0.0, 100.0);
            let group = current.get_or_insert_with(|| ModelQuotaGroup {
                display_name: "Antigravity".to_string(),
                description: String::new(),
                buckets: Vec::new(),
            });
            let slug = group.display_name.to_lowercase().replace(' ', "-");
            group.buckets.push(ModelQuotaBucket {
                bucket_id: format!("{slug}:{window}"),
                display_name: label,
                description: String::new(),
                window: window.to_string(),
                remaining_fraction: pct / 100.0,
                remaining_percent: pct,
                reset_time: String::new(),
            });
            last_bucket = Some(group.buckets.len() - 1);
        } else if let Some(reset) = reset_after(line, now) {
            if let (Some(group), Some(idx)) = (current.as_mut(), last_bucket) {
                group.buckets[idx].reset_time = reset.to_rfc3339();
            }
        } else if let Some(window) = window_of(line) {
            pending = Some((line.to_string(), window));
        } else if is_group_header(line) {
            groups.extend(current.take());
            current = Some(ModelQuotaGroup {
                display_name: title_case(line),
                description: String::new(),
                buckets: Vec::new(),
            });
            pending = None;
            last_bucket = None;
        } else if let Some(models) = line.strip_prefix("Models within this group:") {
            if let Some(group) = current.as_mut() {
                group.description = format!("Model: {}", models.trim());
            }
        }
    }
    groups.extend(current.take());
    groups.retain(|g| !g.buckets.is_empty());
    if groups.is_empty() {
        return Err("Không đọc được quota trên màn /usage của agy".to_string());
    }
    Ok(groups)
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    /// Layout 1 (agy desktop): thanh tiến trình nhiều dòng, phần trăm dòng riêng.
    /// Đã bỏ ANSI; email tài khoản thay bằng `<email>`.
    const SAMPLE_SPLIT: &str = "\
└ Models & Quota
Account:
<email>
GEMINI MODELS
Models within this group: Gemini 4 Neon, Gemini 4 Hydrogen, Orchestrator (Neon), Gemini 3.8 Flash
Weekly Limit Remaining
[
█
░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
]
1.29%
Refreshes in 95h 38m
Five Hour Limit Remaining
[
██████████████████████████████████████████████████
]
100.00%
Quota available
CLAUDE AND GPT MODELS
Models within this group: Claude Opus 5.5, Claude Sonnet 5.5, GPT-OSS 120B
Weekly Limit Remaining
[
██████████████████████████████████████████████████
]
100.00%
Quota available
Five Hour Limit Remaining
[
██████████████████████████████████████████████████
]
100.00%
Quota available
GEMINI 4 ARGON
For paid Pro plans, Argon quota is separate. Higher Argon quota (included as part of the larger Gemini quota bucket) is available on Ultra plans.
Gemini 4 Argon Weekly Limit
[
░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
]
0.00%
Refreshes in 97h 11m
";

    /// Layout 2 (agy laptop): thanh tiến trình một dòng có phần trăm cuối dòng; trước đó còn khung
    /// "Loading quota summary..." đã vẽ. Đã bỏ ANSI; email đã bỏ.
    const SAMPLE_INLINE: &str = "\
└ Models & Quota
  Account: <email>
  ⣷  Loading quota summary...
  ↑/↓ Scroll · esc Close
└ Models & Quota
GEMINI MODELS
  Models within this group: Gemini 3.8 Flash
  Weekly Limit Remaining
    [██████████████████████████████████████████████████] 99.08%
Refreshes in 150h 59m
  Five Hour Limit Remaining
[██████████████████████████████████████████████████] 99.72%
Refreshes in 1h 34m
CLAUDE AND GPT MODELS
  Models within this group: Claude Sonnet 4.6, Claude Opus 4.6, GPT-OSS 120B
  Weekly Limit Remaining
[██████████████████████████████████████████████████] 100.00%
Quota available
  Five Hour Limit Remaining
[██████████████████████████████████████████████████] 100.00%
Quota available
";

    const LOADING_ONLY: &str = "\
└ Models & Quota
  Account: <email>
  ⣷  Loading quota summary...
  ↑/↓ Scroll · esc Close
";

    fn now() -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 11, 21, 0, 0, 0).unwrap()
    }

    #[test]
    fn parses_split_layout_groups_windows_and_percentages() {
        let groups = parse_usage_screen(SAMPLE_SPLIT, now()).unwrap();
        assert_eq!(groups.len(), 3);

        let gemini = &groups[0];
        assert_eq!(gemini.display_name, "Gemini Models");
        assert_eq!(gemini.buckets.len(), 2);
        assert_eq!(gemini.buckets[0].window, "weekly");
        assert!((gemini.buckets[0].remaining_percent - 1.29).abs() < 1e-9);
        assert_eq!(gemini.buckets[1].window, "5h");
        assert!(gemini.description.starts_with("Model: Gemini 4 Neon"));

        let claude = &groups[1];
        assert_eq!(claude.display_name, "Claude and GPT Models");
        assert_eq!(claude.buckets.len(), 2);
        assert!(claude.buckets.iter().all(|b| b.reset_time.is_empty()));

        let argon = &groups[2];
        assert_eq!(argon.display_name, "Gemini 4 Argon");
        assert_eq!(argon.buckets.len(), 1);
        assert!(argon.buckets[0].remaining_percent.abs() < 1e-9);
    }

    #[test]
    fn parses_inline_layout_and_ignores_loading_frame() {
        let groups = parse_usage_screen(SAMPLE_INLINE, now()).unwrap();
        assert_eq!(groups.len(), 2);

        let gemini = &groups[0];
        assert_eq!(gemini.display_name, "Gemini Models");
        assert_eq!(gemini.buckets.len(), 2);
        assert_eq!(gemini.buckets[0].window, "weekly");
        assert!((gemini.buckets[0].remaining_percent - 99.08).abs() < 1e-9);
        assert_eq!(gemini.buckets[1].window, "5h");
        assert!((gemini.buckets[1].remaining_percent - 99.72).abs() < 1e-9);

        let claude = &groups[1];
        assert_eq!(claude.display_name, "Claude and GPT Models");
        assert!((claude.buckets[1].remaining_percent - 100.0).abs() < 1e-9);
    }

    #[test]
    fn reset_time_is_now_plus_refresh_duration() {
        let groups = parse_usage_screen(SAMPLE_SPLIT, now()).unwrap();
        let expected = now() + ChronoDuration::hours(95) + ChronoDuration::minutes(38);
        assert_eq!(groups[0].buckets[0].reset_time, expected.to_rfc3339());
        let expected = now() + ChronoDuration::hours(97) + ChronoDuration::minutes(11);
        assert_eq!(groups[2].buckets[0].reset_time, expected.to_rfc3339());

        let groups = parse_usage_screen(SAMPLE_INLINE, now()).unwrap();
        let expected = now() + ChronoDuration::hours(1) + ChronoDuration::minutes(34);
        assert_eq!(groups[0].buckets[1].reset_time, expected.to_rfc3339());
    }

    #[test]
    fn loading_frame_is_not_ready_and_is_detected() {
        assert!(still_loading(LOADING_ONLY));
        assert!(!quota_block_ready(LOADING_ONLY));
        assert!(!still_loading(SAMPLE_INLINE));
        assert!(quota_block_ready(SAMPLE_INLINE));
        assert!(quota_block_ready(SAMPLE_SPLIT));
        assert!(parse_usage_screen(LOADING_ONLY, now()).is_err());
    }

    #[test]
    fn screen_without_quota_is_an_error() {
        assert!(parse_usage_screen("Select login method\nGoogle OAuth", now()).is_err());
        assert!(parse_usage_screen("", now()).is_err());
    }

    #[test]
    fn title_case_keeps_gpt_and_lowercases_and() {
        assert_eq!(title_case("CLAUDE AND GPT MODELS"), "Claude and GPT Models");
        assert_eq!(title_case("GEMINI 4 ARGON"), "Gemini 4 Argon");
    }
}
