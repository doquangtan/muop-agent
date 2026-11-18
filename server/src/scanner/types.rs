use super::*;

#[derive(Debug, Clone)]
pub(super) struct DbConversationMeta {
    pub title: String,
    pub project_name: String,
    pub project_path: String,
    #[allow(dead_code)]
    pub status: String,
    pub parent_id: String,
    pub agent_name: String,
}

#[derive(Debug, Clone)]
pub(super) struct SpawnedSubagentMeta {
    pub id: String,
    pub name: String,
    pub role: String,
    pub prompt: String,
    pub step_index: usize,
    pub status: String,
    pub last_action: String,
    pub tool_name: String,
}

#[derive(Debug, Clone)]
pub(super) struct ParsedTranscript {
    pub id: String,
    pub title: String,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub status: String,
    pub current_phase: String,
    pub steps: Vec<AgentStep>,
    pub files_touched: Vec<FileTouchRecord>,
    pub commands_run: Vec<CommandExecutionRecord>,
    pub spawned_subagents: Vec<SpawnedSubagentMeta>,
    pub total_input_tokens: u64,
    pub total_output_tokens: u64,
    pub total_cache_tokens: u64,
    pub project_name: String,
    pub project_path: String,
    pub total_steps: usize,
}
