//! Lịch sử commit của project đang xem (chỉ đọc).

use dioxus::prelude::*;

use crate::store::Store;

#[component]
pub fn GitHistoryPanel() -> Element {
    let store = use_context::<Store>();
    let history = store.git_history.read().clone();
    let project = store.project.read().clone();
    let name = crate::ui::explorer::basename(&project);

    rsx! {
        header { class: "conv-header",
            div { class: "conv-title",
                h2 { "Lịch sử commit" }
                p { class: "muted",
                    "{name}"
                    if let Some(h) = history.as_ref() {
                        " · nhánh {h.current_branch} · {h.total_commits} commit"
                    }
                }
            }
            div { class: "conv-stats",
                button { class: "toggle", onclick: move |_| store.load_git_history(), "Làm mới" }
                button { class: "toggle", onclick: move |_| store.toggle_git_panel(), "Đóng" }
            }
        }
        section { class: "git-body",
            match history {
                None => rsx! { p { class: "muted center", "Đang tải lịch sử…" } },
                Some(h) => rsx! {
                    for commit in h.commits.iter() {
                        div { key: "{commit.short_hash}", class: "commit-row",
                            span { class: if commit.is_head { "dot ok small" } else { "dot small" } }
                            div { class: "commit-main",
                                div { class: "commit-subject", "{commit.subject}" }
                                div { class: "muted",
                                    span { class: "mono", "{commit.short_hash}" }
                                    " · {commit.author_name} · {commit.relative_time}"
                                }
                                if !commit.refs.is_empty() {
                                    div { class: "ref-chips",
                                        for r in commit.refs.iter() {
                                            span { key: "{r}", class: "chip", "{r}" }
                                        }
                                    }
                                }
                            }
                        }
                    }
                },
            }
        }
    }
}
