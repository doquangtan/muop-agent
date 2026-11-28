//! Gom id model thành nhóm và tách mức suy luận ở cuối id. Port của
//! `lib/features/chat/domain/model_groups.dart` (logic thuần, không phụ thuộc giao diện).
//!
//! Ví dụ: `agy:gemini-4-argon-medium` và `agy:gemini-4-argon-high` thành nhóm
//! `agy:gemini-4-argon` với các mức `medium`, `high`.

use std::collections::HashMap;

pub const FALLBACK_EFFORT_LEVELS: [&str; 5] = ["low", "medium", "high", "xhigh", "max"];
pub const DEFAULT_EFFORT: &str = "medium";

#[derive(Debug, Clone, PartialEq)]
pub struct ModelOption {
    /// Id đầy đủ gửi lên server, ví dụ `agy:gemini-4-argon-medium`
    pub id: String,
    /// Mức suy luận, `None` nếu model không có mức
    pub effort: Option<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ModelGroup {
    pub id: String,
    pub label: String,
    /// Sắp theo mức tăng dần
    pub options: Vec<ModelOption>,
}

impl ModelGroup {
    pub fn option_with_effort(&self, effort: Option<&str>) -> Option<&ModelOption> {
        self.options.iter().find(|o| o.effort.as_deref() == effort)
    }

    /// Lựa chọn khi chuyển sang nhóm này: giữ mức hiện tại nếu có, không thì `medium`, cuối cùng là đầu tiên.
    pub fn preferred_option(&self, current_effort: Option<&str>) -> &ModelOption {
        self.option_with_effort(current_effort)
            .or_else(|| self.option_with_effort(Some(DEFAULT_EFFORT)))
            .unwrap_or(&self.options[0])
    }

    pub fn has_effort_choices(&self) -> bool {
        self.options.len() > 1 || self.options[0].effort.is_some()
    }
}

/// Tách id thành (id nhóm, mức). Mức là `None` nếu id không kết thúc bằng một mức đã biết.
pub fn parse_model_id(id: &str, levels: &[String]) -> (String, Option<String>) {
    let (prefix, rest) = match id.find(':') {
        Some(i) => (&id[..=i], &id[i + 1..]),
        None => ("", id),
    };
    if let Some(dash) = rest.rfind('-') {
        if dash > 0 {
            let suffix = &rest[dash + 1..];
            if levels.iter().any(|l| l == suffix) {
                return (
                    format!("{prefix}{}", &rest[..dash]),
                    Some(suffix.to_string()),
                );
            }
        }
    }
    (id.to_string(), None)
}

fn effort_rank(effort: &Option<String>, levels: &[String]) -> i64 {
    match effort {
        None => -1,
        Some(e) => levels
            .iter()
            .position(|l| l == e)
            .map(|p| p as i64)
            .unwrap_or(-1),
    }
}

/// Bỏ phần mức ở cuối nhãn: `Gemini 4 Argon (Medium)` → `Gemini 4 Argon`.
/// Ngoặc chứa tên biến thể (ví dụ `Orchestrator (Carbon)`) được giữ lại.
pub fn strip_effort_suffix(label: &str, levels: &[String]) -> String {
    let trimmed = label.trim();
    if let (Some(open), true) = (trimmed.rfind('('), trimmed.ends_with(')')) {
        let inside = trimmed[open + 1..trimmed.len() - 1].trim().to_lowercase();
        if levels.iter().any(|l| l.to_lowercase() == inside) {
            return trimmed[..open].trim().to_string();
        }
    }
    trimmed.to_string()
}

/// Tên nhóm khi server không gửi nhãn: bỏ tiền tố provider, viết hoa từng từ.
pub fn fallback_group_label(group_id: &str) -> String {
    let bare = group_id.split_once(':').map(|(_, b)| b).unwrap_or(group_id);
    bare.split(['-', '_'])
        .filter(|w| !w.is_empty())
        .map(|w| {
            let mut chars = w.chars();
            match chars.next() {
                Some(first) => first.to_uppercase().collect::<String>() + chars.as_str(),
                None => String::new(),
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

/// Gom danh sách model thành nhóm, giữ thứ tự xuất hiện lần đầu.
pub fn group_models(
    models: &[String],
    labels: &HashMap<String, String>,
    levels: &[String],
) -> Vec<ModelGroup> {
    let mut order: Vec<String> = Vec::new();
    let mut by_group: HashMap<String, Vec<(ModelOption, String)>> = HashMap::new();
    for id in models {
        let (group_id, effort) = parse_model_id(id, levels);
        if !by_group.contains_key(&group_id) {
            order.push(group_id.clone());
        }
        let label = labels.get(id).cloned().unwrap_or_default();
        by_group.entry(group_id).or_default().push((
            ModelOption {
                id: id.clone(),
                effort,
            },
            label,
        ));
    }
    order
        .into_iter()
        .map(|group_id| {
            let mut entries = by_group.remove(&group_id).unwrap_or_default();
            entries.sort_by_key(|(o, _)| effort_rank(&o.effort, levels));
            let label = entries
                .iter()
                .find(|(_, l)| !l.is_empty())
                .map(|(_, l)| strip_effort_suffix(l, levels))
                .unwrap_or_else(|| fallback_group_label(&group_id));
            ModelGroup {
                id: group_id,
                label,
                options: entries.into_iter().map(|(o, _)| o).collect(),
            }
        })
        .collect()
}

/// Mức dùng khi danh sách mức từ server rỗng.
pub fn resolve_levels(from_server: &[String]) -> Vec<String> {
    if from_server.is_empty() {
        FALLBACK_EFFORT_LEVELS
            .iter()
            .map(|s| s.to_string())
            .collect()
    } else {
        from_server.to_vec()
    }
}

/// Chữ hoa đầu cho mức: `xhigh` → `XHigh`, `medium` → `Medium`.
pub fn effort_label(effort: &str) -> String {
    if effort == "xhigh" {
        return "XHigh".into();
    }
    let mut chars = effort.chars();
    match chars.next() {
        Some(first) => first.to_uppercase().collect::<String>() + chars.as_str(),
        None => String::new(),
    }
}

pub const CLAUDE_SECTION_TITLE: &str = "Claude Code CLI · limit tài khoản Claude";
pub const AGY_SECTION_TITLE: &str = "Antigravity (agy) · quota Gemini/Claude";

/// Một khối trong menu chọn model: tiêu đề và các nhóm model của provider đó.
#[derive(Debug, Clone, PartialEq)]
pub struct ModelSection {
    pub title: &'static str,
    pub groups: Vec<ModelGroup>,
}

/// Tách các nhóm thành khối theo provider (Claude trước, rồi agy), bỏ khối rỗng.
pub fn model_sections(groups: &[ModelGroup]) -> Vec<ModelSection> {
    let claude: Vec<ModelGroup> = groups
        .iter()
        .filter(|g| g.id.starts_with("claude-cli:"))
        .cloned()
        .collect();
    let agy: Vec<ModelGroup> = groups
        .iter()
        .filter(|g| g.id.starts_with("agy:"))
        .cloned()
        .collect();
    let mut out = Vec::new();
    if !claude.is_empty() {
        out.push(ModelSection {
            title: CLAUDE_SECTION_TITLE,
            groups: claude,
        });
    }
    if !agy.is_empty() {
        out.push(ModelSection {
            title: AGY_SECTION_TITLE,
            groups: agy,
        });
    }
    out
}

/// Model mặc định khi chưa chọn: `claude-cli:claude-sonnet-5-5` nếu có, không thì model đầu tiên.
pub fn default_model(models: &[String]) -> Option<String> {
    if models.iter().any(|m| m == "claude-cli:claude-sonnet-5-5") {
        return Some("claude-cli:claude-sonnet-5-5".into());
    }
    models.first().cloned()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn levels() -> Vec<String> {
        resolve_levels(&[])
    }

    #[test]
    fn parses_effort_suffix_and_keeps_plain_ids() {
        assert_eq!(
            parse_model_id("agy:gemini-4-argon-medium", &levels()),
            ("agy:gemini-4-argon".into(), Some("medium".into()))
        );
        assert_eq!(
            parse_model_id("claude-cli:claude-sonnet-5-5", &levels()),
            ("claude-cli:claude-sonnet-5-5".into(), None)
        );
    }

    #[test]
    fn groups_variants_sorted_by_effort() {
        let models = vec![
            "agy:gemini-4-argon-high".to_string(),
            "agy:gemini-4-argon-low".to_string(),
            "agy:gemini-4-argon-medium".to_string(),
        ];
        let mut labels = HashMap::new();
        labels.insert(
            "agy:gemini-4-argon-high".to_string(),
            "Gemini 4 Argon (High)".to_string(),
        );
        let groups = group_models(&models, &labels, &levels());
        assert_eq!(groups.len(), 1);
        assert_eq!(groups[0].label, "Gemini 4 Argon");
        let efforts: Vec<_> = groups[0]
            .options
            .iter()
            .map(|o| o.effort.clone().unwrap())
            .collect();
        assert_eq!(efforts, vec!["low", "medium", "high"]);
    }

    #[test]
    fn keeps_variant_names_in_parentheses() {
        assert_eq!(
            strip_effort_suffix("Orchestrator (Carbon)", &levels()),
            "Orchestrator (Carbon)"
        );
        assert_eq!(
            strip_effort_suffix("Orchestrator (Medium)", &levels()),
            "Orchestrator"
        );
    }

    #[test]
    fn preferred_option_keeps_effort_then_medium() {
        let models = vec![
            "x:m-low".to_string(),
            "x:m-medium".to_string(),
            "x:m-high".to_string(),
        ];
        let groups = group_models(&models, &HashMap::new(), &levels());
        let g = &groups[0];
        assert_eq!(g.preferred_option(Some("high")).id, "x:m-high");
        assert_eq!(g.preferred_option(Some("max")).id, "x:m-medium");
        assert_eq!(g.preferred_option(None).id, "x:m-medium");
    }

    #[test]
    fn fallback_label_and_effort_label() {
        assert_eq!(
            fallback_group_label("agy:gemini-4-hydrogen"),
            "Gemini 4 Hydrogen"
        );
        assert_eq!(effort_label("xhigh"), "XHigh");
        assert_eq!(effort_label("medium"), "Medium");
    }

    #[test]
    fn sections_split_by_provider_in_order() {
        let models = vec![
            "agy:gemini-4-argon-low".to_string(),
            "claude-cli:claude-sonnet-5-5".to_string(),
            "agy:gemini-4-argon-high".to_string(),
        ];
        let groups = group_models(&models, &HashMap::new(), &levels());
        let sections = model_sections(&groups);
        assert_eq!(sections.len(), 2);
        assert_eq!(sections[0].title, CLAUDE_SECTION_TITLE);
        assert_eq!(sections[0].groups.len(), 1);
        assert_eq!(sections[1].title, AGY_SECTION_TITLE);
        assert_eq!(sections[1].groups[0].options.len(), 2);
        assert!(model_sections(&[]).is_empty());
    }

    #[test]
    fn default_model_prefers_sonnet_then_first() {
        let with = vec![
            "agy:a".to_string(),
            "claude-cli:claude-sonnet-5-5".to_string(),
        ];
        assert_eq!(
            default_model(&with).unwrap(),
            "claude-cli:claude-sonnet-5-5"
        );
        assert_eq!(default_model(&["agy:a".to_string()]).unwrap(), "agy:a");
        assert!(default_model(&[]).is_none());
    }
}
