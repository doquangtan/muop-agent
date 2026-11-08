mod chat;
mod models;
mod scanner;
mod tray;

use axum::{
    body::Body,
    extract::{Query, State},
    http::{header, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use chat::AppState;
use chrono::{DateTime, Utc};
use models::{
    ChatSendRequest, ChatStopRequest, ServerDirListResponse, ServerFileEntry,
    ServerFileReadResponse,
};
use serde_json::json;
use socketioxide::{
    extract::{AckSender, Data, SocketRef},
    SocketIo,
};
use std::collections::HashMap;
use std::fs;
use std::net::SocketAddr;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Instant, SystemTime};
use tokio::time::{interval, Duration};
use tower_http::cors::CorsLayer;

fn setup_socket_handlers(io: &SocketIo, state: AppState) {
    let connect_state = state.clone();
    io.ns("/", move |socket: SocketRef| {
        tracing::info!("⚡ Socket.IO Client connected: {}", socket.id);

        // Gửi ngay snapshot đầu tiên khi client vừa kết nối
        let streams = connect_state
            .active_streams
            .lock()
            .map(|g| g.clone())
            .unwrap_or_default();
        let snapshot = scanner::build_full_snapshot(&streams, None, 100);
        if let Ok(val) = serde_json::to_value(&snapshot) {
            let _ = socket.emit("snapshot:update", &val);
        }

        let req_state = connect_state.clone();
        socket.on("request-snapshot", move |s: SocketRef| {
            let st = req_state.clone();
            async move {
                let active = st
                    .active_streams
                    .lock()
                    .map(|g| g.clone())
                    .unwrap_or_default();
                let snap = scanner::build_full_snapshot(&active, None, 100);
                if let Ok(val) = serde_json::to_value(&snap) {
                    let _ = s.emit("snapshot:update", &val);
                }
            }
        });

        let send_state = connect_state.clone();
        socket.on(
            "chat:send",
            move |Data::<ChatSendRequest>(req), ack: AckSender| {
                let st = send_state.clone();
                async move {
                    let res = chat::start_chat_turn(st.clone(), req).await;
                    st.broadcast_snapshot();
                    let _ = ack.send(&res);
                }
            },
        );

        let stop_state = connect_state.clone();
        socket.on(
            "chat:stop",
            move |Data::<ChatStopRequest>(req), ack: AckSender| {
                let st = stop_state.clone();
                async move {
                    let stopped = chat::stop_chat_turn(&st, &req.conversation_id);
                    let _ = ack.send(&json!({ "ok": true, "stopped": stopped }));
                }
            },
        );
    });
}

async fn handle_ping() -> impl IntoResponse {
    let ips = scanner::detect_lan_ips();
    let hostname = scanner::detect_hostname();
    Json(json!({
        "status": "ok",
        "app": "muop-agent-rust-server",
        "engine": "rust-axum-socketio",
        "hostname": hostname,
        "ips": ips,
        "port": scanner::DEFAULT_PORT,
        "timestamp": Utc::now().to_rfc3339(),
    }))
}

async fn handle_snapshot(State(state): State<AppState>) -> impl IntoResponse {
    let streams = state
        .active_streams
        .lock()
        .map(|g| g.clone())
        .unwrap_or_default();
    let snapshot = scanner::build_full_snapshot(&streams, None, 35);
    Json(snapshot)
}

async fn handle_session_detail(
    Query(params): Query<HashMap<String, String>>,
) -> impl IntoResponse {
    let session_id = match params.get("id").map(|s| s.trim()).filter(|s| !s.is_empty()) {
        Some(id) => id,
        None => {
            return (
                StatusCode::BAD_REQUEST,
                Json(serde_json::json!({"error": "Missing session id"})),
            );
        }
    };

    if let Some(sess) = scanner::get_single_session_full(session_id) {
        (
            StatusCode::OK,
            Json(serde_json::to_value(&sess).unwrap_or_default()),
        )
    } else {
        (
            StatusCode::NOT_FOUND,
            Json(serde_json::json!({"error": "Session not found"})),
        )
    }
}

async fn handle_session_steps(
    Query(params): Query<HashMap<String, String>>,
) -> impl IntoResponse {
    let session_id = match params.get("id").map(|s| s.trim()).filter(|s| !s.is_empty()) {
        Some(id) => id,
        None => {
            return (
                StatusCode::BAD_REQUEST,
                Json(serde_json::json!({"error": "Missing session id"})),
            );
        }
    };

    let before_step = params
        .get("before_step")
        .or_else(|| params.get("beforeStep"))
        .or_else(|| params.get("before_step_index"))
        .and_then(|s| s.parse::<usize>().ok());

    let limit = params
        .get("limit")
        .and_then(|s| s.parse::<usize>().ok())
        .unwrap_or(50)
        .clamp(1, 200);

    if let Some(page) = scanner::get_session_steps_page(session_id, before_step, limit) {
        (
            StatusCode::OK,
            Json(serde_json::to_value(&page).unwrap_or_default()),
        )
    } else {
        (
            StatusCode::NOT_FOUND,
            Json(serde_json::json!({"error": "Session not found"})),
        )
    }
}

async fn handle_chat_send(
    State(state): State<AppState>,
    Json(req): Json<ChatSendRequest>,
) -> impl IntoResponse {
    let result = chat::start_chat_turn(state.clone(), req).await;
    state.broadcast_snapshot();
    let status = if result.ok {
        StatusCode::OK
    } else {
        StatusCode::BAD_REQUEST
    };
    (status, Json(result))
}

async fn handle_chat_stop(
    State(state): State<AppState>,
    Json(req): Json<ChatStopRequest>,
) -> impl IntoResponse {
    let stopped = chat::stop_chat_turn(&state, &req.conversation_id);
    Json(json!({
        "ok": true,
        "stopped": stopped,
    }))
}

async fn handle_project_agents(
    Query(params): Query<HashMap<String, String>>,
) -> impl IntoResponse {
    let project_path = if let Some(p) = params.get("path").map(|s| s.trim()).filter(|s| !s.is_empty()) {
        PathBuf::from(p)
    } else if let Some(n) = params.get("name").map(|s| s.trim()).filter(|s| !s.is_empty()) {
        PathBuf::from(scanner::ECOSYSTEM_DIR_PATH).join(n)
    } else {
        PathBuf::from(scanner::ECOSYSTEM_DIR_PATH).join("muop-erp-server")
    };

    let (specs, available) = scanner::scan_project_agents_and_skills(&project_path);
    let project_name = project_path
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or("project")
        .to_string();

    let mut custom_agents = Vec::new();
    let mut skills = Vec::new();
    let mut rules = Vec::new();
    for s in specs {
        if s.kind == "agent" {
            custom_agents.push(s);
        } else if s.kind == "skill" {
            skills.push(s);
        } else if s.kind == "rule" {
            rules.push(s);
        }
    }

    (
        StatusCode::OK,
        Json(models::ProjectAgentsResponse {
            ok: true,
            project_path: project_path.to_string_lossy().to_string(),
            project_name,
            available_agents: available,
            custom_agents,
            skills,
            rules,
            error: None,
        }),
    )
}

async fn handle_plan_pending(
    Query(params): Query<HashMap<String, String>>,
) -> impl IntoResponse {
    let session_id = params
        .get("id")
        .or_else(|| params.get("conversationId"))
        .map(|s| s.trim())
        .unwrap_or("");
    if session_id.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({ "ok": false, "error": "Thiếu id phiên hội thoại (id / conversationId)" })),
        );
    }
    let plans = scanner::scan_pending_plans(session_id);
    (StatusCode::OK, Json(json!({ "ok": true, "plans": plans })))
}

async fn handle_plan_action(
    State(state): State<AppState>,
    Json(req): Json<models::PlanActionRequest>,
) -> impl IntoResponse {
    let conv_id = req.conversation_id.trim();
    if conv_id.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({ "ok": false, "error": "Thiếu conversation_id" })),
        );
    }

    let brain_dir = Path::new(scanner::BRAIN_DIR_PATH).join(conv_id);
    let meta_file = brain_dir.join(format!("{}.metadata.json", req.file_name));

    if req.action == "approve" {
        // Cập nhật metadata: requestFeedback = false
        if meta_file.exists() {
            if let Ok(content) = fs::read_to_string(&meta_file) {
                if let Ok(mut val) = serde_json::from_str::<serde_json::Value>(&content) {
                    if let Some(map) = val.as_object_mut() {
                        map.insert(
                            "requestFeedback".to_string(),
                            serde_json::Value::Bool(false),
                        );
                        let _ = fs::write(
                            &meta_file,
                            serde_json::to_string_pretty(&val).unwrap_or_default(),
                        );
                    }
                }
            }
        }

        let prompt = format!(
            "Duyệt kế hoạch và bắt đầu chạy song song (Parallel Agents) cho tệp [{}].",
            req.file_name
        );
        let send_req = ChatSendRequest {
            prompt,
            project_path: "/home/john/Documents/muop-ecosystem/muop-erp-server".to_string(),
            conversation_id: conv_id.to_string(),
            agent_name: "Coordinator".to_string(),
            model: req.model.clone(),
        };

        let result = chat::start_chat_turn(state.clone(), send_req).await;
        state.broadcast_snapshot();

        (
            StatusCode::OK,
            Json(json!({
                "ok": true,
                "action": "approved",
                "message": "Đã phê duyệt kế hoạch thành công! Đang kích hoạt chạy tác vụ song song...",
                "chatResult": result
            })),
        )
    } else {
        let feedback_msg = if req.feedback.trim().is_empty() {
            format!(
                "Tôi chưa duyệt kế hoạch [{}]. Vui lòng tạm dừng hoặc điều chỉnh thêm.",
                req.file_name
            )
        } else {
            format!(
                "Tôi yêu cầu điều chỉnh kế hoạch [{}]: {}",
                req.file_name,
                req.feedback.trim()
            )
        };

        let send_req = ChatSendRequest {
            prompt: feedback_msg,
            project_path: "/home/john/Documents/muop-ecosystem/muop-erp-server".to_string(),
            conversation_id: conv_id.to_string(),
            agent_name: "Coordinator".to_string(),
            model: req.model.clone(),
        };

        let result = chat::start_chat_turn(state.clone(), send_req).await;
        state.broadcast_snapshot();

        (
            StatusCode::OK,
            Json(json!({
                "ok": true,
                "action": "rejected",
                "message": "Đã gửi phản hồi yêu cầu điều chỉnh kế hoạch.",
                "chatResult": result
            })),
        )
    }
}

async fn handle_project_create(
    State(state): State<AppState>,
    Json(req): Json<models::CreateProjectRequest>,
) -> impl IntoResponse {
    match scanner::create_new_project(&req.name, &req.template, &req.description) {
        Ok(project) => {
            state.broadcast_snapshot();
            (
                StatusCode::OK,
                Json(models::CreateProjectResponse {
                    ok: true,
                    message: format!("Đã tạo thành công dự án [{}]", project.name),
                    project: Some(project),
                    error: None,
                }),
            )
        }
        Err(err) => (
            StatusCode::BAD_REQUEST,
            Json(models::CreateProjectResponse {
                ok: false,
                message: err.clone(),
                project: None,
                error: Some(err),
            }),
        ),
    }
}

async fn handle_git_push(
    State(state): State<AppState>,
    Json(req): Json<models::GitPushRequest>,
) -> impl IntoResponse {
    let p = PathBuf::from(&req.project_path);
    if !p.exists() || !p.is_dir() {
        return (
            StatusCode::BAD_REQUEST,
            Json(models::GitPushResponse {
                ok: false,
                message: format!("Thư mục dự án không tồn tại: {}", req.project_path),
                output: String::new(),
                error: Some("PathNotFound".to_string()),
            }),
        );
    }

    let mut cmd = tokio::process::Command::new("git");
    cmd.current_dir(&p);
    if !req.branch.trim().is_empty() {
        cmd.args(["push", "origin", req.branch.trim()]);
    } else {
        cmd.arg("push");
    }

    match cmd.output().await {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout).to_string();
            let stderr = String::from_utf8_lossy(&out.stderr).to_string();
            let combined = format!("{}\n{}", stdout, stderr).trim().to_string();
            if out.status.success() {
                state.broadcast_snapshot();
                (
                    StatusCode::OK,
                    Json(models::GitPushResponse {
                        ok: true,
                        message: "Đã push thành công lên máy chủ từ xa (remote git repository)!".to_string(),
                        output: combined,
                        error: None,
                    }),
                )
            } else {
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(models::GitPushResponse {
                        ok: false,
                        message: format!("Lỗi khi chạy git push: {}", combined),
                        output: combined,
                        error: Some("GitPushFailed".to_string()),
                    }),
                )
            }
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(models::GitPushResponse {
                ok: false,
                message: format!("Không thể khởi chạy git push: {}", e),
                output: String::new(),
                error: Some(e.to_string()),
            }),
        ),
    }
}

#[derive(serde::Deserialize)]
struct GitHistoryQuery {
    project_path: String,
    branch: Option<String>,
    limit: Option<usize>,
}

async fn handle_git_history(Query(params): Query<GitHistoryQuery>) -> impl IntoResponse {
    let project_path = params.project_path.trim().to_string();
    let branch_filter = params.branch.map(|s| s.trim().to_string()).filter(|s| !s.is_empty());
    let limit = params.limit.unwrap_or(100).clamp(1, 500);

    let res = tokio::task::spawn_blocking(move || {
        let p = PathBuf::from(&project_path);
        let mut canonical = fs::canonicalize(&p).unwrap_or(p);

        // Tự động tìm kiếm ngược lên thư mục cha nếu path truyền vào là thư mục con bên trong Git repo
        while !canonical.join(".git").exists() {
            if let Some(parent) = canonical.parent() {
                canonical = parent.to_path_buf();
            } else {
                break;
            }
        }

        let project_name = canonical.file_name().and_then(|n| n.to_str()).unwrap_or("project").to_string();

        if !canonical.exists() || !canonical.is_dir() {
            return models::GitHistoryResponse {
                ok: false,
                project_path: canonical.to_string_lossy().to_string(),
                project_name,
                current_branch: String::new(),
                branches: vec![],
                total_commits: 0,
                commits: vec![],
                error: Some(format!("Thư mục không tồn tại: {}", canonical.to_string_lossy())),
            };
        }

        if !canonical.join(".git").exists() {
            return models::GitHistoryResponse {
                ok: false,
                project_path: canonical.to_string_lossy().to_string(),
                project_name,
                current_branch: String::new(),
                branches: vec![],
                total_commits: 0,
                commits: vec![],
                error: Some("Thư mục này không phải là một kho lưu trữ Git (.git không tồn tại)".to_string()),
            };
        }

        // Lấy tên branch hiện tại
        let current_branch = Command::new("git")
            .current_dir(&canonical)
            .args(["rev-parse", "--abbrev-ref", "HEAD"])
            .output()
            .ok()
            .and_then(|o| if o.status.success() { Some(String::from_utf8_lossy(&o.stdout).trim().to_string()) } else { None })
            .unwrap_or_else(|| "HEAD".to_string());

        // Lấy danh sách tất cả các branch (cả local và remote)
        let branches = Command::new("git")
            .current_dir(&canonical)
            .args(["branch", "-a", "--format=%(refname:short)"])
            .output()
            .ok()
            .map(|o| {
                let out = String::from_utf8_lossy(&o.stdout);
                let mut list: Vec<String> = out.lines()
                    .map(|l| l.trim().to_string())
                    .filter(|l| !l.is_empty())
                    .collect();
                list.sort();
                list.dedup();
                list
            })
            .unwrap_or_default();

        let target_branch = branch_filter.unwrap_or_else(|| "HEAD".to_string());

        // Chạy git log với định dạng chuẩn phân cách ký tự điều khiển ASCII
        let log_res = Command::new("git")
            .current_dir(&canonical)
            .args([
                "log",
                &format!("-n{}", limit),
                &target_branch,
                "--pretty=format:%H\x1f%h\x1f%an\x1f%ae\x1f%aI\x1f%ar\x1f%s\x1f%b\x1f%P\x1f%D\x1e",
            ])
            .output();

        match log_res {
            Ok(out) => {
                let stdout = String::from_utf8_lossy(&out.stdout);
                let mut commits = Vec::new();
                for record in stdout.split('\x1e') {
                    let rec = record.trim();
                    if rec.is_empty() {
                        continue;
                    }
                    let fields: Vec<&str> = rec.split('\x1f').collect();
                    if fields.len() < 7 {
                        continue;
                    }

                    let hash = fields.get(0).unwrap_or(&"").trim().to_string();
                    let short_hash = fields.get(1).unwrap_or(&"").trim().to_string();
                    let author_name = fields.get(2).unwrap_or(&"").trim().to_string();
                    let author_email = fields.get(3).unwrap_or(&"").trim().to_string();
                    let committed_at = fields.get(4).unwrap_or(&"").trim().to_string();
                    let relative_time = fields.get(5).unwrap_or(&"").trim().to_string();
                    let subject = fields.get(6).unwrap_or(&"").trim().to_string();
                    let body = fields.get(7).unwrap_or(&"").trim().to_string();
                    let parent_hashes: Vec<String> = fields.get(8)
                        .unwrap_or(&"")
                        .split_whitespace()
                        .map(|s| s.trim().to_string())
                        .filter(|s| !s.is_empty())
                        .collect();
                    let refs_raw = fields.get(9).unwrap_or(&"").trim();
                    let refs: Vec<String> = if !refs_raw.is_empty() {
                        refs_raw.split(',').map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).collect()
                    } else {
                        vec![]
                    };
                    let is_head = refs.iter().any(|r| r.contains("HEAD"));

                    commits.push(models::GitCommitSummary {
                        hash,
                        short_hash,
                        author_name,
                        author_email,
                        committed_at,
                        relative_time,
                        subject,
                        body,
                        parent_hashes,
                        refs,
                        is_head,
                        files_count: 0,
                    });
                }

                models::GitHistoryResponse {
                    ok: true,
                    project_path: canonical.to_string_lossy().to_string(),
                    project_name,
                    current_branch,
                    branches,
                    total_commits: commits.len(),
                    commits,
                    error: None,
                }
            }
            Err(e) => models::GitHistoryResponse {
                ok: false,
                project_path: canonical.to_string_lossy().to_string(),
                project_name,
                current_branch,
                branches,
                total_commits: 0,
                commits: vec![],
                error: Some(format!("Lỗi khi thực thi lệnh git log: {}", e)),
            },
        }
    }).await.unwrap_or_else(|e| models::GitHistoryResponse {
        ok: false,
        project_path: String::new(),
        project_name: String::new(),
        current_branch: String::new(),
        branches: vec![],
        total_commits: 0,
        commits: vec![],
        error: Some(format!("Lỗi hệ thống khi quét lịch sử git: {}", e)),
    });

    Json(res)
}

#[derive(serde::Deserialize)]
struct GitCommitQuery {
    project_path: String,
    hash: String,
}

async fn handle_git_commit(Query(params): Query<GitCommitQuery>) -> impl IntoResponse {
    let project_path = params.project_path.trim().to_string();
    let hash = params.hash.trim().to_string();

    if !hash.chars().all(|c| c.is_ascii_hexdigit()) || hash.len() < 4 || hash.len() > 40 {
        return (
            StatusCode::BAD_REQUEST,
            Json(models::GitCommitDetailResponse {
                ok: false,
                project_path,
                hash,
                short_hash: String::new(),
                author_name: String::new(),
                author_email: String::new(),
                committed_at: String::new(),
                relative_time: String::new(),
                subject: String::new(),
                body: String::new(),
                parent_hashes: vec![],
                refs: vec![],
                files: vec![],
                diff: String::new(),
                error: Some("Mã băm commit không hợp lệ".to_string()),
            }),
        );
    }

    let res = tokio::task::spawn_blocking(move || {
        let p = PathBuf::from(&project_path);
        let mut canonical = fs::canonicalize(&p).unwrap_or(p);

        // Tự động tìm kiếm ngược lên thư mục cha nếu path truyền vào là thư mục con bên trong Git repo
        while !canonical.join(".git").exists() {
            if let Some(parent) = canonical.parent() {
                canonical = parent.to_path_buf();
            } else {
                break;
            }
        }

        if !canonical.exists() || !canonical.join(".git").exists() {
            return models::GitCommitDetailResponse {
                ok: false,
                project_path: canonical.to_string_lossy().to_string(),
                hash: hash.clone(),
                short_hash: String::new(),
                author_name: String::new(),
                author_email: String::new(),
                committed_at: String::new(),
                relative_time: String::new(),
                subject: String::new(),
                body: String::new(),
                parent_hashes: vec![],
                refs: vec![],
                files: vec![],
                diff: String::new(),
                error: Some("Thư mục dự án không phải là kho lưu trữ Git".to_string()),
            };
        }

        // Lấy metadata của commit
        let meta_res = Command::new("git")
            .current_dir(&canonical)
            .args([
                "show",
                "-s",
                "--pretty=format:%H\x1f%h\x1f%an\x1f%ae\x1f%aI\x1f%ar\x1f%s\x1f%b\x1f%P\x1f%D",
                &hash,
            ])
            .output();

        let mut short_hash = hash.chars().take(7).collect::<String>();
        let mut author_name = String::new();
        let mut author_email = String::new();
        let mut committed_at = String::new();
        let mut relative_time = String::new();
        let mut subject = String::new();
        let mut body = String::new();
        let mut parent_hashes = Vec::new();
        let mut refs = Vec::new();

        if let Ok(meta_out) = meta_res {
            let meta_str = String::from_utf8_lossy(&meta_out.stdout);
            let fields: Vec<&str> = meta_str.split('\x1f').collect();
            if fields.len() >= 7 {
                short_hash = fields.get(1).unwrap_or(&"").trim().to_string();
                author_name = fields.get(2).unwrap_or(&"").trim().to_string();
                author_email = fields.get(3).unwrap_or(&"").trim().to_string();
                committed_at = fields.get(4).unwrap_or(&"").trim().to_string();
                relative_time = fields.get(5).unwrap_or(&"").trim().to_string();
                subject = fields.get(6).unwrap_or(&"").trim().to_string();
                body = fields.get(7).unwrap_or(&"").trim().to_string();
                parent_hashes = fields.get(8)
                    .unwrap_or(&"")
                    .split_whitespace()
                    .map(|s| s.trim().to_string())
                    .filter(|s| !s.is_empty())
                    .collect();
                let refs_raw = fields.get(9).unwrap_or(&"").trim();
                if !refs_raw.is_empty() {
                    refs = refs_raw.split(',').map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).collect();
                }
            }
        }

        // Lấy danh sách files và số dòng thêm/bớt qua numstat
        let mut files_map: HashMap<String, (usize, usize, String)> = HashMap::new();
        if let Ok(numstat_out) = Command::new("git")
            .current_dir(&canonical)
            .args(["show", "--numstat", "--format=", &hash])
            .output()
        {
            let numstat_str = String::from_utf8_lossy(&numstat_out.stdout);
            for line in numstat_str.lines() {
                let parts: Vec<&str> = line.split('\t').collect();
                if parts.len() >= 3 {
                    let additions = parts[0].trim().parse::<usize>().unwrap_or(0);
                    let deletions = parts[1].trim().parse::<usize>().unwrap_or(0);
                    let file_path = parts[2].trim().to_string();
                    files_map.insert(file_path, (additions, deletions, "M".to_string()));
                }
            }
        }

        // Lấy trạng thái A, M, D, R qua name-status
        if let Ok(status_out) = Command::new("git")
            .current_dir(&canonical)
            .args(["diff-tree", "--no-commit-id", "--name-status", "-r", &hash])
            .output()
        {
            let status_str = String::from_utf8_lossy(&status_out.stdout);
            for line in status_str.lines() {
                let parts: Vec<&str> = line.split_whitespace().collect();
                if parts.len() >= 2 {
                    let status = parts[0].chars().next().unwrap_or('M').to_string();
                    let file_path = parts.last().unwrap_or(&"").to_string();
                    if let Some(entry) = files_map.get_mut(&file_path) {
                        entry.2 = status;
                    } else {
                        files_map.insert(file_path, (0, 0, status));
                    }
                }
            }
        }

        let mut files: Vec<models::GitCommitFileChange> = files_map.into_iter()
            .map(|(path, (additions, deletions, status))| models::GitCommitFileChange {
                path,
                status,
                additions,
                deletions,
            })
            .collect();
        files.sort_by(|a, b| a.path.cmp(&b.path));

        // Lấy diff chi tiết của commit
        let diff = Command::new("git")
            .current_dir(&canonical)
            .args(["show", "--stat", "-p", &hash])
            .output()
            .ok()
            .map(|o| {
                let out = String::from_utf8_lossy(&o.stdout).to_string();
                if out.len() > 300_000 {
                    let mut truncated = out[..300_000].to_string();
                    truncated.push_str("\n\n... [Diff quá lớn đã được cắt bớt] ...");
                    truncated
                } else {
                    out
                }
            })
            .unwrap_or_default();

        models::GitCommitDetailResponse {
            ok: true,
            project_path: canonical.to_string_lossy().to_string(),
            hash,
            short_hash,
            author_name,
            author_email,
            committed_at,
            relative_time,
            subject,
            body,
            parent_hashes,
            refs,
            files,
            diff,
            error: None,
        }
    }).await.unwrap_or_else(|e| models::GitCommitDetailResponse {
        ok: false,
        project_path: String::new(),
        hash: String::new(),
        short_hash: String::new(),
        author_name: String::new(),
        author_email: String::new(),
        committed_at: String::new(),
        relative_time: String::new(),
        subject: String::new(),
        body: String::new(),
        parent_hashes: vec![],
        refs: vec![],
        files: vec![],
        diff: String::new(),
        error: Some(format!("Lỗi khi lấy thông tin commit: {}", e)),
    });

    (StatusCode::OK, Json(res))
}

async fn handle_files_list(Query(params): Query<HashMap<String, String>>) -> impl IntoResponse {
    let raw_path = params
        .get("path")
        .map(|s| s.trim())
        .filter(|s| !s.is_empty())
        .unwrap_or(scanner::ECOSYSTEM_DIR_PATH);
    let show_hidden = params
        .get("showHidden")
        .map(|s| s == "true" || s == "1")
        .unwrap_or(false);

    let target_path = PathBuf::from(raw_path);
    let canonical = fs::canonicalize(&target_path).unwrap_or(target_path);

    if !canonical.exists() || !canonical.is_dir() {
        return (
            StatusCode::BAD_REQUEST,
            Json(ServerDirListResponse {
                ok: false,
                current_path: canonical.to_string_lossy().to_string(),
                parent_path: String::new(),
                entries: Vec::new(),
                error: "Thư mục không tồn tại hoặc không hợp lệ".to_string(),
            }),
        );
    }

    let parent_path = canonical
        .parent()
        .map(|p| p.to_string_lossy().to_string())
        .unwrap_or_default();

    let mut entries = Vec::new();
    if let Ok(read_dir) = fs::read_dir(&canonical) {
        for item in read_dir.flatten() {
            let p = item.path();
            let name = match p.file_name().and_then(|n| n.to_str()) {
                Some(s) => s.to_string(),
                None => continue,
            };
            if !show_hidden && name.starts_with('.') {
                continue;
            }
            if name == ".git" || name == "target" || name == ".dart_tool" || name == "node_modules"
            {
                continue;
            }
            if let Ok(meta) = fs::metadata(&p) {
                let modified: DateTime<Utc> = meta
                    .modified()
                    .unwrap_or(SystemTime::UNIX_EPOCH)
                    .into();
                let mode = meta.permissions().mode();
                let perms = format_unix_mode(mode, meta.is_dir());
                entries.push(ServerFileEntry {
                    name,
                    path: p.to_string_lossy().to_string(),
                    is_dir: meta.is_dir(),
                    size: if meta.is_dir() { 0 } else { meta.len() },
                    modified_at: modified.to_rfc3339(),
                    permissions: perms,
                });
            }
        }
    }

    entries.sort_by(|a, b| {
        b.is_dir
            .cmp(&a.is_dir)
            .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
    });

    (
        StatusCode::OK,
        Json(ServerDirListResponse {
            ok: true,
            current_path: canonical.to_string_lossy().to_string(),
            parent_path,
            entries,
            error: String::new(),
        }),
    )
}

fn format_unix_mode(mode: u32, is_dir: bool) -> String {
    let mut s = String::with_capacity(10);
    s.push(if is_dir { 'd' } else { '-' });
    let flags = [
        (0o400, 'r'),
        (0o200, 'w'),
        (0o100, 'x'),
        (0o040, 'r'),
        (0o020, 'w'),
        (0o010, 'x'),
        (0o004, 'r'),
        (0o002, 'w'),
        (0o001, 'x'),
    ];
    for (bit, ch) in flags {
        s.push(if mode & bit != 0 { ch } else { '-' });
    }
    s
}

async fn handle_file_read(Query(params): Query<HashMap<String, String>>) -> impl IntoResponse {
    let raw_path = match params.get("path").map(|s| s.trim()).filter(|s| !s.is_empty()) {
        Some(p) => p,
        None => {
            return (
                StatusCode::BAD_REQUEST,
                Json(ServerFileReadResponse {
                    ok: false,
                    path: String::new(),
                    name: String::new(),
                    size: 0,
                    is_binary: false,
                    is_image: false,
                    content: String::new(),
                    git_diff: String::new(),
                    error: "Thiếu đường dẫn tệp (path)".to_string(),
                }),
            );
        }
    };

    let file_path = Path::new(raw_path);
    if !file_path.exists() || !file_path.is_file() {
        return (
            StatusCode::NOT_FOUND,
            Json(ServerFileReadResponse {
                ok: false,
                path: raw_path.to_string(),
                name: String::new(),
                size: 0,
                is_binary: false,
                is_image: false,
                content: String::new(),
                git_diff: String::new(),
                error: "Tệp không tồn tại trên server".to_string(),
            }),
        );
    }

    let name = file_path
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("file")
        .to_string();
    let size = fs::metadata(file_path).map(|m| m.len()).unwrap_or(0);

    let ext = file_path
        .extension()
        .and_then(|s| s.to_str())
        .unwrap_or("")
        .to_lowercase();
    let is_image = matches!(
        ext.as_str(),
        "png" | "jpg" | "jpeg" | "gif" | "webp" | "bmp" | "ico" | "svg"
    );

    // Chạy git diff nếu file nằm trong git repository
    let mut git_diff = String::new();
    if let Some(parent_dir) = file_path.parent() {
        if let Ok(out) = Command::new("git")
            .args(["diff", "HEAD", "--", raw_path])
            .current_dir(parent_dir)
            .output()
        {
            if out.status.success() {
                git_diff = String::from_utf8_lossy(&out.stdout).to_string();
            }
        }
    }

    match fs::read(file_path) {
        Ok(bytes) => {
            let max_preview = 5 * 1024 * 1024; // Hỗ trợ xem các file lớn đến 5MB
            let slice = if bytes.len() > max_preview {
                &bytes[..max_preview]
            } else {
                &bytes[..]
            };
            let is_binary = if is_image && ext != "svg" {
                true
            } else {
                slice.iter().take(512).any(|&b| b == 0)
            };
            let content = if is_binary {
                String::new()
            } else {
                String::from_utf8_lossy(slice).to_string()
            };
            (
                StatusCode::OK,
                Json(ServerFileReadResponse {
                    ok: true,
                    path: raw_path.to_string(),
                    name,
                    size,
                    is_binary,
                    is_image,
                    content,
                    git_diff,
                    error: String::new(),
                }),
            )
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ServerFileReadResponse {
                ok: false,
                path: raw_path.to_string(),
                name,
                size,
                is_binary: false,
                is_image,
                content: String::new(),
                git_diff,
                error: format!("Không thể đọc tệp: {}", e),
            }),
        ),
    }
}

async fn handle_file_download(Query(params): Query<HashMap<String, String>>) -> Response {
    let raw_path = match params.get("path").map(|s| s.trim()).filter(|s| !s.is_empty()) {
        Some(p) => p,
        None => {
            return (
                StatusCode::BAD_REQUEST,
                Json(json!({ "ok": false, "error": "Thiếu đường dẫn file (path)" })),
            )
                .into_response();
        }
    };

    let file_path = Path::new(raw_path);
    if !file_path.exists() || !file_path.is_file() {
        return (
            StatusCode::NOT_FOUND,
            Json(json!({ "ok": false, "error": "Tệp không tồn tại trên server" })),
        )
            .into_response();
    }

    let filename = file_path
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("download.bin")
        .replace('"', "");

    let ext = file_path
        .extension()
        .and_then(|s| s.to_str())
        .unwrap_or("")
        .to_lowercase();
    let mime = match ext.as_str() {
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "svg" => "image/svg+xml",
        "bmp" => "image/bmp",
        "ico" => "image/x-icon",
        "md" | "markdown" => "text/markdown; charset=utf-8",
        "json" => "application/json",
        "txt" | "log" => "text/plain; charset=utf-8",
        _ => "application/octet-stream",
    };

    match tokio::fs::read(file_path).await {
        Ok(bytes) => {
            let len = bytes.len();
            Response::builder()
                .status(StatusCode::OK)
                .header(header::CONTENT_TYPE, mime)
                .header(
                    header::CONTENT_DISPOSITION,
                    format!("inline; filename=\"{}\"", filename),
                )
                .header(header::CONTENT_LENGTH, len.to_string())
                .header(header::CACHE_CONTROL, "public, max-age=3600")
                .body(Body::from(bytes))
                .unwrap_or_else(|_| StatusCode::INTERNAL_SERVER_ERROR.into_response())
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "ok": false, "error": format!("Không thể đọc tệp: {}", e) })),
        )
            .into_response(),
    }
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "info,socketioxide=info".into()),
        )
        .init();

    let (io_layer, io) = SocketIo::builder().build_layer();
    let app_state = AppState::new(io.clone());

    setup_socket_handlers(&io, app_state.clone());

    // Watcher ngầm theo dõi sự thay đổi của transcript.jsonl & conversation_summaries.db (chu kỳ 1.5s, debounce 1.2s)
    let watcher_state = app_state.clone();
    tokio::spawn(async move {
        let mut ticker = interval(Duration::from_millis(1500));
        let mut last_fp = scanner::compute_filesystem_fingerprint();
        let mut last_emit = Instant::now();
        loop {
            ticker.tick().await;
            let current_fp = scanner::compute_filesystem_fingerprint();
            if current_fp != last_fp {
                last_fp = current_fp;

                // Debounce tối thiểu 1.2s để tránh spam client khi agent đang stream liên tục
                if last_emit.elapsed() < Duration::from_millis(1200) {
                    tokio::time::sleep(Duration::from_millis(600)).await;
                }
                last_emit = Instant::now();

                let streams = watcher_state
                    .active_streams
                    .lock()
                    .map(|g| g.clone())
                    .unwrap_or_default();
                let snapshot = tokio::task::spawn_blocking(move || {
                    scanner::build_full_snapshot(&streams, None, 25)
                })
                .await
                .unwrap_or_else(|_| scanner::build_full_snapshot(&HashMap::new(), None, 25));

                if let Ok(val) = serde_json::to_value(&snapshot) {
                    if let Some(ns) = watcher_state.io.of("/") {
                        let _ = ns.emit("snapshot:update", &val);
                    }
                }
            }
        }
    });

    let app = Router::new()
        .route("/", get(handle_snapshot))
        .route("/snapshot", get(handle_snapshot))
        .route("/api/snapshot", get(handle_snapshot))
        .route("/api/session", get(handle_session_detail))
        .route("/api/session/detail", get(handle_session_detail))
        .route("/api/session/steps", get(handle_session_steps))
        .route("/ping", get(handle_ping))
        .route("/health", get(handle_ping))
        .route("/api/ping", get(handle_ping))
        .route("/api/chat/send", post(handle_chat_send))
        .route("/api/chat/stop", post(handle_chat_stop))
        .route("/api/project/create", post(handle_project_create))
        .route("/api/project/agents", get(handle_project_agents))
        .route("/api/git/push", post(handle_git_push))
        .route("/api/git/history", get(handle_git_history))
        .route("/api/git/commit", get(handle_git_commit))
        .route("/api/plan/pending", get(handle_plan_pending))
        .route("/api/plan/action", post(handle_plan_action))
        .route("/api/files/list", get(handle_files_list))
        .route("/api/files/read", get(handle_file_read))
        .route("/api/files/download", get(handle_file_download))
        .layer(io_layer)
        .layer(CorsLayer::permissive())
        .with_state(app_state);

    let port = std::env::var("PORT")
        .ok()
        .and_then(|s| s.parse::<u16>().ok())
        .unwrap_or(scanner::DEFAULT_PORT);
    let addr = SocketAddr::from(([0, 0, 0, 0], port));

    let ips = scanner::detect_lan_ips();
    println!("==============================================================");
    println!("🦀 MƯỚP AGENT RUST SERVER (AXUM + SOCKET.IO v4)");
    println!("--------------------------------------------------------------");
    println!("📡 Đang lắng nghe trên cổng: 0.0.0.0:{}", port);
    for ip in &ips {
        println!("👉 Địa chỉ kết nối (LAN/VPN): {}:{}", ip, port);
    }
    println!("⚡ Socket.IO Realtime Events: snapshot:update, chat:stream");
    println!("📂 File Server API: /api/files/list & /api/files/download");
    println!("🔔 System Tray: Biểu tượng khay hệ thống hiển thị logo Mướp Agent");
    println!("==============================================================");

    // Khởi chạy biểu tượng System Tray nền (StatusNotifierItem)
    tray::spawn_system_tray();

    let listener = tokio::net::TcpListener::bind(addr)
        .await
        .expect("Không thể bind cổng 8787");
    axum::serve(listener, app).await.unwrap();
}
