//! Điều khiển quay màn hình và tắt server qua REST: menu bar của app macOS dùng; tray Linux gọi trực tiếp `ScreenManager`.

use crate::chat::AppState;
use crate::screen::ScreenStatus;
use axum::{extract::State, Json};
use std::time::Duration;

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
