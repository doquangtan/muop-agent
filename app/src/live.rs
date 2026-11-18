// Kết nối Socket.IO tới muop-agent-server bằng các event nhỏ (không còn snapshot đầy đủ):
// - khi kết nối: yêu cầu `request-sessions`, `request-meta`, `request-streams`
// - nhận `sessions:list` (tóm tắt), `session:update` (một conversation), `session:removed`,
//   `meta:update` (project/model/máy), `projects:update`, `streams:update`, `retry:update`
//
// Callback của thư viện chạy ở luồng riêng, nên mọi thay đổi giao diện đi qua upgrade_in_event_loop.

use crate::api::{Meta, PendingRetry, Project, Session, SessionsPayload, StreamsPayload};
use crate::AppWindow;
use rust_socketio::{ClientBuilder, Event, Payload, RawClient, TransportType};
use std::time::Duration;

/// Khởi chạy kết nối nền. Trả về ngay; thư viện tự kết nối lại khi server rớt.
pub fn spawn(base: String, ui: slint::Weak<AppWindow>) {
    std::thread::spawn(move || loop {
        let connect_ui = ui.clone();
        let close_ui = ui.clone();
        let error_ui = ui.clone();
        let list_ui = ui.clone();
        let detail_ui = ui.clone();
        let removed_ui = ui.clone();
        let meta_ui = ui.clone();
        let projects_ui = ui.clone();
        let streams_ui = ui.clone();
        let retry_ui = ui.clone();

        let builder = ClientBuilder::new(base.clone())
            .namespace("/")
            .transport_type(TransportType::Any)
            .reconnect(true)
            .reconnect_on_disconnect(true)
            .reconnect_delay(1000, 3500)
            .on(Event::Connect, move |_: Payload, client: RawClient| {
                set_connection(&connect_ui, true, String::new());
                // Yêu cầu từng phần nhỏ thay cho snapshot đầy đủ
                for event in ["request-sessions", "request-meta", "request-streams"] {
                    let _ = client.emit(event, Payload::Text(vec![]));
                }
            })
            .on(Event::Close, move |_: Payload, _: RawClient| {
                set_connection(
                    &close_ui,
                    false,
                    "Mất kết nối tới server, đang thử lại…".into(),
                );
            })
            .on(Event::Error, move |payload: Payload, _: RawClient| {
                let detail = match payload {
                    Payload::Text(values) => {
                        values.first().map(|v| v.to_string()).unwrap_or_default()
                    }
                    _ => String::new(),
                };
                set_connection(&error_ui, false, format!("Lỗi socket: {detail}"));
            })
            .on("sessions:list", move |payload: Payload, _: RawClient| {
                if let Some(p) = decode::<SessionsPayload>(payload, "sessions:list") {
                    let _ = list_ui.upgrade_in_event_loop(move |ui| {
                        crate::apply_sessions_list(&ui, p.sessions)
                    });
                }
            })
            .on("session:update", move |payload: Payload, _: RawClient| {
                if let Some(sess) = decode::<Session>(payload, "session:update") {
                    let _ = detail_ui
                        .upgrade_in_event_loop(move |ui| crate::apply_session_update(&ui, sess));
                }
            })
            .on("session:removed", move |payload: Payload, _: RawClient| {
                if let Some(id) = decode::<IdPayload>(payload, "session:removed") {
                    let _ = removed_ui
                        .upgrade_in_event_loop(move |ui| crate::apply_session_removed(&ui, &id.id));
                }
            })
            .on("meta:update", move |payload: Payload, _: RawClient| {
                if let Some(meta) = decode::<Meta>(payload, "meta:update") {
                    let _ = meta_ui.upgrade_in_event_loop(move |ui| crate::apply_meta(&ui, meta));
                }
            })
            .on("projects:update", move |payload: Payload, _: RawClient| {
                // Server phát mảng nên socket.io tách thành nhiều đối số: ghép lại từng đối số
                let list = decode_all::<Project>(payload);
                if !list.is_empty() {
                    let _ = projects_ui
                        .upgrade_in_event_loop(move |ui| crate::apply_projects(&ui, list));
                }
            })
            .on("streams:update", move |payload: Payload, _: RawClient| {
                if let Some(p) = decode::<StreamsPayload>(payload, "streams:update") {
                    let _ = streams_ui.upgrade_in_event_loop(move |ui| {
                        crate::apply_streams(&ui, p.active_streams)
                    });
                }
            })
            .on("retry:update", move |payload: Payload, _: RawClient| {
                if let Some(list) = decode::<Vec<PendingRetry>>(payload, "retry:update") {
                    let _ =
                        retry_ui.upgrade_in_event_loop(move |ui| crate::apply_retries(&ui, list));
                }
            });

        match builder.connect() {
            Ok(_client) => {
                // Giữ client sống; thư viện tự kết nối lại khi mất kết nối
                loop {
                    std::thread::sleep(Duration::from_secs(3600));
                }
            }
            Err(e) => {
                set_connection(&ui, false, format!("Không kết nối được server: {e}"));
                std::thread::sleep(Duration::from_secs(3));
            }
        }
    });
}

#[derive(serde::Deserialize)]
struct IdPayload {
    id: String,
}

/// Đọc mọi đối số của event (dùng cho payload dạng mảng bị tách)
fn decode_all<T: serde::de::DeserializeOwned>(payload: Payload) -> Vec<T> {
    match payload {
        Payload::Text(values) => values
            .into_iter()
            .filter_map(|v| serde_json::from_value::<T>(v).ok())
            .collect(),
        _ => Vec::new(),
    }
}

/// Đọc đối số đầu tiên của event thành kiểu mong muốn; lỗi thì ghi log và bỏ qua
fn decode<T: serde::de::DeserializeOwned>(payload: Payload, event: &str) -> Option<T> {
    let value = match payload {
        Payload::Text(values) => values.into_iter().next()?,
        #[allow(deprecated)]
        Payload::String(s) => serde_json::from_str(&s).ok()?,
        Payload::Binary(_) => return None,
    };
    match serde_json::from_value::<T>(value) {
        Ok(v) => Some(v),
        Err(e) => {
            eprintln!("{event} không đọc được: {e}");
            None
        }
    }
}

fn set_connection(ui: &slint::Weak<AppWindow>, connected: bool, status: String) {
    let _ = ui.upgrade_in_event_loop(move |ui| {
        ui.set_connected(connected);
        if !status.is_empty() {
            ui.set_status_text(status.into());
        }
    });
}
