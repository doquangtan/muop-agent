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

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
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

/// Bước cuối của transcript: đủ để xác định trạng thái và việc agy có bị cắt không
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub(super) struct LastStepMeta {
    pub step_type: String,
    pub status: String,
    pub has_tool_calls: bool,
}

/// Metadata của một transcript agy, lưu trong SQLite (bảng `transcript_meta`). Không chứa các bước hội
/// thoại: chúng nằm trong transcript gốc và chỉ được nạp khi cần.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub(super) struct TranscriptMeta {
    /// Tiêu đề lấy từ prompt đầu tiên (chưa gộp với tiêu đề trong DB)
    pub first_prompt_title: String,
    pub created_at: String,
    pub updated_at: String,
    pub last_step: Option<LastStepMeta>,
    pub has_verify: bool,
    pub has_edit_or_parallel: bool,
    pub spawned_subagents: Vec<SpawnedSubagentMeta>,
    pub turn_spawn_start: usize,
    pub total_input_tokens: u64,
    pub total_output_tokens: u64,
    pub total_cache_tokens: u64,
    pub total_steps: usize,
    /// Repo đầu tiên trong danh sách tệp đã sửa (dùng khi conversation không có project)
    pub fallback_repo: String,
    /// Id conversation con xuất hiện trong các dòng spawn/invoke (dùng để nhận diện subagent)
    pub referenced_ids: Vec<String>,
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
    /// Chỉ số đầu tiên trong `spawned_subagents` thuộc lượt hiện tại; các lượt trước chỉ là lịch sử
    pub turn_spawn_start: usize,
    pub total_input_tokens: u64,
    pub total_output_tokens: u64,
    pub total_cache_tokens: u64,
    pub project_name: String,
    pub project_path: String,
    pub total_steps: usize,
    /// Loại bước cuối (dùng để nhận diện lượt bị cắt); None khi không có bước nào
    pub last_step_type: Option<String>,
    /// Id conversation con được nhắc trong transcript (xem `TranscriptMeta::referenced_ids`)
    pub referenced_ids: Vec<String>,
}
