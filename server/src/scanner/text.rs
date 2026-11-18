use super::*;

pub(super) fn clean_user_request_envelope(step_type: &str, raw: &str) -> String {
    if step_type != "USER_INPUT" {
        return raw.to_string();
    }
    if let Some(start) = raw.find("<USER_REQUEST>") {
        let after = &raw[start + "<USER_REQUEST>".len()..];
        if let Some(end) = after.find("</USER_REQUEST>") {
            return after[..end].trim().to_string();
        }
    }
    raw.trim().to_string()
}

pub(super) fn extract_user_request(raw: &str) -> String {
    let cleaned = clean_user_request_envelope("USER_INPUT", raw);
    let first_line = cleaned
        .lines()
        .map(|s| s.trim())
        .find(|s| !s.is_empty())
        .unwrap_or("Yêu cầu từ người dùng");
    let chars: Vec<char> = first_line.chars().collect();
    if chars.len() > 95 {
        let truncated: String = chars.into_iter().take(92).collect();
        format!("{}...", truncated)
    } else {
        first_line.to_string()
    }
}

pub(super) fn safe_truncate(s: &str, max_bytes: usize) -> &str {
    if s.len() <= max_bytes {
        s
    } else {
        let mut idx = max_bytes;
        while idx > 0 && !s.is_char_boundary(idx) {
            idx -= 1;
        }
        &s[..idx]
    }
}

pub(super) fn clean_quoted_string(val: &str) -> String {
    let mut s = val.trim().to_string();
    if s.len() >= 2 && s.starts_with('"') && s.ends_with('"') {
        s = s[1..s.len() - 1].to_string();
    }
    s.replace(r#"\""#, "\"").replace(r"\n", "\n")
}

pub(super) fn classify_repo_from_path(path: &str) -> String {
    if path.contains(".agents/") || path.ends_with("AGENTS.md") {
        return ".agents".to_string();
    }
    if path.contains("muop-erp-androidtv") {
        return "muop-erp-androidtv".to_string();
    }
    if path.contains("muop-erp-web") {
        return "muop-erp-web".to_string();
    }
    if path.contains("muop-erp-app") {
        return "muop-erp-app".to_string();
    }
    if path.contains("muop-erp-server") {
        return "muop-erp-server".to_string();
    }
    if path.contains("muop-agent") || path.contains("muop_agent") {
        return "muop-agent".to_string();
    }
    "system".to_string()
}

pub(super) fn build_tool_summary_label(tool_name: &str, args: &HashMap<String, Value>) -> String {
    let path = args.get("Path").and_then(|v| v.as_str()).unwrap_or("");
    let basename = path.split('/').last().unwrap_or("");

    match tool_name {
        "read_file" => format!("Đọc tệp {}", basename),
        "write_file" => format!("Tạo/Ghi tệp {}", basename),
        "edit_file" => format!("Chỉnh sửa tệp {}", basename),
        "run_command" => {
            let sum = args
                .get("toolSummary")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .trim();
            if !sum.is_empty() {
                sum.to_string()
            } else {
                let cmd = args
                    .get("CommandLine")
                    .and_then(|v| v.as_str())
                    .unwrap_or("");
                format!("Chạy lệnh: {}", cmd)
            }
        }
        "invoke_subagent" => {
            let role = args
                .get("Role")
                .or_else(|| args.get("TypeName"))
                .and_then(|v| v.as_str())
                .unwrap_or("");
            format!("Chạy Subagent: {}", role)
        }
        "define_subagent" => {
            let name = args.get("Name").and_then(|v| v.as_str()).unwrap_or("");
            format!("Đăng ký Subagent: {}", name)
        }
        "send_message" => {
            let rec = args
                .get("Recipient")
                .and_then(|v| v.as_str())
                .unwrap_or("Subagent");
            format!("Gửi message tới {}", rec)
        }
        "manage_subagents" => {
            let act = args
                .get("Action")
                .and_then(|v| v.as_str())
                .unwrap_or("list");
            format!("Quản lý Subagents ({})", act)
        }
        "grep_search" => {
            let q = args.get("Query").and_then(|v| v.as_str()).unwrap_or("");
            format!("Tìm chuỗi \"{}\"", q)
        }
        "find_by_name" => {
            let p = args.get("Pattern").and_then(|v| v.as_str()).unwrap_or("");
            format!("Tìm tệp \"{}\"", p)
        }
        _ => tool_name.to_string(),
    }
}

pub(super) fn determine_step_phase(
    step_type: &str,
    tools: &[ToolCallInfo],
    content: &str,
) -> String {
    if step_type == "USER_INPUT" {
        return "contractDiscovery".to_string();
    }
    if tools.is_empty() && step_type == "PLANNER_RESPONSE" && !content.is_empty() {
        return "completed".to_string();
    }
    for t in tools {
        if t.name == "run_command" {
            let cmd = t
                .args
                .get("CommandLine")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_lowercase();
            let summary = t
                .args
                .get("toolSummary")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_lowercase();
            if cmd.contains("git commit") || summary.contains("commit") {
                return "gitCommit".to_string();
            }
            if cmd.contains("go build")
                || cmd.contains("flutter analyze")
                || cmd.contains("flutter test")
                || cmd.contains("go test")
                || cmd.contains("cargo build")
            {
                return "crossVerification".to_string();
            }
        }
        if t.name == "invoke_subagent"
            || t.name == "define_subagent"
            || t.name == "write_file"
            || t.name == "edit_file"
        {
            return "parallelExecution".to_string();
        }
    }
    "contractDiscovery".to_string()
}

pub(super) fn describe_step_vietnamese(
    step_type: &str,
    tools: &[ToolCallInfo],
    content: &str,
    thinking: &str,
) -> (String, String) {
    if step_type == "USER_INPUT" {
        let req = extract_user_request(content);
        return ("Nhận yêu cầu từ người dùng".to_string(), req);
    }
    if step_type == "SYSTEM_MESSAGE" {
        if content.contains("finished with result") {
            return (
                "Tác vụ nền (Background Task) hoàn tất".to_string(),
                first_lines(content, 2),
            );
        }
        if content.contains("sender=") {
            return (
                "Nhận báo cáo đồng bộ từ Subagent".to_string(),
                first_lines(content, 3),
            );
        }
        return (
            "Thông báo hệ thống (System Wakeup)".to_string(),
            first_lines(content, 2),
        );
    }
    if step_type == "GENERIC" {
        if content.contains("Created the following subagent:") {
            return (
                "Đã khởi tạo phiên Subagent song song".to_string(),
                first_lines(content, 4),
            );
        }
        if content.contains("Created file") {
            return (
                "Đã tạo tệp mới thành công".to_string(),
                content.trim().to_string(),
            );
        }
        if content.contains("Made ") && content.contains("replacement") {
            return (
                "Đã cập nhật nội dung tệp".to_string(),
                content.trim().to_string(),
            );
        }
        return (
            "Kết quả thực thi công cụ".to_string(),
            first_lines(content, 2),
        );
    }
    if !tools.is_empty() {
        for t in tools {
            if t.name == "run_command" {
                let cmd = t
                    .args
                    .get("CommandLine")
                    .and_then(|v| v.as_str())
                    .unwrap_or("");
                let cmd_lower = cmd.to_lowercase();
                let summary = t
                    .args
                    .get("toolSummary")
                    .and_then(|v| v.as_str())
                    .unwrap_or("");
                if cmd_lower.contains("git commit") || summary.to_lowercase().contains("commit") {
                    let commit_msg = extract_commit_message(cmd, summary);
                    let title = if step_type == "PLANNER_RESPONSE" {
                        "Đang thực hiện Git Commit mã nguồn".to_string()
                    } else {
                        "Git Commit mã nguồn".to_string()
                    };
                    let detail = if !commit_msg.is_empty() {
                        format!("Nội dung commit: {}", commit_msg)
                    } else {
                        cmd.to_string()
                    };
                    return (title, detail);
                }
            }
        }

        let labels: Vec<String> = tools.iter().map(|t| t.summary_label.clone()).collect();
        let joined = labels.join(" • ");
        let detail = if !thinking.trim().is_empty() {
            first_lines(thinking.trim(), 2)
        } else {
            joined.clone()
        };
        return (joined, detail);
    }
    if !content.trim().is_empty() {
        return (
            "Phản hồi & Tổng hợp kết quả bàn giao".to_string(),
            first_lines(content, 2),
        );
    }
    (
        "Suy luận chiến lược (Thinking)".to_string(),
        first_lines(thinking, 2),
    )
}

pub(super) fn extract_commit_message(cmd: &str, summary: &str) -> String {
    if let Some(pos) = cmd.find("-m ") {
        let rest = cmd[pos + 3..].trim_start();
        if rest.starts_with('"') {
            if let Some(end) = rest[1..].find('"') {
                return rest[1..1 + end].to_string();
            }
        } else if rest.starts_with('\'') {
            if let Some(end) = rest[1..].find('\'') {
                return rest[1..1 + end].to_string();
            }
        }
    }
    if !summary.trim().is_empty() && summary != "run_command" {
        return summary.trim().to_string();
    }
    cmd.trim().to_string()
}

pub(super) fn first_lines(text: &str, max_lines: usize) -> String {
    let mut lines = Vec::new();
    for line in text.lines() {
        let trimmed = line.trim();
        if !trimmed.is_empty() && !trimmed.starts_with('<') {
            lines.push(trimmed);
            if lines.len() >= max_lines {
                break;
            }
        }
    }
    let joined = lines.join(" — ");
    let chars: Vec<char> = joined.chars().collect();
    if chars.len() > 160 {
        let truncated: String = chars.into_iter().take(157).collect();
        format!("{}...", truncated)
    } else {
        joined
    }
}

pub(super) fn extract_tool_diff(
    tool_name: &str,
    args: &HashMap<String, Value>,
) -> (usize, usize, String) {
    match tool_name {
        "write_file" => {
            let content = args.get("Content").and_then(|v| v.as_str()).unwrap_or("");
            let lines: Vec<&str> = content.lines().collect();
            let added = lines.len().max(1);
            let mut preview = String::new();
            for line in lines.into_iter().take(24) {
                preview.push_str("+ ");
                preview.push_str(line);
                preview.push('\n');
            }
            (added, 0, preview.trim_end().to_string())
        }
        "edit_file" => {
            let target = args.get("Target").and_then(|v| v.as_str()).unwrap_or("");
            let replacement = args
                .get("Replacement")
                .and_then(|v| v.as_str())
                .unwrap_or("");
            let t_lines: Vec<&str> = target.lines().collect();
            let r_lines: Vec<&str> = replacement.lines().collect();
            let removed = t_lines.len().max(1);
            let added = r_lines.len().max(1);
            let mut preview = String::new();
            for line in t_lines.into_iter().take(14) {
                preview.push_str("- ");
                preview.push_str(line);
                preview.push('\n');
            }
            for line in r_lines.into_iter().take(14) {
                preview.push_str("+ ");
                preview.push_str(line);
                preview.push('\n');
            }
            (added, removed, preview.trim_end().to_string())
        }
        _ => (0, 0, String::new()),
    }
}
