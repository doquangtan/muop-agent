//! Tiến trình GStreamer: đọc màn hình (PipeWire), hạ xuống 720p, mã hoá H.264 và đóng gói RTP.
//!
//! Đầu ra stdout là các gói RTP nối liền theo khung RFC 4571 (2 byte độ dài big-endian + gói RTP).
//! Khung này trùng với khung interleaved của RTSP, nên RTSP server chỉ cần thêm `$` + kênh.

use std::os::fd::{AsRawFd, OwnedFd};
use std::process::Stdio;
use tokio::process::{Child, ChildStdout, Command};

/// Chiều cao khung hình đầu ra. Chiều rộng giữ nguyên tỉ lệ.
pub const TARGET_HEIGHT: u32 = 720;
/// Số khung hình tối đa mỗi giây (khung thừa bị bỏ, không nhân đôi)
pub const MAX_FPS: u32 = 24;
/// Bitrate đích của H.264 (kbps)
pub const BITRATE_KBPS: u32 = 3000;
/// Khoảng cách giữa các khung khoá (số khung, ~1 giây). Client vào giữa chừng chờ tới khung khoá kế tiếp.
pub const KEYFRAME_INTERVAL: u32 = 24;
/// Payload type RTP cho H.264 (động, theo SDP của RTSP server)
pub const RTP_PAYLOAD_TYPE: u8 = 96;

/// Tách các gói RTP từ luồng byte RFC 4571 (độ dài 2 byte big-endian + gói).
#[derive(Default)]
pub struct RtpSplitter {
    buf: Vec<u8>,
}

impl RtpSplitter {
    /// Nạp thêm dữ liệu, trả về các gói RTP đã đủ.
    pub fn push(&mut self, data: &[u8]) -> Vec<Vec<u8>> {
        self.buf.extend_from_slice(data);
        let mut packets = Vec::new();
        let mut pos = 0;
        while self.buf.len() - pos >= 2 {
            let len = u16::from_be_bytes([self.buf[pos], self.buf[pos + 1]]) as usize;
            if self.buf.len() - pos - 2 < len {
                break;
            }
            packets.push(self.buf[pos + 2..pos + 2 + len].to_vec());
            pos += 2 + len;
        }
        self.buf.drain(..pos);
        packets
    }
}

/// Kích thước khung đầu ra: hạ về cao [`TARGET_HEIGHT`] và giữ tỉ lệ gốc (không phóng to).
/// Hai cạnh làm tròn xuống bội số của 16 (kích thước macroblock): decoder phần cứng trên Android
/// (MediaCodec) từ chối luồng có chiều rộng lẻ như 1706 với lỗi "Could not open codec".
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

/// Dựng dòng lệnh GStreamer: nguồn → 720p → H.264 → RTP (RFC 4571) → stdout.
pub fn pipeline_args(source: &[String], out_w: u32, out_h: u32) -> Vec<String> {
    let mut args = vec!["-q".to_string()];
    args.extend(source.iter().cloned());
    let tail = [
        "!".to_string(),
        // Caps framerate cố định: nguồn PipeWire có framerate biến thiên, max-rate không giới hạn được.
        // Khung thừa bị bỏ, khung thiếu được lặp lại để luồng ổn định (khung lặp nén rất nhỏ)
        "videorate".to_string(),
        "!".to_string(),
        format!("video/x-raw,framerate={MAX_FPS}/1"),
        "!".to_string(),
        "videoconvert".to_string(),
        "!".to_string(),
        "videoscale".to_string(),
        "!".to_string(),
        // I420: định dạng mà H.264 baseline/main đều hỗ trợ (tránh 4:4:4 từ nguồn PipeWire)
        format!("video/x-raw,format=I420,width={out_w},height={out_h}"),
        "!".to_string(),
        "x264enc".to_string(),
        "tune=zerolatency".to_string(),
        "speed-preset=ultrafast".to_string(),
        format!("bitrate={BITRATE_KBPS}"),
        format!("key-int-max={KEYFRAME_INTERVAL}"),
        "!".to_string(),
        "h264parse".to_string(),
        "!".to_string(),
        // byte-stream: SPS/PPS và khung khoá nằm trong luồng, rtph264pay chèn lại đúng vị trí.
        // Thiếu caps này x264enc xuất AVC (length-prefixed) và client không giải mã được.
        "video/x-h264,stream-format=byte-stream,alignment=au".to_string(),
        "!".to_string(),
        // config-interval=1: lặp SPS/PPS trong mỗi khung khoá để client vào giữa chừng vẫn giải mã được
        format!("rtph264pay"),
        "config-interval=1".to_string(),
        format!("pt={RTP_PAYLOAD_TYPE}"),
        "!".to_string(),
        "rtpstreampay".to_string(),
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

#[cfg(test)]
mod tests {
    use super::*;

    fn framed(packets: &[&[u8]]) -> Vec<u8> {
        let mut out = Vec::new();
        for p in packets {
            out.extend_from_slice(&(p.len() as u16).to_be_bytes());
            out.extend_from_slice(p);
        }
        out
    }

    #[test]
    fn output_size_keeps_aspect_and_caps_height() {
        assert_eq!(output_size(1920, 1080), (1280, 720));
        assert_eq!(output_size(2560, 1600), (1152, 720));
        assert_eq!(output_size(3840, 2160), (1280, 720));
        // Chiều rộng 1706 (2560x1080 hạ về 720p) làm tròn về bội số của 16
        assert_eq!(output_size(2560, 1080), (1696, 720));
        // Nguồn nhỏ hơn 720p không bị phóng to, chỉ căn bội số 16
        assert_eq!(output_size(1280, 600), (1280, 592));
        assert_eq!(output_size(0, 0), (1280, 720));
        for (w, h) in [(2560, 1080), (3440, 1440), (1366, 768), (1921, 1081)] {
            let (ow, oh) = output_size(w, h);
            assert!(ow % 16 == 0 && oh % 16 == 0, "{w}x{h} -> {ow}x{oh}");
        }
    }

    #[test]
    fn splits_back_to_back_packets() {
        let mut s = RtpSplitter::default();
        let data = framed(&[&[0x80, 0x60, 1], &[0x80, 0x60, 2, 3]]);
        assert_eq!(
            s.push(&data),
            vec![vec![0x80, 0x60, 1], vec![0x80, 0x60, 2, 3]]
        );
    }

    #[test]
    fn joins_packet_split_across_reads() {
        let mut s = RtpSplitter::default();
        let data = framed(&[&[9, 8, 7, 6, 5]]);
        // Tách giữa phần độ dài và phần nội dung
        assert!(s.push(&data[..1]).is_empty());
        assert!(s.push(&data[1..4]).is_empty());
        assert_eq!(s.push(&data[4..]), vec![vec![9, 8, 7, 6, 5]]);
    }

    #[test]
    fn pipeline_outputs_h264_rtp_at_requested_size() {
        let args = pipeline_args(&pipewire_source(17, 252), 1280, 720);
        assert!(args.contains(&"video/x-raw,format=I420,width=1280,height=720".to_string()));
        assert!(args.contains(&"rtpstreampay".to_string()));
        assert!(args.contains(&format!("video/x-raw,framerate={MAX_FPS}/1")));
    }
}
