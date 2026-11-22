//! Bridge: server máy B kết nối tới server máy A (Socket.IO) để
//! - gửi lệnh tới agent đang chạy trên A (`chat:send`, `chat:stop`),
//! - trả lời câu hỏi / duyệt plan của agent trên A (REST của A),
//! - nhận các sự kiện của A (`chat:stream`, `session:update`...) và chuyển tiếp cho client của B
//!   dưới tên `bridge:<sự kiện>`.
//!
//! Đọc file của A thì B gọi thẳng REST `/api/files/*`, `/api/git/*` của A; bridge không proxy phần đó.
//! Địa chỉ máy A lưu trong `app_settings` (khoá `bridge_peer_url`).

mod client;
mod protocol;

use crate::infra::store;
use client::SessionEnd;
use serde::Serialize;
use serde_json::Value;
use socketioxide::SocketIo;
use std::sync::{Mutex, OnceLock};
use std::time::Duration;
use tokio::sync::{broadcast, mpsc, oneshot, watch};

const SETTING_KEY: &str = "bridge_peer_url";
const ACK_TIMEOUT: Duration = Duration::from_secs(30);
const HTTP_TIMEOUT: Duration = Duration::from_secs(15);
const RECONNECT_MIN: Duration = Duration::from_secs(1);
const RECONNECT_MAX: Duration = Duration::from_secs(30);

/// Sự kiện của máy A được chuyển tiếp cho client của B. Bỏ `sessions:list`, `meta:update`
/// vì payload rất lớn (hàng trăm KB) và B có thể tự yêu cầu khi cần.
const FORWARDED_EVENTS: &[&str] = &[
    "chat:stream",
    "session:update",
    "streams:update",
    "ai-question:answered",
    "retry:update",
    "quotas:update",
];

#[derive(Debug, Clone)]
pub(crate) struct PeerEvent {
    pub name: String,
    pub data: Value,
}

pub(crate) enum Command {
    Emit {
        name: String,
        payload: Value,
        reply: oneshot::Sender<Result<Value, String>>,
    },
}

#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PeerStatus {
    /// Địa chỉ máy A đã lưu (rỗng nếu chưa cấu hình)
    pub url: String,
    pub connected: bool,
    /// Lỗi của lần kết nối gần nhất (rỗng khi đang kết nối tốt)
    pub error: String,
}

struct Bridge {
    io: SocketIo,
    /// Địa chỉ máy A hiện tại; rỗng nghĩa là không kết nối
    url_tx: watch::Sender<String>,
    cmd_tx: mpsc::UnboundedSender<Command>,
    events: broadcast::Sender<PeerEvent>,
    status: Mutex<PeerStatus>,
}

static BRIDGE: OnceLock<Bridge> = OnceLock::new();

fn bridge() -> Option<&'static Bridge> {
    BRIDGE.get()
}

/// Khởi động bridge: nạp địa chỉ máy A đã lưu và chạy vòng kết nối nền.
pub fn start(io: SocketIo) {
    let saved = store::get_app_setting(SETTING_KEY).unwrap_or_default();
    let (url_tx, url_rx) = watch::channel(saved.clone());
    let (cmd_tx, cmd_rx) = mpsc::unbounded_channel();
    let (events, _) = broadcast::channel(512);
    let bridge = Bridge {
        io,
        url_tx,
        cmd_tx,
        events,
        status: Mutex::new(PeerStatus {
            url: saved,
            connected: false,
            error: String::new(),
        }),
    };
    if BRIDGE.set(bridge).is_err() {
        return;
    }
    let b = bridge_ref();
    tokio::spawn(run_loop(url_rx, cmd_rx));
    tokio::spawn(forward_events(b.events.subscribe()));
}

fn bridge_ref() -> &'static Bridge {
    BRIDGE.get().expect("bridge chưa khởi động")
}

/// Vòng kết nối: giữ một phiên tới máy A, tự kết nối lại với backoff khi mất kết nối.
async fn run_loop(
    mut url_rx: watch::Receiver<String>,
    mut cmd_rx: mpsc::UnboundedReceiver<Command>,
) {
    let b = bridge_ref();
    let mut backoff = RECONNECT_MIN;
    loop {
        let url = url_rx.borrow_and_update().clone();
        if url.is_empty() {
            update_status(b, |s| {
                s.connected = false;
                s.error.clear();
            });
            if url_rx.changed().await.is_err() {
                return;
            }
            backoff = RECONNECT_MIN;
            continue;
        }

        let end = client::run_session(b, &url, &mut url_rx, &mut cmd_rx).await;
        update_status(b, |s| s.connected = false);
        match end {
            SessionEnd::UrlChanged => backoff = RECONNECT_MIN,
            SessionEnd::Closed(why) => {
                tracing::warn!("bridge: {why}");
                update_status(b, |s| s.error = why);
                tokio::select! {
                    _ = tokio::time::sleep(backoff) => {}
                    _ = url_rx.changed() => {
                        backoff = RECONNECT_MIN;
                        continue;
                    }
                }
                backoff = (backoff * 2).min(RECONNECT_MAX);
            }
        }
    }
}

/// Đổi trạng thái và phát `bridge:status` cho client của B.
fn update_status(b: &Bridge, change: impl FnOnce(&mut PeerStatus)) {
    let snapshot = {
        let mut status = b.status.lock().unwrap_or_else(|e| e.into_inner());
        change(&mut status);
        status.clone()
    };
    if let Some(ns) = b.io.of("/") {
        let _ = ns.emit("bridge:status", &snapshot);
    }
}

async fn forward_events(mut rx: broadcast::Receiver<PeerEvent>) {
    loop {
        match rx.recv().await {
            Ok(ev) if FORWARDED_EVENTS.contains(&ev.name.as_str()) => {
                if let Some(ns) = bridge_ref().io.of("/") {
                    let event = format!("bridge:{}", ev.name);
                    let _ = ns.emit(event, &ev.data);
                }
            }
            Ok(_) => {}
            Err(broadcast::error::RecvError::Lagged(n)) => {
                tracing::warn!("bridge: bỏ {n} sự kiện do chậm");
            }
            Err(broadcast::error::RecvError::Closed) => return,
        }
    }
}

pub fn status() -> PeerStatus {
    bridge()
        .map(|b| b.status.lock().unwrap_or_else(|e| e.into_inner()).clone())
        .unwrap_or_default()
}

/// Đặt địa chỉ máy A (chuỗi rỗng để ngắt kết nối). Lưu bền vững trong SQLite.
pub fn set_peer(raw: &str) -> Result<PeerStatus, String> {
    let b = bridge().ok_or("bridge chưa khởi động")?;
    let url = normalize_url(raw)?;
    if !store::set_app_setting(SETTING_KEY, &url) {
        return Err("không lưu được địa chỉ máy A".into());
    }
    b.url_tx.send_replace(url.clone());
    update_status(b, |s| {
        s.url = url.clone();
        s.connected = false;
        s.error.clear();
    });
    Ok(status())
}

fn normalize_url(raw: &str) -> Result<String, String> {
    let trimmed = raw.trim().trim_end_matches('/');
    if trimmed.is_empty() {
        return Ok(String::new());
    }
    match trimmed.strip_prefix("http://") {
        Some(rest) if !rest.is_empty() => Ok(trimmed.to_string()),
        _ => Err("Địa chỉ máy A phải dạng http://IP:8787 (chưa hỗ trợ https)".into()),
    }
}

/// Gửi một sự kiện có ack tới máy A và chờ phản hồi.
pub async fn emit_ack(name: &str, payload: Value) -> Result<Value, String> {
    let b = bridge().ok_or("bridge chưa khởi động")?;
    if !status().connected {
        return Err("chưa kết nối tới máy A".into());
    }
    let (reply, rx) = oneshot::channel();
    b.cmd_tx
        .send(Command::Emit {
            name: name.to_string(),
            payload,
            reply,
        })
        .map_err(|_| "kênh lệnh tới máy A đã đóng".to_string())?;
    match tokio::time::timeout(ACK_TIMEOUT, rx).await {
        Ok(Ok(result)) => result,
        Ok(Err(_)) => Err("máy A ngắt kết nối trước khi trả lời".into()),
        Err(_) => Err(format!(
            "máy A không trả lời {name} trong {} giây",
            ACK_TIMEOUT.as_secs()
        )),
    }
}

/// Gửi lượt chat tới agent trên máy A. Prompt được thêm nhãn nguồn `[Từ máy <tên>]`.
pub async fn send_chat(mut body: Value) -> Result<Value, String> {
    if let Some(prompt) = body
        .get("prompt")
        .and_then(Value::as_str)
        .map(str::to_owned)
    {
        body["prompt"] = Value::String(tag_origin(&prompt, &origin_label()));
    }
    emit_ack("chat:send", body).await
}

/// Thêm nhãn nguồn vào đầu prompt để agent trên A biết tin nhắn đến từ máy nào.
fn tag_origin(prompt: &str, origin: &str) -> String {
    format!("[Từ máy {origin}] {prompt}")
}

pub async fn stop_chat(conversation_id: &str) -> Result<Value, String> {
    emit_ack(
        "chat:stop",
        serde_json::json!({ "conversationId": conversation_id }),
    )
    .await
}

/// Gọi REST trên máy A (dùng cho trả lời câu hỏi và duyệt plan).
pub async fn post_peer(path: &str, body: Value) -> Result<Value, String> {
    let url = status().url;
    if url.is_empty() {
        return Err("chưa cấu hình địa chỉ máy A".into());
    }
    let client = reqwest::Client::builder()
        .timeout(HTTP_TIMEOUT)
        .build()
        .map_err(|e| e.to_string())?;
    let resp = client
        .post(format!("{url}{path}"))
        .json(&body)
        .send()
        .await
        .map_err(|e| format!("không gọi được máy A: {e}"))?;
    resp.json::<Value>()
        .await
        .map_err(|e| format!("phản hồi của máy A không hợp lệ: {e}"))
}

/// Tên máy B, dùng làm nhãn nguồn trong prompt gửi tới A.
pub fn origin_label() -> String {
    std::fs::read_to_string("/etc/hostname")
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "máy B".to_string())
}

#[cfg(test)]
mod tests {
    use super::{normalize_url, tag_origin};

    #[test]
    fn prompt_is_tagged_with_origin() {
        assert_eq!(
            tag_origin("sửa lỗi login", "laptop"),
            "[Từ máy laptop] sửa lỗi login"
        );
    }

    #[test]
    fn accepts_http_url_and_strips_trailing_slash() {
        assert_eq!(
            normalize_url(" http://192.168.31.96:8787/ ").unwrap(),
            "http://192.168.31.96:8787"
        );
    }

    #[test]
    fn empty_clears_the_peer() {
        assert_eq!(normalize_url("  ").unwrap(), "");
    }

    #[test]
    fn rejects_other_schemes_and_bare_scheme() {
        assert!(normalize_url("https://example.com").is_err());
        assert!(normalize_url("192.168.31.96:8787").is_err());
        assert!(normalize_url("http://").is_err());
    }
}
