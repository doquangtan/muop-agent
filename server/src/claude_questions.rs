use std::collections::HashMap;
use std::fs::File;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::claude_code;

const ASK_TOOL: &str = "AskUserQuestion";
const PLAN_TOOL: &str = "ExitPlanMode";
const ASK_MARKER: &str = "Answer questions?";
const PLAN_MARKER: &str = "Exit plan mode?";
const KIND_QUESTION: &str = "question";
const KIND_PLAN: &str = "plan";
const APPROVE_PROMPT: &str = "approved";
const CANCEL_PROMPT: &str = "cancel plan";
const WRITE_TOOL: &str = "Write";
const EDIT_TOOL: &str = "Edit";
/// Plan dạng file: CLI ghi kế hoạch vào thư mục dùng chung này thay vì gọi ExitPlanMode
const PLAN_FILE_DIR: &str = "/.claude/plans/";

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ClaudeQuestionOption {
    pub label: String,
    pub description: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ClaudeQuestionItem {
    pub question: String,
    pub header: String,
    pub multi_select: bool,
    pub options: Vec<ClaudeQuestionOption>,
}

/// Tương tác đang chờ người dùng: câu hỏi (`kind = "question"`) hoặc kế hoạch cần duyệt (`kind = "plan"`)
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PendingClaudeInteraction {
    pub conversation_id: String,
    pub tool_use_id: String,
    pub kind: &'static str,
    pub created_at: String,
    pub questions: Vec<ClaudeQuestionItem>,
    pub plan: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClaudeQuestionAnswer {
    pub question: String,
    pub answer: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClaudeInteractionResponse {
    #[serde(default)]
    pub conversation_id: String,
    #[serde(default)]
    pub tool_use_id: String,
    #[serde(default)]
    pub project_path: String,
    #[serde(default)]
    pub model: String,
    #[serde(default)]
    pub answers: Vec<ClaudeQuestionAnswer>,
    #[serde(default)]
    pub decision: String,
    #[serde(default)]
    pub feedback: String,
}

fn str_field(v: &Value, key: &str) -> String {
    v.get(key)
        .and_then(|x| x.as_str())
        .unwrap_or("")
        .to_string()
}

fn parse_questions(input: &Value) -> Vec<ClaudeQuestionItem> {
    input
        .get("questions")
        .and_then(|q| q.as_array())
        .map(|items| {
            items
                .iter()
                .map(|q| ClaudeQuestionItem {
                    question: str_field(q, "question"),
                    header: str_field(q, "header"),
                    multi_select: q
                        .get("multiSelect")
                        .and_then(|v| v.as_bool())
                        .unwrap_or(false),
                    options: q
                        .get("options")
                        .and_then(|o| o.as_array())
                        .map(|opts| {
                            opts.iter()
                                .map(|o| ClaudeQuestionOption {
                                    label: str_field(o, "label"),
                                    description: str_field(o, "description"),
                                })
                                .collect()
                        })
                        .unwrap_or_default(),
                })
                .collect()
        })
        .unwrap_or_default()
}

fn is_human_text(message: &Value) -> bool {
    match message.get("content") {
        Some(Value::String(s)) => !s.trim().is_empty(),
        Some(Value::Array(blocks)) => blocks.iter().any(|b| {
            b.get("type").and_then(|t| t.as_str()) == Some("text")
                && b.get("text")
                    .and_then(|t| t.as_str())
                    .map(|t| !t.trim().is_empty())
                    .unwrap_or(false)
        }),
        _ => false,
    }
}

fn result_text(block: &Value) -> String {
    match block.get("content") {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Array(items)) => items
            .iter()
            .filter_map(|i| i.get("text").and_then(|t| t.as_str()))
            .collect::<Vec<_>>()
            .join("\n"),
        _ => String::new(),
    }
}

/// Plan dạng file đang chờ: đường dẫn file và thông tin tương tác (nội dung đọc khi quét xong)
struct FilePlan {
    path: PathBuf,
    interaction: PendingClaudeInteraction,
}

/// Đường dẫn plan nếu tool `Write`/`Edit` đang ghi vào thư mục plan của Claude
fn plan_file_path(input: &Value) -> Option<PathBuf> {
    let path = input.get("file_path")?.as_str()?;
    (path.contains(PLAN_FILE_DIR) && path.ends_with(".md")).then(|| PathBuf::from(path))
}

/// Tương tác đang chờ: tool_use gần nhất bị CLI từ chối ở chế độ `-p` (không có người trả lời)
/// và chưa có tin nhắn người dùng nào sau đó. Ngoài ra, plan ghi ra file trong lượt plan mode
/// được coi là đang chờ cho tới khi có tin nhắn người dùng tiếp theo.
fn scan_pending(path: &Path, conversation_id: &str) -> Option<PendingClaudeInteraction> {
    let file = File::open(path).ok()?;
    let mut candidate: Option<PendingClaudeInteraction> = None;
    let mut pending: Option<PendingClaudeInteraction> = None;
    let mut plan_mode = false;
    let mut file_plan: Option<FilePlan> = None;

    for line in BufReader::new(file).lines().map_while(Result::ok) {
        if line.trim().is_empty() {
            continue;
        }
        let Ok(row) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        if row.get("isSidechain").and_then(|v| v.as_bool()) == Some(true) {
            continue;
        }
        let Some(message) = row.get("message") else {
            continue;
        };
        let kind = row.get("type").and_then(|v| v.as_str()).unwrap_or("");
        let blocks: &[Value] = message
            .get("content")
            .and_then(|c| c.as_array())
            .map(|v| v.as_slice())
            .unwrap_or(&[]);

        if kind == "assistant" {
            for b in blocks {
                if b.get("type").and_then(|t| t.as_str()) != Some("tool_use") {
                    continue;
                }
                let name = b.get("name").and_then(|t| t.as_str()).unwrap_or("");
                let input = b.get("input").unwrap_or(&Value::Null);
                if name == WRITE_TOOL || name == EDIT_TOOL {
                    if let (true, Some(plan_path)) = (plan_mode, plan_file_path(input)) {
                        let same_file = file_plan.as_ref().filter(|fp| fp.path == plan_path);
                        let (tool_use_id, created_at) = match same_file {
                            Some(fp) => (
                                fp.interaction.tool_use_id.clone(),
                                fp.interaction.created_at.clone(),
                            ),
                            None => (str_field(b, "id"), str_field(&row, "timestamp")),
                        };
                        file_plan = Some(FilePlan {
                            path: plan_path,
                            interaction: PendingClaudeInteraction {
                                conversation_id: conversation_id.to_string(),
                                tool_use_id,
                                kind: KIND_PLAN,
                                created_at,
                                questions: Vec::new(),
                                plan: String::new(),
                            },
                        });
                    }
                    continue;
                }
                let interaction_kind = match name {
                    ASK_TOOL => KIND_QUESTION,
                    PLAN_TOOL => KIND_PLAN,
                    _ => continue,
                };
                pending = None;
                file_plan = None;
                candidate = Some(PendingClaudeInteraction {
                    conversation_id: conversation_id.to_string(),
                    tool_use_id: str_field(b, "id"),
                    kind: interaction_kind,
                    created_at: str_field(&row, "timestamp"),
                    questions: parse_questions(input),
                    plan: str_field(input, "plan"),
                });
            }
        } else if kind == "user" {
            if let Some(mode) = row.get("permissionMode").and_then(|v| v.as_str()) {
                plan_mode = mode == "plan";
            }
            if is_human_text(message) {
                candidate = None;
                pending = None;
                file_plan = None;
                continue;
            }
            for b in blocks {
                if b.get("type").and_then(|t| t.as_str()) != Some("tool_result") {
                    continue;
                }
                let matches = candidate
                    .as_ref()
                    .map(|c| c.tool_use_id == str_field(b, "tool_use_id"))
                    .unwrap_or(false);
                if !matches {
                    continue;
                }
                let marker = match candidate.as_ref().map(|c| c.kind) {
                    Some(KIND_PLAN) => PLAN_MARKER,
                    _ => ASK_MARKER,
                };
                let is_error = b.get("is_error").and_then(|v| v.as_bool()).unwrap_or(false);
                if is_error && result_text(b).starts_with(marker) {
                    pending = candidate.take();
                } else {
                    candidate = None;
                }
            }
        }
    }

    let file_pending = file_plan.and_then(|fp| {
        let plan = std::fs::read_to_string(&fp.path).ok()?;
        (!plan.trim().is_empty()).then(|| PendingClaudeInteraction {
            plan,
            ..fp.interaction
        })
    });
    pending.or(file_pending)
}

type CacheEntry = ((u64, u64), Option<PendingClaudeInteraction>);

static CACHE: OnceLock<Mutex<HashMap<PathBuf, CacheEntry>>> = OnceLock::new();

fn cache() -> &'static Mutex<HashMap<PathBuf, CacheEntry>> {
    CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

pub fn pending_for_session(session_id: &str) -> Option<PendingClaudeInteraction> {
    let path = claude_code::find_session_file(session_id)?;
    let fp = claude_code::fingerprint(&path)?;
    if let Ok(map) = cache().lock() {
        if let Some((cached_fp, cached)) = map.get(&path) {
            if *cached_fp == fp {
                return cached.clone();
            }
        }
    }
    let pending = scan_pending(&path, session_id);
    if let Ok(mut map) = cache().lock() {
        map.insert(path, (fp, pending.clone()));
    }
    pending
}

fn format_answer_prompt(
    questions: &[ClaudeQuestionItem],
    answers: &[ClaudeQuestionAnswer],
) -> String {
    let mut lines = vec!["Trả lời các câu hỏi bạn vừa đặt:".to_string()];
    for q in questions {
        let answer = answers
            .iter()
            .find(|a| a.question == q.question)
            .map(|a| a.answer.trim())
            .unwrap_or("");
        lines.push(format!("- {}\n  Trả lời: {}", q.question, answer));
    }
    lines.join("\n")
}

/// Prompt gửi lại cho Claude CLI (`--resume`) để tiếp tục lượt đã dừng ở tương tác đang chờ
pub fn build_response_prompt(
    pending: &PendingClaudeInteraction,
    req: &ClaudeInteractionResponse,
) -> Result<String, &'static str> {
    if pending.kind == KIND_PLAN {
        match req.decision.as_str() {
            "approve" => return Ok(APPROVE_PROMPT.to_string()),
            "cancel" => return Ok(CANCEL_PROMPT.to_string()),
            _ => {}
        }
        let feedback = req.feedback.trim();
        if feedback.is_empty() {
            return Err("Thiếu nội dung góp ý");
        }
        return Ok(format!(
            "/plan Góp ý cho kế hoạch vừa trình, hãy cập nhật kế hoạch theo góp ý rồi trình lại. Chưa thực hiện thay đổi nào:\n{}",
            feedback
        ));
    }
    let complete = pending.questions.iter().all(|q| {
        req.answers
            .iter()
            .any(|a| a.question == q.question && !a.answer.trim().is_empty())
    });
    if !complete {
        return Err("Thiếu câu trả lời cho một hoặc nhiều câu hỏi");
    }
    Ok(format_answer_prompt(&pending.questions, &req.answers))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write_transcript(name: &str, rows: &[&str]) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("muop-claude-q-{}", name));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("session.jsonl");
        std::fs::write(&path, rows.join("\n")).unwrap();
        path
    }

    fn plan_file(name: &str, body: &str) -> PathBuf {
        let dir = std::env::temp_dir()
            .join(format!("muop-claude-q-{}", name))
            .join(".claude/plans");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("plan.md");
        std::fs::write(&path, body).unwrap();
        path
    }

    fn user_text(mode: &str, text: &str) -> String {
        format!(
            r#"{{"type":"user","permissionMode":"{}","timestamp":"t","message":{{"role":"user","content":"{}"}}}}"#,
            mode, text
        )
    }

    fn write_plan(path: &Path) -> String {
        format!(
            r#"{{"type":"assistant","timestamp":"t","message":{{"role":"assistant","content":[{{"type":"tool_use","id":"toolu_w1","name":"Write","input":{{"file_path":"{}","content":"x"}}}}]}}}}"#,
            path.display()
        )
    }

    #[test]
    fn plan_mode_file_write_is_pending_until_human_reply() {
        let plan = plan_file("pending", "# Kế hoạch\n- bước 1");
        let rows = [user_text("plan", "lập plan"), write_plan(&plan)];
        let transcript = write_transcript(
            "pending",
            &rows.iter().map(|s| s.as_str()).collect::<Vec<_>>(),
        );
        let found = scan_pending(&transcript, "cid").expect("plan should be pending");
        assert_eq!(found.kind, KIND_PLAN);
        assert_eq!(found.tool_use_id, "toolu_w1");
        assert!(found.plan.contains("bước 1"));
    }

    #[test]
    fn non_plan_mode_write_is_ignored() {
        let plan = plan_file("normal", "# Ghi chú");
        let rows = [user_text("normal", "làm đi"), write_plan(&plan)];
        let transcript = write_transcript(
            "normal",
            &rows.iter().map(|s| s.as_str()).collect::<Vec<_>>(),
        );
        assert!(scan_pending(&transcript, "cid").is_none());
    }

    #[test]
    fn human_reply_clears_file_plan() {
        let plan = plan_file("cleared", "# Kế hoạch");
        let rows = [
            user_text("plan", "lập plan"),
            write_plan(&plan),
            user_text("normal", "approved"),
        ];
        let transcript = write_transcript(
            "cleared",
            &rows.iter().map(|s| s.as_str()).collect::<Vec<_>>(),
        );
        assert!(scan_pending(&transcript, "cid").is_none());
    }
}
