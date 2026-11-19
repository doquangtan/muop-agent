use super::*;

/// Bản ghi hội thoại cuối cùng của transcript, để biết lượt đã trả lời xong hay chưa
#[derive(Clone, Debug, PartialEq)]
pub(super) enum LastRecord {
    User,
    Assistant { stop_reason: String },
}

/// Trạng thái nội bộ của lượt chưa trả lời xong. Chỉ dùng trong parser và `apply_live_status`, không gửi ra client.
pub(super) const UNFINISHED_STATUS: &str = "unfinished";
pub(super) const INTERRUPTED_REASON: &str =
    "Lượt trả lời bị gián đoạn: tiến trình Claude CLI đã dừng trước khi hoàn tất (thường do máy chủ khởi động lại).";

pub(super) fn apply_live_status(
    session: ConversationSession,
    active_streams: &HashMap<String, ChatTurnStreamState>,
    muop_conversations: &HashSet<String>,
) -> ConversationSession {
    apply_live_status_at(session, active_streams, muop_conversations)
}

/// Áp trạng thái đang chạy cho session:
/// - có stream đang chạy trên server → `running`;
/// - lượt do server này chạy mà chưa xong và không còn stream → `interrupted`. Stream luôn còn khi
///   lượt đang chạy, nên mất stream nghĩa là tiến trình đã dừng (thường do server khởi động lại);
/// - phiên tương tác (chạy từ terminal/VSCode) chưa xong → giữ `completed`, vì không xác định được tiến trình có còn chạy không.
pub(super) fn apply_live_status_at(
    mut session: ConversationSession,
    active_streams: &HashMap<String, ChatTurnStreamState>,
    muop_conversations: &HashSet<String>,
) -> ConversationSession {
    let running = active_streams
        .get(&session.id)
        .map(|s| s.is_running)
        .unwrap_or(false);
    let unfinished = session.status == UNFINISHED_STATUS;
    let muop_driven = muop_conversations.contains(&session.id);

    if running {
        session.status = "running".to_string();
        session.current_phase = "running".to_string();
        session.is_interrupted = false;
        session.interrupted_reason = None;
    } else {
        if unfinished {
            if muop_driven {
                session.status = "interrupted".to_string();
                session.current_phase = "interrupted".to_string();
                session.is_interrupted = true;
                session.interrupted_reason = Some(INTERRUPTED_REASON.to_string());
            } else {
                session.status = "completed".to_string();
                session.current_phase = "completed".to_string();
            }
        }
        for lane in session.subagent_lanes.iter_mut() {
            if lane.status == "running" {
                lane.status = "interrupted".to_string();
                lane.current_phase = "interrupted".to_string();
            }
        }
    }
    session
}

#[cfg(test)]
mod unfinished_turn_tests {
    use super::*;

    const USER: &str = r#"{"type":"user","timestamp":"2020-01-01T00:00:00.000Z","message":{"role":"user","content":"hi"}}"#;
    const ANSWER_END: &str = r#"{"type":"assistant","timestamp":"2020-01-01T00:00:01.000Z","message":{"id":"m1","role":"assistant","model":"claude-haiku-5-5","content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}}"#;
    const WAIT_TOOL: &str = r#"{"type":"assistant","timestamp":"2020-01-01T00:00:01.000Z","message":{"id":"m1","role":"assistant","model":"claude-haiku-5-5","content":[{"type":"text","text":"ok"}],"stop_reason":"tool_use","usage":{"input_tokens":1,"output_tokens":1}}}"#;
    const LOCAL_OUTPUT: &str = r#"{"type":"user","timestamp":"2020-01-01T00:00:02.000Z","message":{"role":"user","content":"<local-command-stdout>ok</local-command-stdout>"}}"#;

    fn parse(name: &str, lines: &[&str]) -> ConversationSession {
        let dir = std::env::temp_dir().join(format!("muop-unfinished-test-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join(format!("{name}.jsonl"));
        fs::write(&path, lines.join("\n")).unwrap();
        parse_session_file(&path, false).expect("parse session")
    }

    fn muop_set(ids: &[&str]) -> HashSet<String> {
        ids.iter().map(|s| s.to_string()).collect()
    }

    fn live_stream(cid: &str) -> HashMap<String, ChatTurnStreamState> {
        let mut m = HashMap::new();
        m.insert(
            cid.to_string(),
            ChatTurnStreamState {
                conversation_id: cid.to_string(),
                project_path: String::new(),
                user_prompt: String::new(),
                streaming_text: String::new(),
                is_running: true,
                active_step_type: "recovered".to_string(),
                started_at: String::new(),
                error: String::new(),
                thinking_text: String::new(),
                thinking_tokens: 0,
            },
        );
        m
    }

    #[test]
    fn muop_prompt_without_stream_is_interrupted_even_if_just_written() {
        // Không còn stream nghĩa là tiến trình đã dừng, không chờ theo thời gian ghi file
        let s = parse("prompt_recent", &[USER]);
        let out = apply_live_status_at(s, &HashMap::new(), &muop_set(&["prompt_recent"]));
        assert_eq!(out.status, "interrupted");
        assert!(out.is_interrupted);
        assert!(out.interrupted_reason.is_some());
    }

    #[test]
    fn muop_prompt_without_answer_is_interrupted() {
        let s = parse("prompt_old", &[USER]);
        let out = apply_live_status_at(s, &HashMap::new(), &muop_set(&["prompt_old"]));
        assert_eq!(out.status, "interrupted");
        assert!(out.is_interrupted);
        assert!(out.interrupted_reason.is_some());
    }

    #[test]
    fn interactive_unfinished_turn_is_not_flagged() {
        // Phiên không do muop chạy (terminal/VSCode): không được gắn interrupted dù transcript dở dang
        let s = parse("interactive", &[USER]);
        let out = apply_live_status_at(s, &HashMap::new(), &HashSet::new());
        assert_eq!(out.status, "completed");
        assert!(!out.is_interrupted);
    }

    #[test]
    fn answered_turn_is_completed() {
        let s = parse("answered", &[USER, ANSWER_END]);
        let out = apply_live_status_at(s, &HashMap::new(), &muop_set(&["answered"]));
        assert_eq!(out.status, "completed");
        assert!(!out.is_interrupted);
    }

    #[test]
    fn muop_turn_waiting_for_tool_result_is_interrupted() {
        let s = parse("waiting_tool", &[USER, WAIT_TOOL]);
        let out = apply_live_status_at(s, &HashMap::new(), &muop_set(&["waiting_tool"]));
        assert_eq!(out.status, "interrupted");
        assert!(out.is_interrupted);
    }

    #[test]
    fn slash_command_output_is_not_an_unfinished_turn() {
        let s = parse("local_output", &[USER, ANSWER_END, LOCAL_OUTPUT]);
        let out = apply_live_status_at(s, &HashMap::new(), &muop_set(&["local_output"]));
        assert_eq!(out.status, "completed");
        assert!(!out.is_interrupted);
    }

    #[test]
    fn live_stream_keeps_unfinished_turn_running() {
        let s = parse("live_stream", &[USER]);
        let streams = live_stream("live_stream");
        let out = apply_live_status_at(s, &streams, &muop_set(&["live_stream"]));
        assert_eq!(out.status, "running");
        assert!(!out.is_interrupted);
    }
}
