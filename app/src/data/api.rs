//! REST client tới `muop-agent-server`. Mọi lời gọi chạy trên runtime I/O (`rt`).

use std::fmt;
use std::future::Future;

use reqwest::Url;
use serde::de::DeserializeOwned;
use serde_json::json;

use super::models::{
    AgyAuthStatus, AiQuestionsResponse, ChatSendResponse, ClaudeAuthStatus, ClaudePendingResponse,
    ConversationSession, GitStatusResponse, QuotaSnapshot, SftpListResponse, SftpOpenResponse,
    SftpReadResponse, StepsPage,
};
use super::models::{
    DockerResponse, GitHistoryResponse, SshExecRequest, SshExecResponse, SshHost, SshHostSave,
    SshWriteResponse,
};
use super::rt;

#[derive(Debug, Clone, PartialEq)]
pub enum ApiError {
    Address(String),
    Network(String),
    Status { code: u16, message: String },
    Decode(String),
}

impl fmt::Display for ApiError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ApiError::Address(m) => write!(f, "Địa chỉ không hợp lệ: {m}"),
            ApiError::Network(m) => write!(f, "Không kết nối được máy chủ: {m}"),
            ApiError::Status { code, message } if message.is_empty() => {
                write!(f, "Máy chủ trả lỗi HTTP {code}")
            }
            ApiError::Status { code, message } => write!(f, "Máy chủ trả lỗi {code}: {message}"),
            ApiError::Decode(m) => write!(f, "Dữ liệu máy chủ không đúng định dạng: {m}"),
        }
    }
}

pub type ApiResult<T> = Result<T, ApiError>;

/// Chạy một lời gọi mạng trên runtime I/O và trả `ApiResult`.
pub async fn on_io<T, F>(fut: F) -> ApiResult<T>
where
    F: Future<Output = ApiResult<T>> + Send + 'static,
    T: Send + 'static,
{
    match rt::run(fut).await {
        Ok(result) => result,
        Err(e) => Err(ApiError::Network(e)),
    }
}

fn endpoint(base: &str, path: &str, query: &[(&str, &str)]) -> ApiResult<Url> {
    let raw = format!("{}{}", base.trim_end_matches('/'), path);
    let mut url = Url::parse(&raw).map_err(|e| ApiError::Address(e.to_string()))?;
    if !query.is_empty() {
        let mut pairs = url.query_pairs_mut();
        for (key, value) in query {
            pairs.append_pair(key, value);
        }
    }
    Ok(url)
}

fn network(e: reqwest::Error) -> ApiError {
    ApiError::Network(e.to_string())
}

async fn read_json<T: DeserializeOwned>(response: reqwest::Response) -> ApiResult<T> {
    let status = response.status();
    if !status.is_success() {
        let body = response.text().await.unwrap_or_default();
        let message = body.chars().take(200).collect::<String>();
        return Err(ApiError::Status {
            code: status.as_u16(),
            message,
        });
    }
    response
        .json::<T>()
        .await
        .map_err(|e| ApiError::Decode(e.to_string()))
}

async fn get_json<T: DeserializeOwned>(url: Url) -> ApiResult<T> {
    let response = reqwest::get(url).await.map_err(network)?;
    read_json(response).await
}

async fn post_json<T: DeserializeOwned>(url: Url, body: serde_json::Value) -> ApiResult<T> {
    let response = reqwest::Client::new()
        .post(url)
        .json(&body)
        .send()
        .await
        .map_err(network)?;
    read_json(response).await
}

pub async fn session(base: &str, id: &str) -> ApiResult<ConversationSession> {
    get_json(endpoint(base, "/api/session", &[("id", id)])?).await
}

/// Ảnh gửi kèm lượt chat (base64, đã kiểm tra kích thước ở phía app).
#[derive(Debug, Clone, PartialEq)]
pub struct OutgoingImage {
    pub name: String,
    pub mime_type: String,
    pub data_base64: String,
}

/// Gửi một lượt chat. `conversation_id` rỗng nghĩa là conversation mới.
pub async fn chat_send(
    base: &str,
    prompt: &str,
    project_path: &str,
    conversation_id: &str,
    model: &str,
    images: &[OutgoingImage],
) -> ApiResult<ChatSendResponse> {
    let images: Vec<serde_json::Value> = images
        .iter()
        .map(|i| json!({"name": i.name, "mimeType": i.mime_type, "dataBase64": i.data_base64}))
        .collect();
    let body = json!({
        "prompt": prompt,
        "projectPath": project_path,
        "conversationId": conversation_id,
        "agentName": "",
        "model": model,
        "images": images,
    });
    let response = reqwest::Client::new()
        .post(endpoint(base, "/api/chat/send", &[])?)
        .json(&body)
        .send()
        .await
        .map_err(network)?;
    let status = response.status();
    let text = response.text().await.map_err(network)?;
    // Server trả 400 kèm `{ok: false, error}` khi lượt bị từ chối: đọc lỗi từ body, không báo HTTP thô
    serde_json::from_str::<ChatSendResponse>(&text).map_err(|_| ApiError::Status {
        code: status.as_u16(),
        message: text.chars().take(200).collect(),
    })
}

/// Dừng lượt đang chạy. Trả `true` nếu server xác nhận đã dừng.
pub async fn chat_stop(base: &str, conversation_id: &str) -> ApiResult<bool> {
    let value: serde_json::Value = post_json(
        endpoint(base, "/api/chat/stop", &[])?,
        json!({ "conversationId": conversation_id }),
    )
    .await?;
    Ok(value
        .get("stopped")
        .and_then(|v| v.as_bool())
        .unwrap_or(false))
}

/// Trang lịch sử trước `before_step` (không gồm chính bước đó).
pub async fn session_steps(
    base: &str,
    id: &str,
    before_step: u64,
    limit: u64,
) -> ApiResult<StepsPage> {
    let before = before_step.to_string();
    let limit = limit.to_string();
    get_json(endpoint(
        base,
        "/api/session/steps",
        &[("id", id), ("before_step", &before), ("limit", &limit)],
    )?)
    .await
}

/// Số liệu quota của mọi provider (`GET /api/quota`).
pub async fn quota(base: &str) -> ApiResult<QuotaSnapshot> {
    get_json(endpoint(base, "/api/quota", &[])?).await
}

/// Hủy lịch tự gửi lại của conversation.
pub async fn retry_cancel(base: &str, conversation_id: &str) -> ApiResult<bool> {
    let value: serde_json::Value = post_json(
        endpoint(base, "/api/chat/retry/cancel", &[])?,
        json!({ "conversationId": conversation_id }),
    )
    .await?;
    Ok(value
        .get("cancelled")
        .and_then(|v| v.as_bool())
        .unwrap_or(false))
}

/// Duyệt, từ chối hoặc hủy kế hoạch (`approve` | `reject` | `cancel`).
pub async fn plan_action(
    base: &str,
    conversation_id: &str,
    file_name: &str,
    action: &str,
    feedback: &str,
    model: &str,
) -> ApiResult<serde_json::Value> {
    post_json(
        endpoint(base, "/api/plan/action", &[])?,
        json!({
            "conversationId": conversation_id,
            "fileName": file_name,
            "action": action,
            "feedback": feedback,
            "model": model,
        }),
    )
    .await
}

/// Mở phiên truy cập file của máy server ("Máy này").
pub async fn sftp_local(base: &str) -> ApiResult<SftpOpenResponse> {
    post_json(endpoint(base, "/api/sftp/local", &[])?, json!({})).await
}

/// Liệt kê thư mục tuyệt đối `path` trong phiên đã mở.
pub async fn sftp_list(base: &str, session_id: &str, path: &str) -> ApiResult<SftpListResponse> {
    post_json(
        endpoint(base, "/api/sftp/list", &[])?,
        json!({ "sessionId": session_id, "path": path }),
    )
    .await
}

#[cfg(test)]
mod live_tests {
    //! Chạy khi máy chủ đang bật: `cargo test -- --ignored`
    use super::*;

    /// Gửi kèm ảnh nhưng project không hợp lệ: server phải đọc được `images` và
    /// báo lỗi project (không chạy model, không tốn quota).
    #[test]
    #[ignore = "cần muop-agent-server đang chạy"]
    fn live_chat_send_accepts_image_payload() {
        let base = std::env::var("MUOP_SERVER").unwrap_or_else(|_| "http://127.0.0.1:8787".into());
        let image = OutgoingImage {
            name: "x.png".into(),
            mime_type: "image/png".into(),
            data_base64: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=".into(),
        };
        let resp = super::super::rt::runtime().block_on(async move {
            chat_send(
                &base,
                "thử",
                "/khong/ton/tai",
                "",
                "claude-cli:claude-haiku-5-5-low",
                &[image],
            )
            .await
        });
        let resp = resp.expect("gửi chat");
        assert!(!resp.ok);
        assert!(
            resp.error.contains("project"),
            "lỗi không đúng: {}",
            resp.error
        );
    }

    /// Đọc tệp của chính app qua phiên "Máy này", kiểm tra git status và trạng thái đăng nhập.
    #[test]
    #[ignore = "cần muop-agent-server đang chạy"]
    fn live_read_file_git_status_and_auth() {
        let base = std::env::var("MUOP_SERVER").unwrap_or_else(|_| "http://127.0.0.1:8787".into());
        let manifest = format!("{}/Cargo.toml", env!("CARGO_MANIFEST_DIR"));
        let repo = env!("CARGO_MANIFEST_DIR").to_string();
        let (read, git, agy, claude) = super::super::rt::runtime().block_on(async move {
            let opened = sftp_local(&base).await.expect("mở phiên");
            let sid = opened.session.session_id.clone();
            let read = sftp_read(&base, &sid, &manifest).await.expect("đọc tệp");
            let git = git_status(&base, &repo).await.expect("git status");
            let agy = agy_auth_status(&base).await.expect("agy auth");
            let claude = claude_auth_status(&base).await.expect("claude auth");
            (read, git, agy, claude)
        });
        assert!(read.ok, "đọc tệp lỗi: {}", read.error);
        assert!(
            read.content.contains("[package]"),
            "nội dung Cargo.toml không đúng"
        );
        assert!(!read.binary);
        assert!(git.ok && git.is_repo, "không nhận ra repo git");
        println!(
            "live: git thay đổi={} agy={} claude={}",
            git.kinds.len(),
            agy.logged_in,
            claude.logged_in
        );
    }

    /// Chạy `echo` trên "Máy này" qua `ssh::exec` (không cần sshd, lệnh vô hại).
    #[test]
    #[ignore = "cần muop-agent-server đang chạy"]
    fn live_ssh_exec_echo_on_local_host() {
        let base = std::env::var("MUOP_SERVER").unwrap_or_else(|_| "http://127.0.0.1:8787".into());
        let outcome = super::super::rt::runtime().block_on(async move {
            let hosts = ssh_hosts(&base).await.expect("danh sách máy");
            let local = hosts.iter().find(|h| h.builtin).expect("có máy mặc định");
            let resp = ssh_exec(
                &base,
                &SshExecRequest {
                    host_id: local.id,
                    command: "echo muop-ssh-ok".into(),
                    timeout_secs: 30,
                    password: String::new(),
                    save_password: false,
                },
            )
            .await
            .expect("chạy lệnh");
            assert!(resp.ok, "lỗi: {} / {}", resp.error, resp.stderr);
            assert!(
                resp.stdout.contains("muop-ssh-ok"),
                "stdout: {}",
                resp.stdout
            );
            resp.exit_code
        });
        println!("ssh exec exit: {outcome:?}");
    }

    /// Mở phiên Docker trên "Máy này", quét, rồi đóng. Bỏ qua nếu máy không có Docker.
    #[test]
    #[ignore = "cần muop-agent-server đang chạy"]
    fn live_docker_open_scan_close_on_local_host() {
        let base = std::env::var("MUOP_SERVER").unwrap_or_else(|_| "http://127.0.0.1:8787".into());
        let outcome = super::super::rt::runtime().block_on(async move {
            let hosts = ssh_hosts(&base).await.expect("danh sách máy");
            let local = hosts.iter().find(|h| h.builtin).expect("có máy mặc định");
            let opened = docker_open(&base, local.id).await.expect("mở phiên");
            if !opened.ok {
                return format!("bỏ qua: {}", opened.error);
            }
            let sid = opened.session.as_ref().expect("session").session_id.clone();
            let scanned = docker_scan(&base, &sid).await.expect("quét");
            assert!(scanned.ok, "quét lỗi: {}", scanned.error);
            docker_close(&base, &sid).await.expect("đóng");
            format!(
                "{} container",
                scanned.session.map(|s| s.containers.len()).unwrap_or(0)
            )
        });
        println!("docker: {outcome}");
    }

    /// Lịch sử commit của chính repo app: có commit, có nhánh hiện tại.
    #[test]
    #[ignore = "cần muop-agent-server đang chạy"]
    fn live_git_history_reads_current_branch() {
        let base = std::env::var("MUOP_SERVER").unwrap_or_else(|_| "http://127.0.0.1:8787".into());
        let repo = env!("CARGO_MANIFEST_DIR").to_string();
        let resp = super::super::rt::runtime()
            .block_on(async move { git_history(&base, &repo, 5).await })
            .expect("lịch sử git");
        assert!(resp.ok, "lỗi: {}", resp.error);
        assert!(!resp.current_branch.is_empty());
        assert!(!resp.commits.is_empty());
        assert!(!resp.commits[0].short_hash.is_empty());
    }

    /// Conversation không có tương tác đang chờ: `pending` rỗng, không lỗi.
    #[test]
    #[ignore = "cần muop-agent-server đang chạy"]
    fn live_interactions_endpoints_answer_when_idle() {
        let base = std::env::var("MUOP_SERVER").unwrap_or_else(|_| "http://127.0.0.1:8787".into());
        let (pending, questions) = super::super::rt::runtime().block_on(async move {
            let cid = "00000000-0000-0000-0000-000000000000";
            let p = claude_pending(&base, cid).await.expect("claude pending");
            let q = ai_questions(&base, cid).await.expect("ai questions");
            (p, q)
        });
        assert!(pending.pending.is_none());
        assert!(questions.questions.is_empty());
    }

    #[test]
    #[ignore = "cần muop-agent-server đang chạy"]
    fn live_sftp_local_opens_and_lists_root() {
        let base = std::env::var("MUOP_SERVER").unwrap_or_else(|_| "http://127.0.0.1:8787".into());
        let base2 = base.clone();
        let (session, listing) = super::super::rt::runtime().block_on(async move {
            let opened = sftp_local(&base2).await.expect("mở phiên file");
            assert!(opened.ok, "mở phiên thất bại: {}", opened.error);
            let sid = opened.session.session_id.clone();
            let listing = sftp_list(&base2, &sid, "/").await.expect("liệt kê /");
            (sid, listing)
        });
        assert!(!session.is_empty());
        assert!(listing.ok, "liệt kê thất bại: {}", listing.error);
        assert!(!listing.entries.is_empty(), "thư mục / rỗng");
        println!("sftp: {} mục ở /", listing.entries.len());
    }
}

/// Trả lời của người dùng cho một câu hỏi `AskUserQuestion` (`question`) hoặc quyết định cho kế hoạch (`plan`).
#[derive(Debug, Clone, PartialEq, Default)]
pub struct ClaudeReply {
    pub conversation_id: String,
    pub tool_use_id: String,
    pub project_path: String,
    pub model: String,
    /// `(câu hỏi, câu trả lời)`
    pub answers: Vec<(String, String)>,
    /// `approve`, `cancel` hoặc `feedback` với `plan`
    pub decision: String,
    pub feedback: String,
}

/// Tương tác Claude đang chờ của conversation (`GET /api/claude/pending`).
pub async fn claude_pending(base: &str, conversation_id: &str) -> ApiResult<ClaudePendingResponse> {
    get_json(endpoint(
        base,
        "/api/claude/pending",
        &[("id", conversation_id)],
    )?)
    .await
}

/// Gửi trả lời cho tương tác Claude đang chờ.
pub async fn claude_respond(base: &str, reply: &ClaudeReply) -> ApiResult<serde_json::Value> {
    let answers: Vec<serde_json::Value> = reply
        .answers
        .iter()
        .map(|(q, a)| json!({"question": q, "answer": a}))
        .collect();
    post_json(
        endpoint(base, "/api/claude/respond", &[])?,
        json!({
            "conversationId": reply.conversation_id,
            "toolUseId": reply.tool_use_id,
            "projectPath": reply.project_path,
            "model": reply.model,
            "answers": answers,
            "decision": reply.decision,
            "feedback": reply.feedback,
        }),
    )
    .await
}

/// Câu hỏi của agy trong conversation.
pub async fn ai_questions(base: &str, conversation_id: &str) -> ApiResult<AiQuestionsResponse> {
    get_json(endpoint(
        base,
        "/api/ai-questions",
        &[("conversationId", conversation_id)],
    )?)
    .await
}

/// Ghi câu trả lời cho một câu hỏi của agy.
pub async fn ai_answer(
    base: &str,
    question_id: &str,
    answer: &str,
) -> ApiResult<serde_json::Value> {
    post_json(
        endpoint(base, "/api/ai-questions/answer", &[])?,
        json!({"questionId": question_id, "answer": answer}),
    )
    .await
}

/// Đọc một tệp trong phiên đã mở (tối đa 1MB).
pub async fn sftp_read(base: &str, session_id: &str, path: &str) -> ApiResult<SftpReadResponse> {
    post_json(
        endpoint(base, "/api/sftp/read", &[])?,
        json!({ "sessionId": session_id, "path": path }),
    )
    .await
}

/// Trạng thái git của project: tệp nào đã đổi và đổi kiểu gì.
pub async fn git_status(base: &str, project_path: &str) -> ApiResult<GitStatusResponse> {
    get_json(endpoint(
        base,
        "/api/git/status",
        &[("projectPath", project_path)],
    )?)
    .await
}

/// Trạng thái đăng nhập agy (không mở OAuth, chỉ đọc).
pub async fn agy_auth_status(base: &str) -> ApiResult<AgyAuthStatus> {
    get_json(endpoint(base, "/api/agy/auth/status", &[])?).await
}

/// Trạng thái đăng nhập Claude Code CLI và gói sử dụng.
pub async fn claude_auth_status(base: &str) -> ApiResult<ClaudeAuthStatus> {
    get_json(endpoint(base, "/api/claude/auth/status", &[])?).await
}

/// POST và đọc JSON bất kể mã HTTP: server trả 404 kèm `{ok: false, error}` khi phiên Docker đã kết thúc.
async fn post_lenient<T: DeserializeOwned>(url: Url, body: serde_json::Value) -> ApiResult<T> {
    let response = reqwest::Client::new()
        .post(url)
        .json(&body)
        .send()
        .await
        .map_err(network)?;
    let status = response.status();
    let text = response.text().await.map_err(network)?;
    serde_json::from_str::<T>(&text).map_err(|_| ApiError::Status {
        code: status.as_u16(),
        message: text.chars().take(200).collect(),
    })
}

/// Danh sách máy SSH đã lưu (dùng để chọn máy cho Docker).
pub async fn ssh_hosts(base: &str) -> ApiResult<Vec<SshHost>> {
    get_json(endpoint(base, "/api/ssh/hosts", &[])?).await
}

/// Thêm hoặc sửa máy SSH. Lỗi nghiệp vụ (HTTP 400/403/404) nằm trong `error`.
pub async fn ssh_save(base: &str, host: &SshHostSave) -> ApiResult<SshWriteResponse> {
    let body = serde_json::to_value(host).map_err(|e| ApiError::Decode(e.to_string()))?;
    post_lenient(endpoint(base, "/api/ssh/hosts/save", &[])?, body).await
}

/// Xóa máy SSH đã lưu (không xóa được "Máy này").
pub async fn ssh_delete(base: &str, id: u64) -> ApiResult<SshWriteResponse> {
    post_lenient(
        endpoint(base, "/api/ssh/hosts/delete", &[])?,
        json!({ "id": id }),
    )
    .await
}

/// Chạy một lệnh một lần trên máy SSH. Cần mật khẩu: `needs_password` = true, hỏi rồi gọi lại.
pub async fn ssh_exec(base: &str, req: &SshExecRequest) -> ApiResult<SshExecResponse> {
    let body = serde_json::to_value(req).map_err(|e| ApiError::Decode(e.to_string()))?;
    post_lenient(endpoint(base, "/api/ssh/exec", &[])?, body).await
}

/// Mở phiên Docker của một máy (đã quét container khi mở).
pub async fn docker_open(base: &str, host_id: u64) -> ApiResult<DockerResponse> {
    post_lenient(
        endpoint(base, "/api/docker/sessions/open", &[])?,
        json!({ "hostId": host_id }),
    )
    .await
}

/// Quét lại container của phiên đang mở.
pub async fn docker_scan(base: &str, session_id: &str) -> ApiResult<DockerResponse> {
    post_lenient(
        endpoint(base, "/api/docker/sessions/scan", &[])?,
        json!({ "sessionId": session_id }),
    )
    .await
}

/// Khởi động lại (`restart`) hoặc dừng (`stop`) các container theo ID.
pub async fn docker_action(
    base: &str,
    session_id: &str,
    action: &str,
    container_ids: &[String],
) -> ApiResult<DockerResponse> {
    post_lenient(
        endpoint(base, "/api/docker/sessions/action", &[])?,
        json!({ "sessionId": session_id, "action": action, "containerIds": container_ids }),
    )
    .await
}

/// Đóng phiên Docker (dọn kết nối của máy đó).
pub async fn docker_close(base: &str, session_id: &str) -> ApiResult<serde_json::Value> {
    post_lenient(
        endpoint(base, "/api/docker/sessions/close", &[])?,
        json!({ "sessionId": session_id }),
    )
    .await
}

/// Lịch sử commit của project (tối đa `limit`, server giới hạn 500).
pub async fn git_history(
    base: &str,
    project_path: &str,
    limit: u32,
) -> ApiResult<GitHistoryResponse> {
    let limit = limit.to_string();
    get_json(endpoint(
        base,
        "/api/git/history",
        &[("project_path", project_path), ("limit", &limit)],
    )?)
    .await
}
