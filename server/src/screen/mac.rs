//! Quay màn hình trên macOS: ffmpeg (avfoundation) chụp màn hình, mã hoá H.264 và gửi RTP qua UDP
//! tới một cổng trên 127.0.0.1. Server nhận từng gói RTP và đẩy vào cùng hub RTSP với luồng Linux.
//!
//! Quyền "Ghi màn hình" (Screen Recording) được gắn với app Mướp Agents (tiến trình cha của server),
//! nên người dùng phải bật một lần trong System Settings rồi mở lại app.

use std::process::Stdio;
use std::sync::Arc;
use tokio::net::UdpSocket;
use tokio::process::{Child, Command};
use tokio::sync::broadcast;

use super::capture::{BITRATE_KBPS, MAX_FPS, RTP_PAYLOAD_TYPE, TARGET_HEIGHT};
use super::rtsp::{Packet, RtspHub};

/// FPS của thiết bị chụp; khung thừa được lọc xuống `MAX_FPS` trong bộ lọc `fps`
const CAPTURE_INPUT_FPS: u32 = 30;

pub const PERMISSION_MSG: &str =
    "Chưa cấp quyền Ghi màn hình cho Mướp Agents: vào System Settings → \
     Privacy & Security → Screen Recording, bật Mướp Agents rồi mở lại app";

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

/// Tham số ffmpeg: chụp màn hình `screen`, scale về `out_h`, mã hoá H.264 (baseline), gửi RTP tới `udp_port`.
/// `repeat-headers` và GOP bằng một giây để client vào giữa chừng nhận SPS/PPS và khung khoá sớm.
pub fn ffmpeg_args(screen: u32, out_h: u32, udp_port: u16) -> Vec<String> {
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
        s("libx264"),
        s("-preset"),
        s("veryfast"),
        s("-tune"),
        s("zerolatency"),
        s("-profile:v"),
        s("baseline"),
        s("-pix_fmt"),
        s("yuv420p"),
        s("-b:v"),
        format!("{BITRATE_KBPS}k"),
        s("-maxrate"),
        format!("{BITRATE_KBPS}k"),
        s("-bufsize"),
        format!("{}k", BITRATE_KBPS * 2),
        s("-g"),
        MAX_FPS.to_string(),
        s("-keyint_min"),
        MAX_FPS.to_string(),
        s("-sc_threshold"),
        s("0"),
        s("-x264-params"),
        s("repeat-headers=1"),
        s("-f"),
        s("rtp"),
        s("-payload_type"),
        RTP_PAYLOAD_TYPE.to_string(),
        format!("rtp://127.0.0.1:{udp_port}?pkt_size=1200"),
    ]
}

/// Đọc gói RTP từ UDP và đẩy vào hub. Mỗi datagram là một gói RTP đầy đủ (không cần tách khung).
pub async fn read_packets(socket: UdpSocket, out: broadcast::Sender<Packet>, hub: Arc<RtspHub>) {
    let mut buf = vec![0u8; 2048];
    loop {
        match socket.recv_from(&mut buf).await {
            Ok((n, _)) => {
                let packet = buf[..n].to_vec();
                hub.observe(&packet);
                // Không có client nào thì send trả lỗi: bỏ qua, luồng vẫn chạy
                let _ = out.send(Arc::new(packet));
            }
            Err(_) => break,
        }
    }
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

/// Tiến trình ffmpeg đang chụp và socket nhận RTP
pub struct Capture {
    pub child: Child,
    pub socket: UdpSocket,
}

/// Bật chụp màn hình. Trả lỗi có nội dung hiển thị cho người dùng nếu chưa có quyền, thiếu ffmpeg...
pub async fn start(out_h: u32) -> Result<Capture, String> {
    let ffmpeg = crate::infra::tools::require("ffmpeg")?;
    if !screen_access_granted() {
        request_screen_access();
        return Err(PERMISSION_MSG.into());
    }
    let screen = find_screen(&ffmpeg).await?;
    // Giữ socket để nhận RTP; cổng cấp cho ffmpeg chính là cổng của socket này
    let socket = UdpSocket::bind("127.0.0.1:0")
        .await
        .map_err(|e| format!("Không mở được cổng UDP nhận hình: {e}"))?;
    let port = socket
        .local_addr()
        .map_err(|e| format!("Không đọc được cổng UDP: {e}"))?
        .port();
    let mut child = Command::new(&ffmpeg)
        .args(ffmpeg_args(screen, out_h, port))
        .stdin(Stdio::null())
        .stdout(Stdio::null())
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
    Ok(Capture { child, socket })
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
    fn args_scale_to_height_and_send_rtp_to_port() {
        let args = ffmpeg_args(2, 720, 5004);
        assert!(args.contains(&"2:none".to_string()));
        assert!(args.iter().any(|a| a == "fps=24,scale=-2:720"));
        assert!(args.contains(&"libx264".to_string()));
        assert!(args.contains(&"repeat-headers=1".to_string()));
        assert_eq!(
            args.last().map(String::as_str),
            Some("rtp://127.0.0.1:5004?pkt_size=1200")
        );
    }

    #[tokio::test]
    async fn forwards_udp_rtp_packets_to_hub_subscribers() {
        let hub = RtspHub::new();
        let tx = hub.go_live();
        let mut rx = tx.subscribe();
        let listener = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let reader = tokio::spawn(read_packets(listener, tx, hub.clone()));

        let sender = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        // RTP tối thiểu: version 2, payload type 96, rồi một NAL IDR (0x65)
        let packet = [0x80u8, 0x60, 0, 1, 0, 0, 0, 2, 0, 0, 0, 3, 0x65, 1, 2, 3];
        sender.send_to(&packet, ("127.0.0.1", port)).await.unwrap();
        let got = tokio::time::timeout(std::time::Duration::from_secs(2), rx.recv())
            .await
            .expect("gói RTP tới hub")
            .unwrap();
        assert_eq!(got.as_slice(), &packet);
        reader.abort();
    }
}
