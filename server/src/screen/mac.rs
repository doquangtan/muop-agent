//! Quay màn hình trên macOS: ffmpeg (avfoundation) chụp màn hình, scale và mã hoá từng khung JPEG
//! ra stdout. Server tách khung (`jpeg.rs`) và đăng vào `FrameHub` như luồng Linux.
//!
//! Quyền "Ghi màn hình" (Screen Recording) gắn với chính binary máy chủ. Máy chủ được đóng gói trong
//! app bundle `Muop Agents Server.app` (bundle id `vn.muop.agent-server`) để macOS hiện đúng mục này trong
//! System Settings; máy chủ chạy nền nên không thể tự thêm vào danh sách, phải yêu cầu quyền khi khởi động.

use std::process::Stdio;
use tokio::process::{Child, ChildStdout, Command};

use super::capture::{MAX_FPS, TARGET_HEIGHT};

/// FPS của thiết bị chụp; khung thừa được lọc xuống `MAX_FPS` trong bộ lọc `fps`
const CAPTURE_INPUT_FPS: u32 = 30;

pub const PERMISSION_MSG: &str =
    "Chưa cấp quyền Ghi màn hình cho \"Mướp Agents Server\": vào Cài đặt hệ thống → \
     Quyền riêng tư & Bảo mật → Ghi màn hình, bật \"Mướp Agents Server\", rồi bấm Quay màn hình lại \
     (nếu vẫn lỗi, khởi động lại máy chủ: launchctl kickstart -k gui/$(id -u)/vn.muop.agent-server)";

/// Chỉ số màn hình trong danh sách thiết bị avfoundation (dòng `[N] Capture screen M`).
/// Hàm thuần để kiểm thử; danh sách là đầu ra stderr của `ffmpeg -f avfoundation -list_devices true -i ""`.
pub fn parse_screen_index(listing: &str) -> Option<u32> {
    for line in listing.lines() {
        if let Some(pos) = line.find("Capture screen") {
            let before = &line[..pos];
            let open = before.rfind('[')?;
            let close = open + before[open..].find(']')?;
            return before[open + 1..close].trim().parse().ok();
        }
    }
    None
}

/// Tham số ffmpeg: chụp màn hình `screen`, giảm tốc độ khung về `MAX_FPS`, scale về `out_h`,
/// xuất từng khung JPEG (`image2pipe`) ra stdout. `-q:v` 6 tương đương chất lượng ~75 của libjpeg.
pub fn ffmpeg_args(screen: u32, out_h: u32) -> Vec<String> {
    let s = |v: &str| v.to_string();
    vec![
        s("-hide_banner"),
        s("-loglevel"),
        s("warning"),
        s("-f"),
        s("avfoundation"),
        s("-framerate"),
        CAPTURE_INPUT_FPS.to_string(),
        s("-capture_cursor"),
        s("1"),
        s("-i"),
        format!("{screen}:none"),
        s("-an"),
        s("-vf"),
        format!("fps={MAX_FPS},scale=-2:{out_h}"),
        s("-c:v"),
        s("mjpeg"),
        // 4:2:0 như trên Linux: file nhỏ hơn đáng kể so với 4:4:4
        s("-pix_fmt"),
        s("yuvj420p"),
        s("-q:v"),
        s("6"),
        s("-f"),
        s("image2pipe"),
        s("pipe:1"),
    ]
}

#[cfg(target_os = "macos")]
#[link(name = "CoreGraphics", kind = "framework")]
extern "C" {
    fn CGPreflightScreenCaptureAccess() -> bool;
    fn CGRequestScreenCaptureAccess() -> bool;
}

/// Đã được cấp quyền Ghi màn hình chưa (macOS). Nơi khác không cần quyền.
#[cfg(target_os = "macos")]
pub fn screen_access_granted() -> bool {
    // SAFETY: hàm CoreGraphics không nhận tham số và không có điều kiện đầu vào
    unsafe { CGPreflightScreenCaptureAccess() }
}

#[cfg(not(target_os = "macos"))]
pub fn screen_access_granted() -> bool {
    true
}

/// Yêu cầu quyền: macOS hiện hộp thoại (lần đầu) hoặc chỉ ghi nhận (đã từ chối trước đó)
#[cfg(target_os = "macos")]
pub fn request_screen_access() {
    // SAFETY: như trên
    unsafe {
        CGRequestScreenCaptureAccess();
    }
}

#[cfg(not(target_os = "macos"))]
pub fn request_screen_access() {}

/// Mở trang Ghi màn hình trong System Settings. Máy chủ chạy trong phiên GUI (LaunchAgent gui/<uid>)
/// nên `open` hiện được cửa sổ cài đặt.
#[cfg(target_os = "macos")]
pub fn open_screen_recording_settings() {
    const URL: &str =
        "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture";
    if let Err(e) = std::process::Command::new("/usr/bin/open").arg(URL).spawn() {
        tracing::warn!("Không mở được System Settings (Ghi màn hình): {e}");
    }
}

#[cfg(not(target_os = "macos"))]
pub fn open_screen_recording_settings() {}

/// Khi máy chủ khởi động (sau khi đăng nhập): nếu chưa có quyền thì hiện hộp thoại yêu cầu ngay,
/// vì máy chủ chạy nền và người dùng không có nút nào để kích hoạt yêu cầu quyền.
pub fn prompt_screen_access_at_startup() {
    if !screen_access_granted() {
        tracing::info!("📺 Chưa có quyền Ghi màn hình: yêu cầu quyền cho \"Mướp Agents Server\"");
        request_screen_access();
    }
}

/// Lấy chỉ số màn hình đầu tiên từ ffmpeg (danh sách thiết bị được in ra stderr)
async fn find_screen(ffmpeg: &str) -> Result<u32, String> {
    let out = Command::new(ffmpeg)
        .args([
            "-hide_banner",
            "-f",
            "avfoundation",
            "-list_devices",
            "true",
            "-i",
            "",
        ])
        .output()
        .await
        .map_err(|e| format!("Không chạy được ffmpeg: {e}"))?;
    let listing = String::from_utf8_lossy(&out.stderr);
    parse_screen_index(&listing)
        .ok_or_else(|| "Không tìm thấy màn hình để quay (avfoundation)".into())
}

/// Bật chụp màn hình. Trả lỗi có nội dung hiển thị cho người dùng nếu chưa có quyền, thiếu ffmpeg...
/// Khung JPEG đọc từ `stdout` của tiến trình (xem `capture::read_frames`).
pub async fn start() -> Result<(Child, ChildStdout), String> {
    let ffmpeg = crate::infra::tools::require("ffmpeg")?;
    if !screen_access_granted() {
        // Yêu cầu quyền và mở đúng trang System Settings, để người dùng bật ngay từ lần bấm này
        request_screen_access();
        open_screen_recording_settings();
        return Err(PERMISSION_MSG.into());
    }
    let screen = find_screen(&ffmpeg).await?;
    let mut child = Command::new(&ffmpeg)
        .args(ffmpeg_args(screen, OUTPUT_HEIGHT))
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .map_err(|e| format!("Không chạy được ffmpeg: {e}"))?;
    if let Some(stderr) = child.stderr.take() {
        use tokio::io::{AsyncBufReadExt, BufReader};
        tokio::spawn(async move {
            let mut lines = BufReader::new(stderr).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                tracing::warn!("ffmpeg: {line}");
            }
        });
    }
    let stdout = child
        .stdout
        .take()
        .ok_or("Không lấy được stdout của ffmpeg")?;
    Ok((child, stdout))
}

/// Chiều cao đầu ra mặc định (giống luồng Linux)
pub const OUTPUT_HEIGHT: u32 = TARGET_HEIGHT;

#[cfg(test)]
mod tests {
    use super::*;

    const LISTING: &str = "[AVFoundation indev @ 0x7f8] AVFoundation video devices:\n\
        [AVFoundation indev @ 0x7f8] [0] FaceTime HD Camera\n\
        [AVFoundation indev @ 0x7f8] [2] Capture screen 0\n\
        [AVFoundation indev @ 0x7f8] [3] Capture screen 1\n\
        [AVFoundation indev @ 0x7f8] AVFoundation audio devices:\n";

    #[test]
    fn picks_first_screen_index() {
        assert_eq!(parse_screen_index(LISTING), Some(2));
    }

    #[test]
    fn no_screen_gives_none() {
        assert_eq!(
            parse_screen_index("[AVFoundation indev @ 0x1] [0] FaceTime HD Camera"),
            None
        );
    }

    #[test]
    fn args_scale_to_height_and_write_jpeg_to_stdout() {
        let args = ffmpeg_args(2, 720);
        assert!(args.contains(&"2:none".to_string()));
        assert!(args.iter().any(|a| a == "fps=10,scale=-2:720"));
        assert!(args.contains(&"mjpeg".to_string()));
        assert!(args.contains(&"image2pipe".to_string()));
        assert_eq!(args.last().map(String::as_str), Some("pipe:1"));
        assert!(!args.iter().any(|a| a.contains("264") || a == "rtp"));
    }
}
