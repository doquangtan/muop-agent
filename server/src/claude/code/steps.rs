use super::*;

pub(super) fn line_count(s: &str) -> usize {
    if s.is_empty() {
        0
    } else {
        s.lines().count()
    }
}

pub(super) fn tool_summary(name: &str, args: &HashMap<String, Value>) -> String {
    let detail = ["file_path", "path", "command", "pattern", "description"]
        .iter()
        .find_map(|k| args.get(*k).and_then(|v| v.as_str()))
        .unwrap_or("");
    let detail: String = detail.chars().take(80).collect();
    if detail.is_empty() {
        name.to_string()
    } else {
        format!("{}: {}", name, detail)
    }
}

#[allow(clippy::too_many_arguments)]
pub(super) fn make_step(
    index: usize,
    step_type: &str,
    source: &str,
    agent_name: &str,
    timestamp: String,
    content: String,
    thinking: String,
    tool_calls: Vec<ToolCallInfo>,
    input_tokens: u64,
    output_tokens: u64,
    cache_read_tokens: u64,
) -> AgentStep {
    let (vi_title, vi_detail) = if step_type == "USER_INPUT" {
        ("Yêu cầu của người dùng", "")
    } else {
        ("Phản hồi của Claude Code", "")
    };
    AgentStep {
        step_index: index,
        source: source.to_string(),
        step_type: step_type.to_string(),
        status: "DONE".to_string(),
        created_at: timestamp,
        content,
        thinking,
        tool_calls,
        input_tokens,
        output_tokens,
        cache_read_tokens,
        agent_name: agent_name.to_string(),
        phase: "completed".to_string(),
        vietnamese_title: vi_title.to_string(),
        vietnamese_detail: vi_detail.to_string(),
        model: String::new(),
        image_count: 0,
        image_urls: Vec::new(),
    }
}
