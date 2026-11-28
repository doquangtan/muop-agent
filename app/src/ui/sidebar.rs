//! Sidebar: địa chỉ máy chủ, trạng thái kết nối, nút conversation mới và danh sách theo project.

use std::collections::BTreeMap;

use dioxus::prelude::*;

use crate::data::models::SessionSummary;
use crate::store::Store;
use crate::ui::format::{short_local_time, status_label};

#[component]
pub fn Sidebar() -> Element {
    let store = use_context::<Store>();
    let mut address_input = use_signal(|| store.base());
    let mut address_error = use_signal(|| None::<String>);

    let connected = *store.connected.read();
    let sessions = store.sessions.read().clone();
    let streams = store.streams.read().clone();
    let selected = store.selected.read().clone();
    let hostname = store
        .meta
        .read()
        .as_ref()
        .map(|m| m.hostname.clone())
        .unwrap_or_default();
    let notice = store.notice.read().clone();
    let base = store.base();
    let saved = store.saved_servers();

    let mut groups: BTreeMap<String, Vec<SessionSummary>> = BTreeMap::new();
    for session in &sessions {
        let key = if session.project_name.is_empty() {
            "Không rõ project".to_string()
        } else {
            session.project_name.clone()
        };
        groups.entry(key).or_default().push(session.clone());
    }

    let dot_class = if connected { "dot ok" } else { "dot bad" };
    let status_text = if connected {
        if hostname.is_empty() {
            "Đã kết nối".to_string()
        } else {
            format!("Đã kết nối · {hostname}")
        }
    } else {
        "Chưa kết nối".to_string()
    };
    let new_active = selected.is_none();
    let explorer_open = *store.explorer_open.read();
    let theme_light = *store.theme_light.read();
    let docker_open = *store.docker_panel.read();
    let ssh_open = *store.ssh_panel.read();
    let agy = *store.agy_logged_in.read();
    let claude = store.claude_auth.read().clone();
    let claude_ok = claude.as_ref().map(|c| c.logged_in).unwrap_or(false);
    let claude_label = match &claude {
        Some(c) if c.logged_in => {
            let plan = if c.subscription_type.is_empty() {
                String::new()
            } else {
                format!(" ({})", c.subscription_type)
            };
            format!("{}{}", c.email, plan)
        }
        Some(_) => "chưa đăng nhập".to_string(),
        None => "…".to_string(),
    };

    rsx! {
        aside { class: "sidebar",
            div { class: "sidebar-header",
                h1 { "Mướp Agent" }
                div { class: "status",
                    span { class: "{dot_class}" }
                    span { "{status_text}" }
                }
                div { class: "auth-row",
                    span { class: if agy == Some(true) { "pill ok" } else { "pill" },
                        "agy: "
                        {if agy == Some(true) { "đã đăng nhập" } else if agy == Some(false) { "chưa đăng nhập" } else { "…" }}
                    }
                    span { class: if claude_ok { "pill ok" } else { "pill" },
                        "Claude: "
                        {claude_label}
                    }
                }
            }

            div { class: "sidebar-actions",
                button {
                    class: if new_active { "new-chat active" } else { "new-chat" },
                    onclick: move |_| store.new_conversation(),
                    "+ Conversation mới"
                }
                button {
                    class: if ssh_open { "toggle on" } else { "toggle" },
                    title: "Danh sách máy SSH đã lưu và chạy lệnh một lần",
                    onclick: move |_| store.toggle_ssh_panel(),
                    "SSH"
                }
                button {
                    class: if docker_open { "toggle on" } else { "toggle" },
                    title: "Quản lý container Docker trên máy đã lưu",
                    onclick: move |_| store.toggle_docker_panel(),
                    "Docker"
                }
                button {
                    class: "toggle theme-toggle",
                    title: if theme_light { "Chuyển sang theme tối" } else { "Chuyển sang theme sáng" },
                    onclick: move |_| store.toggle_theme(),
                    if theme_light { "☾" } else { "☀" }
                }
                button {
                    class: if explorer_open { "toggle on" } else { "toggle" },
                    title: "Hiện/ẩn workspace và cây tệp",
                    onclick: move |_| {
                        let mut open = store.explorer_open;
                        let now = open();
                        open.set(!now);
                    },
                    "Tệp"
                }
            }

            form {
                class: "server-form",
                onsubmit: move |event: FormEvent| {
                    event.prevent_default();
                    match store.connect_to(&address_input()) {
                        Ok(()) => address_error.set(None),
                        Err(message) => address_error.set(Some(message)),
                    }
                },
                label { "Máy chủ" }
                div { class: "server-row",
                    input {
                        r#type: "text",
                        placeholder: "192.168.1.10:8787",
                        value: "{address_input}",
                        oninput: move |event| address_input.set(event.value()),
                    }
                    button { r#type: "submit", "Kết nối" }
                }
                if let Some(message) = address_error() {
                    p { class: "form-error", "{message}" }
                }
            }

            if !saved.is_empty() {
                div { class: "saved-servers",
                    for server in saved.iter() {
                        button {
                            key: "{server}",
                            class: if *server == base { "chip active" } else { "chip" },
                            onclick: {
                                let server = server.clone();
                                move |_| {
                                    if store.connect_to(&server).is_ok() {
                                        address_input.set(server.clone());
                                    }
                                }
                            },
                            "{server}"
                        }
                    }
                }
            }

            if let Some(message) = notice {
                div { class: "banner error", "{message}" }
            }

            nav { class: "session-list",
                if sessions.is_empty() {
                    p { class: "muted", "Chưa có conversation nào." }
                }
                for (project, items) in groups {
                    section { key: "{project}", class: "group",
                        h2 { "{project}" }
                        for session in items {
                            SessionRow {
                                key: "{session.id}",
                                session: session.clone(),
                                running: session.is_running || streams.contains_key(&session.id),
                                active: selected.as_deref() == Some(session.id.as_str()),
                            }
                        }
                    }
                }
            }
        }
    }
}

#[derive(Props, Clone, PartialEq)]
struct SessionRowProps {
    session: SessionSummary,
    running: bool,
    active: bool,
}

#[component]
fn SessionRow(props: SessionRowProps) -> Element {
    let store = use_context::<Store>();
    let session = props.session.clone();
    let class = if props.active { "row active" } else { "row" };
    let state = status_label(&session.status, props.running, session.is_interrupted);
    let time = short_local_time(&session.updated_at);
    let title = if session.title.trim().is_empty() {
        "(không có tiêu đề)".to_string()
    } else {
        session.title.clone()
    };
    let id = session.id.clone();

    rsx! {
        button {
            class: "{class}",
            onclick: move |_| store.select(Some(id.clone())),
            span { class: "row-title", "{title}" }
            span { class: "row-meta",
                if props.running {
                    span { class: "dot ok small" }
                }
                "{state}"
                if !time.is_empty() {
                    " · {time}"
                }
            }
        }
    }
}
