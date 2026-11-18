use super::*;

/// Tóm tắt các session (không kèm steps/lanes/files) để gửi `sessions:list`
pub fn summarize_sessions(
    sessions: &[ConversationSession],
    streams: &HashMap<String, ChatTurnStreamState>,
) -> Vec<crate::models::SessionSummary> {
    sessions
        .iter()
        .map(|s| crate::models::SessionSummary {
            id: s.id.clone(),
            title: s.title.clone(),
            created_at: s.created_at.clone(),
            updated_at: s.updated_at.clone(),
            status: s.status.clone(),
            current_phase: s.current_phase.clone(),
            project_name: s.project_name.clone(),
            project_path: s.project_path.clone(),
            source: s.source.clone(),
            context_tokens: s.context_tokens,
            context_model: s.context_model.clone(),
            selected_model: crate::infra::store::conversation_model(&s.id).unwrap_or_default(),
            is_running: s.status == "running"
                || streams
                    .values()
                    .any(|st| st.is_running && st.conversation_id == s.id),
            is_interrupted: s.is_interrupted,
            files_count: s.files_touched.len(),
            pending_plans: s.pending_plans.clone(),
        })
        .collect()
}

/// Metadata chung: project, model, máy chủ (dùng cho `meta:update`)
pub fn build_meta(sessions: &[ConversationSession]) -> crate::models::MetaPayload {
    crate::models::MetaPayload {
        projects: discover_projects(sessions),
        available_models: default_models(),
        effort_levels: crate::claude::code::effort_levels(),
        model_labels: model_labels(),
        model_context_limits: crate::infra::store::context_limits(),
        hostname: detect_hostname(),
        lan_ips: detect_lan_ips(),
        port: DEFAULT_PORT,
        timestamp: Utc::now().to_rfc3339(),
    }
}
