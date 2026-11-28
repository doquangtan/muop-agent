//! Tiến trình GStreamer: đọc màn hình (PipeWire), hạ xuống 720p, mã hoá JPEG từng khung.
//!
//! Đầu ra stdout là các khung JPEG nối liền (tách bởi `jpeg::JpegSplitter`). Khung được đăng vào
//! `FrameHub` và client lấy qua HTTP (`/api/screen/frame`). JPEG chạy được trên mọi trình duyệt và
//! không cần thư viện giải mã video: web, desktop và mobile dùng chung một đường.

use std::os::fd::{AsRawFd, OwnedFd};
use std::process::Stdio;
use std::sync::Arc;
use tokio::io::AsyncReadExt;
use tokio::process::{Child, ChildStdout, Command};

use super::frames::FrameHub;
use super::jpeg::JpegSplitter;

/// Chiều cao khung hình đầu ra. Chiều rộng giữ nguyên tỉ lệ.
pub const TARGET_HEIGHT: u32 = 720;
/// Số khung hình tối đa mỗi giây. Màn hình tĩnh không tốn băng thông nhờ bỏ khung trùng.
pub const MAX_FPS: u32 = 10;
/// Chất lượng JPEG (0–100). 60 cho khung chữ/giao diện ~30 KB ở 720p.
pub const JPEG_QUALITY: u32 = 60;

/// Kích thước khung đầu ra: hạ về cao [`TARGET_HEIGHT`] và giữ tỉ lệ gốc (không phóng to).
/// Hai cạnh làm tròn xuống bội số của 16 (kích thước macroblock, giữ thói quen của bản H.264 cũ).
/// JPEG không cần bội số 16, nhưng không có lý do để đổi kích thước đã chạy ổn định.
pub fn output_size(src_w: u32, src_h: u32) -> (u32, u32) {
    if src_w == 0 || src_h == 0 {
        // Không rõ kích thước nguồn: dùng 16:9
        return (TARGET_HEIGHT * 16 / 9, TARGET_HEIGHT);
    }
    if src_h <= TARGET_HEIGHT {
        return (align16(src_w), align16(src_h));
    }
    let w = (src_w as u64 * TARGET_HEIGHT as u64 / src_h as u64) as u32;
    (align16(w), align16(TARGET_HEIGHT))
}

/// Làm tròn xuống bội số của 16, tối thiểu 16
fn align16(v: u32) -> u32 {
    (v & !15).max(16)
}

/// Nguồn PipeWire qua fd đã mở bởi portal
pub fn pipewire_source(fd: i32, node_id: u32) -> Vec<String> {
    vec![
        "pipewiresrc".to_string(),
        format!("fd={fd}"),
        format!("path={node_id}"),
        "do-timestamp=true".to_string(),
    ]
}

/// Dựng dòng lệnh GStreamer: nguồn → 720p → JPEG → stdout.
pub fn pipeline_args(source: &[String], out_w: u32, out_h: u32) -> Vec<String> {
    let mut args = vec!["-q".to_string()];
    args.extend(source.iter().cloned());
    let tail = [
        "!".to_string(),
        // Caps framerate cố định: nguồn PipeWire có framerate biến thiên. Khung thừa bị bỏ.
        "videorate".to_string(),
        "!".to_string(),
        format!("video/x-raw,framerate={MAX_FPS}/1"),
        "!".to_string(),
        "videoconvert".to_string(),
        "!".to_string(),
        "videoscale".to_string(),
        "!".to_string(),
        // I420 (chroma 4:2:0): jpegenc giữ nguyên cách lấy mẫu của đầu vào, nên file nhỏ hơn ~2 lần so với 4:4:4
        format!("video/x-raw,format=I420,width={out_w},height={out_h}"),
        "!".to_string(),
        // Mỗi tham số là một đối số riêng: gst-launch không tách chuỗi có khoảng trắng
        "jpegenc".to_string(),
        format!("quality={JPEG_QUALITY}"),
        "!".to_string(),
        "fdsink".to_string(),
        "fd=1".to_string(),
    ];
    args.extend(tail);
    args
}

/// Chạy pipeline. Nếu có `fd` (nguồn PipeWire) thì fd được để mở trong tiến trình con.
pub fn spawn(args: Vec<String>, fd: Option<OwnedFd>) -> Result<(Child, ChildStdout), String> {
    let raw = fd.as_ref().map(|f| f.as_raw_fd());
    let mut cmd = Command::new("gst-launch-1.0");
    cmd.args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    if let Some(raw) = raw {
        // SAFETY: closure chỉ gọi fcntl (an toàn sau fork), không cấp phát bộ nhớ
        unsafe {
            cmd.pre_exec(move || {
                let flags = libc::fcntl(raw, libc::F_GETFD);
                if flags < 0 || libc::fcntl(raw, libc::F_SETFD, flags & !libc::FD_CLOEXEC) < 0 {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }
    }
    let mut child = cmd
        .spawn()
        .map_err(|e| format!("Không chạy được gst-launch-1.0: {e}"))?;
    // Tiến trình con đã có bản sao của fd; bản của tiến trình này có thể đóng
    drop(fd);
    if let Some(stderr) = child.stderr.take() {
        tokio::spawn(async move {
            use tokio::io::{AsyncBufReadExt, BufReader};
            let mut lines = BufReader::new(stderr).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                tracing::warn!("gst-launch: {line}");
            }
        });
    }
    let stdout = child
        .stdout
        .take()
        .ok_or("Không lấy được stdout của GStreamer")?;
    Ok((child, stdout))
}

/// Đọc khung JPEG từ stdout của tiến trình quay và đăng vào hub tới khi luồng kết thúc.
pub async fn read_frames(mut stdout: ChildStdout, hub: Arc<FrameHub>) {
    let mut splitter = JpegSplitter::default();
    let mut chunk = vec![0u8; 64 * 1024];
    loop {
        match stdout.read(&mut chunk).await {
            Ok(0) | Err(_) => break,
            Ok(n) => {
                for jpeg in splitter.push(&chunk[..n]) {
                    hub.publish(jpeg);
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn output_size_keeps_aspect_and_caps_height() {
        assert_eq!(output_size(1920, 1080), (1280, 720));
        assert_eq!(output_size(2560, 1600), (1152, 720));
        assert_eq!(output_size(3840, 2160), (1280, 720));
        assert_eq!(output_size(2560, 1080), (1696, 720));
        assert_eq!(output_size(1280, 600), (1280, 592));
        assert_eq!(output_size(0, 0), (1280, 720));
        for (w, h) in [(2560, 1080), (3440, 1440), (1366, 768), (1921, 1081)] {
            let (ow, oh) = output_size(w, h);
            assert!(ow % 16 == 0 && oh % 16 == 0, "{w}x{h} -> {ow}x{oh}");
        }
    }

    #[test]
    fn pipeline_outputs_jpeg_at_requested_size() {
        let args = pipeline_args(&pipewire_source(17, 252), 1280, 720);
        assert!(args.contains(&"video/x-raw,format=I420,width=1280,height=720".to_string()));
        assert!(args.contains(&"jpegenc".to_string()));
        assert!(args.contains(&format!("quality={JPEG_QUALITY}")));
        assert!(args.contains(&format!("video/x-raw,framerate={MAX_FPS}/1")));
        assert!(!args.iter().any(|a| a.contains("x264") || a.contains("rtp")));
    }
}
