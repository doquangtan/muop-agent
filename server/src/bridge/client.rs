//! Một phiên WebSocket tới máy A. Chỉ dùng WebSocket: polling lỗi với gói lớn (đã kiểm chứng
//! bằng spike với `rust_socketio` 0.6), còn server của A phát đầy đủ qua WebSocket.

use super::protocol::{encode_event, parse, Packet};
use super::{update_status, Bridge, Command, PeerEvent};
use futures_util::{SinkExt, StreamExt};
use serde_json::Value;
use std::collections::HashMap;
use tokio::sync::{mpsc, oneshot, watch};
use tokio_tungstenite::{connect_async, tungstenite::Message};

pub(super) enum SessionEnd {
    /// Người dùng đổi địa chỉ máy A: kết nối lại ngay
    UrlChanged,
    /// Phiên kết thúc vì lỗi hoặc máy A đóng kết nối
    Closed(String),
}

/// `http://host:port` → `ws://host:port/socket.io/?EIO=4&transport=websocket`
pub(super) fn ws_endpoint(http_url: &str) -> String {
    let rest = http_url.trim_start_matches("http://").trim_end_matches('/');
    format!("ws://{rest}/socket.io/?EIO=4&transport=websocket")
}

pub(super) async fn run_session(
    b: &Bridge,
    url: &str,
    url_rx: &mut watch::Receiver<String>,
    cmd_rx: &mut mpsc::UnboundedReceiver<Command>,
) -> SessionEnd {
    let (ws, _) = match connect_async(ws_endpoint(url)).await {
        Ok(v) => v,
        Err(e) => return SessionEnd::Closed(format!("không kết nối được {url}: {e}")),
    };
    let (mut tx, mut rx) = ws.split();

    match rx.next().await {
        Some(Ok(Message::Text(open))) if open.starts_with('0') => {}
        other => return SessionEnd::Closed(format!("handshake thất bại: {other:?}")),
    }
    if tx.send(Message::Text("40".into())).await.is_err() {
        return SessionEnd::Closed("không gửi được gói connect".into());
    }
    update_status(b, |s| {
        s.connected = true;
        s.error.clear();
    });
    tracing::info!("bridge: đã kết nối tới {url}");

    let mut pending: HashMap<u64, oneshot::Sender<Result<Value, String>>> = HashMap::new();
    let mut next_id: u64 = 0;

    let end = loop {
        tokio::select! {
            incoming = rx.next() => match incoming {
                Some(Ok(Message::Text(text))) => match parse(&text) {
                    Ok(Packet::Ping) => {
                        if tx.send(Message::Text("3".into())).await.is_err() {
                            break SessionEnd::Closed("mất kết nối khi trả ping".into());
                        }
                    }
                    Ok(Packet::Event { name, data }) => {
                        let _ = b.events.send(PeerEvent { name, data });
                    }
                    Ok(Packet::Ack { id, data }) => {
                        if let Some(reply) = pending.remove(&id) {
                            let _ = reply.send(Ok(data));
                        }
                    }
                    Ok(Packet::Disconnect) => break SessionEnd::Closed("máy A ngắt kết nối".into()),
                    Ok(Packet::Other) => {}
                    Err(e) => tracing::warn!("bridge: bỏ qua gói lỗi: {e}"),
                },
                Some(Ok(Message::Close(_))) | None => {
                    break SessionEnd::Closed("kết nối tới máy A đã đóng".into());
                }
                Some(Err(e)) => break SessionEnd::Closed(format!("lỗi đọc từ máy A: {e}")),
                Some(Ok(_)) => {}
            },
            cmd = cmd_rx.recv() => match cmd {
                Some(Command::Emit { name, payload, reply }) => {
                    next_id += 1;
                    pending.insert(next_id, reply);
                    let frame = encode_event(&name, &payload, Some(next_id));
                    if tx.send(Message::Text(frame.into())).await.is_err() {
                        break SessionEnd::Closed("gửi lệnh tới máy A thất bại".into());
                    }
                }
                None => break SessionEnd::Closed("kênh lệnh đã đóng".into()),
            },
            changed = url_rx.changed() => match changed {
                Ok(()) => break SessionEnd::UrlChanged,
                Err(_) => break SessionEnd::Closed("kênh địa chỉ đã đóng".into()),
            },
        }
    };

    for (_, reply) in pending.drain() {
        let _ = reply.send(Err("kết nối tới máy A bị ngắt trước khi có phản hồi".into()));
    }
    let _ = tx.close().await;
    end
}

#[cfg(test)]
mod tests {
    use super::ws_endpoint;

    #[test]
    fn builds_websocket_endpoint_from_http_url() {
        assert_eq!(
            ws_endpoint("http://192.168.31.96:8787"),
            "ws://192.168.31.96:8787/socket.io/?EIO=4&transport=websocket"
        );
        assert_eq!(
            ws_endpoint("http://127.0.0.1:8787/"),
            "ws://127.0.0.1:8787/socket.io/?EIO=4&transport=websocket"
        );
    }
}
