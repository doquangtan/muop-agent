use super::*;

/// Đọc đầy đủ session kết hợp kiểm tra trạng thái active_streams hiện thời,
/// kèm model đã chọn (kèm mức) của conversation
pub fn get_single_session_with_streams(
    session_id: &str,
    active_streams: &HashMap<String, ChatTurnStreamState>,
) -> Option<ConversationSession> {
    let mut session = get_single_session_inner(session_id, active_streams)?;
    session.selected_model =
        crate::infra::store::conversation_model(session_id).unwrap_or_default();
    Some(session)
}

pub(super) fn get_single_session_inner(
    session_id: &str,
    active_streams: &HashMap<String, ChatTurnStreamState>,
) -> Option<ConversationSession> {
    if let Some(session) = crate::claude::code::get_session(session_id, active_streams) {
        return Some(session);
    }
    let brain_dir = Path::new(BRAIN_DIR_PATH);

    let db_meta_map = load_conversation_summary_meta();
    // Nếu session_id là child subagent, tự động chuyển sang đọc session cha
    let target_id = if let Some(m) = db_meta_map.get(session_id) {
        if !m.parent_id.is_empty() {
            m.parent_id.as_str()
        } else {
            session_id
        }
    } else {
        session_id
    };

    let session_dir = brain_dir.join(target_id);
    if !session_dir.exists() {
        return None;
    }
    let transcript_path = session_dir.join(".system_generated/logs/transcript.jsonl");
    let meta = fs::metadata(&transcript_path).ok()?;
    let modified: DateTime<Utc> = meta.modified().unwrap_or(SystemTime::UNIX_EPOCH).into();

    let db_meta = db_meta_map.get(target_id);

    let parsed = parse_transcript_file(target_id, modified, db_meta)?;

    let mut raw_sessions: HashMap<String, ParsedTranscript> = HashMap::new();
    for s in &parsed.spawned_subagents {
        if !s.id.is_empty() {
            let sub_path = brain_dir
                .join(&s.id)
                .join(".system_generated/logs/transcript.jsonl");
            if let Ok(smeta) = fs::metadata(&sub_path) {
                let smod: DateTime<Utc> = smeta.modified().unwrap_or(SystemTime::UNIX_EPOCH).into();
                if let Some(sparsed) = parse_transcript_file(&s.id, smod, db_meta_map.get(&s.id)) {
                    raw_sessions.insert(s.id.clone(), sparsed);
                }
            }
        }
    }

    let live_agy_cids = scan_running_agy_conversations();
    let cut_turns = crate::infra::store::cut_short_turns();
    let is_stream_running = active_streams
        .get(target_id)
        .map(|st| st.is_running)
        .unwrap_or(false);
    let is_actually_running = is_stream_running || live_agy_cids.contains(target_id);
    let (status, is_interrupted, interrupted_reason) = if is_actually_running {
        ("running".to_string(), false, None)
    } else if parsed.status == "running"
        || parsed.status == "interrupted"
        || agy_turn_cut_short(&parsed, &cut_turns)
    {
        (
            "interrupted".to_string(),
            true,
            Some("Tiến trình Agent bị gián đoạn do máy chủ khởi động lại hoặc agy CLI dừng đột ngột.".to_string()),
        )
    } else {
        (parsed.status.clone(), false, None)
    };

    let lanes = build_subagent_lanes(&parsed, &raw_sessions, is_actually_running);
    let sub_to_parent_step: HashMap<String, usize> = parsed
        .spawned_subagents
        .iter()
        .filter(|s| !s.id.is_empty())
        .map(|s| (s.id.clone(), s.step_index))
        .collect();

    let mut files = parsed.files_touched.clone();
    let mut commands = parsed.commands_run.clone();
    for lane in &lanes {
        if let Some(sub_parsed) = raw_sessions.get(&lane.id) {
            let parent_step = sub_to_parent_step.get(&lane.id).cloned().unwrap_or(0);
            for mut f in sub_parsed.files_touched.clone() {
                if parent_step > 0 {
                    f.step_index = parent_step;
                }
                files.push(f);
            }
            for mut c in sub_parsed.commands_run.clone() {
                if parent_step > 0 {
                    c.step_index = parent_step;
                }
                commands.push(c);
            }
        }
    }
    files.sort_by(|a, b| b.timestamp.cmp(&a.timestamp));
    commands.sort_by(|a, b| b.timestamp.cmp(&a.timestamp));

    if files.len() > 100 {
        files.truncate(100);
    }
    if commands.len() > 50 {
        commands.truncate(50);
    }

    let mut final_steps = if parsed.steps.len() > 100 {
        parsed.steps[parsed.steps.len() - 100..].to_vec()
    } else {
        parsed.steps
    };
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
                });
            }
        }
    }

    let agy_ctx = agy_context_for(&parsed.id, &parsed.updated_at.to_rfc3339());
    let (custom_agents, available_agents) =
        scan_project_agents_and_skills(Path::new(&parsed.project_path));
    let is_erp_proj = parsed.project_name == "muop-erp-server"
        || parsed.project_name == "muop-erp-app"
        || Path::new(&parsed.project_path)
            .join(".agents/rules/parallel-erp-sync.md")
            .exists();
    let has_parallel_flow = is_erp_proj || !parsed.spawned_subagents.is_empty() || lanes.len() > 1;

    Some(ConversationSession {
        id: parsed.id.clone(),
        title: parsed.title.clone(),
        created_at: parsed.created_at.to_rfc3339(),
        updated_at: parsed.updated_at.to_rfc3339(),
        status,
        current_phase: if is_interrupted {
            "completed".to_string()
        } else {
            parsed.current_phase
        },
        steps: final_steps,
        subagent_lanes: lanes,
        files_touched: files,
        commands_run: commands,
        total_input_tokens: parsed.total_input_tokens,
        total_output_tokens: parsed.total_output_tokens,
        total_cache_tokens: parsed.total_cache_tokens,
        git_sync_status: check_git_sync_status(&parsed.project_path),
        project_name: parsed.project_name,
        project_path: parsed.project_path,
        is_simulated: false,
        pending_plans: scan_pending_plans(&parsed.id),
        is_interrupted,
        interrupted_reason,
        custom_agents,
        available_agents,
        has_parallel_flow,
        source: "agy".to_string(),
        context_tokens: agy_ctx.tokens,
        context_model: agy_ctx.model,
        selected_model: String::new(),
    })
}

/// Lấy danh sách các bước (steps) theo phân trang (paging):
/// Trả về `limit` bước xảy ra ngay trước `before_step` (sắp xếp tăng dần theo thời gian).
pub fn get_session_steps_page(
    session_id: &str,
    before_step: Option<usize>,
    limit: usize,
) -> Option<SessionStepsPageResponse> {
    if let Some(page) = crate::claude::code::get_steps_page(session_id, before_step, limit) {
        return Some(page);
    }
    let brain_dir = Path::new(BRAIN_DIR_PATH);
    let session_dir = brain_dir.join(session_id);
    if !session_dir.exists() {
        return None;
    }
    let transcript_path = session_dir.join(".system_generated/logs/transcript.jsonl");
    let meta = fs::metadata(&transcript_path).ok()?;
    let modified: DateTime<Utc> = meta.modified().unwrap_or(SystemTime::UNIX_EPOCH).into();

    let db_meta_map = load_conversation_summary_meta();
    let db_meta = db_meta_map.get(session_id);

    let parsed = parse_transcript_file(session_id, modified, db_meta)?;
    let total_steps = parsed.total_steps;

    let earliest_in_cache = parsed.steps.first().map(|s| s.step_index).unwrap_or(0);
    let can_use_cache = match before_step {
        None => true,
        Some(target) => target > earliest_in_cache,
    };

    if can_use_cache {
        let candidate_steps: Vec<&AgentStep> = if let Some(target) = before_step {
            parsed
                .steps
                .iter()
                .filter(|s| s.step_index < target)
                .collect()
        } else {
            parsed.steps.iter().collect()
        };

        let count = candidate_steps.len();
        let take_count = limit.min(count);
        let start_idx = count.saturating_sub(take_count);
        let page_steps: Vec<AgentStep> = candidate_steps[start_idx..count]
            .iter()
            .map(|&s| s.clone())
            .collect();

        let earliest_step_index = page_steps.first().map(|s| s.step_index).unwrap_or(0);
        let has_more = earliest_step_index > 0;

        return Some(SessionStepsPageResponse {
            session_id: session_id.to_string(),
            steps: page_steps,
            has_more,
            earliest_step_index,
            total_steps,
        });
    }

    read_steps_page_from_file(
        &transcript_path,
        session_id,
        before_step,
        limit,
        total_steps,
        modified,
    )
}

pub(super) fn read_steps_page_from_file(
    path: &Path,
    session_id: &str,
    before_step: Option<usize>,
    limit: usize,
    total_steps: usize,
    file_modified: DateTime<Utc>,
) -> Option<SessionStepsPageResponse> {
    use std::collections::VecDeque;
    use std::io::{BufRead, BufReader};
    let file = fs::File::open(path).ok()?;
    let reader = BufReader::new(file);

    let target_step = before_step.unwrap_or(usize::MAX);
    let mut candidate_deque: VecDeque<AgentStep> = VecDeque::new();

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
            .unwrap_or(0);

        if step_index >= target_step {
            continue;
        }

        let step = parse_single_agent_step(&map, step_index, file_modified);
        candidate_deque.push_back(step);
        if candidate_deque.len() > limit {
            candidate_deque.pop_front();
        }
    }

    let page_steps: Vec<AgentStep> = candidate_deque.into_iter().collect();
    let earliest_step_index = page_steps.first().map(|s| s.step_index).unwrap_or(0);
    let has_more = earliest_step_index > 0;

    Some(SessionStepsPageResponse {
        session_id: session_id.to_string(),
        steps: page_steps,
        has_more,
        earliest_step_index,
        total_steps,
    })
}
