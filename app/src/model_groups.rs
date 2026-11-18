// Port của lib/models/model_grouping.dart: gom id model thành nhóm theo tên và tách mức suy luận.
//
// Ví dụ `agy:gemini-4-argon-medium` + `agy:gemini-4-argon-high`
//   → nhóm `agy:gemini-4-argon` với các mức low/medium/high/xhigh/max.
// Model không có hậu tố mức (ví dụ `claude-cli:claude-sonnet-5-5`) là nhóm một lựa chọn.

use std::collections::HashMap;

pub const EFFORT_LEVELS: [&str; 5] = ["low", "medium", "high", "xhigh", "max"];
pub const DEFAULT_EFFORT: &str = "medium";

#[derive(Clone, Debug)]
pub struct ModelOption {
    /// Id đầy đủ gửi lên server, ví dụ `agy:gemini-4-argon-medium`
    pub id: String,
    pub effort: Option<String>,
    pub label: String,
}

#[derive(Clone, Debug)]
pub struct ModelGroup {
    pub label: String,
    /// Sắp theo mức tăng dần
    pub options: Vec<ModelOption>,
}

impl ModelGroup {
    pub fn option_with_effort(&self, effort: Option<&str>) -> Option<&ModelOption> {
        self.options.iter().find(|o| o.effort.as_deref() == effort)
    }

    /// Giữ mức hiện tại nếu nhóm có; không thì `medium`; cuối cùng là lựa chọn đầu tiên.
    pub fn preferred_option(&self, current_effort: Option<&str>) -> &ModelOption {
        self.option_with_effort(current_effort)
            .or_else(|| self.option_with_effort(Some(DEFAULT_EFFORT)))
            .unwrap_or(&self.options[0])
    }
}

/// Tách id thành (id nhóm, mức). Mức là None nếu không có hậu tố mức.
pub fn parse_model_id(id: &str) -> (String, Option<String>) {
    let (prefix, rest) = match id.find(':') {
        Some(i) => (&id[..=i], &id[i + 1..]),
        None => ("", id),
    };
    if let Some(dash) = rest.rfind('-') {
        if dash > 0 {
            let suffix = &rest[dash + 1..];
            if EFFORT_LEVELS.contains(&suffix) {
                return (
                    format!("{prefix}{}", &rest[..dash]),
                    Some(suffix.to_string()),
                );
            }
        }
    }
    (id.to_string(), None)
}

fn effort_rank(effort: Option<&str>) -> isize {
    match effort {
        None => -1,
        Some(e) => EFFORT_LEVELS
            .iter()
            .position(|l| *l == e)
            .map_or(-1, |p| p as isize),
    }
}

/// Bỏ phần nhãn trong ngoặc cuối: `Gemini 4 Argon (Medium)` → `Gemini 4 Argon`
fn strip_effort_suffix(label: &str) -> String {
    let t = label.trim_end();
    if t.ends_with(')') {
        if let Some(open) = t.rfind('(') {
            return t[..open].trim().to_string();
        }
    }
    t.to_string()
}

/// Tên nhóm khi server không có nhãn: bỏ tiền tố provider, viết hoa từng từ
fn fallback_group_label(group_id: &str) -> String {
    let bare = match group_id.find(':') {
        Some(i) => &group_id[i + 1..],
        None => group_id,
    };
    bare.split(['-', '_'])
        .filter(|w| !w.is_empty())
        .map(|w| {
            let mut cs = w.chars();
            match cs.next() {
                Some(f) => f.to_uppercase().collect::<String>() + cs.as_str(),
                None => String::new(),
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

/// Nhãn mức để hiển thị: `xhigh` → `XHigh`, `medium` → `Medium`
pub fn effort_label(effort: &str) -> String {
    if effort == "xhigh" {
        return "XHigh".to_string();
    }
    let mut cs = effort.chars();
    match cs.next() {
        Some(f) => f.to_uppercase().collect::<String>() + cs.as_str(),
        None => String::new(),
    }
}

pub fn group_models<'a>(
    models: impl IntoIterator<Item = &'a String>,
    labels: &HashMap<String, String>,
) -> Vec<ModelGroup> {
    let mut order: Vec<String> = Vec::new();
    let mut by_group: HashMap<String, Vec<ModelOption>> = HashMap::new();
    for id in models {
        let (group_id, effort) = parse_model_id(id);
        if !by_group.contains_key(&group_id) {
            order.push(group_id.clone());
        }
        by_group.entry(group_id).or_default().push(ModelOption {
            id: id.clone(),
            effort,
            label: labels.get(id).cloned().unwrap_or_default(),
        });
    }

    order
        .into_iter()
        .map(|group_id| {
            let mut options = by_group.remove(&group_id).unwrap_or_default();
            options.sort_by_key(|o| effort_rank(o.effort.as_deref()));
            let label = match options.iter().find(|o| !o.label.is_empty()) {
                Some(sample) => strip_effort_suffix(&sample.label),
                None => fallback_group_label(&group_id),
            };
            ModelGroup { label, options }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn groups_agy_efforts() {
        let ids: Vec<String> = [
            "agy:gemini-4-argon-high",
            "agy:gemini-4-argon-medium",
            "claude-cli:claude-sonnet-5-5",
        ]
        .iter()
        .map(|s| s.to_string())
        .collect();
        let mut labels = HashMap::new();
        labels.insert(
            "agy:gemini-4-argon-medium".to_string(),
            "Gemini 4 Argon (Medium)".to_string(),
        );
        let groups = group_models(&ids, &labels);
        assert_eq!(groups.len(), 2);
        assert_eq!(groups[0].options[1].id, "agy:gemini-4-argon-high");
        assert_eq!(groups[0].label, "Gemini 4 Argon");
        assert_eq!(groups[0].options[0].effort.as_deref(), Some("medium"));
        assert_eq!(groups[1].label, "Claude Sonnet 5 5");
        assert!(groups[1].options[0].effort.is_none());
        assert_eq!(
            groups[0].preferred_option(Some("high")).effort.as_deref(),
            Some("high")
        );
        assert_eq!(
            groups[0].preferred_option(Some("max")).effort.as_deref(),
            Some("medium")
        );
    }
}
