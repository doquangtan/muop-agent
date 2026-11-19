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
        crate::chat::attachments::split_agy_attachments(&clean_user_request_envelope(
            &step_type, &content,
        ))
    } else {
        (clean_user_request_envelope(&step_type, &content), Vec::new())
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

pub(super) fn parse_transcript_file(
    id: &str,
    file_modified: DateTime<Utc>,
    db_meta: Option<&DbConversationMeta>,
) -> Option<ParsedTranscript> {
    let path = PathBuf::from(BRAIN_DIR_PATH)
        .join(id)
        .join(".system_generated/logs/transcript.jsonl");

    let meta = fs::metadata(&path).ok()?;
    let file_len = meta.len();

    // 1. Kiểm tra cache trong bộ nhớ RAM (tránh đọc đĩa và parse JSON lặp đi lặp lại)
    if let Ok(cache) = get_transcript_cache().lock() {
        if let Some(entry) = cache.get(id) {
            if entry.modified == file_modified && entry.len == file_len {
                return Some((*entry.parsed).clone());
            }
        }
    }

    use std::collections::VecDeque;
    use std::io::{BufRead, BufReader};

    let file = fs::File::open(&path).ok()?;
    let reader = BufReader::new(file);

    let mut title = db_meta
        .filter(|m| !m.title.is_empty())
        .map(|m| m.title.clone())
        .unwrap_or_else(|| format!("Phiên #{}", id));
    let mut first_user_prompt_title = String::new();
    let mut created_at: Option<DateTime<Utc>> = None;
    let mut updated_at = file_modified;
    let mut total_input: u64 = 0;
    let mut total_output: u64 = 0;
    let mut total_cache: u64 = 0;

    let mut steps_deque: VecDeque<AgentStep> = VecDeque::new();
    let mut files_deque: VecDeque<FileTouchRecord> = VecDeque::new();
    let mut commands_deque: VecDeque<CommandExecutionRecord> = VecDeque::new();
    let mut spawned_subagents: Vec<SpawnedSubagentMeta> = Vec::new();
    let mut pending_subagent_indices: Vec<usize> = Vec::new();

    let conv_id_re = Regex::new(r#""conversationId"\s*:\s*"([^"]+)""#).ok()?;
    let mut total_step_count: usize = 0;
    let mut has_verify = false;
    let mut has_edit_or_parallel = false;
    let agy_turns = load_agy_turn_models(id);

    for line_res in reader.lines() {
        let line = match line_res {
            Ok(l) => l,
            Err(_) => continue,
        };
        if line.trim().is_empty() {
            continue;
        }
        let map: Value = match serde_json::from_str(&line) {
            Ok(v) => v,
            Err(_) => continue,
        };

        let step_index = map
            .get("step_index")
            .and_then(|v| v.as_u64())
            .map(|v| v as usize)
            .unwrap_or(total_step_count);

        total_step_count += 1;

        let mut step = parse_single_agent_step(&map, step_index, file_modified);
        let step_time = match DateTime::parse_from_rfc3339(&step.created_at) {
            Ok(dt) => dt.with_timezone(&Utc),
            Err(_) => file_modified,
        };
        if step.step_type == "PLANNER_RESPONSE" {
            step.model = agy_turn_model_at(&agy_turns, step_time);
        }

        if created_at.is_none() {
            created_at = Some(step_time);
        }
        if step_time > updated_at {
            updated_at = step_time;
        }

        total_input += step.input_tokens;
        total_output += step.output_tokens;
        total_cache += step.cache_read_tokens;

        if step.step_type == "USER_INPUT"
            && !step.content.is_empty()
            && first_user_prompt_title.is_empty()
        {
            let extracted = extract_user_request(&step.content);
            if !extracted.is_empty() {
                first_user_prompt_title = extracted;
            }
        }

        if step.phase == "crossVerification" {
            has_verify = true;
        } else if step.phase == "parallelExecution" {
            has_edit_or_parallel = true;
        }

        for tc in &step.tool_calls {
            let path_arg = tc.target_path.as_deref().unwrap_or("");
            if !path_arg.is_empty() {
                let action = match tc.name.as_str() {
                    "read_file" | "view_file_outline" => Some("READ"),
                    "write_file" => Some("WRITE"),
                    "edit_file" => Some("EDIT"),
                    _ => None,
                };
                if let Some(act) = action {
                    let (added_lines, removed_lines, diff_preview) =
                        extract_tool_diff(&tc.name, &tc.args);
                    let touch_agent = if tc.repo_tag == "muop-erp-server" {
                        "erp-server-agent"
                    } else if tc.repo_tag == "muop-erp-app" {
                        "erp-app-agent"
                    } else {
                        "Coordinator"
                    };
                    files_deque.push_back(FileTouchRecord {
                        path: path_arg.to_string(),
                        action: act.to_string(),
                        repo: tc.repo_tag.clone(),
                        agent_name: touch_agent.to_string(),
                        step_index,
                        timestamp: step.created_at.clone(),
                        added_lines,
                        removed_lines,
                        diff_preview: safe_truncate(&diff_preview, 200).to_string(),
                        source: String::new(),
                    });
                    if files_deque.len() > 80 {
                        files_deque.pop_front();
                    }
                }
            }

            if tc.name == "run_command" {
                let cmd_line = tc
                    .args
                    .get("CommandLine")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string();
                let summary = tc
                    .args
                    .get("toolSummary")
                    .and_then(|v| v.as_str())
                    .unwrap_or("Thực thi lệnh terminal")
                    .to_string();
                let cmd_agent =
                    if cmd_line.contains("flutter analyze") || cmd_line.contains("go build") {
                        "erp-contract-verifier"
                    } else if cmd_line.contains("muop-erp-server") {
                        "erp-server-agent"
                    } else if cmd_line.contains("muop-erp-app") {
                        "erp-app-agent"
                    } else {
                        "Coordinator"
                    };
                commands_deque.push_back(CommandExecutionRecord {
                    command_line: cmd_line,
                    summary,
                    agent_name: cmd_agent.to_string(),
                    step_index,
                    timestamp: step.created_at.clone(),
                    output_preview: String::new(),
                    is_success: true,
                });
                if commands_deque.len() > 40 {
                    commands_deque.pop_front();
                }
            }

            if tc.name == "invoke_subagent" {
                let role = tc
                    .args
                    .get("Role")
                    .and_then(|v| v.as_str())
                    .unwrap_or("Subagent Worker")
                    .to_string();
                let type_name = tc
                    .args
                    .get("TypeName")
                    .and_then(|v| v.as_str())
                    .unwrap_or("self")
                    .to_string();
                let prompt = tc
                    .args
                    .get("Prompt")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string();
                let name = if type_name == "self" {
                    role.clone()
                } else {
                    type_name
                };
                let idx = spawned_subagents.len();
                spawned_subagents.push(SpawnedSubagentMeta {
                    id: String::new(),
                    name,
                    role: role.clone(),
                    prompt,
                    step_index,
                    status: "running".to_string(),
                    last_action: format!("Đang khởi chạy Subagent: {}", role),
                    tool_name: "invoke_subagent".to_string(),
                });
                pending_subagent_indices.push(idx);
            }
        }

        if step.step_type == "GENERIC"
            && step.content.contains("Created the following subagent:")
            && !pending_subagent_indices.is_empty()
        {
            let idx = pending_subagent_indices.remove(0);
            if let Some(caps) = conv_id_re.captures(&step.content) {
                if let Some(m) = caps.get(1) {
                    if let Some(sub) = spawned_subagents.get_mut(idx) {
                        sub.id = m.as_str().to_string();
                    }
                }
            }
        }

        if step.step_type == "SYSTEM_MESSAGE" && step.content.contains("<SYSTEM_MESSAGE>") {
            for sub in &mut spawned_subagents {
                if !sub.id.is_empty() && step.content.contains(&sub.id) {
                    if step.content.contains("encountered an error") {
                        sub.status = "error".to_string();
                        sub.last_action = "Subagent gặp lỗi khi thực thi".to_string();
                    } else {
                        sub.status = "completed".to_string();
                        sub.last_action =
                            "Đã hoàn thành nhiệm vụ & gửi báo cáo về Coordinator".to_string();
                    }
                }
            }
        }

        steps_deque.push_back(step);
        if steps_deque.len() > 150 {
            steps_deque.pop_front();
        }
    }

    if total_step_count == 0 {
        return None;
    }

    let steps: Vec<AgentStep> = steps_deque.into_iter().collect();
    let files_touched: Vec<FileTouchRecord> = files_deque.into_iter().collect();
    let commands_run: Vec<CommandExecutionRecord> = commands_deque.into_iter().collect();

    if title.starts_with("Phiên #") && !first_user_prompt_title.is_empty() {
        title = first_user_prompt_title;
    }

    let mut project_name = db_meta.map(|m| m.project_name.clone()).unwrap_or_default();
    let mut project_path = db_meta.map(|m| m.project_path.clone()).unwrap_or_default();
    if project_name.is_empty() {
        for f in &files_touched {
            if f.repo != "system" && f.repo != ".agents" {
                project_name = f.repo.clone();
                project_path = format!("{}/{}", ECOSYSTEM_DIR_PATH, f.repo);
                break;
            }
        }
        if project_name.is_empty() {
            project_name = "muop-erp-server".to_string();
            project_path = format!("{}/muop-erp-server", ECOSYSTEM_DIR_PATH);
        }
    }

    let mut session_status = "completed".to_string();
    let mut current_phase = "completed".to_string();

    if let Some(last) = steps.last() {
        // Đánh giá trạng thái chính xác theo tiến trình thực tế trong transcript:
        // 1. Nếu bước cuối cùng là PLANNER_RESPONSE và không còn tool_calls -> ĐÃ HOÀN TẤT LƯỢT TRẢ LỜI
        if last.step_type == "PLANNER_RESPONSE" && last.tool_calls.is_empty() {
            session_status = "completed".to_string();
        } else if last.status != "DONE" || !last.tool_calls.is_empty() {
            // Bước cuối chưa DONE hoặc đang gọi tool_call:
            // Chỉ coi là đang chạy nếu file vừa mới được ghi log gần đây (dưới 20 giây).
            // Nếu đã quá 20 giây không có hoạt động, tiến trình đã dừng hoặc bị ngắt!
            let age_secs = (Utc::now() - updated_at).num_seconds().abs();
            if age_secs < 20 {
                session_status = "running".to_string();
            } else {
                session_status = "interrupted".to_string();
            }
        } else {
            // Bước cuối là GENERIC hoặc USER_INPUT: chỉ coi là đang chạy nếu phát sinh rất gần (dưới 15 giây)
            let age_secs = (Utc::now() - updated_at).num_seconds().abs();
            if age_secs < 15 && (last.step_type == "GENERIC" || last.step_type == "USER_INPUT") {
                session_status = "running".to_string();
            } else {
                session_status = "completed".to_string();
            }
        }

        if session_status == "completed" {
            current_phase = "completed".to_string();
        } else if has_verify {
            current_phase = "crossVerification".to_string();
        } else if has_edit_or_parallel {
            current_phase = "parallelExecution".to_string();
        } else {
            current_phase = "contractDiscovery".to_string();
        }
    }

    let parsed_res = ParsedTranscript {
        id: id.to_string(),
        title,
        created_at: created_at.unwrap_or(file_modified),
        updated_at,
        status: session_status,
        current_phase,
        steps,
        files_touched,
        commands_run,
        spawned_subagents,
        total_input_tokens: total_input,
        total_output_tokens: total_output,
        total_cache_tokens: total_cache,
        project_name,
        project_path,
        total_steps: total_step_count,
    };

    if let Ok(mut cache) = get_transcript_cache().lock() {
        cache.insert(
            id.to_string(),
            CachedTranscript {
                modified: file_modified,
                len: file_len,
                parsed: std::sync::Arc::new(parsed_res.clone()),
            },
        );
    }

    Some(parsed_res)
}
