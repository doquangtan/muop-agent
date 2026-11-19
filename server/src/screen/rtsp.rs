//! RTSP server phát luồng H.264 màn hình cho nhiều client (VLC, ffplay, mpv...).
//!
//! - Một tiến trình GStreamer mã hoá; mọi client cùng nhận gói RTP qua `broadcast`.
//! - Chỉ RTP over TCP (interleaved, `$` + kênh + độ dài + gói), nên qua được NAT/tường lửa LAN.
//! - Hỗ trợ: OPTIONS, DESCRIBE, SETUP, PLAY, PAUSE, GET_PARAMETER, TEARDOWN.
//! - Không có xác thực: chỉ dùng trong mạng LAN tin cậy.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::io::{AsyncBufRead, AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::broadcast::error::RecvError;
use tokio::sync::{broadcast, mpsc};

use super::capture::RTP_PAYLOAD_TYPE;

/// Cổng RTSP mặc định
pub const RTSP_PORT: u16 = 8554;
/// Đường dẫn của luồng màn hình: `rtsp://<host>:8554/screen`
pub const MOUNT_PATH: &str = "/screen";
/// Client không gửi request và không nhận gói nào trong khoảng này thì bị đóng
const SESSION_TIMEOUT: Duration = Duration::from_secs(60);
/// Số gói RTP được đệm cho mỗi client trước khi bị coi là chậm
const PACKET_BUFFER: usize = 4096;

pub type Packet = Arc<Vec<u8>>;

/// Điểm trung gian giữa tiến trình quay màn hình và các client RTSP
#[derive(Default)]
pub struct RtspHub {
    live: Mutex<Option<broadcast::Sender<Packet>>>,
}

impl RtspHub {
    pub fn new() -> Arc<Self> {
        Arc::new(Self::default())
    }

    /// Bắt đầu một lượt phát: trả về sender để nguồn đẩy gói RTP vào
    pub fn go_live(&self) -> broadcast::Sender<Packet> {
        let (tx, _) = broadcast::channel(PACKET_BUFFER);
        if let Ok(mut live) = self.live.lock() {
            *live = Some(tx.clone());
        }
        tx
    }

    /// Kết thúc lượt phát: client đang xem sẽ bị đóng, client mới không vào được
    pub fn go_offline(&self) {
        if let Ok(mut live) = self.live.lock() {
            *live = None;
        }
    }

    pub fn is_live(&self) -> bool {
        self.live.lock().map(|l| l.is_some()).unwrap_or(false)
    }

    fn subscribe(&self) -> Option<broadcast::Receiver<Packet>> {
        self.live.lock().ok()?.as_ref().map(|tx| tx.subscribe())
    }
}

/// Một request RTSP đã đọc xong phần đầu
#[derive(Debug)]
pub struct Request {
    pub method: String,
    pub uri: String,
    pub headers: Vec<(String, String)>,
}

impl Request {
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(k, _)| k.eq_ignore_ascii_case(name))
            .map(|(_, v)| v.as_str())
    }

    fn cseq(&self) -> String {
        self.header("CSeq").unwrap_or("0").to_string()
    }
}

/// Đọc một request: dòng đầu, các header, rồi bỏ qua body nếu có Content-Length.
/// Trả `Ok(None)` khi client đóng kết nối trước khi gửi gì.
pub async fn read_request<R: AsyncBufRead + Unpin>(r: &mut R) -> std::io::Result<Option<Request>> {
    let mut line = String::new();
    loop {
        line.clear();
        if r.read_line(&mut line).await? == 0 {
            return Ok(None);
        }
        if !line.trim().is_empty() {
            break;
        }
    }
    let mut parts = line.split_whitespace();
    let (Some(method), Some(uri)) = (parts.next(), parts.next()) else {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "Dòng đầu RTSP không hợp lệ",
        ));
    };
    let (method, uri) = (method.to_string(), uri.to_string());

    let mut headers = Vec::new();
    loop {
        line.clear();
        if r.read_line(&mut line).await? == 0 {
            break;
        }
        let text = line.trim_end();
        if text.is_empty() {
            break;
        }
        if let Some((k, v)) = text.split_once(':') {
            headers.push((k.trim().to_string(), v.trim().to_string()));
        }
    }

    let req = Request {
        method,
        uri,
        headers,
    };
    if let Some(len) = req
        .header("Content-Length")
        .and_then(|v| v.parse::<usize>().ok())
        .filter(|n| *n > 0 && *n <= 64 * 1024)
    {
        let mut body = vec![0u8; len];
        r.read_exact(&mut body).await?;
    }
    Ok(Some(req))
}

/// Phần đường dẫn của URI: `rtsp://host:8554/screen/streamid=0` → `/screen/streamid=0`
pub fn uri_path(uri: &str) -> &str {
    match uri.strip_prefix("rtsp://") {
        Some(rest) => rest.find('/').map(|i| &rest[i..]).unwrap_or("/"),
        None => uri,
    }
}

fn is_stream_path(uri: &str) -> bool {
    uri_path(uri).starts_with(MOUNT_PATH)
}

/// SDP của luồng H.264 (RTP/AVP, payload động). SPS/PPS đi kèm trong gói RTP.
pub fn sdp() -> String {
    format!(
        "v=0\r\n\
         o=- 0 0 IN IP4 127.0.0.1\r\n\
         s=Muop Agent Screen\r\n\
         t=0 0\r\n\
         m=video 0 RTP/AVP {pt}\r\n\
         c=IN IP4 0.0.0.0\r\n\
         a=rtpmap:{pt} H264/90000\r\n\
         a=fmtp:{pt} packetization-mode=1\r\n\
         a=control:streamid=0\r\n",
        pt = RTP_PAYLOAD_TYPE
    )
}

fn new_session_id() -> String {
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(0);
    let n = COUNTER.fetch_add(1, Ordering::Relaxed);
    format!(
        "{:016x}",
        nanos ^ (n.rotate_left(32)) ^ std::process::id() as u64
    )
}

/// Dựng phản hồi RTSP. Body (nếu có) được đặt Content-Length theo số byte.
fn response(status: &str, cseq: &str, extra: &[(&str, String)], body: &str) -> String {
    let mut out = format!("RTSP/1.0 {status}\r\nCSeq: {cseq}\r\n");
    for (k, v) in extra {
        out.push_str(&format!("{k}: {v}\r\n"));
    }
    if !body.is_empty() {
        out.push_str(&format!("Content-Length: {}\r\n", body.len()));
    }
    out.push_str("\r\n");
    out.push_str(body);
    out
}

/// Kết quả xử lý một request: phản hồi cần gửi và có đóng kết nối không
struct Outcome {
    response: String,
    close: bool,
}

/// Thêm header Session (kèm timeout) nếu đã có phiên
fn with_session<'a>(
    mut extra: Vec<(&'a str, String)>,
    session: &Option<String>,
) -> Vec<(&'a str, String)> {
    if let Some(sid) = session {
        extra.push((
            "Session",
            format!("{sid};timeout={}", SESSION_TIMEOUT.as_secs()),
        ));
    }
    extra
}

fn handle_request(
    req: &Request,
    hub: &RtspHub,
    session: &mut Option<String>,
    playing: &mut Option<broadcast::Receiver<Packet>>,
) -> Outcome {
    let cseq = req.cseq();
    let reply = |status: &str, extra: Vec<(&str, String)>, body: &str| Outcome {
        response: response(status, &cseq, &extra, body),
        close: false,
    };
    // Phiên trong header có thể kèm ";timeout=..." nên so sánh phần trước dấu ';'
    let header_session_matches = |session: &Option<String>| match (req.header("Session"), session) {
        (Some(h), Some(sid)) => h.split(';').next().map(str::trim) == Some(sid.as_str()),
        _ => false,
    };

    match req.method.as_str() {
        "OPTIONS" => reply(
            "200 OK",
            vec![(
                "Public",
                "OPTIONS, DESCRIBE, SETUP, PLAY, PAUSE, GET_PARAMETER, TEARDOWN".to_string(),
            )],
            "",
        ),
        "DESCRIBE" => {
            if !is_stream_path(&req.uri) || !hub.is_live() {
                return reply("404 Not Found", vec![], "");
            }
            let base = if req.uri.ends_with('/') {
                req.uri.clone()
            } else {
                format!("{}/", req.uri)
            };
            reply(
                "200 OK",
                vec![
                    ("Content-Type", "application/sdp".to_string()),
                    ("Content-Base", base),
                ],
                &sdp(),
            )
        }
        "SETUP" => {
            if !is_stream_path(&req.uri) || !hub.is_live() {
                return reply("404 Not Found", vec![], "");
            }
            let transport = req.header("Transport").unwrap_or("");
            // Chỉ RTP over TCP (interleaved): không mở cổng UDP
            if !transport.contains("RTP/AVP/TCP") && !transport.contains("interleaved") {
                return reply("461 Unsupported Transport", vec![], "");
            }
            let sid = session.get_or_insert_with(new_session_id).clone();
            let extra = vec![
                (
                    "Transport",
                    "RTP/AVP/TCP;unicast;interleaved=0-1".to_string(),
                ),
                (
                    "Session",
                    format!("{sid};timeout={}", SESSION_TIMEOUT.as_secs()),
                ),
            ];
            reply("200 OK", extra, "")
        }
        "PLAY" => {
            if !header_session_matches(session) {
                return reply("454 Session Not Found", vec![], "");
            }
            match hub.subscribe() {
                Some(rx) => {
                    *playing = Some(rx);
                    reply(
                        "200 OK",
                        with_session(vec![("Range", "npt=0.000-".to_string())], session),
                        "",
                    )
                }
                None => reply("404 Not Found", vec![], ""),
            }
        }
        "PAUSE" => {
            *playing = None;
            reply("200 OK", with_session(vec![], session), "")
        }
        "GET_PARAMETER" | "SET_PARAMETER" => reply("200 OK", with_session(vec![], session), ""),
        "TEARDOWN" => Outcome {
            response: response("200 OK", &cseq, &with_session(vec![], session), ""),
            close: true,
        },
        _ => reply(
            "405 Method Not Allowed",
            vec![(
                "Allow",
                "OPTIONS, DESCRIBE, SETUP, PLAY, PAUSE, GET_PARAMETER, TEARDOWN".to_string(),
            )],
            "",
        ),
    }
}

async fn recv_packet(rx: &mut Option<broadcast::Receiver<Packet>>) -> Result<Packet, RecvError> {
    match rx {
        Some(r) => r.recv().await,
        None => std::future::pending().await,
    }
}

/// Xử lý một kết nối RTSP. Request đọc ở task riêng để nhận request và gửi gói RTP cùng lúc.
/// Gói RTP có phải điểm bắt đầu của một khung khoá (SPS/PPS/IDR) không.
/// Đọc loại NAL trong payload: đơn (1-23), STAP-A (24), FU-A (28).
pub fn is_keyframe_start(packet: &[u8]) -> bool {
    const KEY_NALS: [u8; 3] = [5, 7, 8];
    if packet.len() < 13 {
        return false;
    }
    let payload = &packet[12..];
    match payload[0] & 0x1f {
        24 => payload.len() > 3 && KEY_NALS.contains(&(payload[3] & 0x1f)),
        28 => {
            payload.len() > 1 && payload[1] & 0x80 != 0 && KEY_NALS.contains(&(payload[1] & 0x1f))
        }
        t => KEY_NALS.contains(&t),
    }
}

async fn handle_client(stream: TcpStream, hub: Arc<RtspHub>) -> std::io::Result<()> {
    let peer = stream
        .peer_addr()
        .map(|a| a.to_string())
        .unwrap_or_default();
    let (rd, mut wr) = stream.into_split();
    let (req_tx, mut req_rx) = mpsc::channel::<std::io::Result<Request>>(8);
    tokio::spawn(async move {
        let mut rd = BufReader::new(rd);
        loop {
            match read_request(&mut rd).await {
                Ok(Some(req)) => {
                    if req_tx.send(Ok(req)).await.is_err() {
                        break;
                    }
                }
                Ok(None) => break,
                Err(e) => {
                    let _ = req_tx.send(Err(e)).await;
                    break;
                }
            }
        }
    });

    let mut session: Option<String> = None;
    let mut playing: Option<broadcast::Receiver<Packet>> = None;
    let mut last_activity = Instant::now();
    let mut resync = false;
    let mut idle = tokio::time::interval(Duration::from_secs(5));

    loop {
        tokio::select! {
            req = req_rx.recv() => {
                let req = match req {
                    Some(Ok(req)) => req,
                    _ => break,
                };
                last_activity = Instant::now();
                let outcome = handle_request(&req, &hub, &mut session, &mut playing);
                wr.write_all(outcome.response.as_bytes()).await?;
                if outcome.close {
                    break;
                }
            }
            pkt = recv_packet(&mut playing) => {
                match pkt {
                    Ok(p) => {
                        // Sau khi bị lag: bỏ mọi gói cho tới khi gặp khung khoá, tránh gửi P-frame thiếu tham chiếu
                        if resync {
                            if !is_keyframe_start(&p) {
                                continue;
                            }
                            resync = false;
                        }
                        // Interleaved: '$' + kênh 0 (RTP) + độ dài 2 byte + gói RTP
                        let mut frame = Vec::with_capacity(p.len() + 4);
                        frame.push(b'$');
                        frame.push(0);
                        frame.extend_from_slice(&(p.len() as u16).to_be_bytes());
                        frame.extend_from_slice(&p);
                        wr.write_all(&frame).await?;
                        last_activity = Instant::now();
                    }
                    // Client chậm: gói đã bị bỏ giữa GOP, nên chờ khung khoá kế tiếp rồi mới gửi tiếp
                    Err(RecvError::Lagged(missed)) => {
                        tracing::warn!("RTSP client {peer} chậm, bỏ {missed} gói; đồng bộ lại tại khung khoá");
                        resync = true;
                    }
                    // Lượt quay đã kết thúc: đóng để player kết nối lại khi có luồng mới
                    Err(RecvError::Closed) => break,
                }
            }
            _ = idle.tick() => {
                if last_activity.elapsed() > SESSION_TIMEOUT {
                    break;
                }
            }
        }
    }
    Ok(())
}

/// Chấp nhận kết nối RTSP trên `listener` cho đến khi tác vụ bị huỷ
pub async fn serve(listener: TcpListener, hub: Arc<RtspHub>) {
    loop {
        match listener.accept().await {
            Ok((stream, peer)) => {
                let _ = stream.set_nodelay(true);
                let hub = hub.clone();
                tokio::spawn(async move {
                    if let Err(e) = handle_client(stream, hub).await {
                        tracing::debug!("RTSP client {peer} lỗi: {e}");
                    }
                });
            }
            Err(e) => {
                tracing::warn!("RTSP accept lỗi: {e}");
                tokio::time::sleep(Duration::from_secs(1)).await;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn uri_path_strips_scheme_and_host() {
        assert_eq!(uri_path("rtsp://10.0.0.5:8554/screen"), "/screen");
        assert_eq!(
            uri_path("rtsp://10.0.0.5:8554/screen/streamid=0"),
            "/screen/streamid=0"
        );
        assert_eq!(uri_path("rtsp://10.0.0.5:8554"), "/");
        assert!(is_stream_path("rtsp://h:8554/screen/"));
        assert!(!is_stream_path("rtsp://h:8554/other"));
    }

    fn rtp(payload: &[u8]) -> Vec<u8> {
        let mut v = vec![0x80, 0x60, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0];
        v.extend_from_slice(payload);
        v
    }

    #[test]
    fn detects_keyframe_starts() {
        assert!(is_keyframe_start(&rtp(&[0x65, 1, 2]))); // IDR đơn
        assert!(is_keyframe_start(&rtp(&[0x67, 1, 2]))); // SPS
        assert!(is_keyframe_start(&rtp(&[0x68, 1, 2]))); // PPS
        assert!(is_keyframe_start(&rtp(&[0x7c, 0x85, 1]))); // FU-A bắt đầu IDR
        assert!(!is_keyframe_start(&rtp(&[0x7c, 0x05, 1]))); // FU-A tiếp theo, không phải điểm bắt đầu
        assert!(!is_keyframe_start(&rtp(&[0x41, 1, 2]))); // P-frame
        assert!(is_keyframe_start(&rtp(&[0x78, 0, 2, 0x67, 1]))); // STAP-A có SPS
        assert!(!is_keyframe_start(&rtp(&[0x7c]))); // gói quá ngắn
    }

    #[test]
    fn sdp_describes_h264_over_dynamic_payload() {
        let s = sdp();
        assert!(s.contains("m=video 0 RTP/AVP 96"));
        assert!(s.contains("a=rtpmap:96 H264/90000"));
    }

    #[tokio::test]
    async fn reads_request_with_headers() {
        let raw = b"OPTIONS rtsp://h/screen RTSP/1.0\r\nCSeq: 2\r\nUser-Agent: test\r\n\r\n";
        let mut r = BufReader::new(&raw[..]);
        let req = read_request(&mut r).await.unwrap().unwrap();
        assert_eq!(req.method, "OPTIONS");
        assert_eq!(req.cseq(), "2");
        assert_eq!(req.header("user-agent"), Some("test"));
    }

    #[tokio::test]
    async fn options_and_describe_flow_without_stream() {
        let hub = RtspHub::new();
        let mut session = None;
        let mut playing = None;
        let req = Request {
            method: "OPTIONS".into(),
            uri: "rtsp://h/screen".into(),
            headers: vec![("CSeq".into(), "1".into())],
        };
        let out = handle_request(&req, &hub, &mut session, &mut playing);
        assert!(out.response.starts_with("RTSP/1.0 200 OK\r\nCSeq: 1\r\n"));

        // Chưa có luồng: DESCRIBE trả 404
        let req = Request {
            method: "DESCRIBE".into(),
            uri: "rtsp://h/screen".into(),
            headers: vec![("CSeq".into(), "2".into())],
        };
        let out = handle_request(&req, &hub, &mut session, &mut playing);
        assert!(out.response.starts_with("RTSP/1.0 404"));

        // Có luồng: DESCRIBE trả SDP
        let _tx = hub.go_live();
        let out = handle_request(&req, &hub, &mut session, &mut playing);
        assert!(out.response.starts_with("RTSP/1.0 200 OK"));
        assert!(out.response.contains("Content-Type: application/sdp"));
        assert!(out.response.contains("m=video 0 RTP/AVP 96"));
    }

    #[tokio::test]
    async fn setup_rejects_udp_and_play_needs_session() {
        let hub = RtspHub::new();
        let _tx = hub.go_live();
        let mut session = None;
        let mut playing = None;
        let udp = Request {
            method: "SETUP".into(),
            uri: "rtsp://h/screen/streamid=0".into(),
            headers: vec![
                ("CSeq".into(), "3".into()),
                (
                    "Transport".into(),
                    "RTP/AVP;unicast;client_port=5000-5001".into(),
                ),
            ],
        };
        let out = handle_request(&udp, &hub, &mut session, &mut playing);
        assert!(out.response.starts_with("RTSP/1.0 461"));

        let tcp = Request {
            method: "SETUP".into(),
            uri: "rtsp://h/screen/streamid=0".into(),
            headers: vec![
                ("CSeq".into(), "4".into()),
                (
                    "Transport".into(),
                    "RTP/AVP/TCP;unicast;interleaved=0-1".into(),
                ),
            ],
        };
        let out = handle_request(&tcp, &hub, &mut session, &mut playing);
        assert!(out.response.starts_with("RTSP/1.0 200 OK"));
        let sid = session.clone().unwrap();
        assert!(out.response.contains(&format!("Session: {sid};timeout=60")));

        let play_no_session = Request {
            method: "PLAY".into(),
            uri: "rtsp://h/screen/".into(),
            headers: vec![("CSeq".into(), "5".into())],
        };
        let out = handle_request(&play_no_session, &hub, &mut session, &mut playing);
        assert!(out.response.starts_with("RTSP/1.0 454"));

        let play = Request {
            method: "PLAY".into(),
            uri: "rtsp://h/screen/".into(),
            headers: vec![("CSeq".into(), "6".into()), ("Session".into(), sid.clone())],
        };
        let out = handle_request(&play, &hub, &mut session, &mut playing);
        assert!(out.response.starts_with("RTSP/1.0 200 OK"));
        assert!(playing.is_some());
    }
}
