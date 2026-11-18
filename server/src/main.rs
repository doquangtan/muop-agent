mod api;
mod chat;
mod claude;
mod docker;
mod files;
mod git;
mod infra;
mod lsp;
mod models;
mod scanner;
mod socket;
mod ssh;

use crate::chat::AppState;
use serde_json::json;
use socketioxide::SocketIo;
use std::net::SocketAddr;
use tokio::time::{interval, Duration};
use tower_http::cors::CorsLayer;

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

    socket::setup_socket_handlers(&io, app_state.clone());

    // Lượt chat còn chạy từ trước khi server khởi động lại: đưa lại vào trạng thái stream
    let adopt_state = app_state.clone();
    let _ =
        tokio::task::spawn_blocking(move || chat::recovery::adopt_live_turns(&adopt_state)).await;

    // Watcher ngầm theo dõi các session độc lập: mỗi loại thay đổi phát một event riêng
    //  - session:update  : đúng conversation có thay đổi
    //  - projects:update : metadata project thay đổi
    //  - snapshot:update : full resync khi có conversation bị xoá khỏi đĩa
    let watcher_state = app_state.clone();
    tokio::spawn(async move {
        let mut ticker = interval(Duration::from_millis(1500));
        let mut tracker = scanner::init_session_change_tracker();
        // Bản streams đã phát gần nhất (JSON) để chỉ phát `streams:update` khi có thay đổi
        let mut last_streams: Option<String> = None;
        loop {
            ticker.tick().await;
            // Lượt đã nhận lại mà tiến trình đã kết thúc: đóng stream và làm mới session
            for cid in chat::recovery::reconcile_adopted_turns(&watcher_state) {
                watcher_state.broadcast_session_update(&cid);
            }
            let changes = scanner::detect_changed_sessions(&mut tracker);

            for rid in &changes.removed_ids {
                if let Some(ns) = watcher_state.io.of("/") {
                    let _ = ns.emit("session:removed", &json!({ "id": rid }));
                }
            }

            let streams_now = watcher_state
                .active_streams
                .lock()
                .map(|g| g.clone())
                .unwrap_or_default();
            if let Ok(serialized) = serde_json::to_string(&streams_now) {
                if last_streams.as_deref() != Some(serialized.as_str()) {
                    last_streams = Some(serialized);
                    if let Some(ns) = watcher_state.io.of("/") {
                        let _ = ns.emit("streams:update", &json!({ "activeStreams": streams_now }));
                    }
                }
            }

            if !changes.changed_sessions.is_empty() {
                let streams = watcher_state
                    .active_streams
                    .lock()
                    .map(|g| g.clone())
                    .unwrap_or_default();
                for sid in changes.changed_sessions {
                    if let Some(session) = scanner::get_single_session_with_streams(&sid, &streams)
                    {
                        if let Ok(val) = serde_json::to_value(&session) {
                            if let Some(ns) = watcher_state.io.of("/") {
                                let _ = ns.emit("session:update", &val);
                            }
                        }
                    }
                }
            }

            if changes.projects_changed {
                watcher_state.broadcast_projects_update();
            }
        }
    });

    // Watcher quota: định kỳ hỏi daemon, chỉ phát `quotas:update` khi số liệu thực sự thay đổi
    let quota_state = app_state.clone();
    tokio::spawn(async move {
        let mut ticker = interval(Duration::from_secs(15));
        loop {
            ticker.tick().await;
            quota_state.spawn_quotas_update(false, false);
        }
    });

    // Dọn phiên terminal SSH không được dùng quá lâu
    tokio::spawn(async {
        let mut ticker = interval(Duration::from_secs(600));
        loop {
            ticker.tick().await;
            let closed = crate::ssh::terminal::reap_idle();
            if closed > 0 {
                tracing::info!("Đã đóng {closed} phiên SSH không hoạt động");
            }
            let closed_lsp = lsp::reap_idle().await;
            if closed_lsp > 0 {
                tracing::info!("Đã dừng {closed_lsp} tiến trình LSP không hoạt động");
            }
            let closed_docker = crate::docker::sessions::reap_idle().await;
            if closed_docker > 0 {
                tracing::info!("Đã đóng {closed_docker} phiên Docker không hoạt động");
            }
        }
    });

    let app = api::router()
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
    println!("⚡ Socket.IO Realtime Events: session:update, sessions:list, meta:update, streams:update, chat:stream");
    println!("📂 File Server API: /api/files/list & /api/files/download");
    println!("🔔 System Tray: Biểu tượng khay hệ thống hiển thị logo Mướp Agent");
    println!("==============================================================");

    // Khởi chạy biểu tượng System Tray nền (StatusNotifierItem)
    crate::infra::tray::spawn_system_tray();

    // Phiên Docker của lần chạy trước (ControlMaster còn sót) đã mất theo tiến trình cũ: dọn đi
    crate::docker::sessions::cleanup_stale();

    let listener = tokio::net::TcpListener::bind(addr)
        .await
        .expect("Không thể bind cổng 8787");
    axum::serve(listener, app).await.unwrap();
}
