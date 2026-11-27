//! Khung hội thoại: tiêu đề, số liệu và danh sách bước (chỉ đọc).

use dioxus::prelude::*;

use crate::data::models::{AgentStep, ConversationSession};
use crate::ui::format::{format_tokens, model_label, status_label};

#[derive(Props, Clone, PartialEq)]
pub struct ConversationProps {
    pub detail: Option<Result<ConversationSession, String>>,
}

#[component]
pub fn Conversation(props: ConversationProps) -> Element {
    match props.detail {
        None => rsx! {
            div { class: "empty",
                h2 { "Chọn một conversation" }
                p { "Danh sách bên trái lấy từ máy chủ đang kết nối." }
            }
        },
        Some(Err(message)) => rsx! {
            div { class: "empty error",
                h2 { "Không mở được conversation" }
                p { "{message}" }
            }
        },
        Some(Ok(session)) => rsx! { ConversationView { session: session } },
    }
}

#[derive(Props, Clone, PartialEq)]
struct ConversationViewProps {
    session: ConversationSession,
}

#[component]
fn ConversationView(props: ConversationViewProps) -> Element {
    let session = props.session;
    let title = if session.title.trim().is_empty() {
        "(không có tiêu đề)".to_string()
    } else {
        session.title.clone()
    };
    let state = status_label(&session.status, false, session.is_interrupted);
    let model = model_label(&session.selected_model);
    let context = format_tokens(session.context_tokens);
    let step_count = session.steps.len();

    rsx! {
        header { class: "conv-header",
            div { class: "conv-title",
                h2 { "{title}" }
                p { class: "muted",
                    "{session.project_name} · {state}"
                    if !model.is_empty() {
                        " · {model}"
                    }
                }
            }
            div { class: "conv-stats muted",
                span { "{step_count} bước" }
                if session.context_tokens > 0 {
                    span { "Ngữ cảnh {context}" }
                }
            }
        }
        if session.is_interrupted && !session.interrupted_reason.is_empty() {
            div { class: "banner warn", "{session.interrupted_reason}" }
        }
        section { class: "steps",
            if session.steps.is_empty() {
                p { class: "muted center", "Conversation chưa có bước nào." }
            }
            for step in session.steps.iter() {
                StepView { key: "{step.step_index}", step: step.clone() }
            }
        }
    }
}

#[derive(Props, Clone, PartialEq)]
struct StepViewProps {
    step: AgentStep,
}

#[component]
fn StepView(props: StepViewProps) -> Element {
    let step = props.step;
    match step.kind.as_str() {
        "USER_INPUT" => rsx! {
            div { class: "bubble user",
                div { class: "bubble-text", "{step.content}" }
            }
        },
        "PLANNER_RESPONSE" => {
            let who = if step.agent_name.is_empty() {
                "Agent".to_string()
            } else {
                step.agent_name.clone()
            };
            let model = model_label(&step.model);
            rsx! {
                div { class: "ai",
                    div { class: "ai-meta muted",
                        "{who}"
                        if !model.is_empty() {
                            " · {model}"
                        }
                    }
                    if step.content.trim().is_empty() {
                        p { class: "muted", "(không có nội dung)" }
                    } else {
                        div { class: "ai-text", "{step.content}" }
                    }
                }
            }
        }
        _ => {
            let label = if step.vietnamese_title.is_empty() {
                step.kind.clone()
            } else {
                step.vietnamese_title.clone()
            };
            rsx! {
                div { class: "activity muted",
                    span { class: "dot small" }
                    span { "{label}" }
                }
            }
        }
    }
}
