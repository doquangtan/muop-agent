//! Hộp thoại chi tiết: danh sách tool call hoặc tệp đã đổi của một lượt.

use dioxus::prelude::*;

use crate::store::{Dialog, Store};
use crate::ui::turns::{line_totals, preview_args};

/// Đặt ở gốc giao diện để phủ lên mọi màn hình khi có hộp thoại đang mở.
#[component]
pub fn DialogHost() -> Element {
    let store = use_context::<Store>();
    let dialog = store.dialog.read().clone();
    let Some(dialog) = dialog else {
        return rsx! {};
    };
    let title = match &dialog {
        Dialog::Tools { title, .. } | Dialog::Files { title, .. } => title.clone(),
    };

    rsx! {
        div { class: "modal-backdrop", onclick: move |_| store.close_dialog(),
            div { class: "modal", onclick: move |e| e.stop_propagation(),
                header { class: "modal-header",
                    h3 { "{title}" }
                    button { class: "link", onclick: move |_| store.close_dialog(), "Đóng" }
                }
                match dialog {
                    Dialog::Tools { calls, .. } => rsx! {
                        if calls.is_empty() {
                            p { class: "muted", "Không có thao tác nào." }
                        }
                        for (i, call) in calls.into_iter().enumerate() {
                            div { key: "{i}", class: "modal-item",
                                div { class: "modal-item-title",
                                    span { class: "tool-name", "{call.name}" }
                                    if !call.summary_label.is_empty() && call.summary_label != call.name {
                                        span { class: "muted", " · {call.summary_label}" }
                                    }
                                }
                                if !call.target_path.is_empty() {
                                    p { class: "muted mono", "{call.target_path}" }
                                }
                                if !call.args.is_null() {
                                    pre { class: "args", "{preview_args(&call.args)}" }
                                }
                            }
                        }
                    },
                    Dialog::Files { files, .. } => rsx! {
                        {
                            let (added, removed) = line_totals(&files);
                            rsx! { p { class: "muted", "{files.len()} tệp · +{added} −{removed}" } }
                        }
                        for (i, file) in files.into_iter().enumerate() {
                            div { key: "{i}", class: "modal-item",
                                div { class: "modal-item-title",
                                    span { class: "mono", "{file.path}" }
                                }
                                p { class: "muted",
                                    "{file.action} · +{file.added_lines} −{file.removed_lines}"
                                    if !file.agent_name.is_empty() {
                                        " · {file.agent_name}"
                                    }
                                }
                            }
                        }
                    },
                }
            }
        }
    }
}
