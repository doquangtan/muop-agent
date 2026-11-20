use super::*;

pub fn scan_all_sessions(
    active_streams: &HashMap<String, ChatTurnStreamState>,
    active_id: Option<&str>,
    max_sessions: usize,
) -> Vec<ConversationSession> {
    let brain_dir = Path::new(BRAIN_DIR_PATH);
    if !brain_dir.exists() {
        return Vec::new();
    }

    let db_meta_map = load_conversation_summary_meta();
    let mut child_subagent_ids: HashSet<String> = HashSet::new();

    // 1. Nhận diện trước toàn bộ subagents từ database meta: nếu có parent_id hoặc agent_name != "" (và != "Coordinator")
    for (id, m) in &db_meta_map {
        if !m.parent_id.is_empty()
            || (!m.agent_name.is_empty() && m.agent_name != "Coordinator" && m.agent_name != "user")
        {
            child_subagent_ids.insert(id.clone());
        }
    }

    // 2. Quét nhanh transcript để bổ sung các subagent ID được spawn trong phiên làm việc
    let conv_id_re = Regex::new(r#""conversationId"\s*:\s*"([^"]+)""#).ok();
    if let Ok(read_dir) = fs::read_dir(brain_dir) {
        for entry in read_dir.flatten() {
            let path = entry.path();
            if path.is_dir() {
                let transcript_path = path.join(".system_generated/logs/transcript.jsonl");
                if let Ok(file) = fs::File::open(&transcript_path) {
                    use std::io::{BufRead, BufReader};
                    let reader = BufReader::new(file);
                    for line_res in reader.lines() {
                        if let Ok(line) = line_res {
                            if line.contains("Created the following subagent:")
                                || line.contains("invoke_subagent")
                            {
                                if let Some(ref re) = conv_id_re {
                                    if let Some(caps) = re.captures(&line) {
                                        if let Some(m) = caps.get(1) {
                                            child_subagent_ids.insert(m.as_str().to_string());
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    let mut entries: Vec<(String, DateTime<Utc>)> = Vec::new();

    if let Ok(read_dir) = fs::read_dir(brain_dir) {
        for entry in read_dir.flatten() {
            let path = entry.path();
            if path.is_dir() {
                let id = match path.file_name().and_then(|n| n.to_str()) {
                    Some(s) => s.to_string(),
                    None => continue,
                };
                if id == "tempmediaStorage" || id.starts_with('.') {
                    continue;
                }
                let transcript_path = path.join(".system_generated/logs/transcript.jsonl");
                if let Ok(meta) = fs::metadata(&transcript_path) {
                    let modified: DateTime<Utc> =
                        meta.modified().unwrap_or(SystemTime::UNIX_EPOCH).into();
                    entries.push((id, modified));
                }
            }
        }
    }

    entries.sort_by(|a, b| b.1.cmp(&a.1));

    // Lọc ra các conversation top-level (loại bỏ child subagents ngay từ đầu)
    let mut top_level_entries: Vec<(String, DateTime<Utc>)> = Vec::new();
    for (id, modified) in entries {
        if child_subagent_ids.contains(&id) {
            continue;
        }
        top_level_entries.push((id, modified));
    }

    let selected: Vec<(String, DateTime<Utc>)> =
        if max_sessions == 0 || max_sessions >= top_level_entries.len() {
            top_level_entries
        } else {
            top_level_entries.into_iter().take(max_sessions).collect()
        };

    let target_active = active_id
        .map(|s| s.to_string())
        .or_else(|| selected.first().map(|(id, _)| id.clone()));

    let mut raw_sessions: HashMap<String, ParsedTranscript> = HashMap::new();

    for (id, modified) in &selected {
        let meta = db_meta_map.get(id);
        if let Some(parsed) = parse_transcript_file(id, *modified, meta) {
            for s in &parsed.spawned_subagents {
                if !s.id.is_empty() {
                    child_subagent_ids.insert(s.id.clone());
                }
            }
            raw_sessions.insert(id.clone(), parsed);
        }
    }

    // Transcript của sub-agent (kể cả agent cháu) để dựng cây lane
    let extra_roots: Vec<String> = child_subagent_ids
        .iter()
        .filter(|id| !raw_sessions.contains_key(*id))
        .cloned()
        .collect();
    raw_sessions.extend(load_subagent_transcripts(
        Path::new(BRAIN_DIR_PATH),
        extra_roots,
        &db_meta_map,
    ));

    let live_agy_cids = scan_running_agy_conversations();
    let cut_turns = crate::infra::store::cut_short_turns();
    let mut git_sync_cache: HashMap<String, Option<GitSyncStatus>> = HashMap::new();
    let mut project_agents_cache: HashMap<String, (Vec<CustomAgentSpec>, Vec<String>)> =
        HashMap::new();
    let mut sessions = Vec::new();
    for (idx, (id, _)) in selected.iter().enumerate() {
        if let Some(m) = db_meta_map.get(id) {
            if !m.parent_id.is_empty() {
                continue;
            }
        }
        if child_subagent_ids.contains(id) {
            continue;
        }
        let parsed = match raw_sessions.get(id) {
            Some(p) => p,
            None => continue,
        };

        let is_active_session =
            target_active.as_deref() == Some(id.as_str()) || (target_active.is_none() && idx == 0);

        let is_stream_running = active_streams
            .get(&parsed.id)
            .map(|st| st.is_running)
            .unwrap_or(false);
        let is_os_agy_running = live_agy_cids.contains(&parsed.id);
        let is_actually_running = is_stream_running || is_os_agy_running;

        let (effective_status, is_interrupted, interrupted_reason) = if is_actually_running {
            ("running".to_string(), false, None)
        } else if parsed.status == "running"
            || parsed.status == "interrupted"
            || agy_turn_cut_short(parsed, &cut_turns)
        {
            (
                "interrupted".to_string(),
                true,
                Some("Tiến trình Agent bị gián đoạn do máy chủ khởi động lại hoặc agy CLI dừng đột ngột.".to_string()),
            )
        } else {
            (parsed.status.clone(), false, None)
        };

        // Khi có 2 hay nhiều conversation cùng chạy, tất cả các conversation đang chạy
        // hoặc conversation active đều phải được nạp đầy đủ lanes và 150 steps gần nhất.
        let should_load_full = is_active_session || is_actually_running;

        let lanes = if should_load_full {
            build_subagent_lanes(parsed, &raw_sessions, is_actually_running)
        } else {
            Vec::new()
        };

        let sub_to_parent_step: HashMap<String, usize> = parsed
            .spawned_subagents
            .iter()
            .filter(|s| !s.id.is_empty())
            .map(|s| (s.id.clone(), s.step_index))
            .collect();

        // Tối ưu Payload Snapshot:
        // CHỈ nạp files, commands và steps cho session đang active hoặc đang chạy!
        // Các session inactive trong snapshot chỉ cần metadata gọn nhẹ để sidebar hiển thị.
        // Khi người dùng bấm vào session bất kỳ, client sẽ fetch full detail qua /api/session.
        let (files, commands) = if should_load_full {
            let mut f_list = parsed.files_touched.clone();
            let mut c_list = parsed.commands_run.clone();

            for lane in &lanes {
                if let Some(sub_parsed) = raw_sessions.get(&lane.id) {
                    let parent_step = sub_to_parent_step.get(&lane.id).cloned().unwrap_or(0);
                    for mut f in sub_parsed.files_touched.clone() {
                        if parent_step > 0 {
                            f.step_index = parent_step;
                        }
                        f_list.push(f);
                    }
                    for mut c in sub_parsed.commands_run.clone() {
                        if parent_step > 0 {
                            c.step_index = parent_step;
                        }
                        c_list.push(c);
                    }
                }
            }

            f_list.sort_by(|a, b| b.timestamp.cmp(&a.timestamp));
            c_list.sort_by(|a, b| b.timestamp.cmp(&a.timestamp));

            if f_list.len() > 80 {
                f_list.truncate(80);
            }
            for f in &mut f_list {
                if f.diff_preview.len() > 200 {
                    f.diff_preview = format!("{}...", safe_truncate(&f.diff_preview, 200));
                }
            }
            if c_list.len() > 40 {
                c_list.truncate(40);
            }
            for c in &mut c_list {
                if c.output_preview.len() > 200 {
                    c.output_preview = format!("{}...", safe_truncate(&c.output_preview, 200));
                }
            }
            (f_list, c_list)
        } else {
            (Vec::new(), Vec::new())
        };

        // Chỉ nạp 100 steps gần nhất cho session active/running, rỗng cho session inactive
        let steps = if should_load_full {
            if parsed.steps.len() > 100 {
                parsed.steps[parsed.steps.len() - 100..].to_vec()
            } else {
                parsed.steps.clone()
            }
        } else {
            Vec::new()
        };

        let mut final_steps = steps;
        if is_interrupted {
            if let Some(last) = final_steps.last() {
                if last.step_type == "PLANNER_RESPONSE" && !last.tool_calls.is_empty() {
                    final_steps.push(AgentStep {
                        step_index: last.step_index + 1,
                        source: "SYSTEM".to_string(),
                        step_type: "GENERIC".to_string(),
                        status: "INTERRUPTED".to_string(),
                        created_at: Utc::now().to_rfc3339(),
                        content: "⚠️ Tiến trình Agent bị gián đoạn do máy chủ khởi động lại hoặc lệnh CLI bị ngắt đột ngột. Bạn có thể gửi tin nhắn tiếp theo để tiếp tục.".to_string(),
                        thinking: String::new(),
                        tool_calls: Vec::new(),
                        input_tokens: 0,
                        output_tokens: 0,
                        cache_read_tokens: 0,
                        agent_name: "Coordinator".to_string(),
                        phase: "completed".to_string(),
                        vietnamese_title: "Tiến trình Agent bị gián đoạn".to_string(),
                        vietnamese_detail: "Tiến trình xử lý của Agent đã bị ngắt do server restart hoặc dừng đột ngột. Bạn có thể tiếp tục bằng cách gửi tin nhắn tiếp theo.".to_string(),
                        model: String::new(),
                        image_count: 0,
                        image_urls: Vec::new(),
                    });
                }
            }
        }

        let (p_custom_agents, p_available_agents) = project_agents_cache
            .entry(parsed.project_path.clone())
            .or_insert_with(|| scan_project_agents_and_skills(Path::new(&parsed.project_path)))
            .clone();

        let is_erp_proj = parsed.project_name == "muop-erp-server"
            || parsed.project_name == "muop-erp-app"
            || Path::new(&parsed.project_path)
                .join(".agents/rules/parallel-erp-sync.md")
                .exists();
        let has_parallel_flow =
            is_erp_proj || !parsed.spawned_subagents.is_empty() || lanes.len() > 1;

        let agy_ctx = agy_context_for(&parsed.id, &parsed.updated_at.to_rfc3339());
        sessions.push(ConversationSession {
            id: parsed.id.clone(),
            title: parsed.title.clone(),
            created_at: parsed.created_at.to_rfc3339(),
            updated_at: parsed.updated_at.to_rfc3339(),
            status: effective_status,
            current_phase: if is_interrupted {
                "completed".to_string()
            } else {
                parsed.current_phase.clone()
            },
            steps: final_steps,
            subagent_lanes: lanes,
            files_touched: files,
            commands_run: commands,
            total_input_tokens: parsed.total_input_tokens,
            total_output_tokens: parsed.total_output_tokens,
            total_cache_tokens: parsed.total_cache_tokens,
            project_name: parsed.project_name.clone(),
            project_path: parsed.project_path.clone(),
            is_simulated: false,
            pending_plans: scan_pending_plans(&parsed.id),
            git_sync_status: git_sync_cache
                .entry(parsed.project_path.clone())
                .or_insert_with(|| check_git_sync_status(&parsed.project_path))
                .clone(),
            is_interrupted,
            interrupted_reason,
            custom_agents: if should_load_full {
                p_custom_agents
            } else {
                Vec::new()
            },
            available_agents: p_available_agents,
            has_parallel_flow,
            source: "agy".to_string(),
            context_tokens: agy_ctx.tokens,
            context_model: agy_ctx.model.clone(),
            selected_model: String::new(),
        });
    }

    // Session của Claude Code CLI (~/.claude/projects) được gộp chung vào danh sách
    sessions.extend(crate::claude::code::scan_sessions(active_streams));
    sessions
}
