use super::*;

/// Sub-agent được gọi trong session (tool `Agent`/`Task`), ghép với transcript con sau khi parse
pub(super) struct SpawnedAgent {
    pub(super) tool_use_id: String,
    pub(super) name: String,
    pub(super) role: String,
    pub(super) prompt: String,
    pub(super) agent_id: Option<String>,
    pub(super) completed: bool,
}

/// Parse toàn bộ file session thành `ConversationSession` (đủ mọi step).
/// `is_subagent`: file là transcript của sub-agent (mọi dòng đều là sidechain).
pub(super) fn parse_session_file(path: &Path, is_subagent: bool) -> Option<ConversationSession> {
    parse_session_parts(path, is_subagent).map(|(session, _)| session)
}

/// Như [`parse_session_file`] nhưng trả thêm các sub-agent mà file này gọi (tool `Agent`/`Task`).
/// Dùng để dựng cây sub-agent: agent con có thể spawn agent cháu.
pub(super) fn parse_session_parts(
    path: &Path,
    is_subagent: bool,
) -> Option<(ConversationSession, Vec<SpawnedAgent>)> {
    let session_id = path.file_stem()?.to_str()?.to_string();
    let content = fs::read_to_string(path).ok()?;

    let mut steps: Vec<AgentStep> = Vec::new();
    let mut files: Vec<FileTouchRecord> = Vec::new();
    let mut commands: Vec<CommandExecutionRecord> = Vec::new();
    let mut ai_title: Option<String> = None;
    let mut cwd = String::new();
    let mut first_ts: Option<String> = None;
    let mut last_ts: Option<String> = None;
    let mut counted_message_ids: HashSet<String> = HashSet::new();
    let (mut total_in, mut total_out, mut total_cache) = (0u64, 0u64, 0u64);
    // Context đang dùng = input + cache tạo + cache đọc của message assistant gần nhất
    let (mut context_tokens, mut context_model) = (0u64, String::new());
    let mut first_user_text = String::new();
    let mut spawns: Vec<SpawnedAgent> = Vec::new();
    // Vị trí đầu tiên trong `spawns` của lượt hiện tại (sau tin nhắn người dùng gần nhất)
    let mut turn_spawn_start: usize = 0;
    let mut last_record: Option<LastRecord> = None;

    for line in content.lines() {
        let Ok(v) = serde_json::from_str::<Value>(line) else {
            continue;
        };
        // Hội thoại của sub-agent (sidechain) không trộn vào luồng chính; được nạp qua lane riêng
        if !is_subagent
            && v.get("isSidechain")
                .and_then(|x| x.as_bool())
                .unwrap_or(false)
        {
            continue;
        }
        if cwd.is_empty() {
            if let Some(c) = v.get("cwd").and_then(|x| x.as_str()) {
                cwd = c.to_string();
            }
        }
        let ts = v
            .get("timestamp")
            .and_then(|x| x.as_str())
            .map(|s| s.to_string());
        if let Some(t) = &ts {
            if first_ts.is_none() {
                first_ts = Some(t.clone());
            }
            last_ts = Some(t.clone());
        }
        let ts_str = ts.clone().unwrap_or_default();

        match v.get("type").and_then(|x| x.as_str()).unwrap_or("") {
            "ai-title" => {
                if let Some(t) = v.get("aiTitle").and_then(|x| x.as_str()) {
                    ai_title = Some(t.to_string());
                }
            }
            "user" => {
                record_agent_results(&v, &mut spawns);
                if v.get("isMeta").and_then(|x| x.as_bool()).unwrap_or(false) {
                    continue;
                }
                let Some(msg) = v.get("message") else {
                    continue;
                };
                // Chỉ lấy text do người dùng gõ; các block tool_result được bỏ qua
                let texts: Vec<String> = match msg.get("content") {
                    Some(Value::String(s)) => vec![s.clone()],
                    Some(Value::Array(blocks)) => blocks
                        .iter()
                        .filter(|b| b.get("type").and_then(|x| x.as_str()) == Some("text"))
                        .filter_map(|b| b.get("text").and_then(|x| x.as_str()).map(String::from))
                        .collect(),
                    _ => Vec::new(),
                };
                let text = texts.join("\n").trim().to_string();
                // Thông báo hoàn tất của subagent nền do Claude tạo, không phải tin nhắn của người dùng
                // (đã được ghi nhận ở record_agent_results nên bỏ qua khỏi lịch sử)
                if text.starts_with("<task-notification>") {
                    continue;
                }
                // Output của lệnh slash (`<local-command-...>`) không có lượt trả lời nên không tính là lượt chưa xong
                if !text.starts_with("<local-command") {
                    last_record = Some(LastRecord::User);
                }
                // Bản ghi chỉ có tool_result (text rỗng) không phải tin nhắn mới của người dùng
                if text.is_empty() {
                    continue;
                }
                if !text.starts_with("<local-command") {
                    turn_spawn_start = spawns.len();
                }
                // Bỏ qua các text bọc trong tag hệ thống (<ide_selection>, <command-name>...) khi lấy tiêu đề
                if first_user_text.is_empty() && !text.starts_with('<') {
                    first_user_text = text.clone();
                }
                // Ảnh đính kèm nằm ở block `image` (base64), chỉ cần đếm để hiển thị
                let image_count = match msg.get("content") {
                    Some(Value::Array(blocks)) => blocks
                        .iter()
                        .filter(|b| b.get("type").and_then(|x| x.as_str()) == Some("image"))
                        .count(),
                    _ => 0,
                };
                let idx = steps.len();
                steps.push(make_step(
                    idx,
                    "USER_INPUT",
                    "USER_EXPLICIT",
                    "user",
                    ts_str,
                    text,
                    String::new(),
                    Vec::new(),
                    0,
                    0,
                    0,
                ));
                let uuid = v.get("uuid").and_then(|x| x.as_str()).unwrap_or("");
                let session_id = path.file_stem().and_then(|s| s.to_str()).unwrap_or("");
                if let Some(step) = steps.last_mut() {
                    step.image_count = image_count;
                    if !uuid.is_empty() && !session_id.is_empty() {
                        step.image_urls = (0..image_count)
                            .map(|i| {
                                crate::chat::attachments::transcript_attachment_url(
                                    session_id, uuid, i,
                                )
                            })
                            .collect();
                    }
                }
            }
            "assistant" => {
                let Some(msg) = v.get("message") else {
                    continue;
                };
                last_record = Some(LastRecord::Assistant {
                    stop_reason: msg
                        .get("stop_reason")
                        .and_then(|x| x.as_str())
                        .unwrap_or("")
                        .to_string(),
                });
                let idx = steps.len();

                // Claude ghi mỗi content block thành một dòng riêng cùng message.id,
                // usage chỉ được cộng một lần cho mỗi message.id.
                let msg_id = msg
                    .get("id")
                    .and_then(|x| x.as_str())
                    .unwrap_or("")
                    .to_string();
                let first_time_for_message =
                    msg_id.is_empty() || counted_message_ids.insert(msg_id);
                let (mut inp, mut out, mut cache) = (0u64, 0u64, 0u64);
                if first_time_for_message {
                    if let Some(u) = msg.get("usage") {
                        inp = u.get("input_tokens").and_then(|x| x.as_u64()).unwrap_or(0);
                        out = u.get("output_tokens").and_then(|x| x.as_u64()).unwrap_or(0);
                        cache = u
                            .get("cache_read_input_tokens")
                            .and_then(|x| x.as_u64())
                            .unwrap_or(0);
                        total_in += inp;
                        total_out += out;
                        total_cache += cache;
                        let cache_created = u
                            .get("cache_creation_input_tokens")
                            .and_then(|x| x.as_u64())
                            .unwrap_or(0);
                        let ctx = inp + cache_created + cache;
                        if ctx > 0 {
                            context_tokens = ctx;
                            context_model = msg
                                .get("model")
                                .and_then(|x| x.as_str())
                                .filter(|m| !m.is_empty() && !m.starts_with('<'))
                                .map(|m| format!("claude-cli:{m}"))
                                .unwrap_or_default();
                        }
                    }
                }

                let mut text_parts: Vec<String> = Vec::new();
                let mut thinking_parts: Vec<String> = Vec::new();
                let mut tool_calls: Vec<ToolCallInfo> = Vec::new();

                if let Some(Value::Array(blocks)) = msg.get("content") {
                    for b in blocks {
                        match b.get("type").and_then(|x| x.as_str()).unwrap_or("") {
                            "text" => {
                                if let Some(t) = b.get("text").and_then(|x| x.as_str()) {
                                    text_parts.push(t.to_string());
                                }
                            }
                            "thinking" => {
                                if let Some(t) = b.get("thinking").and_then(|x| x.as_str()) {
                                    thinking_parts.push(t.to_string());
                                }
                            }
                            "tool_use" => {
                                let name = b
                                    .get("name")
                                    .and_then(|x| x.as_str())
                                    .unwrap_or("tool")
                                    .to_string();
                                let args: HashMap<String, Value> = b
                                    .get("input")
                                    .and_then(|x| x.as_object())
                                    .map(|o| {
                                        o.iter().map(|(k, v)| (k.clone(), v.clone())).collect()
                                    })
                                    .unwrap_or_default();
                                let target_path = ["file_path", "notebook_path", "path"]
                                    .iter()
                                    .find_map(|k| args.get(*k).and_then(|x| x.as_str()))
                                    .map(String::from);
                                if name == "Agent" || name == "Task" {
                                    spawns.push(SpawnedAgent {
                                        tool_use_id: b
                                            .get("id")
                                            .and_then(|x| x.as_str())
                                            .unwrap_or("")
                                            .to_string(),
                                        name: args
                                            .get("subagent_type")
                                            .and_then(|x| x.as_str())
                                            .filter(|s| !s.is_empty())
                                            .unwrap_or("general-purpose")
                                            .to_string(),
                                        role: args
                                            .get("description")
                                            .and_then(|x| x.as_str())
                                            .unwrap_or("")
                                            .to_string(),
                                        prompt: args
                                            .get("prompt")
                                            .and_then(|x| x.as_str())
                                            .unwrap_or("")
                                            .to_string(),
                                        agent_id: None,
                                        completed: false,
                                    });
                                }
                                record_side_effects(
                                    &name,
                                    &args,
                                    idx,
                                    &ts_str,
                                    &mut files,
                                    &mut commands,
                                );
                                tool_calls.push(ToolCallInfo {
                                    summary_label: tool_summary(&name, &args),
                                    name,
                                    args,
                                    target_path,
                                    repo_tag: String::new(),
                                });
                            }
                            _ => {}
                        }
                    }
                }

                if text_parts.is_empty() && thinking_parts.is_empty() && tool_calls.is_empty() {
                    continue;
                }
                // Model thực tế do Claude báo trong message (bỏ qua giá trị đặc biệt như `<synthetic>`)
                let model_name = msg
                    .get("model")
                    .and_then(|x| x.as_str())
                    .filter(|m| !m.is_empty() && !m.starts_with('<'))
                    .unwrap_or("")
                    .to_string();
                let mut step = make_step(
                    idx,
                    "PLANNER_RESPONSE",
                    "MODEL",
                    "Coordinator",
                    ts_str,
                    text_parts.join("\n\n"),
                    thinking_parts.join("\n\n"),
                    tool_calls,
                    inp,
                    out,
                    cache,
                );
                step.model = model_name;
                steps.push(step);
            }
            _ => {}
        }
    }

    let fallback_time = fingerprint(path)
        .map(|(ms, _)| {
            chrono::DateTime::<chrono::Utc>::from(UNIX_EPOCH + std::time::Duration::from_millis(ms))
                .to_rfc3339()
        })
        .unwrap_or_default();
    let created_at = first_ts.clone().unwrap_or_else(|| fallback_time.clone());
    let updated_at = last_ts.unwrap_or(fallback_time);
    // Lượt chưa xong: bản ghi cuối là prompt/tool_result, hoặc assistant đang chờ tool_result
    let unfinished = !is_subagent
        && match &last_record {
            Some(LastRecord::User) => true,
            Some(LastRecord::Assistant { stop_reason }) => stop_reason == "tool_use",
            None => false,
        };
    let base_status = if unfinished {
        UNFINISHED_STATUS
    } else {
        "completed"
    };

    let title = match ai_title {
        Some(t) if !t.trim().is_empty() => t.trim().to_string(),
        _ => {
            let fallback: String = first_user_text.chars().take(60).collect();
            if fallback.trim().is_empty() {
                "Phiên Claude Code".to_string()
            } else {
                fallback.replace('\n', " ")
            }
        }
    };

    let project_path = if cwd.is_empty() {
        path.parent()
            .map(|p| p.to_string_lossy().to_string())
            .unwrap_or_default()
    } else {
        cwd
    };
    let project_name = Path::new(&project_path)
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("")
        .to_string();

    detect_bash_file_changes(&project_path, &steps, &mut files);
    files.sort_by(|a, b| b.timestamp.cmp(&a.timestamp));
    files.truncate(100);
    commands.sort_by(|a, b| b.timestamp.cmp(&a.timestamp));
    commands.truncate(50);

    // Chỉ session chính dựng cây sub-agent; transcript con đã được dựng từ lane của cha
    // Lane chỉ gồm các lần gọi của lượt hiện tại; lượt trước đã xong không hiện lại
    let subagent_lanes = if is_subagent {
        Vec::new()
    } else {
        let start = turn_spawn_start.min(spawns.len());
        build_subagent_lanes(path, &spawns[start..], &project_name)
    };
    let has_parallel_flow = !subagent_lanes.is_empty();

    let session = ConversationSession {
        id: session_id,
        title,
        created_at,
        updated_at,
        status: base_status.to_string(),
        current_phase: base_status.to_string(),
        steps,
        subagent_lanes,
        lanes_loaded: true,
        files_touched: files,
        commands_run: commands,
        total_input_tokens: total_in,
        total_output_tokens: total_out,
        total_cache_tokens: total_cache,
        project_name,
        project_path,
        is_simulated: false,
        pending_plans: Vec::new(),
        git_sync_status: None,
        is_interrupted: false,
        interrupted_reason: None,
        custom_agents: Vec::new(),
        available_agents: Vec::new(),
        has_parallel_flow,
        source: "claude-cli".to_string(),
        context_tokens,
        context_model,
        selected_model: String::new(),
    };
    Some((session, spawns))
}
