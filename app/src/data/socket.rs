//! Client Socket.IO v4 qua WebSocket, viết tay cho giao thức của `muop-agent-server`.
//!
//! - Mở `ws://host:port/socket.io/?EIO=4&transport=websocket`.
//! - Server gửi `0{...}` (open); client gửi `40` để vào namespace `/`, server trả `40{...}`.
//! - `2` (ping) → client trả `3`. `42[name, data]` là sự kiện. `42<id>[...]` là yêu cầu ack,
//!   `43<id>[...]` là ack trả về.
//! - Mất kết nối thì tự kết nối lại với backoff; lệnh gửi trong lúc mất kết nối bị hủy.

use std::collections::HashMap;
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use tokio::sync::{mpsc, oneshot};
use tokio_tungstenite::{connect_async, tungstenite::Message};

use super::rt;

const MAX_BACKOFF: Duration = Duration::from_secs(5);

/// Sự kiện từ server (hoặc trạng thái kết nối) đưa lên UI.
#[derive(Debug, Clone, PartialEq)]
pub enum Incoming {
    Connected,
    Disconnected(String),
    Event { name: String, data: Value },
}

enum Command {
    Emit { event: String, data: Value },
}

/// Tay cầm để gửi sự kiện tới server. Có thể sao chép thoải mái.
#[derive(Clone)]
pub struct SocketClient {
    tx: mpsc::UnboundedSender<Command>,
}

impl SocketClient {
    /// Gửi sự kiện không cần ack. Không làm gì nếu đang mất kết nối.
    pub fn emit(&self, event: &str, data: Value) {
        let _ = self.tx.send(Command::Emit {
            event: event.to_string(),
            data,
        });
    }
}

/// Mở kết nối tới `base_url` (dạng `http://host:port`). Trả về tay cầm gửi và luồng sự kiện.
/// Khi tay cầm và luồng bị bỏ, tác vụ nền tự kết thúc.
pub fn connect(base_url: &str) -> (SocketClient, mpsc::UnboundedReceiver<Incoming>) {
    let (cmd_tx, cmd_rx) = mpsc::unbounded_channel();
    let (ev_tx, ev_rx) = mpsc::unbounded_channel();
    let url = ws_endpoint(base_url);
    rt::runtime().spawn(run(url, cmd_rx, ev_tx));
    (SocketClient { tx: cmd_tx }, ev_rx)
}

/// `http://host:port` → `ws://host:port/socket.io/?EIO=4&transport=websocket`
pub fn ws_endpoint(base_url: &str) -> String {
    let trimmed = base_url.trim_end_matches('/');
    let rest = trimmed
        .strip_prefix("https://")
        .map(|r| ("wss", r))
        .or_else(|| trimmed.strip_prefix("http://").map(|r| ("ws", r)))
        .unwrap_or(("ws", trimmed));
    format!(
        "{}://{}/socket.io/?EIO=4&transport=websocket",
        rest.0, rest.1
    )
}

enum End {
    Lost(String),
    ClientGone,
}

async fn run(
    url: String,
    mut cmd_rx: mpsc::UnboundedReceiver<Command>,
    ev_tx: mpsc::UnboundedSender<Incoming>,
) {
    let mut backoff = Duration::from_secs(1);
    loop {
        let end = match connect_async(url.as_str()).await {
            Ok((ws, _)) => {
                let (mut sink, mut stream) = ws.split();
                session(&mut sink, &mut stream, &mut cmd_rx, &ev_tx).await
            }
            Err(e) => End::Lost(e.to_string()),
        };
        match end {
            End::ClientGone => return,
            End::Lost(reason) => {
                if ev_tx.send(Incoming::Disconnected(reason)).is_err() {
                    return;
                }
            }
        }
        // Đang chờ kết nối lại: lệnh gửi vào lúc này bị bỏ, không để dồn thành lệnh cũ.
        let wait = tokio::time::sleep(backoff);
        tokio::pin!(wait);
        loop {
            tokio::select! {
                _ = &mut wait => break,
                cmd = cmd_rx.recv() => if cmd.is_none() { return },
            }
        }
        backoff = (backoff * 2).min(MAX_BACKOFF);
    }
}

type Sink = futures_util::stream::SplitSink<
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>,
    Message,
>;
type Stream = futures_util::stream::SplitStream<
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>,
>;

async fn session(
    sink: &mut Sink,
    stream: &mut Stream,
    cmd_rx: &mut mpsc::UnboundedReceiver<Command>,
    ev_tx: &mpsc::UnboundedSender<Incoming>,
) -> End {
    let mut pending: HashMap<u64, oneshot::Sender<Value>> = HashMap::new();
    let mut connected = false;

    loop {
        tokio::select! {
            msg = stream.next() => {
                let text = match msg {
                    Some(Ok(Message::Text(t))) => t.to_string(),
                    Some(Ok(Message::Close(_))) | None => return End::Lost("máy chủ đóng kết nối".into()),
                    Some(Ok(_)) => continue,
                    Some(Err(e)) => return End::Lost(e.to_string()),
                };
                match handle_packet(&text, &mut pending) {
                    Packet::Open => {
                        if sink.send(Message::Text("40".into())).await.is_err() {
                            return End::Lost("không gửi được yêu cầu vào namespace".into());
                        }
                    }
                    Packet::Namespace => {
                        if !connected {
                            connected = true;
                            if ev_tx.send(Incoming::Connected).is_err() {
                                return End::ClientGone;
                            }
                        }
                    }
                    Packet::Ping => {
                        if sink.send(Message::Text("3".into())).await.is_err() {
                            return End::Lost("mất kết nối khi trả ping".into());
                        }
                    }
                    Packet::Event(name, data) => {
                        if ev_tx.send(Incoming::Event { name, data }).is_err() {
                            return End::ClientGone;
                        }
                    }
                    Packet::Disconnect => return End::Lost("máy chủ ngắt namespace".into()),
                    Packet::Other => {}
                }
            }
            cmd = cmd_rx.recv() => {
                let Some(cmd) = cmd else { return End::ClientGone };
                if !connected {
                    // Chưa vào namespace: bỏ lệnh, không để dồn thành lệnh cũ khi kết nối lại.
                    continue;
                }
                let Command::Emit { event, data } = cmd;
                let frame = encode_event(&event, &data, None);
                if sink.send(Message::Text(frame.into())).await.is_err() {
                    return End::Lost("không gửi được lệnh".into());
                }
            }
        }
    }
}

#[derive(Debug)]
enum Packet {
    Open,
    Namespace,
    Ping,
    Disconnect,
    Event(String, Value),
    Other,
}

/// Phân tích một khung văn bản của Engine.IO/Socket.IO. Ack được trả thẳng vào `pending`.
fn handle_packet(text: &str, pending: &mut HashMap<u64, oneshot::Sender<Value>>) -> Packet {
    if text.starts_with('0') {
        return Packet::Open;
    }
    if text == "2" {
        return Packet::Ping;
    }
    if text == "41" {
        return Packet::Disconnect;
    }
    if let Some(rest) = text.strip_prefix("40") {
        // `40` hoặc `40{"sid":...}` (vào namespace `/`), không có namespace khác
        return if rest.is_empty() || rest.starts_with('{') {
            Packet::Namespace
        } else {
            Packet::Other
        };
    }
    if let Some(rest) = text.strip_prefix("43") {
        let digits: String = rest.chars().take_while(|c| c.is_ascii_digit()).collect();
        if let (Ok(id), Ok(Value::Array(args))) = (
            digits.parse::<u64>(),
            serde_json::from_str::<Value>(&rest[digits.len()..]),
        ) {
            if let Some(reply) = pending.remove(&id) {
                let first = args.into_iter().next().unwrap_or(Value::Null);
                let _ = reply.send(first);
            }
        }
        return Packet::Other;
    }
    if let Some(rest) = text.strip_prefix("42") {
        // Sự kiện có thể kèm id ack từ phía server; bỏ qua id, lấy mảng `[name, ...args]`
        let body = rest.trim_start_matches(|c: char| c.is_ascii_digit());
        if let Ok(Value::Array(items)) = serde_json::from_str::<Value>(body) {
            let mut iter = items.into_iter();
            if let Some(Value::String(name)) = iter.next() {
                let args: Vec<Value> = iter.collect();
                let data = match args.len() {
                    0 => Value::Null,
                    1 => args.into_iter().next().unwrap_or(Value::Null),
                    _ => Value::Array(args),
                };
                return Packet::Event(name, data);
            }
        }
    }
    Packet::Other
}

/// `42[name,data]`, hoặc `42<id>[name,data]` khi cần ack.
pub fn encode_event(event: &str, data: &Value, ack_id: Option<u64>) -> String {
    let body = if data.is_null() {
        json!([event])
    } else {
        json!([event, data])
    };
    match ack_id {
        Some(id) => format!("42{id}{body}"),
        None => format!("42{body}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn builds_websocket_endpoint() {
        assert_eq!(
            ws_endpoint("http://192.168.31.96:8787/"),
            "ws://192.168.31.96:8787/socket.io/?EIO=4&transport=websocket"
        );
        assert_eq!(
            ws_endpoint("https://example.test"),
            "wss://example.test/socket.io/?EIO=4&transport=websocket"
        );
    }

    #[test]
    fn parses_open_namespace_ping_disconnect() {
        let mut pending = HashMap::new();
        assert!(matches!(
            handle_packet(r#"0{"sid":"x"}"#, &mut pending),
            Packet::Open
        ));
        assert!(matches!(
            handle_packet(r#"40{"sid":"x"}"#, &mut pending),
            Packet::Namespace
        ));
        assert!(matches!(handle_packet("2", &mut pending), Packet::Ping));
        assert!(matches!(
            handle_packet("41", &mut pending),
            Packet::Disconnect
        ));
        assert!(matches!(
            handle_packet("42/other,[\"x\"]", &mut pending),
            Packet::Other
        ));
    }

    #[test]
    fn parses_event_and_takes_single_argument() {
        let mut pending = HashMap::new();
        match handle_packet(r#"42["meta:update",{"port":8787}]"#, &mut pending) {
            Packet::Event(name, data) => {
                assert_eq!(name, "meta:update");
                assert_eq!(data["port"], 8787);
            }
            other => panic!("không đúng: {other:?}"),
        }
        match handle_packet(r#"42["retry:update"]"#, &mut pending) {
            Packet::Event(name, data) => {
                assert_eq!(name, "retry:update");
                assert!(data.is_null());
            }
            other => panic!("không đúng: {other:?}"),
        }
    }

    #[test]
    fn ack_resolves_pending_request() {
        let mut pending = HashMap::new();
        let (tx, mut rx) = oneshot::channel();
        pending.insert(12, tx);
        handle_packet(r#"4312[{"ok":true,"conversationId":"c1"}]"#, &mut pending);
        let value = rx.try_recv().expect("ack phải được trả về");
        assert_eq!(value["conversationId"], "c1");
        assert!(pending.is_empty());
    }

    #[test]
    fn encodes_with_and_without_ack() {
        assert_eq!(
            encode_event("chat:send", &json!({"a": 1}), Some(3)),
            r#"423["chat:send",{"a":1}]"#
        );
        assert_eq!(
            encode_event("request-meta", &Value::Null, None),
            r#"42["request-meta"]"#
        );
    }

    /// Chạy thủ công khi máy chủ đang bật:
    /// `MUOP_SERVER=http://127.0.0.1:8787 cargo test live -- --ignored --nocapture`
    #[test]
    #[ignore = "cần muop-agent-server đang chạy"]
    fn live_socket_gets_meta_and_sessions_then_detail() {
        use super::super::api;
        use super::super::models::{parse_session_list, ServerMeta};

        let base = std::env::var("MUOP_SERVER").unwrap_or_else(|_| "http://127.0.0.1:8787".into());
        let (client, mut events) = connect(&base);
        let outcome = rt::runtime().block_on(async {
            let mut meta: Option<ServerMeta> = None;
            let mut sessions = None;
            let waited = tokio::time::timeout(Duration::from_secs(20), async {
                while let Some(event) = events.recv().await {
                    match event {
                        Incoming::Connected => {
                            client.emit("request-meta", Value::Null);
                            client.emit("request-sessions", Value::Null);
                        }
                        Incoming::Event { name, data } if name == "meta:update" => {
                            meta = serde_json::from_value(data).ok();
                        }
                        Incoming::Event { name, data } if name == "sessions:list" => {
                            sessions = parse_session_list(data).ok();
                        }
                        Incoming::Disconnected(reason) => panic!("mất kết nối: {reason}"),
                        _ => {}
                    }
                    if meta.is_some() && sessions.is_some() {
                        break;
                    }
                }
            })
            .await;
            assert!(
                waited.is_ok(),
                "không nhận đủ meta và sessions trong 20 giây"
            );
            let meta = meta.expect("meta");
            let sessions = sessions.expect("sessions");
            assert!(!meta.available_models.is_empty(), "meta không có model");
            assert!(!sessions.is_empty(), "máy chủ không có session");
            let first = sessions[0].id.clone();
            let base2 = base.clone();
            let detail = api::on_io(async move { api::session(&base2, &first).await })
                .await
                .expect("chi tiết session");
            (
                meta.available_models.len(),
                sessions.len(),
                detail.steps.len(),
            )
        });
        println!(
            "socket: models={} sessions={} steps(first)={}",
            outcome.0, outcome.1, outcome.2
        );
    }
}
