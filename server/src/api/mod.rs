pub mod chat;
pub mod claude;
pub mod docker;
pub mod files;
pub mod git;
pub mod lsp;
pub mod meta;
pub mod models;
pub mod plans;
pub mod projects;
pub mod sessions;
pub mod ssh;

use crate::chat::AppState;
use axum::{
    routing::{get, post},
    Router,
};

/// Toàn bộ route REST của server (state được gắn ở main)
pub fn router() -> Router<AppState> {
    Router::new()
        .route("/api/sessions", get(sessions::handle_sessions_list))
        .route("/api/meta", get(meta::handle_meta))
        .route("/api/streams", get(meta::handle_streams))
        .route("/api/session", get(sessions::handle_session_detail))
        .route("/api/session/detail", get(sessions::handle_session_detail))
        .route("/api/session/steps", get(sessions::handle_session_steps))
        .route("/ping", get(meta::handle_ping))
        .route("/health", get(meta::handle_ping))
        .route("/api/ping", get(meta::handle_ping))
        .route("/api/chat/send", post(chat::handle_chat_send))
        .route("/api/chat/stop", post(chat::handle_chat_stop))
        .route("/api/chat/attachment", get(chat::handle_chat_attachment))
        .route(
            "/api/chat/retry/cancel",
            post(chat::handle_chat_retry_cancel),
        )
        .route("/api/ssh/hosts", get(ssh::handle_ssh_hosts_list))
        .route("/api/ssh/sessions", get(ssh::handle_ssh_sessions_list))
        .route("/api/ssh/hosts/save", post(ssh::handle_ssh_host_save))
        .route("/api/ssh/hosts/delete", post(ssh::handle_ssh_host_delete))
        .route("/api/ssh/exec", post(ssh::handle_ssh_exec))
        .route(
            "/api/lsp/settings",
            get(lsp::handle_lsp_settings_get).post(lsp::handle_lsp_settings_set),
        )
        .route("/api/code/fold", get(lsp::handle_code_fold))
        .route("/api/code/symbols", get(lsp::handle_code_symbols))
        .route("/api/code/definition", post(lsp::handle_code_definition))
        .route("/api/code/references", post(lsp::handle_code_references))
        .route("/api/code/hover", post(lsp::handle_code_hover))
        .route("/api/code/tokens", get(lsp::handle_code_tokens))
        .route(
            "/api/docker/sessions",
            get(docker::handle_docker_sessions_list),
        )
        .route(
            "/api/docker/sessions/open",
            post(docker::handle_docker_session_open),
        )
        .route(
            "/api/docker/sessions/scan",
            post(docker::handle_docker_session_scan),
        )
        .route(
            "/api/docker/sessions/action",
            post(docker::handle_docker_session_action),
        )
        .route(
            "/api/docker/sessions/close",
            post(docker::handle_docker_session_close),
        )
        .route(
            "/api/conversation/model",
            get(models::handle_conversation_model_get).post(models::handle_conversation_model_set),
        )
        .route(
            "/api/model/context-limit",
            post(models::handle_model_context_limit_set),
        )
        .route("/api/project/create", post(projects::handle_project_create))
        .route("/api/project/agents", get(projects::handle_project_agents))
        .route(
            "/api/claude/extensions",
            get(projects::handle_claude_extensions),
        )
        .route("/api/git/push", post(git::handle_git_push))
        .route("/api/git/history", get(git::handle_git_history))
        .route("/api/git/commit", get(git::handle_git_commit))
        .route(
            "/api/git/status",
            get(crate::git::status::handle_git_status),
        )
        .route("/api/plan/pending", get(plans::handle_plan_pending))
        .route("/api/plan/action", post(plans::handle_plan_action))
        .route("/api/files/list", get(files::handle_files_list))
        .route("/api/files/read", get(files::handle_file_read))
        .route("/api/files/download", get(files::handle_file_download))
        .route(
            "/api/files/lines",
            get(crate::files::lines::handle_file_lines),
        )
        .route("/api/claude/pending", get(claude::handle_claude_pending))
        .route("/api/claude/respond", post(claude::handle_claude_respond))
        .route("/api/ai-questions", get(claude::handle_ai_questions))
        .route(
            "/api/ai-questions/answer",
            post(claude::handle_ai_question_answer),
        )
}
