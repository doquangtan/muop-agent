//! DTO đọc từ `muop-agent-server`. App giữ DTO riêng, không dùng chung crate với server.
//!
//! Khóa JSON là camelCase. Mọi trường có `#[serde(deserialize_with = "nullable")]`:
//! server có thể trả `null` ở bất kỳ trường nào, và `null` rơi về giá trị mặc định.

use std::collections::HashMap;

use serde::{Deserialize, Deserializer, Serialize};

fn nullable<'de, D, T>(deserializer: D) -> Result<T, D::Error>
where
    D: Deserializer<'de>,
    T: Deserialize<'de> + Default,
{
    Option::<T>::deserialize(deserializer).map(Option::unwrap_or_default)
}

/// Một phần tử của `sessions:list` / `GET /api/sessions`.
#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct SessionSummary {
    #[serde(deserialize_with = "nullable")]
    pub id: String,
    #[serde(deserialize_with = "nullable")]
    pub title: String,
    #[serde(deserialize_with = "nullable")]
    pub project_name: String,
    #[serde(deserialize_with = "nullable")]
    pub project_path: String,
    #[serde(deserialize_with = "nullable")]
    pub status: String,
    #[serde(deserialize_with = "nullable")]
    pub current_phase: String,
    #[serde(deserialize_with = "nullable")]
    pub source: String,
    #[serde(deserialize_with = "nullable")]
    pub selected_model: String,
    #[serde(deserialize_with = "nullable")]
    pub is_running: bool,
    #[serde(deserialize_with = "nullable")]
    pub is_interrupted: bool,
    #[serde(deserialize_with = "nullable")]
    pub created_at: String,
    #[serde(deserialize_with = "nullable")]
    pub updated_at: String,
    #[serde(deserialize_with = "nullable")]
    pub context_tokens: u64,
    #[serde(deserialize_with = "nullable")]
    pub files_count: u64,
}

impl SessionSummary {
    /// Tóm tắt từ conversation đầy đủ (dùng khi `session:update` đổi tiêu đề/trạng thái).
    pub fn from_session(s: &ConversationSession) -> Self {
        Self {
            id: s.id.clone(),
            title: s.title.clone(),
            project_name: s.project_name.clone(),
            project_path: s.project_path.clone(),
            status: s.status.clone(),
            current_phase: s.current_phase.clone(),
            source: s.source.clone(),
            selected_model: s.selected_model.clone(),
            is_running: s.status == "running",
            is_interrupted: s.is_interrupted,
            created_at: s.created_at.clone(),
            updated_at: s.updated_at.clone(),
            context_tokens: s.context_tokens,
            files_count: s.files_count,
        }
    }
}

/// Một bước của conversation. Trường `type` được đổi tên thành `kind`.
#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct AgentStep {
    #[serde(deserialize_with = "nullable")]
    pub step_index: u64,
    #[serde(rename = "type", deserialize_with = "nullable")]
    pub kind: String,
    #[serde(deserialize_with = "nullable")]
    pub source: String,
    #[serde(deserialize_with = "nullable")]
    pub status: String,
    #[serde(deserialize_with = "nullable")]
    pub agent_name: String,
    #[serde(deserialize_with = "nullable")]
    pub model: String,
    #[serde(deserialize_with = "nullable")]
    pub content: String,
    #[serde(deserialize_with = "nullable")]
    pub vietnamese_title: String,
    #[serde(deserialize_with = "nullable")]
    pub created_at: String,
    #[serde(deserialize_with = "nullable")]
    pub input_tokens: u64,
    #[serde(deserialize_with = "nullable")]
    pub output_tokens: u64,
    #[serde(deserialize_with = "nullable")]
    pub tool_calls: Vec<ToolCall>,
    #[serde(deserialize_with = "nullable")]
    pub image_count: u64,
    /// Đường dẫn tương đối (`/api/chat/attachment?...`), chỉ có với `USER_INPUT`
    #[serde(deserialize_with = "nullable")]
    pub image_urls: Vec<String>,
}

/// Một lệnh gọi tool trong một bước của agent.
#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ToolCall {
    #[serde(deserialize_with = "nullable")]
    pub name: String,
    #[serde(deserialize_with = "nullable")]
    pub summary_label: String,
    #[serde(deserialize_with = "nullable")]
    pub target_path: String,
    #[serde(deserialize_with = "nullable")]
    pub args: serde_json::Value,
}

/// Một tệp đã đọc hoặc sửa trong conversation (`filesTouched`).
#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct FileTouched {
    #[serde(deserialize_with = "nullable")]
    pub path: String,
    #[serde(deserialize_with = "nullable")]
    pub action: String,
    #[serde(deserialize_with = "nullable")]
    pub added_lines: u64,
    #[serde(deserialize_with = "nullable")]
    pub removed_lines: u64,
    #[serde(deserialize_with = "nullable")]
    pub agent_name: String,
    #[serde(deserialize_with = "nullable")]
    pub step_index: u64,
    #[serde(deserialize_with = "nullable")]
    pub repo: String,
}

/// `session` đầy đủ (`GET /api/session`, `session:update`).
#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ConversationSession {
    #[serde(deserialize_with = "nullable")]
    pub id: String,
    #[serde(deserialize_with = "nullable")]
    pub title: String,
    #[serde(deserialize_with = "nullable")]
    pub status: String,
    #[serde(deserialize_with = "nullable")]
    pub current_phase: String,
    #[serde(deserialize_with = "nullable")]
    pub project_name: String,
    #[serde(deserialize_with = "nullable")]
    pub project_path: String,
    #[serde(deserialize_with = "nullable")]
    pub source: String,
    #[serde(deserialize_with = "nullable")]
    pub selected_model: String,
    #[serde(deserialize_with = "nullable")]
    pub is_interrupted: bool,
    #[serde(deserialize_with = "nullable")]
    pub interrupted_reason: String,
    #[serde(deserialize_with = "nullable")]
    pub created_at: String,
    #[serde(deserialize_with = "nullable")]
    pub updated_at: String,
    #[serde(deserialize_with = "nullable")]
    pub context_tokens: u64,
    #[serde(deserialize_with = "nullable")]
    pub files_count: u64,
    #[serde(deserialize_with = "nullable")]
    pub context_model: String,
    #[serde(deserialize_with = "nullable")]
    pub total_input_tokens: u64,
    #[serde(deserialize_with = "nullable")]
    pub total_output_tokens: u64,
    #[serde(deserialize_with = "nullable")]
    pub steps: Vec<AgentStep>,
    #[serde(deserialize_with = "nullable")]
    pub pending_plans: Vec<PendingPlan>,
    #[serde(deserialize_with = "nullable")]
    pub files_touched: Vec<FileTouched>,
}

/// Kế hoạch đang chờ duyệt (`pendingPlans` của conversation).
#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct PendingPlan {
    #[serde(deserialize_with = "nullable")]
    pub file_name: String,
    #[serde(deserialize_with = "nullable")]
    pub title: String,
    #[serde(deserialize_with = "nullable")]
    pub summary: String,
    #[serde(deserialize_with = "nullable")]
    pub request_feedback: bool,
    #[serde(deserialize_with = "nullable")]
    pub content: String,
}

#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct QuotaBucket {
    #[serde(deserialize_with = "nullable")]
    pub display_name: String,
    #[serde(deserialize_with = "nullable")]
    pub description: String,
    #[serde(deserialize_with = "nullable")]
    pub window: String,
    #[serde(deserialize_with = "nullable")]
    pub remaining_percent: f64,
    #[serde(deserialize_with = "nullable")]
    pub reset_time: String,
}

#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct QuotaGroup {
    #[serde(deserialize_with = "nullable")]
    pub display_name: String,
    #[serde(deserialize_with = "nullable")]
    pub buckets: Vec<QuotaBucket>,
}

/// `QuotaReport` của một provider. `error` ghi lý do khi không có số liệu.
#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct QuotaReport {
    #[serde(deserialize_with = "nullable")]
    pub provider: String,
    #[serde(deserialize_with = "nullable")]
    pub groups: Vec<QuotaGroup>,
    #[serde(deserialize_with = "nullable")]
    pub error: String,
}

/// `GET /api/quota` và `quotas:update` (sau khi tải lại).
#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct QuotaSnapshot {
    #[serde(deserialize_with = "nullable")]
    pub agy: QuotaReport,
    #[serde(deserialize_with = "nullable")]
    pub claude: QuotaReport,
}

impl QuotaSnapshot {
    /// Báo cáo của provider: `agy` hoặc `claude`.
    pub fn report(&self, provider: &str) -> Option<&QuotaReport> {
        match provider {
            "agy" => Some(&self.agy),
            "claude" => Some(&self.claude),
            _ => None,
        }
    }
}

/// Một trang lịch sử (`GET /api/session/steps`), bước sắp theo thứ tự tăng dần.
#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct StepsPage {
    #[serde(deserialize_with = "nullable")]
    pub steps: Vec<AgentStep>,
    #[serde(deserialize_with = "nullable")]
    pub has_more: bool,
    #[serde(deserialize_with = "nullable")]
    pub earliest_step_index: u64,
    #[serde(deserialize_with = "nullable")]
    pub total_steps: u64,
}

/// Một mục trong thư mục của máy server (`/api/sftp/list`).
#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct FsEntry {
    #[serde(deserialize_with = "nullable")]
    pub name: String,
    #[serde(deserialize_with = "nullable")]
    pub path: String,
    #[serde(deserialize_with = "nullable")]
    pub is_dir: bool,
    #[serde(deserialize_with = "nullable")]
    pub size: u64,
}

#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct SftpSession {
    #[serde(deserialize_with = "nullable")]
    pub session_id: String,
    #[serde(deserialize_with = "nullable")]
    pub home: String,
}

/// `POST /api/sftp/local`.
#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct SftpOpenResponse {
    #[serde(deserialize_with = "nullable")]
    pub ok: bool,
    #[serde(deserialize_with = "nullable")]
    pub error: String,
    #[serde(deserialize_with = "nullable")]
    pub session: SftpSession,
}

/// `POST /api/sftp/list`.
#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct SftpListResponse {
    #[serde(deserialize_with = "nullable")]
    pub ok: bool,
    #[serde(deserialize_with = "nullable")]
    pub error: String,
    #[serde(deserialize_with = "nullable")]
    pub session_gone: bool,
    #[serde(deserialize_with = "nullable")]
    pub entries: Vec<FsEntry>,
}

/// `POST /api/sftp/read`.
#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct SftpReadResponse {
    #[serde(deserialize_with = "nullable")]
    pub ok: bool,
    #[serde(deserialize_with = "nullable")]
    pub error: String,
    #[serde(deserialize_with = "nullable")]
    pub session_gone: bool,
    #[serde(deserialize_with = "nullable")]
    pub content: String,
    #[serde(deserialize_with = "nullable")]
    pub binary: bool,
    #[serde(deserialize_with = "nullable")]
    pub size: u64,
}

/// `GET /api/git/status?projectPath=`: đường dẫn tuyệt đối → loại thay đổi (`modified`, `created`, ...).
#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct GitStatusResponse {
    #[serde(deserialize_with = "nullable")]
    pub ok: bool,
    #[serde(deserialize_with = "nullable")]
    pub is_repo: bool,
    #[serde(deserialize_with = "nullable")]
    pub kinds: HashMap<String, String>,
    #[serde(deserialize_with = "nullable")]
    pub error: String,
}

/// `GET /api/agy/auth/status`.
#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct AgyAuthStatus {
    #[serde(deserialize_with = "nullable")]
    pub logged_in: bool,
    #[serde(deserialize_with = "nullable")]
    pub phase: String,
}

/// `GET /api/claude/auth/status`.
#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ClaudeAuthStatus {
    #[serde(deserialize_with = "nullable")]
    pub logged_in: bool,
    #[serde(deserialize_with = "nullable")]
    pub email: String,
    #[serde(deserialize_with = "nullable")]
    pub subscription_type: String,
}

/// Máy trong danh sách SSH (`GET /api/ssh/hosts`). Không có bí mật, chỉ có cờ `has_password` / `has_key`.
#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct SshHost {
    #[serde(deserialize_with = "nullable")]
    pub id: u64,
    #[serde(deserialize_with = "nullable")]
    pub name: String,
    #[serde(deserialize_with = "nullable")]
    pub host: String,
    #[serde(deserialize_with = "nullable")]
    pub port: u16,
    #[serde(deserialize_with = "nullable")]
    pub username: String,
    /// `password` hoặc `key`
    #[serde(deserialize_with = "nullable")]
    pub auth_type: String,
    #[serde(deserialize_with = "nullable")]
    pub has_password: bool,
    #[serde(deserialize_with = "nullable")]
    pub has_key: bool,
    /// Mục mặc định "Máy này": không sửa, không xóa
    #[serde(deserialize_with = "nullable")]
    pub builtin: bool,
}

/// Body của `POST /api/ssh/hosts/save`. Để trống `password` / `private_key` khi sửa nghĩa là giữ giá trị đã lưu.
#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SshHostSave {
    pub id: u64,
    pub name: String,
    pub host: String,
    pub port: u16,
    pub username: String,
    pub auth_type: String,
    pub password: String,
    pub private_key: String,
}

/// Phản hồi của `save` và `delete` máy SSH.
#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct SshWriteResponse {
    #[serde(deserialize_with = "nullable")]
    pub ok: bool,
    #[serde(deserialize_with = "nullable")]
    pub id: u64,
    #[serde(deserialize_with = "nullable")]
    pub error: String,
}

/// Body của `POST /api/ssh/exec`.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SshExecRequest {
    pub host_id: u64,
    pub command: String,
    pub timeout_secs: u64,
    /// Mật khẩu người dùng vừa nhập khi server báo `needsPassword`. Rỗng = dùng mật khẩu đã lưu.
    pub password: String,
    pub save_password: bool,
}

/// Kết quả chạy lệnh trên máy SSH (`POST /api/ssh/exec`).
#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct SshExecResponse {
    #[serde(deserialize_with = "nullable")]
    pub ok: bool,
    #[serde(deserialize_with = "nullable")]
    pub exit_code: Option<i32>,
    #[serde(deserialize_with = "nullable")]
    pub stdout: String,
    #[serde(deserialize_with = "nullable")]
    pub stderr: String,
    #[serde(deserialize_with = "nullable")]
    pub error: String,
    /// Server cần mật khẩu (chưa có hoặc sai): hỏi người dùng rồi chạy lại
    #[serde(deserialize_with = "nullable")]
    pub needs_password: bool,
    /// `ssh` hoặc `sudo`, để hỏi đúng loại mật khẩu
    #[serde(deserialize_with = "nullable")]
    pub password_kind: String,
}

/// Một container trong phiên Docker.
#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct DockerContainer {
    #[serde(deserialize_with = "nullable")]
    pub id: String,
    #[serde(deserialize_with = "nullable")]
    pub name: String,
    #[serde(deserialize_with = "nullable")]
    pub image: String,
    #[serde(deserialize_with = "nullable")]
    pub state: String,
    #[serde(deserialize_with = "nullable")]
    pub status: String,
    #[serde(deserialize_with = "nullable")]
    pub project: String,
    #[serde(deserialize_with = "nullable")]
    pub service: String,
}

/// Phiên Docker của một máy (`session` trong phản hồi `/api/docker/sessions/*`).
#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct DockerSession {
    #[serde(deserialize_with = "nullable")]
    pub session_id: String,
    #[serde(deserialize_with = "nullable")]
    pub host_id: u64,
    #[serde(deserialize_with = "nullable")]
    pub host_name: String,
    #[serde(deserialize_with = "nullable")]
    pub connected: bool,
    #[serde(deserialize_with = "nullable")]
    pub error: String,
    #[serde(deserialize_with = "nullable")]
    pub containers: Vec<DockerContainer>,
}

/// Phản hồi chung của các endpoint Docker: `{ok, error, session}`.
#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct DockerResponse {
    #[serde(deserialize_with = "nullable")]
    pub ok: bool,
    #[serde(deserialize_with = "nullable")]
    pub error: String,
    #[serde(deserialize_with = "nullable")]
    pub session: Option<DockerSession>,
}

/// Một commit trong lịch sử git (`GitCommitSummary`).
#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct GitCommit {
    #[serde(deserialize_with = "nullable")]
    pub short_hash: String,
    #[serde(deserialize_with = "nullable")]
    pub subject: String,
    #[serde(deserialize_with = "nullable")]
    pub author_name: String,
    #[serde(deserialize_with = "nullable")]
    pub relative_time: String,
    #[serde(deserialize_with = "nullable")]
    pub refs: Vec<String>,
    #[serde(deserialize_with = "nullable")]
    pub is_head: bool,
}

/// `GET /api/git/history`. Server đọc `project_path` trong query (tài liệu ghi `projectPath`).
#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct GitHistoryResponse {
    #[serde(deserialize_with = "nullable")]
    pub ok: bool,
    #[serde(deserialize_with = "nullable")]
    pub error: String,
    #[serde(deserialize_with = "nullable")]
    pub current_branch: String,
    #[serde(deserialize_with = "nullable")]
    pub total_commits: u64,
    #[serde(deserialize_with = "nullable")]
    pub commits: Vec<GitCommit>,
}

/// Lịch tự gửi lại sau rate limit (`retry:update`, mảng).
#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct PendingRetry {
    #[serde(deserialize_with = "nullable")]
    pub conversation_id: String,
    #[serde(deserialize_with = "nullable")]
    pub provider: String,
    #[serde(deserialize_with = "nullable")]
    pub reason: String,
    #[serde(deserialize_with = "nullable")]
    pub retry_at: String,
    #[serde(deserialize_with = "nullable")]
    pub attempt: u64,
    #[serde(deserialize_with = "nullable")]
    pub max_attempts: u64,
    #[serde(deserialize_with = "nullable")]
    pub wait_source: String,
    #[serde(deserialize_with = "nullable")]
    pub wait_detail: String,
    #[serde(deserialize_with = "nullable")]
    pub reset_at: String,
}

/// Lựa chọn của một câu hỏi `AskUserQuestion`.
#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ClaudeOption {
    #[serde(deserialize_with = "nullable")]
    pub label: String,
    #[serde(deserialize_with = "nullable")]
    pub description: String,
}

#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ClaudeQuestion {
    #[serde(deserialize_with = "nullable")]
    pub question: String,
    #[serde(deserialize_with = "nullable")]
    pub header: String,
    #[serde(deserialize_with = "nullable")]
    pub multi_select: bool,
    #[serde(deserialize_with = "nullable")]
    pub options: Vec<ClaudeOption>,
}

/// Tương tác đang chờ người dùng: câu hỏi (`question`) hoặc kế hoạch cần duyệt (`plan`).
#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ClaudePending {
    #[serde(deserialize_with = "nullable")]
    pub conversation_id: String,
    #[serde(deserialize_with = "nullable")]
    pub tool_use_id: String,
    #[serde(deserialize_with = "nullable")]
    pub kind: String,
    #[serde(deserialize_with = "nullable")]
    pub questions: Vec<ClaudeQuestion>,
    #[serde(deserialize_with = "nullable")]
    pub plan: String,
}

/// `GET /api/claude/pending`: `pending` là `null` khi không có gì chờ.
#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ClaudePendingResponse {
    #[serde(deserialize_with = "nullable")]
    pub pending: Option<ClaudePending>,
}

/// Câu hỏi của agy (`GET /api/ai-questions`).
#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct AiQuestion {
    #[serde(deserialize_with = "nullable")]
    pub id: String,
    #[serde(deserialize_with = "nullable")]
    pub question: String,
    #[serde(deserialize_with = "nullable")]
    pub answer: Option<String>,
    #[serde(deserialize_with = "nullable")]
    pub is_pending: bool,
}

#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct AiQuestionsResponse {
    #[serde(deserialize_with = "nullable")]
    pub questions: Vec<AiQuestion>,
}

/// Đọc mảng `retry:update`.
pub fn parse_retries(value: serde_json::Value) -> Result<Vec<PendingRetry>, String> {
    serde_json::from_value::<Vec<PendingRetry>>(value).map_err(|e| e.to_string())
}

#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct SessionListBody {
    #[serde(deserialize_with = "nullable")]
    sessions: Vec<SessionSummary>,
}

/// Đọc `{ "sessions": [...] }`.
pub fn parse_session_list(value: serde_json::Value) -> Result<Vec<SessionSummary>, String> {
    serde_json::from_value::<SessionListBody>(value)
        .map(|b| b.sessions)
        .map_err(|e| e.to_string())
}

/// Dự án (`ProjectWorkspace` của server).
#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ProjectWorkspace {
    #[serde(deserialize_with = "nullable")]
    pub id: String,
    #[serde(deserialize_with = "nullable")]
    pub name: String,
    #[serde(deserialize_with = "nullable")]
    pub path: String,
    #[serde(deserialize_with = "nullable")]
    pub session_count: u64,
    #[serde(deserialize_with = "nullable")]
    pub running_count: u64,
    #[serde(deserialize_with = "nullable")]
    pub last_active_at: String,
}

/// `meta:update` / `GET /api/meta`.
#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ServerMeta {
    #[serde(deserialize_with = "nullable")]
    pub projects: Vec<ProjectWorkspace>,
    #[serde(deserialize_with = "nullable")]
    pub available_models: Vec<String>,
    #[serde(deserialize_with = "nullable")]
    pub model_labels: HashMap<String, String>,
    #[serde(deserialize_with = "nullable")]
    pub effort_levels: Vec<String>,
    #[serde(deserialize_with = "nullable")]
    pub hostname: String,
    #[serde(deserialize_with = "nullable")]
    pub workspace_root: String,
    #[serde(deserialize_with = "nullable")]
    pub home_dir: String,
}

/// Lượt chat đang chạy (`chat:stream`, mục `activeStreams` của `streams:update`).
#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct StreamState {
    #[serde(deserialize_with = "nullable")]
    pub conversation_id: String,
    #[serde(deserialize_with = "nullable")]
    pub project_path: String,
    #[serde(deserialize_with = "nullable")]
    pub user_prompt: String,
    #[serde(deserialize_with = "nullable")]
    pub streaming_text: String,
    #[serde(deserialize_with = "nullable")]
    pub thinking_text: String,
    #[serde(deserialize_with = "nullable")]
    pub is_running: bool,
    #[serde(deserialize_with = "nullable")]
    pub active_step_type: String,
    #[serde(deserialize_with = "nullable")]
    pub error: String,
}

#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct StreamsBody {
    #[serde(deserialize_with = "nullable")]
    active_streams: HashMap<String, StreamState>,
}

/// Đọc `{ "activeStreams": { id: stream } }`.
pub fn parse_streams(value: serde_json::Value) -> Result<HashMap<String, StreamState>, String> {
    serde_json::from_value::<StreamsBody>(value)
        .map(|b| b.active_streams)
        .map_err(|e| e.to_string())
}

/// Kết quả `POST /api/chat/send` (và ack `chat:send`).
#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ChatSendResponse {
    #[serde(deserialize_with = "nullable")]
    pub ok: bool,
    #[serde(deserialize_with = "nullable")]
    pub conversation_id: String,
    #[serde(deserialize_with = "nullable")]
    pub project_path: String,
    #[serde(deserialize_with = "nullable")]
    pub source: String,
    #[serde(deserialize_with = "nullable")]
    pub error: String,
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn parses_session_list_and_ignores_unknown_fields() {
        let list = parse_session_list(json!({
            "sessions": [{
                "id": "s1",
                "projectName": "muop-erp-server",
                "isRunning": true,
                "contextTokens": 230186,
                "somethingNew": {"nested": true}
            }]
        }))
        .unwrap();
        assert_eq!(list.len(), 1);
        assert!(list[0].is_running);
        assert_eq!(list[0].context_tokens, 230186);
    }

    #[test]
    fn parses_steps_and_maps_type_to_kind() {
        let s: ConversationSession = serde_json::from_value(json!({
            "id": "abc",
            "steps": [
                {"stepIndex": 1, "type": "USER_INPUT", "content": "xin chào", "toolCalls": []},
                {"stepIndex": 2, "type": "PLANNER_RESPONSE", "agentName": "Coordinator",
                 "model": "gemini-4", "content": "Chào bạn", "outputTokens": 397}
            ]
        }))
        .unwrap();
        assert_eq!(s.steps[0].kind, "USER_INPUT");
        assert_eq!(s.steps[1].agent_name, "Coordinator");
        assert_eq!(s.steps[1].output_tokens, 397);
    }

    #[test]
    fn null_fields_fall_back_to_defaults() {
        let s: ConversationSession = serde_json::from_value(json!({
            "interruptedReason": null, "steps": null, "title": null
        }))
        .unwrap();
        assert_eq!(s.interrupted_reason, "");
        assert!(s.steps.is_empty());
        assert_eq!(s.title, "");
    }

    #[test]
    fn parses_meta_projects_and_models() {
        let m: ServerMeta = serde_json::from_value(json!({
            "projects": [{"id": "p1", "name": "muop", "path": "/x/muop", "sessionCount": 3}],
            "availableModels": ["claude-cli:claude-sonnet-5-5-medium"],
            "modelLabels": {"agy:a": "A (High)"},
            "effortLevels": ["low", "medium"],
            "workspaceRoot": "/x"
        }))
        .unwrap();
        assert_eq!(m.projects[0].path, "/x/muop");
        assert_eq!(m.available_models.len(), 1);
        assert_eq!(m.model_labels["agy:a"], "A (High)");
        assert_eq!(m.effort_levels, vec!["low", "medium"]);
    }

    #[test]
    fn parses_active_streams() {
        let streams = parse_streams(json!({
            "activeStreams": {"c1": {"conversationId": "c1", "isRunning": true,
                                     "streamingText": "đang viết", "userPrompt": "hi"}}
        }))
        .unwrap();
        assert!(streams["c1"].is_running);
        assert_eq!(streams["c1"].streaming_text, "đang viết");
    }

    #[test]
    fn parses_quota_snapshot_and_retry_list() {
        let q: QuotaSnapshot = serde_json::from_value(json!({
            "agy": {"provider": "agy", "error": "", "groups": [{"displayName": "G",
                "buckets": [{"window": "5h", "remainingPercent": 58.5, "resetTime": ""}]}]},
            "claude": {"provider": "claude", "error": "Không có dữ liệu quota", "groups": []}
        }))
        .unwrap();
        assert_eq!(
            q.report("agy").unwrap().groups[0].buckets[0].remaining_percent,
            58.5
        );
        assert_eq!(q.claude.error, "Không có dữ liệu quota");
        let r = parse_retries(
            json!([{"conversationId": "c1", "attempt": 2, "maxAttempts": 8,
                                      "waitDetail": "Chờ reset quota"}]),
        )
        .unwrap();
        assert_eq!(r[0].attempt, 2);
        assert_eq!(r[0].wait_detail, "Chờ reset quota");
    }

    #[test]
    fn parses_tool_calls_files_and_images() {
        let s: ConversationSession = serde_json::from_value(json!({
            "id": "c",
            "steps": [
                {"stepIndex": 1, "type": "USER_INPUT", "content": "xem ảnh", "imageCount": 1,
                 "imageUrls": ["/api/chat/attachment?path=%2Fx.png"]},
                {"stepIndex": 2, "type": "PLANNER_RESPONSE", "content": "ok",
                 "toolCalls": [{"name": "update_steps", "summaryLabel": "update_steps",
                                "targetPath": null, "args": {"steps": "[]"}}]}
            ],
            "filesTouched": [{"path": "/x/a.rs", "action": "EDIT", "addedLines": 3,
                              "removedLines": 1, "stepIndex": 2}]
        }))
        .unwrap();
        assert_eq!(s.steps[0].image_urls.len(), 1);
        assert_eq!(s.steps[0].image_count, 1);
        assert_eq!(s.steps[1].tool_calls[0].name, "update_steps");
        assert_eq!(s.steps[1].tool_calls[0].target_path, "");
        assert_eq!(s.files_touched[0].added_lines, 3);
        assert_eq!(s.files_touched[0].step_index, 2);
    }

    #[test]
    fn parses_pending_plans() {
        let s: ConversationSession = serde_json::from_value(json!({
            "id": "c", "pendingPlans": [{"fileName": "plan.md", "title": "Kế hoạch",
                                          "requestFeedback": true, "content": "# x"}]
        }))
        .unwrap();
        assert_eq!(s.pending_plans[0].file_name, "plan.md");
        assert!(s.pending_plans[0].request_feedback);
    }

    #[test]
    fn parses_steps_page() {
        let p: StepsPage = serde_json::from_value(json!({
            "sessionId": "x", "hasMore": true, "earliestStepIndex": 897, "totalSteps": 949,
            "steps": [{"stepIndex": 897, "type": "USER_INPUT", "content": "cũ"}]
        }))
        .unwrap();
        assert!(p.has_more);
        assert_eq!(p.earliest_step_index, 897);
        assert_eq!(p.total_steps, 949);
        assert_eq!(p.steps[0].content, "cũ");
    }

    #[test]
    fn parses_sftp_open_and_list() {
        let open: SftpOpenResponse = serde_json::from_value(json!({
            "ok": true, "error": "", "session": {"sessionId": "abc", "home": "/home/x"}
        }))
        .unwrap();
        assert_eq!(open.session.session_id, "abc");
        let list: SftpListResponse = serde_json::from_value(json!({
            "ok": true, "path": "/x", "entries": [
                {"name": "lib", "path": "/x/lib", "isDir": true, "size": 0, "modified": "x", "modifiedUnix": null},
                {"name": "a.txt", "path": "/x/a.txt", "isDir": false, "size": 12}
            ]
        }))
        .unwrap();
        assert!(list.entries[0].is_dir);
        assert_eq!(list.entries[1].size, 12);
        let gone: SftpListResponse =
            serde_json::from_value(json!({"ok": false, "sessionGone": true, "error": "hết hạn"}))
                .unwrap();
        assert!(gone.session_gone);
    }

    #[test]
    fn parses_claude_pending_null_and_question() {
        let none: ClaudePendingResponse =
            serde_json::from_value(json!({"ok": true, "conversationId": "c", "pending": null}))
                .unwrap();
        assert!(none.pending.is_none());
        let some: ClaudePendingResponse = serde_json::from_value(json!({
            "ok": true,
            "pending": {"conversationId": "c", "toolUseId": "toolu_1", "kind": "question",
                "questions": [{"question": "Chọn?", "header": "H", "multiSelect": true,
                    "options": [{"label": "A", "description": "mô tả"}]}]}
        }))
        .unwrap();
        let p = some.pending.unwrap();
        assert_eq!(p.tool_use_id, "toolu_1");
        assert!(p.questions[0].multi_select);
        assert_eq!(p.questions[0].options[0].label, "A");
    }

    #[test]
    fn parses_ai_questions() {
        let r: AiQuestionsResponse = serde_json::from_value(json!({
            "ok": true, "questions": [{"id": "q1", "question": "Tên?", "answer": null, "isPending": true}]
        }))
        .unwrap();
        assert!(r.questions[0].is_pending);
        assert_eq!(r.questions[0].answer, None);
    }

    #[test]
    fn parses_chat_send_error_response() {
        let r: ChatSendResponse =
            serde_json::from_value(json!({"ok": false, "error": "Chưa khởi tạo"})).unwrap();
        assert!(!r.ok);
        assert_eq!(r.error, "Chưa khởi tạo");
    }
}
