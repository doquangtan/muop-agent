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
use std::time::SystemTime;
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
            let max_preview = 120 * 1024;
            let slice = if bytes.len() > max_preview {
                &bytes[..max_preview]
            } else {
                &bytes[..]
            };
            let is_binary = slice.iter().take(512).any(|&b| b == 0);
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

    match tokio::fs::read(file_path).await {
        Ok(bytes) => {
            let len = bytes.len();
            Response::builder()
                .status(StatusCode::OK)
                .header(header::CONTENT_TYPE, "application/octet-stream")
                .header(
                    header::CONTENT_DISPOSITION,
                    format!("attachment; filename=\"{}\"", filename),
                )
                .header(header::CONTENT_LENGTH, len.to_string())
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

    // Watcher ngầm theo dõi sự thay đổi của transcript.jsonl & conversation_summaries.db (chu kỳ 1s)
    let watcher_state = app_state.clone();
    tokio::spawn(async move {
        let mut ticker = interval(Duration::from_millis(1000));
        let mut last_fp = scanner::compute_filesystem_fingerprint();
        loop {
            ticker.tick().await;
            let current_fp = scanner::compute_filesystem_fingerprint();
            if current_fp != last_fp {
                last_fp = current_fp;
                let streams = watcher_state
                    .active_streams
                    .lock()
                    .map(|g| g.clone())
                    .unwrap_or_default();
                let snapshot = tokio::task::spawn_blocking(move || {
                    scanner::build_full_snapshot(&streams, None, 100)
                })
                .await
                .unwrap_or_else(|_| scanner::build_full_snapshot(&HashMap::new(), None, 100));

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
        .route("/api/git/push", post(handle_git_push))
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
