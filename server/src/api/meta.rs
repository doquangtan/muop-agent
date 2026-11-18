use crate::chat::AppState;
use crate::scanner;
use axum::{extract::State, response::IntoResponse, Json};
use chrono::Utc;
use serde_json::json;

pub async fn handle_ping() -> impl IntoResponse {
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

/// Metadata chung (project, model, máy chủ): `GET /api/meta`
pub async fn handle_meta(State(state): State<AppState>) -> impl IntoResponse {
    let streams = state
        .active_streams
        .lock()
        .map(|g| g.clone())
        .unwrap_or_default();
    let meta = tokio::task::spawn_blocking(move || {
        let sessions = scanner::scan_all_sessions(&streams, None, 500);
        scanner::build_meta(&sessions)
    })
    .await;
    match meta {
        Ok(m) => Json(serde_json::to_value(&m).unwrap_or_default()),
        Err(_) => Json(json!({ "error": "meta không sẵn sàng" })),
    }
}

/// Các lượt chat đang chạy: `GET /api/streams`
pub async fn handle_streams(State(state): State<AppState>) -> impl IntoResponse {
    let streams = state
        .active_streams
        .lock()
        .map(|g| g.clone())
        .unwrap_or_default();
    Json(json!({ "activeStreams": streams }))
}
