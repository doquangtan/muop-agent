//! Khung chính: giữ trạng thái kết nối, poll máy chủ, ghép sidebar và hội thoại.

use std::time::Duration;

use dioxus::prelude::*;

use crate::data::api;
use crate::data::config::{normalize_server_address, DEFAULT_SERVER_ADDRESS};
use crate::data::models::{ConversationSession, PingInfo, SessionSummary};
use crate::data::time::sleep;
use crate::ui::conversation::Conversation;
use crate::ui::sidebar::Sidebar;

/// Chu kỳ làm mới danh sách và conversation đang mở.
/// Tạm thời dùng poll REST; thay bằng sự kiện Socket.IO `snapshot:update` ở bước sau.
const POLL_INTERVAL: Duration = Duration::from_secs(3);

#[component]
pub fn Shell() -> Element {
    // Ô nhập địa chỉ và địa chỉ đang dùng (đã chuẩn hóa).
    let mut address_input = use_signal(|| DEFAULT_SERVER_ADDRESS.to_string());
    let mut address = use_signal(|| DEFAULT_SERVER_ADDRESS.to_string());
    let mut address_error = use_signal(|| None::<String>);
    let mut selected = use_signal(|| None::<String>);
    // Tăng mỗi chu kỳ để các resource bên dưới tải lại.
    let mut tick = use_signal(|| 0u64);

    use_future(move || async move {
        loop {
            sleep(POLL_INTERVAL).await;
            *tick.write() += 1;
        }
    });

    let ping = use_resource(move || {
        let base = address();
        let _ = tick();
        async move { api::ping(&base).await }
    });

    let sessions = use_resource(move || {
        let base = address();
        let _ = tick();
        async move { api::sessions(&base).await }
    });

    let detail = use_resource(move || {
        let base = address();
        let id = selected();
        let _ = tick();
        async move {
            match id {
                Some(id) => Some(api::session(&base, &id).await),
                None => None,
            }
        }
    });

    let sessions_view: Result<Vec<SessionSummary>, String> = match &*sessions.read() {
        Some(Ok(list)) => Ok(list.clone()),
        Some(Err(e)) => Err(e.to_string()),
        None => Ok(Vec::new()),
    };
    let loading = sessions.read().is_none();
    let server_info: Option<PingInfo> = match &*ping.read() {
        Some(Ok(info)) => Some(info.clone()),
        _ => None,
    };
    let detail_view: Option<Result<ConversationSession, String>> = match &*detail.read() {
        Some(Some(Ok(session))) => Some(Ok(session.clone())),
        Some(Some(Err(e))) => Some(Err(e.to_string())),
        _ => None,
    };

    let connection_error = sessions_view.as_ref().err().cloned();
    let connected = !loading && connection_error.is_none();

    rsx! {
        div { class: "app",
            Sidebar {
                sessions: sessions_view.clone().unwrap_or_default(),
                selected: selected(),
                loading: loading,
                connected: connected,
                connection_error: connection_error,
                hostname: server_info.map(|i| i.hostname).unwrap_or_default(),
                address_input: address_input(),
                address_error: address_error(),
                on_address_input: move |value: String| address_input.set(value),
                on_connect: move |_| {
                    match normalize_server_address(&address_input()) {
                        Ok(normalized) => {
                            address_input.set(normalized.clone());
                            address.set(normalized);
                            address_error.set(None);
                            selected.set(None);
                        }
                        Err(message) => address_error.set(Some(message)),
                    }
                },
                on_select: move |id: String| selected.set(Some(id)),
            }
            main { class: "main",
                Conversation { detail: detail_view }
            }
        }
    }
}
