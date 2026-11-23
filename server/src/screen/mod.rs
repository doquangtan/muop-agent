//! Quay màn hình và phát luồng RTSP.
//!
//! - Bật/tắt bằng checkbox trên system tray (xem `infra/tray.rs`).
//! - Chụp qua portal ScreenCast + GStreamer, hạ xuống 720p, mã hoá H.264 (`capture.rs`).
//! - Phát qua RTSP tại `rtsp://<ip-lan>:8554/screen` (`rtsp.rs`). Mở bằng bất kỳ player nào (VLC, mpv, ffplay).
//!
//! Socket.IO chỉ đưa trạng thái: `screen:status` (server → tất cả): `{streaming, starting, error, height, fps, rtspUrl}`.

pub mod capture;
pub mod portal;
pub mod rtsp;

use serde::Serialize;
use socketioxide::SocketIo;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::process::Child;
use tokio::runtime::Handle;
use tokio::sync::broadcast;
use tokio::sync::Mutex as AsyncMutex;
use tokio::task::JoinHandle;

/// Chờ portal/desktop sẵn sàng sau khi tray đăng ký (lúc boot, phiên đồ hoạ có thể chưa xong)
const AUTOSTART_DELAY: Duration = Duration::from_secs(5);
/// Số lần thử tự bật; lỗi do người dùng huỷ hộp thoại thì không thử lại
const AUTOSTART_ATTEMPTS: u32 = 3;
const AUTOSTART_RETRY_EVERY: Duration = Duration::from_secs(15);

#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ScreenStatus {
    /// Luồng đang chạy
    pub streaming: bool,
    /// Đang mở phiên portal (có thể đang chờ người dùng xác nhận)
    pub starting: bool,
    /// Lỗi của lần bật gần nhất, rỗng nếu không có
    pub error: String,
    pub height: u32,
    pub fps: u32,
    /// Địa chỉ để mở bằng player, rỗng khi chưa bật
    pub rtsp_url: String,
}

/// Một phiên đang chạy: tiến trình GStreamer, task đọc gói RTP và phiên portal
struct Running {
    generation: u64,
    child: Child,
    reader: JoinHandle<()>,
    portal: portal::PortalSession,
}

pub struct ScreenManager {
    /// Socket.IO: chỉ dùng để gửi trạng thái
    io: SocketIo,
    /// Runtime của Tokio, để gọi từ thread của tray (không nằm trong runtime)
    rt: Option<Handle>,
    status: Mutex<ScreenStatus>,
    running: AsyncMutex<Option<Running>>,
    generation: AtomicU64,
    /// Các client RTSP đang xem luồng hiện tại
    hub: Arc<rtsp::RtspHub>,
}

impl ScreenManager {
    pub fn new(io: SocketIo) -> Arc<Self> {
        Arc::new(Self {
            io,
            rt: Handle::try_current().ok(),
            status: Mutex::new(ScreenStatus {
                height: capture::TARGET_HEIGHT,
                fps: capture::MAX_FPS,
                ..Default::default()
            }),
            running: AsyncMutex::new(None),
            generation: AtomicU64::new(0),
            hub: rtsp::RtspHub::new(),
        })
    }

    /// Mở cổng RTSP (8554) trên mọi giao diện LAN. Gọi một lần khi server khởi động.
    pub fn start_rtsp_server(self: &Arc<Self>) {
        let hub = self.hub.clone();
        tokio::spawn(async move {
            let addr = format!("0.0.0.0:{}", rtsp::RTSP_PORT);
            match tokio::net::TcpListener::bind(&addr).await {
                Ok(listener) => {
                    tracing::info!("📺 RTSP server lắng nghe tại {addr}{}", rtsp::MOUNT_PATH);
                    rtsp::serve(listener, hub).await;
                }
                Err(e) => tracing::error!("Không mở được cổng RTSP {addr}: {e}"),
            }
        });
    }

    pub fn status(&self) -> ScreenStatus {
        self.status.lock().map(|s| s.clone()).unwrap_or_default()
    }

    /// Checkbox của tray: đang bật (kể cả lúc chờ xác nhận)
    pub fn is_active(&self) -> bool {
        let s = self.status();
        s.streaming || s.starting
    }

    /// Bật nếu đang tắt, tắt nếu đang bật. Gọi được từ bất kỳ thread nào.
    pub fn toggle(self: &Arc<Self>) {
        let turn_on = !self.is_active();
        tracing::info!("📺 Yêu cầu bật/tắt quay màn hình từ tray (bật: {turn_on})");
        let this = self.clone();
        let Some(rt) = self.rt.clone() else {
            tracing::error!("Không có runtime Tokio để bật quay màn hình");
            return;
        };
        rt.spawn(async move {
            if this.is_active() {
                this.stop().await;
            } else {
                this.start().await;
            }
        });
    }

    fn update_status(&self, f: impl FnOnce(&mut ScreenStatus)) {
        if let Ok(mut s) = self.status.lock() {
            f(&mut s);
        }
        self.emit_status();
    }

    fn emit_status(&self) {
        let status = self.status();
        if let Some(ns) = self.io.of("/") {
            let _ = ns.emit("screen:status", &status);
        }
        crate::infra::tray::refresh();
    }

    /// Mở phiên portal và chạy GStreamer. Có thể chờ người dùng xác nhận vài chục giây.
    pub async fn start(self: &Arc<Self>) {
        let mut guard = self.running.lock().await;
        if guard.is_some() {
            return;
        }
        self.update_status(|s| {
            s.starting = true;
            s.error.clear();
        });

        let restore = load_restore_token();
        let opened = match portal::open(restore).await {
            Ok(o) => o,
            Err(e) => {
                tracing::warn!("Không mở được quay màn hình: {e}");
                self.update_status(|s| {
                    s.starting = false;
                    s.error = e;
                });
                return;
            }
        };
        if let Some(tok) = opened.restore_token.as_deref() {
            save_restore_token(tok);
        }

        let (out_w, out_h) = match opened.source_size {
            Some((w, h)) => capture::output_size(w, h),
            None => capture::output_size(0, 0),
        };
        let source =
            capture::pipewire_source(std::os::fd::AsRawFd::as_raw_fd(&opened.fd), opened.node_id);
        let args = capture::pipeline_args(&source, out_w, out_h);
        let (mut child, stdout) = match capture::spawn(args, Some(opened.fd)) {
            Ok(c) => c,
            Err(e) => {
                tracing::warn!("Không chạy được pipeline quay màn hình: {e}");
                opened.session.close().await;
                self.update_status(|s| {
                    s.starting = false;
                    s.error = e;
                });
                return;
            }
        };

        let generation = self.generation.fetch_add(1, Ordering::Relaxed) + 1;
        let packets = self.hub.go_live();
        let manager = self.clone();
        let hub = self.hub.clone();
        let reader = tokio::spawn(async move {
            read_packets(stdout, packets, hub).await;
            manager.capture_ended(generation).await;
        });

        // Kiểm tra nhanh: GStreamer chết ngay sau khi chạy (portal từ chối, node sai...)
        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        if let Ok(Some(_)) = child.try_wait() {
            reader.abort();
            self.hub.go_offline();
            opened.session.close().await;
            self.update_status(|s| {
                s.starting = false;
                s.error = "Pipeline quay màn hình dừng ngay sau khi bật (xem log server)".into();
            });
            return;
        }

        let url = rtsp_url();
        *guard = Some(Running {
            generation,
            child,
            reader,
            portal: opened.session,
        });
        self.update_status(|s| {
            s.starting = false;
            s.streaming = true;
            s.height = out_h;
            s.rtsp_url = url.clone();
        });
        tracing::info!("📺 Bắt đầu quay màn hình {out_w}x{out_h} — mở bằng: {url}");
    }

    /// Luôn tự bật stream sau khi tray đăng ký. Chỉ cần portal đã được cấp quyền
    /// (có restore token) để không hiện hộp thoại chia sẻ lúc khởi động.
    pub async fn autostart(self: &Arc<Self>) {
        if load_restore_token().is_none() {
            tracing::info!("📺 Không tự bật quay màn hình: chưa được cấp quyền chia sẻ màn hình");
            return;
        }
        tokio::time::sleep(AUTOSTART_DELAY).await;
        for attempt in 1..=AUTOSTART_ATTEMPTS {
            if self.is_active() {
                return;
            }
            tracing::info!("📺 Tự bật quay màn hình (lần {attempt}/{AUTOSTART_ATTEMPTS})");
            self.start().await;
            let status = self.status();
            if status.streaming || status.error.contains("Đã hủy") {
                return;
            }
            tokio::time::sleep(AUTOSTART_RETRY_EVERY).await;
        }
        tracing::warn!("📺 Tự bật quay màn hình thất bại sau {AUTOSTART_ATTEMPTS} lần thử");
    }

    /// Dừng pipeline và đóng phiên portal
    pub async fn stop(&self) {
        let running = self.running.lock().await.take();
        self.hub.go_offline();
        if let Some(r) = running {
            end_running(r).await;
            tracing::info!("📺 Đã dừng quay màn hình");
        }
        self.update_status(|s| {
            s.streaming = false;
            s.starting = false;
            s.rtsp_url.clear();
        });
    }

    /// Pipeline kết thúc do lỗi hoặc nguồn bị đóng (không phải do người dùng tắt)
    async fn capture_ended(&self, generation: u64) {
        let mut guard = self.running.lock().await;
        let matches = guard.as_ref().is_some_and(|r| r.generation == generation);
        if !matches {
            return;
        }
        self.hub.go_offline();
        if let Some(r) = guard.take() {
            r.portal.close().await;
            // Tiến trình đã kết thúc, chỉ cần thu dọn
            drop(r.child);
        }
        drop(guard);
        self.update_status(|s| {
            s.streaming = false;
            s.rtsp_url.clear();
            s.error = "Luồng quay màn hình đã dừng bất ngờ".into();
        });
    }
}

async fn end_running(mut r: Running) {
    let _ = r.child.start_kill();
    let _ = r.child.wait().await;
    r.reader.abort();
    r.portal.close().await;
}

/// Đọc các gói RTP từ GStreamer và đẩy vào hub cho mọi client RTSP
async fn read_packets(
    stdout: tokio::process::ChildStdout,
    out: broadcast::Sender<rtsp::Packet>,
    hub: Arc<rtsp::RtspHub>,
) {
    use tokio::io::AsyncReadExt;
    let mut stdout = stdout;
    let mut splitter = capture::RtpSplitter::default();
    let mut chunk = vec![0u8; 64 * 1024];
    loop {
        match stdout.read(&mut chunk).await {
            Ok(0) | Err(_) => break,
            Ok(n) => {
                for packet in splitter.push(&chunk[..n]) {
                    hub.observe(&packet);
                    // Không có client nào thì send trả lỗi: bỏ qua, luồng vẫn chạy
                    let _ = out.send(Arc::new(packet));
                }
            }
        }
    }
}

/// Địa chỉ RTSP cho client trong LAN: ưu tiên IP 192.168.x.x, rồi 10.x, rồi IP đầu tiên
fn rtsp_url() -> String {
    let ips = crate::scanner::detect_lan_ips();
    let host = ips
        .iter()
        .find(|ip| ip.starts_with("192.168."))
        .or_else(|| ips.iter().find(|ip| ip.starts_with("10.")))
        .or_else(|| ips.first())
        .cloned()
        .unwrap_or_else(|| "127.0.0.1".to_string());
    format!("rtsp://{host}:{}{}", rtsp::RTSP_PORT, rtsp::MOUNT_PATH)
}

/// File lưu restore token của portal (quyền 0600), để không hỏi lại mỗi lần bật
fn restore_token_path() -> PathBuf {
    crate::infra::paths::app_data_dir().join("screen-restore-token")
}

fn load_restore_token() -> Option<String> {
    std::fs::read_to_string(restore_token_path())
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

fn save_restore_token(token: &str) {
    let path = restore_token_path();
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    if std::fs::write(&path, token).is_ok() {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
    }
}
