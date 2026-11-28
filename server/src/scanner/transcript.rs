use super::*;

pub(super) fn parse_single_agent_step(
    map: &Value,
    step_index: usize,
    file_modified: DateTime<Utc>,
) -> AgentStep {
    let source = map
        .get("source")
        .and_then(|v| v.as_str())
        .unwrap_or("MODEL")
        .to_string();
    let step_type = map
        .get("type")
        .and_then(|v| v.as_str())
        .unwrap_or("GENERIC")
        .to_string();
    let status = map
        .get("status")
        .and_then(|v| v.as_str())
        .unwrap_or("DONE")
        .to_string();
    let content = map
        .get("content")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    let thinking = map
        .get("thinking")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();

    let step_time = map
        .get("created_at")
        .and_then(|v| v.as_str())
        .and_then(|s| DateTime::parse_from_rfc3339(s).ok())
        .map(|dt| dt.with_timezone(&Utc))
        .unwrap_or(file_modified);

    let mut in_tok = map
        .get("input_tokens")
        .and_then(|v| v.as_u64())
        .unwrap_or(0);
    let mut out_tok = map
        .get("output_tokens")
        .and_then(|v| v.as_u64())
        .unwrap_or(0);
    let mut cache_tok = map
        .get("cache_read_tokens")
        .and_then(|v| v.as_u64())
        .unwrap_or(0);

    if in_tok == 0 && out_tok == 0 {
        let char_len = (content.len() + thinking.len()) as u64;
        if step_type == "PLANNER_RESPONSE" {
            out_tok = (char_len / 4).max(48);
            in_tok = 950 + (step_index as u64) * 210;
            cache_tok = (step_index as u64) * 640;
        } else {
            in_tok = (char_len / 4).max(32);
        }
    }

    let mut tool_calls = Vec::new();
    if let Some(Value::Array(raw_calls)) = map.get("tool_calls") {
        for item in raw_calls {
            let t_name = item
                .get("name")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            let mut args_map: HashMap<String, Value> = HashMap::new();
            if let Some(Value::Object(raw_args)) = item.get("args") {
                for (k, v) in raw_args {
                    let str_val = match v {
                        Value::String(s) => clean_quoted_string(s),
                        other => clean_quoted_string(&other.to_string()),
                    };
                    args_map.insert(k.clone(), Value::String(str_val));
                }
            }

            let path_arg = args_map
                .get("Path")
                .and_then(|v| v.as_str())
                .map(|s| s.to_string());
            let repo_tag = classify_repo_from_path(path_arg.as_deref().unwrap_or(""));
            let summary_label = build_tool_summary_label(&t_name, &args_map);

            tool_calls.push(ToolCallInfo {
                name: t_name,
                args: args_map,
                summary_label,
                target_path: path_arg,
                repo_tag,
            });
        }
    }

    let phase = determine_step_phase(&step_type, &tool_calls, &content);
    let (vn_title, vn_detail) =
        describe_step_vietnamese(&step_type, &tool_calls, &content, &thinking);
    let step_agent = classify_step_agent(&step_type, &tool_calls, &content, &thinking);
    // Agy ghi khối ảnh đính kèm vào prompt: tách ra để hiển thị chữ sạch và đếm số ảnh
    let (user_content, image_paths) = if step_type == "USER_INPUT" {
        let (text, paths) = crate::chat::attachments::split_agy_attachments(
            &clean_user_request_envelope(&step_type, &content),
        );
        (
            crate::chat::attachments::strip_agy_workdir_note(&text),
            paths,
        )
    } else {
        (
            clean_user_request_envelope(&step_type, &content),
            Vec::new(),
        )
    };
    let image_count = image_paths.len();
    let image_urls = image_paths
        .iter()
        .map(|p| crate::chat::attachments::agy_attachment_url(p))
        .collect();

    AgentStep {
        step_index,
        source,
        step_type: step_type.clone(),
        status,
        created_at: step_time.to_rfc3339(),
        content: user_content,
        image_count,
        image_urls,
        thinking,
        tool_calls,
        input_tokens: in_tok,
        output_tokens: out_tok,
        cache_read_tokens: cache_tok,
        agent_name: step_agent,
        phase,
        vietnamese_title: vn_title,
        vietnamese_detail: vn_detail,
        model: String::new(),
    }
}

/// Đường dẫn transcript của một conversation agy
pub(super) fn transcript_path(id: &str) -> PathBuf {
    brain_root()
        .join(id)
        .join(".system_generated/logs/transcript.jsonl")
}

/// Trạng thái và pha của lượt agy theo bước cuối và thời điểm hiện tại (không cache: phụ thuộc thời gian).
pub(super) fn derive_status(
    last: Option<&LastStepMeta>,
    updated_at: DateTime<Utc>,
    has_verify: bool,
    has_edit_or_parallel: bool,
    now: DateTime<Utc>,
) -> (String, String) {
    let mut session_status = "completed".to_string();
    let mut current_phase = "completed".to_string();
    if let Some(last) = last {
        // Đánh giá trạng thái chính xác theo tiến trình thực tế trong transcript:
        // 1. Nếu bước cuối cùng là PLANNER_RESPONSE và không còn tool_calls -> ĐÃ HOÀN TẤT LƯỢT TRẢ LỜI
        if last.step_type == "PLANNER_RESPONSE" && !last.has_tool_calls {
            session_status = "completed".to_string();
        } else if last.status != "DONE" || last.has_tool_calls {
            // Chỉ coi là đang chạy nếu file vừa được ghi log gần đây (dưới 20 giây)
            let age_secs = (now - updated_at).num_seconds().abs();
            session_status = if age_secs < 20 {
                "running".to_string()
            } else {
                "interrupted".to_string()
            };
        } else {
            // Bước cuối là GENERIC hoặc USER_INPUT: chỉ đang chạy nếu phát sinh rất gần (dưới 15 giây)
            let age_secs = (now - updated_at).num_seconds().abs();
            session_status = if age_secs < 15
                && (last.step_type == "GENERIC" || last.step_type == "USER_INPUT")
            {
                "running".to_string()
            } else {
                "completed".to_string()
            };
        }

        current_phase = if session_status == "completed" {
            "completed".to_string()
        } else if has_verify {
            "crossVerification".to_string()
        } else if has_edit_or_parallel {
            "parallelExecution".to_string()
        } else {
            "contractDiscovery".to_string()
        };
    }
    (session_status, current_phase)
}

/// Gắn metadata với DB (tiêu đề, project, nhóm mount) và tính trạng thái theo thời điểm hiện tại.
/// `steps`, `files_touched`, `commands_run` rỗng khi chỉ cần metadata (session không active).
pub(super) fn finish(
    id: &str,
    meta: &TranscriptMeta,
    steps: Vec<AgentStep>,
    files_touched: Vec<FileTouchRecord>,
    commands_run: Vec<CommandExecutionRecord>,
    db_meta: Option<&DbConversationMeta>,
) -> ParsedTranscript {
    let created_at = DateTime::parse_from_rfc3339(&meta.created_at)
        .map(|d| d.with_timezone(&Utc))
        .unwrap_or_else(|_| Utc::now());
    let updated_at = DateTime::parse_from_rfc3339(&meta.updated_at)
        .map(|d| d.with_timezone(&Utc))
        .unwrap_or_else(|_| Utc::now());

    let mut title = db_meta
        .filter(|m| !m.title.is_empty())
        .map(|m| m.title.clone())
        .unwrap_or_else(|| format!("Phiên #{}", id));
    if title.starts_with("Phiên #") && !meta.first_prompt_title.is_empty() {
        title = meta.first_prompt_title.clone();
    }

    let mut project_name = db_meta.map(|m| m.project_name.clone()).unwrap_or_default();
    let mut project_path = db_meta.map(|m| m.project_path.clone()).unwrap_or_default();
    // Project đã ghi lúc bắt đầu lượt được ưu tiên: agy có thể không ghi thư mục làm việc
    if let Some((name, path)) = crate::infra::store::conversation_project(id) {
        project_name = name;
        project_path = path;
    }
    if project_name.is_empty() {
        if !meta.fallback_repo.is_empty() {
            project_name = meta.fallback_repo.clone();
            project_path = crate::setup::workspace_root()
                .map(|r| r.join(&meta.fallback_repo).to_string_lossy().into_owned())
                .unwrap_or_default();
        } else {
            project_name = "(không rõ project)".to_string();
        }
    }

    // Conversation chạy trong mount (project của máy khác): nhóm riêng, nhãn "Mount - <tên project>"
    if crate::fsmount::is_mount_path(&project_path) && !project_name.starts_with("Mount - ") {
        project_name = format!("Mount - {project_name}");
    }

    let (status, phase) = derive_status(
        meta.last_step.as_ref(),
        updated_at,
        meta.has_verify,
        meta.has_edit_or_parallel,
        Utc::now(),
    );

    ParsedTranscript {
        id: id.to_string(),
        title,
        created_at,
        updated_at,
        status,
        current_phase: phase,
        steps,
        files_touched,
        commands_run,
        spawned_subagents: meta.spawned_subagents.clone(),
        turn_spawn_start: meta.turn_spawn_start,
        total_input_tokens: meta.total_input_tokens,
        total_output_tokens: meta.total_output_tokens,
        total_cache_tokens: meta.total_cache_tokens,
        project_name,
        project_path,
        total_steps: meta.total_steps,
        last_step_type: meta.last_step.as_ref().map(|s| s.step_type.clone()),
        referenced_ids: meta.referenced_ids.clone(),
    }
}

/// Dấu hiệu thay đổi của transcript: mtime (nano giây) và độ dài file
pub(super) fn transcript_fingerprint(path: &Path) -> Option<String> {
    let m = fs::metadata(path).ok()?;
    let nanos = m
        .modified()
        .ok()?
        .duration_since(SystemTime::UNIX_EPOCH)
        .ok()?
        .as_nanos();
    Some(format!("{nanos}:{}", m.len()))
}

/// Parse đầy đủ một transcript cho session đang xem chi tiết hoặc đang chạy: metadata + tối đa
/// `TAIL_STEPS` bước cuối (đọc theo chỉ mục) + tệp/lệnh gần nhất. Không giữ kết quả trong RAM.
pub(super) fn parse_transcript_file(
    id: &str,
    file_modified: DateTime<Utc>,
    db_meta: Option<&DbConversationMeta>,
) -> Option<ParsedTranscript> {
    super::transcript_index::load_parsed(
        id,
        file_modified,
        db_meta,
        super::transcript_index::TAIL_STEPS,
        true,
    )
}

/// Chỉ metadata của transcript (không có bước, tệp, lệnh) cho danh sách conversation.
pub(super) fn parse_transcript_shell(
    id: &str,
    file_modified: DateTime<Utc>,
    db_meta: Option<&DbConversationMeta>,
) -> Option<ParsedTranscript> {
    super::transcript_index::load_parsed(id, file_modified, db_meta, 0, false)
}

#[cfg(test)]
mod meta_tests {
    use super::*;

    fn last(step_type: &str, status: &str, has_tool_calls: bool) -> LastStepMeta {
        LastStepMeta {
            step_type: step_type.to_string(),
            status: status.to_string(),
            has_tool_calls,
        }
    }

    #[test]
    fn planner_response_without_tools_is_completed() {
        let now = Utc::now();
        let (status, phase) = derive_status(
            Some(&last("PLANNER_RESPONSE", "DONE", false)),
            now,
            false,
            false,
            now,
        );
        assert_eq!(
            (status.as_str(), phase.as_str()),
            ("completed", "completed")
        );
    }

    #[test]
    fn recent_tool_call_is_running_and_old_one_is_interrupted() {
        let now = Utc::now();
        let (running, _) = derive_status(
            Some(&last("PLANNER_RESPONSE", "DONE", true)),
            now - chrono::Duration::seconds(5),
            false,
            false,
            now,
        );
        assert_eq!(running, "running");
        let (interrupted, _) = derive_status(
            Some(&last("PLANNER_RESPONSE", "DONE", true)),
            now - chrono::Duration::seconds(60),
            false,
            false,
            now,
        );
        assert_eq!(interrupted, "interrupted");
    }

    #[test]
    fn user_input_runs_only_for_a_few_seconds() {
        let now = Utc::now();
        let (recent, _) = derive_status(
            Some(&last("USER_INPUT", "DONE", false)),
            now - chrono::Duration::seconds(5),
            false,
            false,
            now,
        );
        assert_eq!(recent, "running");
        let (old, _) = derive_status(
            Some(&last("USER_INPUT", "DONE", false)),
            now - chrono::Duration::seconds(30),
            false,
            false,
            now,
        );
        assert_eq!(old, "completed");
    }

    #[test]
    fn phase_follows_flags_only_when_not_completed() {
        let now = Utc::now();
        let stale = now - chrono::Duration::seconds(60);
        let (_, verify) = derive_status(
            Some(&last("PLANNER_RESPONSE", "DONE", true)),
            stale,
            true,
            false,
            now,
        );
        assert_eq!(verify, "crossVerification");
        let (_, parallel) = derive_status(
            Some(&last("PLANNER_RESPONSE", "DONE", true)),
            stale,
            false,
            true,
            now,
        );
        assert_eq!(parallel, "parallelExecution");
        let (_, base) = derive_status(
            Some(&last("PLANNER_RESPONSE", "DONE", true)),
            stale,
            false,
            false,
            now,
        );
        assert_eq!(base, "contractDiscovery");
    }

    #[test]
    fn empty_transcript_is_completed() {
        let now = Utc::now();
        assert_eq!(
            derive_status(None, now, false, false, now),
            ("completed".to_string(), "completed".to_string())
        );
    }

    #[test]
    fn meta_round_trips_through_json_without_steps() {
        let meta = TranscriptMeta {
            first_prompt_title: "Hỏi về lỗi".into(),
            created_at: "2026-11-26T10:00:00+00:00".into(),
            updated_at: "2026-11-26T10:05:00+00:00".into(),
            last_step: Some(last("PLANNER_RESPONSE", "DONE", false)),
            has_verify: true,
            has_edit_or_parallel: false,
            spawned_subagents: vec![SpawnedSubagentMeta {
                id: "sub-1".into(),
                name: "Worker".into(),
                role: "Worker".into(),
                prompt: "p".into(),
                step_index: 3,
                status: "completed".into(),
                last_action: "ok".into(),
                tool_name: "invoke_subagent".into(),
            }],
            turn_spawn_start: 0,
            total_input_tokens: 10,
            total_output_tokens: 20,
            total_cache_tokens: 30,
            total_steps: 42,
            fallback_repo: "muop-agent".into(),
            referenced_ids: vec!["sub-1".into()],
        };
        let json = serde_json::to_string(&meta).unwrap();
        let back: TranscriptMeta = serde_json::from_str(&json).unwrap();
        assert_eq!(back.total_steps, 42);
        assert_eq!(back.spawned_subagents[0].id, "sub-1");
        assert_eq!(back.referenced_ids, vec!["sub-1".to_string()]);
        assert_eq!(back.last_step.unwrap().step_type, "PLANNER_RESPONSE");
    }
}
