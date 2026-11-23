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
use crate::scanner;
use client::SessionEnd;
use serde::Serialize;
use serde_json::{json, Value};
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
                // Conversation máy phụ chạy cho một project của máy này: chuyển về project đó; còn lại bỏ
                let data = if ev.name == "session:update" {
                    match map_peer_session(&ev.data) {
                        Some(mapped) => mapped,
                        None => continue,
                    }
                } else {
                    ev.data.clone()
                };
                if let Some(ns) = bridge_ref().io.of("/") {
                    let event = format!("bridge:{}", ev.name);
                    let _ = ns.emit(event, &data);
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

/// Các project trên máy này (thư mục dưới hệ sinh thái), kèm tên thư mục mount mà máy phụ dùng cho từng project:
/// `fsmount::mount_name(tên máy này, đường dẫn project)`.
pub fn local_projects() -> Vec<(String, String)> {
    let host = origin_label();
    let Some(root) = crate::setup::workspace_root() else {
        return Vec::new();
    };
    let Ok(entries) = std::fs::read_dir(root) else {
        return Vec::new();
    };
    entries
        .flatten()
        .filter(|e| e.path().is_dir())
        .filter_map(|e| {
            let name = e.file_name().to_string_lossy().to_string();
            if name.starts_with('.') {
                return None;
            }
            let path = e.path().to_string_lossy().to_string();
            Some((crate::fsmount::mount_name(&host, &path), path))
        })
        .collect()
}

/// Chuyển một conversation của máy phụ về project của máy này. Máy phụ chạy conversation với cwd là thư mục mount,
/// nên chỉ conversation có `projectPath` nằm trong `mounts/` và đúng tên thư mục mount của một project mới được nhận.
/// Conversation khác (của chính máy phụ) trả None và không hiện.
pub fn map_peer_session(session: &Value) -> Option<Value> {
    map_peer_session_in(session, &local_projects())
}

pub fn map_peer_session_in(session: &Value, projects: &[(String, String)]) -> Option<Value> {
    let path = session
        .get("projectPath")
        .and_then(Value::as_str)
        .unwrap_or("")
        .trim_end_matches('/');
    if !path.contains("/mounts/") {
        return None;
    }
    let mount_name = path.rsplit('/').next().unwrap_or("");
    let (_, project) = projects.iter().find(|(name, _)| name == mount_name)?;
    let mut out = session.clone();
    out["projectPath"] = json!(project);
    out["projectName"] = json!(project.rsplit('/').next().unwrap_or(project));
    Some(out)
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

/// Gửi lượt chat tới agent trên máy A (prompt giữ nguyên).
///
/// Kèm `remoteProject` (địa chỉ máy này + đường dẫn project) để máy A mount đúng thư mục này về máy A
/// và làm việc trên đó. Máy A không cần cấu hình gì thêm.
pub async fn send_chat(mut body: Value) -> Result<Value, String> {
    let project = body
        .get("projectPath")
        .and_then(Value::as_str)
        .unwrap_or("")
        .trim()
        .to_string();
    if !project.is_empty() {
        body["remoteProject"] = remote_project(&project, &scanner::detect_lan_ips(), scanner::listen_port(), &origin_label());
    }
    // Prompt gửi nguyên văn: máy phụ không thêm nhãn nguồn, phân biệt bằng màu trên máy chính
    emit_ack("chat:send", body).await
}

/// Thông tin máy này gửi cho máy phụ khi được thêm vào cầu nối: các địa chỉ của máy này và thư mục gốc
/// của hệ sinh thái (máy phụ chỉ kiểm tra kết nối vào thư mục này, không mount).
pub fn local_identity() -> crate::models::RemoteProject {
    let port = scanner::listen_port();
    let mut urls: Vec<String> = scanner::detect_lan_ips()
        .iter()
        .map(|ip| format!("http://{ip}:{port}"))
        .collect();
    urls.push(format!("http://127.0.0.1:{port}"));
    crate::models::RemoteProject {
        urls,
        project_path: crate::setup::workspace_root()
            .map(|r| r.to_string_lossy().into_owned())
            .unwrap_or_default(),
        origin_host: origin_label(),
    }
}

/// Gọi máy phụ tại [url] để đăng ký máy này. Trả về phản hồi của máy phụ (`ok`, `origin` hoặc `error`).
pub async fn register_on_peer(url: &str) -> Result<Value, String> {
    let identity = local_identity();
    if identity.project_path.is_empty() {
        return Err("máy chính chưa cấu hình thư mục project (Cài đặt → Thư mục project)".into());
    }
    let resp = peer_http_client()?
        .post(format!("{url}/api/fsmount/register"))
        .json(&identity)
        .send()
        .await
        .map_err(|e| format!("không gọi được máy phụ để đăng ký: {e}"))?;
    let body = resp
        .json::<Value>()
        .await
        .map_err(|e| format!("phản hồi đăng ký của máy phụ không hợp lệ: {e}"))?;
    if body["ok"] == json!(true) {
        Ok(body)
    } else {
        Err(body["error"]
            .as_str()
            .unwrap_or("máy phụ từ chối đăng ký")
            .to_string())
    }
}

/// Thông tin project gửi kèm lượt chat: các địa chỉ máy này (IP LAN trước, loopback sau) và đường dẫn
/// project. Máy nhận tự chọn địa chỉ kết nối được.
fn remote_project(project: &str, lan_ips: &[String], port: u16, host: &str) -> Value {
    let mut urls: Vec<String> = lan_ips
        .iter()
        .map(|ip| format!("http://{ip}:{port}"))
        .collect();
    urls.push(format!("http://127.0.0.1:{port}"));
    json!({
        "urls": urls,
        "projectPath": project,
        "originHost": host,
    })
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
    let url = configured_peer_url()?;
    let client = peer_http_client()?;
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

/// Gọi GET trên máy A (chỉ đọc, ví dụ tương tác Claude đang chờ)
pub async fn get_peer(path: &str) -> Result<Value, String> {
    let url = configured_peer_url()?;
    let client = peer_http_client()?;
    let resp = client
        .get(format!("{url}{path}"))
        .send()
        .await
        .map_err(|e| format!("không gọi được máy A: {e}"))?;
    resp.json::<Value>()
        .await
        .map_err(|e| format!("phản hồi của máy A không hợp lệ: {e}"))
}

fn configured_peer_url() -> Result<String, String> {
    let url = status().url;
    if url.is_empty() {
        return Err("chưa cấu hình địa chỉ máy A".into());
    }
    Ok(url)
}

fn peer_http_client() -> Result<reqwest::Client, String> {
    reqwest::Client::builder()
        .timeout(HTTP_TIMEOUT)
        .build()
        .map_err(|e| e.to_string())
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
    use super::{map_peer_session_in, normalize_url, remote_project};
    use serde_json::json;

    #[test]
    fn remote_project_lists_lan_addresses_before_loopback() {
        let ips = vec!["192.168.31.96".to_string(), "10.0.0.5".to_string()];
        let v = remote_project("/home/john/p", &ips, 8787, "asrock");
        assert_eq!(v["projectPath"], "/home/john/p");
        assert_eq!(v["originHost"], "asrock");
        assert_eq!(
            v["urls"],
            serde_json::json!([
                "http://192.168.31.96:8787",
                "http://10.0.0.5:8787",
                "http://127.0.0.1:8787"
            ])
        );
    }

    #[test]
    fn peer_session_in_a_mount_maps_to_the_local_project() {
        let projects = vec![(
            "3b0cf23755d3e304".to_string(),
            "/home/john/Documents/muop-ecosystem/muop-agent".to_string(),
        )];
        let s = json!({
            "id": "cid-1",
            "projectPath": "/home/john/.local/share/muop-agent/mounts/3b0cf23755d3e304",
            "projectName": "3b0cf23755d3e304"
        });
        let mapped = map_peer_session_in(&s, &projects).expect("thuộc project của máy này");
        assert_eq!(mapped["projectPath"], "/home/john/Documents/muop-ecosystem/muop-agent");
        assert_eq!(mapped["projectName"], "muop-agent");
        assert_eq!(mapped["id"], "cid-1");
    }

    #[test]
    fn peer_conversations_outside_mounts_are_not_shown() {
        let projects = vec![(
            "3b0cf23755d3e304".to_string(),
            "/home/john/Documents/muop-ecosystem/muop-agent".to_string(),
        )];
        // Conversation chạy trên chính máy phụ (không qua mount)
        let own = json!({"projectPath": "/home/john/Documents/muop-ecosystem/muop-erp-app"});
        // Mount của project không thuộc máy này
        let other_mount = json!({"projectPath": "/home/john/.local/share/muop-agent/mounts/0000000000000000"});
        assert!(map_peer_session_in(&own, &projects).is_none());
        assert!(map_peer_session_in(&other_mount, &projects).is_none());
        assert!(map_peer_session_in(&json!({}), &projects).is_none());
    }

    #[test]
    fn mount_directory_name_matches_what_the_peer_uses() {
        // Tên thư mục mount đã thấy trên Laptop khi mount project này từ máy chính
        assert_eq!(
            crate::fsmount::mount_name(
                "ASRock-X99-Taichi-Server",
                "/home/john/Documents/muop-ecosystem/muop-agent"
            ),
            "3b0cf23755d3e304"
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
