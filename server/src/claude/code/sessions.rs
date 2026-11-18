use super::*;

/// Danh sách session Claude Code (đã áp trạng thái đang chạy từ active_streams)
pub fn scan_sessions(
    active_streams: &HashMap<String, ChatTurnStreamState>,
) -> Vec<ConversationSession> {
    let files = list_session_files();
    // Loại bỏ cache của các file đã không còn
    if let Ok(mut map) = cache().lock() {
        let alive: HashSet<&PathBuf> = files.iter().map(|(p, _)| p).collect();
        map.retain(|p, _| alive.contains(p));
    }
    let muop = crate::infra::store::claude_muop_conversations();
    files
        .iter()
        .filter_map(|(path, fp)| load_cached(path, *fp))
        .filter(|s| !s.steps.is_empty())
        .map(|s| apply_live_status(s, active_streams, &muop))
        .collect()
}

/// Chi tiết một session (với tối đa `SNAPSHOT_STEP_LIMIT` step cuối)
pub fn get_session(
    session_id: &str,
    active_streams: &HashMap<String, ChatTurnStreamState>,
) -> Option<ConversationSession> {
    let path = find_session_file(session_id)?;
    let fp = fingerprint(&path)?;
    let muop = crate::infra::store::claude_muop_conversations();
    load_cached(&path, fp).map(|s| apply_live_status(s, active_streams, &muop))
}

/// Phân trang step theo cùng quy ước với Antigravity: lấy `limit` step ngay trước `before_step`.
pub fn get_steps_page(
    session_id: &str,
    before_step: Option<usize>,
    limit: usize,
) -> Option<SessionStepsPageResponse> {
    let path = find_session_file(session_id)?;
    let full = parse_session_file(&path, false)?;
    let total_steps = full.steps.len();
    let candidates: Vec<&AgentStep> = full
        .steps
        .iter()
        .filter(|s| before_step.map_or(true, |b| s.step_index < b))
        .collect();
    let take = limit.min(candidates.len());
    let start = candidates.len() - take;
    let page: Vec<AgentStep> = candidates[start..].iter().map(|s| (*s).clone()).collect();
    let earliest = page.first().map(|s| s.step_index).unwrap_or(0);
    Some(SessionStepsPageResponse {
        session_id: session_id.to_string(),
        steps: page,
        has_more: earliest > 0,
        earliest_step_index: earliest,
        total_steps,
    })
}
