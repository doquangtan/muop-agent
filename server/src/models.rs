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
    /// Model đã chọn kèm mức của conversation (vd. `claude-cli:claude-haiku-5-5-high`), lấy từ lượt gửi gần nhất.
    /// Rỗng nếu chưa ghi nhận (conversation cũ trước khi có tính năng này).
    #[serde(default)]
    pub selected_model: String,
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

/// Lượt chat đang chờ tự gửi lại sau khi bị rate limit (phát qua event `retry:update`)
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PendingRetryDto {
    pub conversation_id: String,
    pub provider: String,
    /// Thông điệp lỗi gốc từ CLI
    pub reason: String,
    /// Thời điểm sẽ gửi lại (RFC3339, UTC)
    pub retry_at: String,
    /// Lần gửi lại thứ mấy (1 = lần đầu tự thử lại)
    pub attempt: u32,
    pub max_attempts: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CancelRetryRequest {
    #[serde(default)]
    pub conversation_id: String,
}

/// Máy SSH gửi xuống client. Không chứa mật khẩu hay private key, chỉ cho biết đã có hay chưa.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SshHostDto {
    pub id: i64,
    pub name: String,
    pub host: String,
    pub port: u16,
    pub username: String,
    /// `password` hoặc `key`
    pub auth_type: String,
    pub has_password: bool,
    pub has_key: bool,
}

/// Thêm/sửa máy SSH. Để trống `password` hoặc `privateKey` khi sửa nghĩa là giữ nguyên giá trị đã lưu.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SshHostSaveRequest {
    #[serde(default)]
    pub id: i64,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub host: String,
    #[serde(default = "default_ssh_port")]
    pub port: u16,
    #[serde(default)]
    pub username: String,
    #[serde(default = "default_auth_type")]
    pub auth_type: String,
    #[serde(default)]
    pub password: String,
    #[serde(default)]
    pub private_key: String,
}

fn default_ssh_port() -> u16 {
    22
}

fn default_auth_type() -> String {
    "password".to_string()
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SshHostIdRequest {
    #[serde(default)]
    pub id: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SshExecRequest {
    #[serde(default)]
    pub host_id: i64,
    #[serde(default)]
    pub command: String,
    #[serde(default = "default_exec_timeout")]
    pub timeout_secs: u64,
}

fn default_exec_timeout() -> u64 {
    30
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SshExecResponse {
    pub ok: bool,
    pub exit_code: Option<i32>,
    pub stdout: String,
    pub stderr: String,
    pub error: String,
}

/// Mở phiên terminal SSH tương tác trên máy đã lưu
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SshTerminalOpenRequest {
    #[serde(default)]
    pub host_id: i64,
    #[serde(default = "default_term_cols")]
    pub cols: u16,
    #[serde(default = "default_term_rows")]
    pub rows: u16,
}

fn default_term_cols() -> u16 {
    100
}

fn default_term_rows() -> u16 {
    30
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SshTerminalInputRequest {
    #[serde(default)]
    pub session_id: String,
    /// Dữ liệu bàn phím, mã hóa base64
    #[serde(default)]
    pub data: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SshTerminalResizeRequest {
    #[serde(default)]
    pub session_id: String,
    #[serde(default = "default_term_cols")]
    pub cols: u16,
    #[serde(default = "default_term_rows")]
    pub rows: u16,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SshTerminalSessionRequest {
    #[serde(default)]
    pub session_id: String,
}

/// Kết quả gắn lại phiên terminal: đầu ra đã đệm (base64) để vẽ lại màn hình
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SshTerminalAttachResponse {
    pub ok: bool,
    pub session_id: String,
    pub host_name: String,
    pub buffer: String,
    pub error: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SshTerminalOpenResponse {
    pub ok: bool,
    pub session_id: String,
    pub error: String,
}

/// Container Docker đang chạy trên máy SSH
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DockerContainerDto {
    pub id: String,
    pub name: String,
    pub image: String,
    pub state: String,
    pub status: String,
    pub ports: String,
    /// Tên compose project (label `com.docker.compose.project`), rỗng nếu không thuộc compose
    pub project: String,
    /// Tên service compose (label `com.docker.compose.service`)
    pub service: String,
    pub created: String,
}

/// Phiên Docker: một kết nối SSH giữ sẵn tới máy, kèm kết quả quét gần nhất
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DockerSessionDto {
    pub session_id: String,
    pub host_id: i64,
    pub host_name: String,
    pub started_at: String,
    /// Kết nối SSH còn sống (lần kiểm tra gần nhất)
    pub connected: bool,
    pub scanned_at: String,
    /// Lỗi của lần kiểm tra/quét gần nhất (rỗng = ổn)
    pub error: String,
    pub containers: Vec<DockerContainerDto>,
}

/// Kết quả chung của các API Docker. `session` = trạng thái sau khi thực hiện thao tác.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DockerSessionResponse {
    pub ok: bool,
    pub error: String,
    pub session: Option<DockerSessionDto>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DockerOpenRequest {
    #[serde(default)]
    pub host_id: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DockerSessionIdRequest {
    #[serde(default)]
    pub session_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DockerActionRequest {
    #[serde(default)]
    pub session_id: String,
    /// `stop` hoặc `restart`
    #[serde(default)]
    pub action: String,
    #[serde(default)]
    pub container_ids: Vec<String>,
}

/// Mở luồng log của một container trong phiên Docker
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DockerLogsOpenRequest {
    #[serde(default)]
    pub session_id: String,
    #[serde(default)]
    pub container_id: String,
    #[serde(default = "default_log_tail")]
    pub tail: u32,
}

fn default_log_tail() -> u32 {
    300
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DockerLogsOpenResponse {
    pub ok: bool,
    pub stream_id: String,
    pub error: String,
}

/// Ping, dừng một luồng log
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DockerLogsStreamRequest {
    #[serde(default)]
    pub stream_id: String,
}

/// Đặt đường dẫn LSP cho một ngôn ngữ. `path` rỗng = xóa cấu hình, dùng lại đường dẫn tự dò.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LspSettingRequest {
    #[serde(default)]
    pub language: String,
    #[serde(default)]
    pub path: String,
}

/// Định nghĩa của ký hiệu tại vị trí con trỏ (dòng, cột đếm từ 0)
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CodeDefinitionRequest {
    #[serde(default)]
    pub path: String,
    #[serde(default)]
    pub line: u32,
    #[serde(default)]
    pub character: u32,
}

/// Thông tin tóm tắt một conversation (không kèm steps, lanes, files): dùng cho `sessions:list`
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionSummary {
    pub id: String,
    pub title: String,
    pub created_at: String,
    pub updated_at: String,
    pub status: String,
    pub current_phase: String,
    pub project_name: String,
    pub project_path: String,
    pub source: String,
    pub context_tokens: u64,
    pub context_model: String,
    /// Model kèm mức đã chọn của conversation (xem `ConversationSession::selected_model`)
    #[serde(default)]
    pub selected_model: String,
    pub is_running: bool,
    pub is_interrupted: bool,
    pub files_count: usize,
    pub pending_plans: Vec<PlanArtifactInfo>,
}

/// Metadata dùng chung (project, model, máy chủ): `meta:update`
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MetaPayload {
    pub projects: Vec<ProjectWorkspace>,
    pub available_models: Vec<String>,
    /// Các mức suy nghĩ (effort) CLI hỗ trợ, đọc từ `claude --help`; rỗng nếu không đọc được
    pub effort_levels: Vec<String>,
    pub model_labels: HashMap<String, String>,
    pub model_context_limits: HashMap<String, u64>,
    pub hostname: String,
    pub lan_ips: Vec<String>,
    pub port: u16,
    pub timestamp: String,
}
