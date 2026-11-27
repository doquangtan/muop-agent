//! Sidebar: ô địa chỉ máy chủ, trạng thái kết nối và danh sách conversation.

use std::collections::BTreeMap;

use dioxus::prelude::*;

use crate::data::models::SessionSummary;
use crate::ui::format::{short_local_time, status_label};

#[derive(Props, Clone, PartialEq)]
pub struct SidebarProps {
    pub sessions: Vec<SessionSummary>,
    pub selected: Option<String>,
    pub loading: bool,
    pub connected: bool,
    pub connection_error: Option<String>,
    pub hostname: String,
    pub address_input: String,
    pub address_error: Option<String>,
    pub on_address_input: EventHandler<String>,
    pub on_connect: EventHandler<()>,
    pub on_select: EventHandler<String>,
}

#[component]
pub fn Sidebar(props: SidebarProps) -> Element {
    // Nhóm theo project, giữ thứ tự tên project.
    let mut groups: BTreeMap<String, Vec<SessionSummary>> = BTreeMap::new();
    for session in &props.sessions {
        let key = if session.project_name.is_empty() {
            "Không rõ project".to_string()
        } else {
            session.project_name.clone()
        };
        groups.entry(key).or_default().push(session.clone());
    }

    let dot_class = if props.connected {
        "dot ok"
    } else if props.loading {
        "dot wait"
    } else {
        "dot bad"
    };
    let status_text = if props.connected {
        if props.hostname.is_empty() {
            "Đã kết nối".to_string()
        } else {
            format!("Đã kết nối · {}", props.hostname)
        }
    } else if props.loading {
        "Đang kết nối…".to_string()
    } else {
        "Mất kết nối".to_string()
    };

    rsx! {
        aside { class: "sidebar",
            div { class: "sidebar-header",
                h1 { "Mướp Agent" }
                div { class: "status",
                    span { class: "{dot_class}" }
                    span { "{status_text}" }
                }
            }

            form {
                class: "server-form",
                onsubmit: move |event: FormEvent| {
                    event.prevent_default();
                    props.on_connect.call(());
                },
                label { "Máy chủ" }
                div { class: "server-row",
                    input {
                        r#type: "text",
                        placeholder: "192.168.1.10:8787",
                        value: "{props.address_input}",
                        oninput: move |event| props.on_address_input.call(event.value()),
                    }
                    button { r#type: "submit", "Kết nối" }
                }
                if let Some(message) = props.address_error.clone() {
                    p { class: "form-error", "{message}" }
                }
            }

            if let Some(message) = props.connection_error.clone() {
                div { class: "banner error", "{message}" }
            }

            nav { class: "session-list",
                if props.sessions.is_empty() && !props.loading && props.connection_error.is_none() {
                    p { class: "muted", "Chưa có conversation nào." }
                }
                for (project, items) in groups {
                    section { key: "{project}", class: "group",
                        h2 { "{project}" }
                        for session in items {
                            SessionRow {
                                key: "{session.id}",
                                session: session.clone(),
                                active: props.selected.as_deref() == Some(session.id.as_str()),
                                on_select: props.on_select,
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
    active: bool,
    on_select: EventHandler<String>,
}

#[component]
fn SessionRow(props: SessionRowProps) -> Element {
    let session = props.session.clone();
    let class = if props.active { "row active" } else { "row" };
    let state = status_label(&session.status, session.is_running, session.is_interrupted);
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
            onclick: move |_| props.on_select.call(id.clone()),
            span { class: "row-title", "{title}" }
            span { class: "row-meta",
                if session.is_running {
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
