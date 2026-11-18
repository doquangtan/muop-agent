// DTO đọc từ muop-agent-server và các lệnh gọi REST.
// Mọi struct dùng camelCase giống server; trường thiếu thì lấy giá trị mặc định.

use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::time::Duration;

#[derive(Deserialize, Default, Clone)]
#[serde(rename_all = "camelCase", default)]
pub struct Snapshot {
    pub sessions: Vec<Session>,
    pub projects: Vec<Project>,
    pub available_models: Vec<String>,
    pub model_labels: HashMap<String, String>,
    pub active_streams: HashMap<String, Stream>,
    pub model_context_limits: HashMap<String, u64>,
    pub hostname: String,
}

#[derive(Deserialize, Default, Clone)]
#[serde(rename_all = "camelCase", default)]
pub struct Session {
    pub id: String,
    pub title: String,
    pub updated_at: String,
    pub status: String,
    pub steps: Vec<Step>,
    pub files_touched: Vec<FileTouch>,
    pub pending_plans: Vec<Plan>,
    pub project_name: String,
    pub project_path: String,
    pub source: String,
    pub context_tokens: u64,
    pub context_model: String,
    pub is_interrupted: bool,
}

#[derive(Deserialize, Default, Clone)]
#[serde(rename_all = "camelCase", default)]
pub struct Step {
    pub source: String,
    #[serde(rename = "type")]
    pub step_type: String,
    pub step_index: usize,
    pub content: String,
    pub tool_calls: Vec<ToolCall>,
}

#[derive(Deserialize, Default, Clone)]
#[serde(rename_all = "camelCase", default)]
pub struct ToolCall {
    pub name: String,
    pub summary_label: String,
}

#[derive(Deserialize, Default, Clone)]
#[serde(rename_all = "camelCase", default)]
pub struct FileTouch {
    pub path: String,
    pub action: String,
    pub step_index: usize,
    pub added_lines: usize,
    pub removed_lines: usize,
}

#[derive(Deserialize, Default, Clone)]
#[serde(rename_all = "camelCase", default)]
pub struct Plan {
    pub file_name: String,
    pub title: String,
    pub summary: String,
    pub request_feedback: bool,
}

#[derive(Deserialize, Default, Clone)]
#[serde(rename_all = "camelCase", default)]
pub struct Project {
    pub name: String,
    pub path: String,
}

#[derive(Deserialize, Default, Clone)]
#[serde(rename_all = "camelCase", default)]
pub struct Stream {
    pub conversation_id: String,
    pub project_path: String,
    pub user_prompt: String,
    pub streaming_text: String,
    pub is_running: bool,
    pub error: String,
}

#[derive(Deserialize, Default, Clone)]
#[serde(rename_all = "camelCase", default)]
pub struct AiQuestion {
    pub id: String,
    pub question: String,
    pub is_pending: bool,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct QuestionsResponse {
    questions: Vec<AiQuestion>,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
pub struct SendResponse {
    pub ok: bool,
    pub conversation_id: String,
    pub error: String,
}

const TIMEOUT: Duration = Duration::from_secs(15);

fn http_error(err: ureq::Error) -> String {
    match err {
        ureq::Error::Status(code, resp) => {
            let body = resp.into_string().unwrap_or_default();
            serde_json::from_str::<Value>(&body)
                .ok()
                .and_then(|v| v.get("error").and_then(|e| e.as_str()).map(str::to_string))
                .filter(|e| !e.is_empty())
                .unwrap_or_else(|| format!("HTTP {code}: {body}"))
        }
        ureq::Error::Transport(t) => format!("Không kết nối được server: {t}"),
    }
}

/// Payload của `sessions:list` và `GET /api/sessions`
#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
pub struct SessionsPayload {
    pub sessions: Vec<SessionSummary>,
}

pub fn get_sessions(base: &str) -> Result<Vec<SessionSummary>, String> {
    ureq::get(&format!("{base}/api/sessions"))
        .timeout(TIMEOUT)
        .call()
        .map_err(http_error)?
        .into_json::<SessionsPayload>()
        .map(|p| p.sessions)
        .map_err(|e| format!("Danh sách conversation không hợp lệ: {e}"))
}

pub fn get_meta(base: &str) -> Result<Meta, String> {
    ureq::get(&format!("{base}/api/meta"))
        .timeout(TIMEOUT)
        .call()
        .map_err(http_error)?
        .into_json::<Meta>()
        .map_err(|e| format!("Metadata không hợp lệ: {e}"))
}

pub fn get_streams(base: &str) -> Result<HashMap<String, Stream>, String> {
    ureq::get(&format!("{base}/api/streams"))
        .timeout(TIMEOUT)
        .call()
        .map_err(http_error)?
        .into_json::<StreamsPayload>()
        .map(|p| p.active_streams)
        .map_err(|e| format!("Lượt đang chạy không hợp lệ: {e}"))
}

pub fn get_ai_questions(base: &str, conversation_id: &str) -> Result<Vec<AiQuestion>, String> {
    let url = format!("{base}/api/ai-questions");
    ureq::get(&url)
        .query("conversationId", conversation_id)
        .timeout(TIMEOUT)
        .call()
        .map_err(http_error)?
        .into_json::<QuestionsResponse>()
        .map(|r| r.questions.into_iter().filter(|q| q.is_pending).collect())
        .map_err(|e| format!("Câu hỏi AI không hợp lệ: {e}"))
}

pub fn post_json(base: &str, path: &str, body: Value) -> Result<Value, String> {
    ureq::post(&format!("{base}{path}"))
        .timeout(Duration::from_secs(120))
        .send_json(body)
        .map_err(http_error)?
        .into_json::<Value>()
        .map_err(|e| format!("Phản hồi không hợp lệ: {e}"))
}

pub fn send_chat(
    base: &str,
    prompt: &str,
    project_path: &str,
    conversation_id: &str,
    model: &str,
) -> Result<SendResponse, String> {
    let v = post_json(
        base,
        "/api/chat/send",
        json!({
            "prompt": prompt,
            "projectPath": project_path,
            "conversationId": conversation_id,
            "agentName": "",
            "model": model,
        }),
    )?;
    serde_json::from_value(v).map_err(|e| format!("Phản hồi gửi tin không hợp lệ: {e}"))
}

pub fn stop_chat(base: &str, conversation_id: &str) -> Result<(), String> {
    post_json(
        base,
        "/api/chat/stop",
        json!({ "conversationId": conversation_id }),
    )
    .map(|_| ())
}

pub fn plan_action(
    base: &str,
    conversation_id: &str,
    file_name: &str,
    action: &str,
    feedback: &str,
    model: &str,
) -> Result<(), String> {
    let v = post_json(
        base,
        "/api/plan/action",
        json!({
            "conversationId": conversation_id,
            "fileName": file_name,
            "action": action,
            "feedback": feedback,
            "model": model,
        }),
    )?;
    if v.get("ok").and_then(Value::as_bool).unwrap_or(false) {
        Ok(())
    } else {
        Err(v
            .get("error")
            .or_else(|| v.get("message"))
            .and_then(Value::as_str)
            .unwrap_or("Thao tác kế hoạch thất bại")
            .to_string())
    }
}

pub fn answer_question(base: &str, question_id: &str, answer: &str) -> Result<(), String> {
    let v = post_json(
        base,
        "/api/ai-questions/answer",
        json!({ "questionId": question_id, "answer": answer }),
    )?;
    match v.get("ok").and_then(Value::as_bool) {
        Some(false) => Err(v
            .get("error")
            .and_then(Value::as_str)
            .unwrap_or("Trả lời thất bại")
            .to_string()),
        _ => Ok(()),
    }
}

/// Lượt chat đang chờ tự gửi lại sau rate limit (socket `retry:update`)
#[derive(Deserialize, Default, Clone)]
#[serde(rename_all = "camelCase", default)]
pub struct PendingRetry {
    pub conversation_id: String,
    pub reason: String,
    pub retry_at: String,
    pub attempt: u32,
    pub max_attempts: u32,
}

pub fn cancel_retry(base: &str, conversation_id: &str) -> Result<(), String> {
    post_json(
        base,
        "/api/chat/retry/cancel",
        json!({ "conversationId": conversation_id }),
    )
    .map(|_| ())
}

/// Tóm tắt một conversation từ `sessions:list` (không có steps/files)
#[derive(Deserialize, Default, Clone)]
#[serde(rename_all = "camelCase", default)]
pub struct SessionSummary {
    pub id: String,
    pub title: String,
    pub updated_at: String,
    pub status: String,
    pub project_name: String,
    pub project_path: String,
    pub source: String,
    pub context_tokens: u64,
    pub context_model: String,
    pub is_interrupted: bool,
    pub pending_plans: Vec<Plan>,
}

impl From<SessionSummary> for Session {
    fn from(s: SessionSummary) -> Self {
        Session {
            id: s.id,
            title: s.title,
            updated_at: s.updated_at,
            status: s.status,
            project_name: s.project_name,
            project_path: s.project_path,
            source: s.source,
            context_tokens: s.context_tokens,
            context_model: s.context_model,
            is_interrupted: s.is_interrupted,
            pending_plans: s.pending_plans,
            ..Default::default()
        }
    }
}

/// Metadata chung từ `meta:update`
#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
pub struct Meta {
    pub projects: Vec<Project>,
    pub available_models: Vec<String>,
    pub model_labels: HashMap<String, String>,
    pub model_context_limits: HashMap<String, u64>,
    pub hostname: String,
}

/// Payload của `streams:update`
#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
pub struct StreamsPayload {
    pub active_streams: HashMap<String, Stream>,
}

/// Chi tiết đầy đủ một conversation (steps, files, plan) qua `/api/session`
pub fn get_session_detail(base: &str, conversation_id: &str) -> Result<Session, String> {
    ureq::get(&format!("{base}/api/session"))
        .query("id", conversation_id)
        .timeout(TIMEOUT)
        .call()
        .map_err(http_error)?
        .into_json::<Session>()
        .map_err(|e| format!("Chi tiết conversation không hợp lệ: {e}"))
}
