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

/// Trả về hệ điều hành phần bộ nhớ đã giải phóng nhưng glibc còn giữ trong các arena của thread.
/// Sau một lần quét lớn (parse nhiều transcript) phần này có thể lên hàng trăm MB; trên macOS không cần.
pub fn release_unused_memory() {
    #[cfg(target_os = "linux")]
    // SAFETY: malloc_trim chỉ trả bộ nhớ trống, không ảnh hưởng tới con trỏ đang dùng
    unsafe {
        libc::malloc_trim(0);
    }
}

/// Đặt `FD_CLOEXEC` cho fd của `openpty`. Không có cờ này, shell và mọi tiến trình con khác
/// (agy, claude...) thừa hưởng fd master; PTY không bao giờ bị hangup khi server chết nên
/// shell và lệnh đang chạy trong đó sống tiếp thành tiến trình mồ côi.
pub fn set_cloexec(fd: i32) {
    // SAFETY: fcntl chỉ đổi cờ của fd do chính server vừa mở
    unsafe {
        let flags = libc::fcntl(fd, libc::F_GETFD);
        if flags >= 0 {
            libc::fcntl(fd, libc::F_SETFD, flags | libc::FD_CLOEXEC);
        }
    }
}
