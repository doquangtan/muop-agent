//! Điều khiển quay màn hình và tắt server qua REST: menu bar của app macOS dùng; tray Linux gọi trực tiếp `ScreenManager`.

use crate::chat::AppState;
use crate::screen::ScreenStatus;
use axum::{
    extract::{Query, State},
    http::{header, HeaderValue, StatusCode},
    response::{IntoResponse, Response},
    Json,
};
use serde::Deserialize;
use std::time::Duration;

/// Thời gian đợi tối đa của một lần long-poll (ms)
const MAX_FRAME_WAIT_MS: u64 = 10_000;
const DEFAULT_FRAME_WAIT_MS: u64 = 2_500;

#[derive(Deserialize)]
pub struct FrameQuery {
    /// Số thứ tự khung client đã có; server chỉ trả khung mới hơn
    #[serde(default)]
    pub after: u64,
    /// Thời gian đợi (ms) nếu chưa có khung mới
    pub wait: Option<u64>,
}

/// Khung JPEG mới nhất có `seq > after`. `200` kèm `X-Frame-Seq`; `204` nếu hết thời gian đợi
/// (không có khung mới, ví dụ màn hình tĩnh hoặc luồng đang tắt). Client lặp lại với `after` mới.
pub async fn handle_screen_frame(
    State(st): State<AppState>,
    Query(q): Query<FrameQuery>,
) -> Response {
    let wait_ms = q
        .wait
        .unwrap_or(DEFAULT_FRAME_WAIT_MS)
        .min(MAX_FRAME_WAIT_MS);
    match st
        .screen
        .frames()
        .wait_newer(q.after, Duration::from_millis(wait_ms))
        .await
    {
        Some(frame) => (
            StatusCode::OK,
            [
                (header::CONTENT_TYPE, HeaderValue::from_static("image/jpeg")),
                (header::CACHE_CONTROL, HeaderValue::from_static("no-store")),
                (
                    header::HeaderName::from_static("x-frame-seq"),
                    HeaderValue::from(frame.seq),
                ),
            ],
            frame.jpeg.clone(),
        )
            .into_response(),
        None => StatusCode::NO_CONTENT.into_response(),
    }
}

/// Trạng thái quay màn hình hiện tại
pub async fn handle_screen_status(State(st): State<AppState>) -> Json<ScreenStatus> {
    Json(st.screen.status())
}

/// Bật nếu đang tắt, tắt nếu đang bật. Trả trạng thái ngay (có thể còn `starting`; client hỏi lại).
pub async fn handle_screen_toggle(State(st): State<AppState>) -> Json<ScreenStatus> {
    st.screen.toggle();
    Json(st.screen.status())
}

/// Tắt server theo yêu cầu của menu bar. Trả lời trước, rồi dừng quay màn hình (để ffmpeg con không bị bỏ lại)
/// và thoát mã 0. Client đang kết nối sẽ bị ngắt; mở lại app thì khởi động lại server.
pub async fn handle_server_shutdown(State(st): State<AppState>) -> Json<serde_json::Value> {
    let screen = st.screen.clone();
    tokio::spawn(async move {
        // Chờ để phản hồi HTTP kịp gửi đi trước khi tiến trình thoát
        tokio::time::sleep(Duration::from_millis(300)).await;
        screen.stop().await;
        tracing::info!("🛑 Nhận lệnh dừng server từ menu bar, đang thoát");
        std::process::exit(0);
    });
    Json(serde_json::json!({ "ok": true }))
}
