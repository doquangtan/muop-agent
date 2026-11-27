//! DTO đọc từ REST của `muop-agent-server`.
//!
//! App giữ DTO riêng, không dùng chung crate với server (quyết định của người
//! dùng). Mọi trường đều có `#[serde(default)]` để server thêm/bớt trường
//! không làm vỡ app. Khóa JSON là camelCase.

use serde::{Deserialize, Deserializer};

/// Server có thể trả `null` cho trường bất kỳ (ví dụ `interruptedReason`).
/// `null` và trường thiếu đều rơi về giá trị mặc định của kiểu.
fn nullable<'de, D, T>(deserializer: D) -> Result<T, D::Error>
where
    D: Deserializer<'de>,
    T: Deserialize<'de> + Default,
{
    Option::<T>::deserialize(deserializer).map(Option::unwrap_or_default)
}

#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct PingInfo {
    #[serde(deserialize_with = "nullable")]
    pub status: String,
    #[serde(deserialize_with = "nullable")]
    pub hostname: String,
    #[serde(deserialize_with = "nullable")]
    pub port: u16,
}

/// Một phần tử của `GET /api/sessions`.
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

#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct SessionList {
    #[serde(deserialize_with = "nullable")]
    pub sessions: Vec<SessionSummary>,
}

/// Một bước của conversation. Trường `type` được đổi tên thành `kind`.
#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct AgentStep {
    #[serde(deserialize_with = "nullable")]
    pub step_index: u64,
    #[serde(rename = "type")]
    #[serde(deserialize_with = "nullable")]
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
}

/// `GET /api/session?id=...` (chỉ các trường app đang dùng).
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
    pub context_model: String,
    #[serde(deserialize_with = "nullable")]
    pub total_input_tokens: u64,
    #[serde(deserialize_with = "nullable")]
    pub total_output_tokens: u64,
    #[serde(deserialize_with = "nullable")]
    pub steps: Vec<AgentStep>,
}

#[cfg(test)]
mod tests {
    use super::*;

    const SESSION_LIST: &str = r#"{
        "sessions": [{
            "id": "55846012-e142-44e4-b66f-7f8cb872cded",
            "title": "hi bạn là model nào",
            "projectName": "muop-erp-server",
            "projectPath": "/home/john/Documents/muop-ecosystem/muop-erp-server",
            "status": "running",
            "currentPhase": "completed",
            "source": "agy",
            "selectedModel": "agy:gemini-4-hydrogen-high",
            "isRunning": true,
            "isInterrupted": false,
            "createdAt": "2026-11-25T09:26:21+00:00",
            "updatedAt": "2026-11-27T14:41:28.455171648+00:00",
            "contextTokens": 230186,
            "filesCount": 80,
            "pendingPlans": [],
            "someFieldTheAppDoesNotKnow": {"nested": true}
        }]
    }"#;

    const SESSION_DETAIL: &str = r#"{
        "id": "abc",
        "title": "t",
        "steps": [
            {"stepIndex": 1, "type": "USER_INPUT", "source": "USER_EXPLICIT",
             "content": "xin chào", "toolCalls": [], "imageUrls": []},
            {"stepIndex": 2, "type": "PLANNER_RESPONSE", "status": "DONE",
             "agentName": "Coordinator", "model": "gemini-4-hydrogen-high",
             "content": "Chào bạn", "inputTokens": 3063, "outputTokens": 397}
        ],
        "totalInputTokens": 3063,
        "contextTokens": 230186
    }"#;

    #[test]
    fn parses_session_list_and_ignores_unknown_fields() {
        let list: SessionList = serde_json::from_str(SESSION_LIST).unwrap();
        assert_eq!(list.sessions.len(), 1);
        let s = &list.sessions[0];
        assert_eq!(s.project_name, "muop-erp-server");
        assert!(s.is_running);
        assert_eq!(s.context_tokens, 230186);
        assert_eq!(s.files_count, 80);
    }

    #[test]
    fn parses_steps_and_maps_type_to_kind() {
        let s: ConversationSession = serde_json::from_str(SESSION_DETAIL).unwrap();
        assert_eq!(s.steps.len(), 2);
        assert_eq!(s.steps[0].kind, "USER_INPUT");
        assert_eq!(s.steps[1].kind, "PLANNER_RESPONSE");
        assert_eq!(s.steps[1].agent_name, "Coordinator");
        assert_eq!(s.steps[1].output_tokens, 397);
        // Trường thiếu rơi về giá trị mặc định, không lỗi.
        assert_eq!(s.status, "");
    }

    #[test]
    fn null_fields_fall_back_to_defaults() {
        let s: ConversationSession =
            serde_json::from_str(r#"{"interruptedReason": null, "steps": null, "title": null}"#)
                .unwrap();
        assert_eq!(s.interrupted_reason, "");
        assert!(s.steps.is_empty());
        assert_eq!(s.title, "");
    }

    #[test]
    fn empty_object_is_valid() {
        let s: ConversationSession = serde_json::from_str("{}").unwrap();
        assert!(s.steps.is_empty());
    }
}
