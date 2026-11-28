use super::*;

/// Sub-agent được gọi trong session (tool `Agent`/`Task`), ghép với transcript con sau khi parse
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub(super) struct SpawnedAgent {
    pub(super) tool_use_id: String,
    pub(super) name: String,
    pub(super) role: String,
    pub(super) prompt: String,
    pub(super) agent_id: Option<String>,
    pub(super) completed: bool,
}

/// Parse một file session thành `ConversationSession` (tối đa `TAIL_STEPS` bước cuối, có lanes) trong bộ nhớ,
/// không ghi vào SQLite. Chỉ dùng cho kiểm thử; đường dùng thật dùng chỉ mục (`session_indexed`).
#[cfg(test)]
pub(super) fn parse_session_file(path: &Path, is_subagent: bool) -> Option<ConversationSession> {
    parse_in_memory(path, is_subagent).map(|(session, _)| session)
}

/// Session và các sub-agent mà file này gọi (tool `Agent`/`Task`), dựng từ chỉ mục SQLite.
/// Dùng để dựng cây sub-agent: agent con có thể spawn agent cháu.
pub(super) fn parse_session_parts(
    path: &Path,
    is_subagent: bool,
) -> Option<(ConversationSession, Vec<SpawnedAgent>)> {
    session_indexed(path, is_subagent, !is_subagent, TAIL_STEPS)
}
