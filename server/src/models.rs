use serde::{Deserialize, Serialize};
use std::collections::HashMap;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectWorkspace {
    pub id: String,
    pub name: String,
    pub path: String,
    pub session_count: usize,
    pub running_count: usize,
    pub last_active_at: Option<String>,
    #[serde(default)]
    pub git_sync_status: Option<GitSyncStatus>,
    #[serde(default)]
    pub custom_agents: Vec<CustomAgentSpec>,
    #[serde(default)]
    pub available_agents: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatTurnStreamState {
    pub conversation_id: String,
    pub project_path: String,
    pub user_prompt: String,
    pub streaming_text: String,
    pub is_running: bool,
    pub active_step_type: String,
    pub started_at: String,
    pub error: String,
    #[serde(default)]
    pub thinking_text: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ToolCallInfo {
    pub name: String,
    pub args: HashMap<String, serde_json::Value>,
    pub summary_label: String,
    pub target_path: Option<String>,
    pub repo_tag: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentStep {
    pub step_index: usize,
    pub source: String,
    #[serde(rename = "type")]
    pub step_type: String,
    pub status: String,
    pub created_at: String,
    pub content: String,
    pub thinking: String,
    pub tool_calls: Vec<ToolCallInfo>,
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cache_read_tokens: u64,
    pub agent_name: String,
    pub phase: String,
    pub vietnamese_title: String,
    pub vietnamese_detail: String,
    /// Model thực tế đã trả lời (vd. `claude-haiku-5-5`), rỗng nếu không xác định
    #[serde(default)]
    pub model: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SubagentLane {
    pub id: String,
    pub name: String,
    pub role: String,
    pub target_repo: String,
    pub status: String,
    pub current_phase: String,
    pub current_step_index: usize,
    pub current_action_text: String,
    pub current_tool_name: String,
    pub prompt_brief: String,
    pub steps: Vec<AgentStep>,
    pub progress: f64,
    pub files_modified: Vec<String>,
    pub last_updated: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FileTouchRecord {
    pub path: String,
    pub action: String,
    pub repo: String,
    pub agent_name: String,
    pub step_index: usize,
    pub timestamp: String,
    #[serde(default)]
    pub added_lines: usize,
    #[serde(default)]
    pub removed_lines: usize,
    #[serde(default)]
    pub diff_preview: String,
    /// Nguồn ghi nhận: `bash` khi suy ra từ lệnh Bash, rỗng khi từ tool Edit/Write
    #[serde(default)]
    pub source: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CommandExecutionRecord {
    pub command_line: String,
    pub summary: String,
    pub agent_name: String,
    pub step_index: usize,
    pub timestamp: String,
    pub output_preview: String,
    pub is_success: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CustomAgentSpec {
    pub name: String,
    pub description: String,
    pub kind: String,
    pub file_path: String,
    pub body_content: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConversationSession {
    pub id: String,
    pub title: String,
    pub created_at: String,
    pub updated_at: String,
    pub status: String,
    pub current_phase: String,
    pub steps: Vec<AgentStep>,
    pub subagent_lanes: Vec<SubagentLane>,
    pub files_touched: Vec<FileTouchRecord>,
    pub commands_run: Vec<CommandExecutionRecord>,
    pub total_input_tokens: u64,
    pub total_output_tokens: u64,
    pub total_cache_tokens: u64,
    pub project_name: String,
    pub project_path: String,
    pub is_simulated: bool,
    #[serde(default)]
    pub pending_plans: Vec<PlanArtifactInfo>,
    #[serde(default)]
    pub git_sync_status: Option<GitSyncStatus>,
    #[serde(default)]
    pub is_interrupted: bool,
    #[serde(default)]
    pub interrupted_reason: Option<String>,
    #[serde(default)]
    pub custom_agents: Vec<CustomAgentSpec>,
    #[serde(default)]
    pub available_agents: Vec<String>,
    #[serde(default)]
    pub has_parallel_flow: bool,
    #[serde(default = "default_source")]
    pub source: String,
    /// Số token context đang dùng ở lượt gọi model gần nhất (0 nếu chưa rõ)
    #[serde(default)]
    pub context_tokens: u64,
    /// Model id (có tiền tố provider) đã tạo ra lượt gần nhất, dùng để tra giới hạn context
    #[serde(default)]
    pub context_model: String,
}

fn default_source() -> String {
    "agy".to_string()
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlanArtifactInfo {
    pub file_name: String,
    pub file_path: String,
    pub title: String,
    pub summary: String,
    pub updated_at: String,
    pub request_feedback: bool,
    pub content: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlanActionRequest {
    pub conversation_id: String,
    pub file_name: String,
    pub action: String,
    #[serde(default)]
    pub feedback: String,
    #[serde(default)]
    pub model: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelQuotaBucket {
    pub bucket_id: String,
    pub display_name: String,
    #[serde(default)]
    pub description: String,
    pub window: String,
    pub remaining_fraction: f64,
    pub remaining_percent: f64,
    #[serde(default)]
    pub reset_time: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelQuotaGroup {
    pub display_name: String,
    #[serde(default)]
    pub description: String,
    pub buckets: Vec<ModelQuotaBucket>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentMonitorSnapshot {
    pub sessions: Vec<ConversationSession>,
    pub custom_agents: Vec<CustomAgentSpec>,
    pub projects: Vec<ProjectWorkspace>,
    pub available_models: Vec<String>,
    pub available_agents: Vec<String>,
    pub active_streams: HashMap<String, ChatTurnStreamState>,
    #[serde(default)]
    pub model_quotas: Vec<ModelQuotaGroup>,
    /// Nhãn hiển thị theo id model (ví dụ `agy:gemini-4-argon-medium` → `Gemini 4 Argon (Medium)`)
    #[serde(default)]
    pub model_labels: HashMap<String, String>,
    /// Giới hạn context theo model id (ví dụ `agy:gemini-4-argon-medium` → 256000)
    #[serde(default)]
    pub model_context_limits: HashMap<String, u64>,
    pub hostname: String,
    pub lan_ips: Vec<String>,
    pub port: u16,
    pub timestamp: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatSendRequest {
    #[serde(default)]
    pub prompt: String,
    #[serde(default)]
    pub project_path: String,
    #[serde(default)]
    pub conversation_id: String,
    #[serde(default)]
    pub agent_name: String,
    #[serde(default)]
    pub model: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatSendResponse {
    pub ok: bool,
    pub conversation_id: String,
    pub project_path: String,
    pub error: String,
    /// Nguồn provider đã xử lý lượt chat: `claude-cli` hoặc `agy`
    #[serde(default)]
    pub source: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatStopRequest {
    #[serde(default)]
    pub conversation_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConversationModelRequest {
    #[serde(default)]
    pub conversation_id: String,
    #[serde(default)]
    pub model: String,
}

/// Sửa tay giới hạn context của một model (id có tiền tố provider)
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelContextLimitRequest {
    #[serde(default)]
    pub model: String,
    #[serde(default)]
    pub limit: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ServerFileEntry {
    pub name: String,
    pub path: String,
    pub is_dir: bool,
    pub size: u64,
    pub modified_at: String,
    #[serde(default)]
    pub permissions: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ServerDirListResponse {
    pub ok: bool,
    pub current_path: String,
    pub parent_path: String,
    pub entries: Vec<ServerFileEntry>,
    pub error: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ServerFileReadResponse {
    pub ok: bool,
    pub path: String,
    pub name: String,
    pub size: u64,
    pub is_binary: bool,
    #[serde(default)]
    pub is_image: bool,
    pub content: String,
    pub git_diff: String,
    pub error: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionStepsPageResponse {
    pub session_id: String,
    pub steps: Vec<AgentStep>,
    pub has_more: bool,
    pub earliest_step_index: usize,
    pub total_steps: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CreateProjectRequest {
    pub name: String,
    #[serde(default = "default_project_template")]
    pub template: String,
    #[serde(default)]
    pub description: String,
}

fn default_project_template() -> String {
    "standard".to_string()
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CreateProjectResponse {
    pub ok: bool,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub project: Option<ProjectWorkspace>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GitSyncStatus {
    pub project_path: String,
    pub project_name: String,
    pub branch: String,
    pub ahead_count: usize,
    pub last_commit_hash: String,
    pub last_commit_message: String,
    pub last_commit_author: String,
    pub last_commit_at: String,
    pub is_ahead: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GitPushRequest {
    pub project_path: String,
    #[serde(default)]
    pub branch: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GitPushResponse {
    pub ok: bool,
    pub message: String,
    #[serde(default)]
    pub output: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectAgentsResponse {
    pub ok: bool,
    pub project_path: String,
    pub project_name: String,
    pub available_agents: Vec<String>,
    pub custom_agents: Vec<CustomAgentSpec>,
    pub skills: Vec<CustomAgentSpec>,
    pub rules: Vec<CustomAgentSpec>,
    #[serde(default)]
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClaudeExtensionsResponse {
    pub ok: bool,
    pub items: Vec<CustomAgentSpec>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GitCommitSummary {
    pub hash: String,
    pub short_hash: String,
    pub author_name: String,
    pub author_email: String,
    pub committed_at: String,
    pub relative_time: String,
    pub subject: String,
    pub body: String,
    pub parent_hashes: Vec<String>,
    pub refs: Vec<String>,
    pub is_head: bool,
    pub files_count: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GitHistoryResponse {
    pub ok: bool,
    pub project_path: String,
    pub project_name: String,
    pub current_branch: String,
    pub branches: Vec<String>,
    pub total_commits: usize,
    pub commits: Vec<GitCommitSummary>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GitCommitFileChange {
    pub path: String,
    pub status: String,
    pub additions: usize,
    pub deletions: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GitCommitDetailResponse {
    pub ok: bool,
    pub project_path: String,
    pub hash: String,
    pub short_hash: String,
    pub author_name: String,
    pub author_email: String,
    pub committed_at: String,
    pub relative_time: String,
    pub subject: String,
    pub body: String,
    pub parent_hashes: Vec<String>,
    pub refs: Vec<String>,
    pub files: Vec<GitCommitFileChange>,
    pub diff: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AIQuestion {
    pub id: String,
    pub conversation_id: String,
    pub step_index: usize,
    pub question: String,
    pub created_at: String,
    pub answered_at: Option<String>,
    pub answer: Option<String>,
    pub is_pending: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AIQuestionResponse {
    pub question_id: String,
    pub answer: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AIQuestionsResponse {
    pub ok: bool,
    pub conversation_id: String,
    pub questions: Vec<AIQuestion>,
    #[serde(default)]
    pub error: Option<String>,
}
