//! Biểu tượng menu bar trên macOS, do MÁY CHỦ khởi chạy (không phải app Flutter).
//!
//! Máy chủ chạy nền bằng LaunchAgent; helper `muop-agent-tray` (AppKit, cạnh binary máy chủ) được
//! khởi chạy từ đây và đi theo máy chủ: helper tự thoát khi máy chủ dừng (mồ côi hoặc không trả lời).
//! Thoát app Flutter không ảnh hưởng đến máy chủ hay biểu tượng này.

use crate::infra::platform::IS_MACOS;
use std::path::PathBuf;
use std::time::Duration;

/// Tên helper cài cạnh binary máy chủ (xem packaging/macos)
const HELPER_NAME: &str = "muop-agent-tray";
const RESTART_MIN: Duration = Duration::from_secs(2);
const RESTART_MAX: Duration = Duration::from_secs(60);

/// Đường dẫn helper: cùng thư mục với binary máy chủ đang chạy
fn helper_path() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?;
    let path = exe.parent()?.join(HELPER_NAME);
    path.is_file().then_some(path)
}

/// Khởi chạy helper menu bar và giữ nó sống cùng máy chủ. Helper thoát thì khởi động lại với độ trễ tăng dần
/// (chạy đủ lâu thì coi như lỗi tạm thời). Không có nút ẩn biểu tượng: icon biến mất vĩnh viễn tới lần khởi động
/// máy chủ sau nên người dùng không tìm lại được. Khi máy chủ tự thoát, helper mồ côi tự thoát theo.
pub fn spawn_menu_bar() {
    if !IS_MACOS {
        return;
    }
    let Some(helper) = helper_path() else {
        tracing::warn!("Không tìm thấy {HELPER_NAME} cạnh máy chủ, bỏ qua biểu tượng menu bar");
        return;
    };
    let port = crate::scanner::listen_port();
    tokio::spawn(async move {
        // Đợi máy chủ nhận kết nối trước: helper hỏi trạng thái qua REST ngay khi khởi động
        tokio::time::sleep(Duration::from_secs(1)).await;
        let mut delay = RESTART_MIN;
        loop {
            let started = std::time::Instant::now();
            let spawned = tokio::process::Command::new(&helper)
                .arg("--port")
                .arg(port.to_string())
                .stdin(std::process::Stdio::null())
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .spawn();
            let mut child = match spawned {
                Ok(child) => child,
                Err(e) => {
                    tracing::warn!("Không chạy được {HELPER_NAME}: {e}");
                    tokio::time::sleep(delay).await;
                    delay = (delay * 2).min(RESTART_MAX);
                    continue;
                }
            };
            tracing::info!("🍎 Đã khởi chạy biểu tượng menu bar ({HELPER_NAME})");
            // Mọi lần thoát đều khởi động lại: helper không còn lối thoát có chủ đích (không có nút ẩn),
            // nên thoát mã 0 thường là macOS yêu cầu quit (Quit & Reopen sau khi cấp quyền) chứ không phải người dùng
            match child.wait().await {
                Ok(status) => tracing::warn!("{HELPER_NAME} thoát ({status}), khởi động lại"),
                Err(e) => tracing::warn!("Không đợi được {HELPER_NAME}: {e}"),
            }
            // Chạy đủ lâu thì coi như lỗi tạm thời: lần sau bắt đầu lại độ trễ nhỏ
            delay = if started.elapsed() > Duration::from_secs(60) {
                RESTART_MIN
            } else {
                (delay * 2).min(RESTART_MAX)
            };
            tokio::time::sleep(delay).await;
        }
    });
}
