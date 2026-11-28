use super::*;

/// Danh sách session Claude Code (đã áp trạng thái đang chạy từ active_streams).
/// Metadata lấy từ SQLite; chỉ session đang chạy và session mới nhất được nạp đầy đủ bước.
pub fn scan_sessions(
    active_streams: &HashMap<String, ChatTurnStreamState>,
) -> Vec<ConversationSession> {
    let files = list_session_files();
    let on_disk: HashSet<String> = files
        .iter()
        .filter_map(|(p, _)| p.file_stem().and_then(|s| s.to_str()).map(String::from))
        .collect();
    crate::infra::store::transcript_meta_prune("claude", &on_disk);

    let muop = crate::infra::store::claude_muop_conversations();
    let metas: Vec<(PathBuf, (u64, u64), ConversationSession, usize)> = files
        .iter()
        .filter_map(|(path, fp)| load_meta(path, *fp).map(|(s, c)| (path.clone(), *fp, s, c)))
        .filter(|m| m.3 > 0)
        .collect();
    let newest = metas
        .iter()
        .max_by(|a, b| a.2.updated_at.cmp(&b.2.updated_at))
        .map(|m| m.0.clone());

    metas
        .into_iter()
        .map(|(path, fp, session, _)| {
            let running = active_streams
                .get(&session.id)
                .is_some_and(|st| st.is_running);
            let full = running || newest.as_ref() == Some(&path);
            let session = if full {
                load_full(&path, fp).unwrap_or(session)
            } else {
                session
            };
            apply_live_status(session, active_streams, &muop)
        })
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
    load_full(&path, fp).map(|s| apply_live_status(s, active_streams, &muop))
}

/// Phân trang step theo cùng quy ước với Antigravity: lấy `limit` step ngay trước `before_step`.
/// Đọc theo chỉ mục SQLite, không parse cả file.
pub fn get_steps_page(
    session_id: &str,
    before_step: Option<usize>,
    limit: usize,
) -> Option<SessionStepsPageResponse> {
    let path = find_session_file(session_id)?;
    steps_page(&path, before_step, limit)
}
