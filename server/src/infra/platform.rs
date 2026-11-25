//! Biến điều kiện theo hệ điều hành của máy đang chạy server.
//!
//! Server chạy đầy đủ trên Linux (systemd, FUSE, `/proc`, StatusNotifier tray) và chạy được trên macOS
//! với một số tính năng bị bỏ qua (xem từng chỗ dùng). Dùng các hằng số `cfg!` này để nhánh rẽ
//! trong code thường; chỉ dùng `#[cfg(...)]` khi một crate hoặc API không biên dịch được trên nền tảng kia.

/// Máy đang chạy server là macOS
pub const IS_MACOS: bool = cfg!(target_os = "macos");

/// Máy đang chạy server là Linux
pub const IS_LINUX: bool = cfg!(target_os = "linux");

/// Tên nền tảng gửi xuống client (`linux` | `macos` | `other`), để màn Khởi tạo chọn nội dung hiển thị
pub fn name() -> &'static str {
    if IS_MACOS {
        "macos"
    } else if IS_LINUX {
        "linux"
    } else {
        "other"
    }
}
