use super::*;

pub(super) fn agy_args(
    prompt: &str,
    model: &str,
    conv_id: Option<&str>,
    agent: &str,
) -> Vec<String> {
    let mut args = vec![
        "--app_data_dir=antigravity".to_string(),
        "--dangerously-skip-permissions".to_string(),
        "--output-format=stream-json".to_string(),
    ];
    if let Some(cid) = conv_id {
        args.push("--conversation".to_string());
        args.push(cid.to_string());
    }
    if !agent.is_empty() && agent != "Coordinator" && agent != "default" {
        args.push("--agent".to_string());
        args.push(agent.to_string());
    }
    if !model.is_empty() {
        args.push("--model".to_string());
        args.push(model.to_string());
    }
    args.push("-p".to_string());
    args.push(prompt.to_string());
    args
}

/// Nhãn source của session Claude Code, khớp với `ConversationSession.source` phía scanner
pub const CLAUDE_SOURCE: &str = "claude-cli";
/// Nhãn source của session Antigravity (agy)
pub const AGY_SOURCE: &str = "agy";

pub(super) fn provider_source(provider: Provider) -> &'static str {
    match provider {
        Provider::ClaudeCli => CLAUDE_SOURCE,
        Provider::Agy => AGY_SOURCE,
    }
}

/// Tách lệnh `/plan` ở đầu prompt: trả về (có bật plan mode, nội dung còn lại)
pub(super) fn strip_plan_command(prompt: &str) -> (bool, &str) {
    match prompt.strip_prefix("/plan") {
        Some(rest) if rest.is_empty() || rest.starts_with(char::is_whitespace) => {
            (true, rest.trim())
        }
        _ => (false, prompt),
    }
}

/// Tham số `claude`. Khi `stream_input` = true, nội dung (chữ + ảnh) được gửi qua stdin dạng
/// stream-json nên `prompt` không đi qua argv.
pub(super) fn claude_args(
    prompt: &str,
    model: &str,
    conv_id: Option<&str>,
    cwd: &str,
    plan_mode: bool,
    stream_input: bool,
) -> Vec<String> {
    // Claude Code không tự nhận thư mục làm việc từ tiến trình cha một cách đáng tin cậy,
    // nên đưa đường dẫn project vào system prompt và cấp quyền truy cập thư mục đó tường minh.
    let cwd_prompt = format!(
        "Thư mục project đang làm việc là: {cwd}. Mọi thao tác đọc/ghi file và lệnh shell phải thực hiện trong thư mục này. Khi người dùng hỏi về thư mục hiện tại, hãy trả lời theo đường dẫn trên."
    );
    // Mức suy nghĩ nằm ở hậu tố của id model (ví dụ `...-high`): tách ra và truyền bằng --effort
    let (base_model, effort) = crate::claude::code::split_effort(model);
    let mut args: Vec<String> = vec!["-p".to_string()];
    if stream_input {
        args.push("--input-format".to_string());
        args.push("stream-json".to_string());
    } else {
        args.push(prompt.to_string());
    }
    args.extend([
        "--output-format".to_string(),
        "stream-json".to_string(),
        "--verbose".to_string(),
        "--include-partial-messages".to_string(),
        "--model".to_string(),
        base_model,
    ]);
    if let Some(level) = effort {
        args.push("--effort".to_string());
        args.push(level);
    }
    args.push("--append-system-prompt".to_string());
    args.push(cwd_prompt);
    if plan_mode {
        // Plan mode chỉ có hiệu lực khi không đi kèm --dangerously-skip-permissions
        args.push("--permission-mode".to_string());
        args.push("plan".to_string());
    } else {
        // CLI chạy không hỏi quyền (không có người trả lời prompt)
        args.push("--dangerously-skip-permissions".to_string());
    }
    if let Some(cid) = conv_id {
        args.push("--resume".to_string());
        args.push(cid.to_string());
    }
    // `--add-dir` nhận nhiều giá trị nên đặt cuối cùng
    args.push("--add-dir".to_string());
    args.push(cwd.to_string());
    args
}

#[cfg(test)]
mod claude_effort_args_tests {
    use super::*;

    fn arg_after(args: &[String], flag: &str) -> Option<String> {
        args.iter()
            .position(|a| a == flag)
            .and_then(|i| args.get(i + 1).cloned())
    }

    #[test]
    fn agy_text_in_same_step_is_appended_as_is() {
        let mut committed = String::new();
        let mut step = None;
        append_agy_text(&mut committed, &mut step, Some(3), "Tôi sẽ ");
        append_agy_text(&mut committed, &mut step, Some(3), "đọc file.");
        assert_eq!(committed, "Tôi sẽ đọc file.");
    }

    #[test]
    fn agy_text_across_steps_gets_paragraph_break() {
        let mut committed = String::new();
        let mut step = None;
        append_agy_text(&mut committed, &mut step, Some(1), "Tôi sẽ đọc file.");
        append_agy_text(&mut committed, &mut step, Some(3), "Đã đọc xong.");
        assert_eq!(committed, "Tôi sẽ đọc file.\n\nĐã đọc xong.");
    }

    #[test]
    fn agy_no_extra_break_when_previous_text_ends_with_newline() {
        let mut committed = String::new();
        let mut step = None;
        append_agy_text(&mut committed, &mut step, Some(1), "Dòng một.\n");
        append_agy_text(&mut committed, &mut step, Some(3), "Dòng hai.");
        assert_eq!(committed, "Dòng một.\nDòng hai.");
    }

    #[test]
    fn effort_suffix_becomes_effort_flag() {
        let args = claude_args("hi", "claude-sonnet-5-5-high", None, "/tmp", false, false);
        assert_eq!(
            arg_after(&args, "--model").as_deref(),
            Some("claude-sonnet-5-5")
        );
        assert_eq!(arg_after(&args, "--effort").as_deref(), Some("high"));
    }

    #[test]
    fn model_without_suffix_has_no_effort_flag() {
        let args = claude_args("hi", "claude-opus-5-5", None, "/tmp", false, false);
        assert_eq!(
            arg_after(&args, "--model").as_deref(),
            Some("claude-opus-5-5")
        );
        assert!(!args.iter().any(|a| a == "--effort"));
    }

    #[test]
    fn stream_input_keeps_prompt_out_of_argv() {
        let args = claude_args("nội dung", "claude-haiku-5-5", Some("cid-1"), "/tmp", false, true);
        assert_eq!(arg_after(&args, "--input-format").as_deref(), Some("stream-json"));
        assert!(!args.iter().any(|a| a == "nội dung"));
        assert_eq!(arg_after(&args, "--resume").as_deref(), Some("cid-1"));
    }

    #[test]
    fn text_only_keeps_prompt_in_argv() {
        let args = claude_args("hi", "claude-haiku-5-5", None, "/tmp", false, false);
        assert_eq!(arg_after(&args, "-p").as_deref(), Some("hi"));
        assert!(!args.iter().any(|a| a == "--input-format"));
    }
}
