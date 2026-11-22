//! Dọn tiến trình agy do server mở ở lần chạy trước (hub, terminal đăng nhập).

/// Biến môi trường đánh dấu TUI do server mở (đặt khi spawn, đọc khi dọn)
pub const MARK_ENV: &str = "MUOP_AGY_HOST";

/// Tắt TUI do server mở ở lần chạy trước (đã mồ côi khi server thoát). Chỉ tiến trình cùng user
/// và có đánh dấu [`MARK_ENV`] mới bị tắt; agy do người dùng tự mở không có đánh dấu nên được giữ.
pub fn cleanup_stale() {
    use std::os::unix::fs::MetadataExt;
    // SAFETY: getuid không có điều kiện nào và không thể lỗi
    let me = unsafe { libc::getuid() };
    let needle = format!("{MARK_ENV}=1");
    let Ok(entries) = std::fs::read_dir("/proc") else {
        return;
    };
    for entry in entries.flatten() {
        let Some(pid) = entry
            .file_name()
            .to_str()
            .and_then(|s| s.parse::<libc::pid_t>().ok())
        else {
            continue;
        };
        let dir = entry.path();
        match std::fs::metadata(&dir) {
            Ok(meta) if meta.uid() == me => {}
            _ => continue,
        }
        let Ok(env) = std::fs::read(dir.join("environ")) else {
            continue;
        };
        if env.split(|b| *b == 0).any(|kv| kv == needle.as_bytes()) {
            // SAFETY: gửi SIGTERM tới tiến trình con do server tạo ra ở lần chạy trước
            unsafe {
                libc::kill(pid, libc::SIGTERM);
            }
        }
    }
}
