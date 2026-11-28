//! Khung hội thoại: tiêu đề, danh sách bước, lượt đang chạy và lượt vừa gửi.

use dioxus::prelude::*;

use crate::data::models::{AgentStep, ConversationSession, FileTouched, PendingPlan, PendingRetry};
use crate::store::{Dialog, PendingTurn, Store};
use crate::ui::composer::Composer;
use crate::ui::format::short_local_time;
use crate::ui::format::{format_tokens, model_label, status_label};
use crate::ui::interactions::{AiQuestions, ClaudeInteraction};
use crate::ui::markdown::MarkdownView;
use crate::ui::turns::{files_for_turn, line_totals};

#[component]
pub fn Conversation() -> Element {
    let store = use_context::<Store>();
    let selected = store.selected.read().clone();
    let detail = store.detail.read().clone();
    let detail_error = store.detail_error.read().clone();
    let streams = store.streams.read().clone();
    let claude_pending = store.claude_pending.read().clone();
    let ai_questions = store.ai_questions.read().clone();
    let pending = store.pending.read().clone();

    let stream = selected.as_ref().and_then(|id| streams.get(id).cloned());
    let pending_here: Option<PendingTurn> =
        pending.filter(|p| p.conversation_id == selected.clone().unwrap_or_default());
    let retry_here: Option<PendingRetry> = selected.as_ref().and_then(|id| {
        store
            .retries
            .read()
            .iter()
            .find(|r| &r.conversation_id == id)
            .cloned()
    });

    rsx! {
        if let Some(session) = detail.clone() {
            ConversationHeader { session: session.clone() }
        } else if selected.is_none() {
            header { class: "conv-header",
                div { class: "conv-title",
                    h2 { "Conversation mới" }
                    p { class: "muted", "Chọn project và nhập tin nhắn bên dưới." }
                }
            }
        }

        section { class: "steps",
            if let Some(message) = detail_error.clone() {
                div { class: "empty error",
                    h2 { "Không mở được conversation" }
                    p { "{message}" }
                }
            }
            if selected.is_none() && pending_here.is_none() {
                div { class: "empty",
                    h2 { "Bắt đầu một cuộc trò chuyện" }
                    p { "Chọn project, chọn model rồi gửi tin nhắn đầu tiên." }
                }
            }
            if let Some(retry) = retry_here.clone() {
                RetryBanner { retry: retry }
            }
            if *store.has_older.read() {
                div { class: "load-older",
                    button {
                        class: "secondary",
                        disabled: *store.loading_older.read(),
                        onclick: move |_| store.load_older(),
                        if *store.loading_older.read() { "Đang tải…" } else { "Tải lịch sử trước đó" }
                    }
                }
            }
            if let Some(session) = detail.clone() {
                for plan in session.pending_plans.iter() {
                    PlanCard {
                        key: "{plan.file_name}",
                        conversation_id: session.id.clone(),
                        plan: plan.clone(),
                    }
                }
                if session.is_interrupted && !session.interrupted_reason.is_empty() {
                    div { class: "banner warn", "{session.interrupted_reason}" }
                }
                if session.steps.is_empty() && pending_here.is_none() && stream.is_none() {
                    p { class: "muted center", "Conversation chưa có bước nào." }
                }
                for (i, step) in session.steps.iter().enumerate() {
                    StepView {
                        key: "{step.step_index}",
                        step: step.clone(),
                        turn_files: if step.kind == "PLANNER_RESPONSE" {
                            files_for_turn(&session.steps, &session.files_touched, i)
                        } else {
                            Vec::new()
                        },
                    }
                }
            }
            if let Some(turn) = pending_here.clone() {
                div { class: "bubble user",
                    div { class: "bubble-text", "{turn.prompt}" }
                }
            }
            if let Some(live) = stream.clone() {
                if !live.user_prompt.is_empty()
                    && pending_here.as_ref().map(|p| p.prompt.as_str()) != Some(live.user_prompt.as_str())
                {
                    div { class: "bubble user",
                        div { class: "bubble-text", "{live.user_prompt}" }
                    }
                }
                div { class: "ai live",
                    div { class: "ai-meta muted", "Agent · đang trả lời" }
                    if !live.thinking_text.is_empty() {
                        div { class: "thinking muted", "{live.thinking_text}" }
                    }
                    if live.streaming_text.trim().is_empty() {
                        p { class: "muted", "Đang xử lý…" }
                    } else {
                        div { class: "ai-text", MarkdownView { text: live.streaming_text.clone() } }
                    }
                }
            }
        }

        if let Some(pending) = claude_pending.clone() {
            ClaudeInteraction { key: "{pending.tool_use_id}", pending: pending.clone() }
        }
        AiQuestions { questions: ai_questions.clone() }
        Composer {}
    }
}

#[derive(Props, Clone, PartialEq)]
struct HeaderProps {
    session: ConversationSession,
}

#[component]
fn ConversationHeader(props: HeaderProps) -> Element {
    let session = props.session;
    let title = if session.title.trim().is_empty() {
        "(không có tiêu đề)".to_string()
    } else {
        session.title.clone()
    };
    let state = status_label(
        &session.status,
        session.status == "running",
        session.is_interrupted,
    );
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
    }
}

#[derive(Props, Clone, PartialEq)]
struct StepViewProps {
    step: AgentStep,
    /// Tệp đã đổi trong lượt của bước này (chỉ với `PLANNER_RESPONSE`)
    turn_files: Vec<FileTouched>,
}

#[component]
fn StepView(props: StepViewProps) -> Element {
    let store = use_context::<Store>();
    let step = props.step;
    let turn_files = props.turn_files;
    match step.kind.as_str() {
        "USER_INPUT" => {
            let base = store.base();
            let urls = step.image_urls.clone();
            let count = step.image_count;
            rsx! {
                div { class: "bubble user",
                    if !urls.is_empty() {
                        div { class: "bubble-images",
                            for (i, url) in urls.into_iter().enumerate() {
                                img { key: "{i}", class: "bubble-image", alt: "Ảnh đính kèm", src: "{base}{url}" }
                            }
                        }
                    } else if count > 0 {
                        p { class: "muted", "{count} ảnh đính kèm" }
                    }
                    if !step.content.trim().is_empty() {
                        div { class: "bubble-text", "{step.content}" }
                    }
                }
            }
        }
        "PLANNER_RESPONSE" => {
            let who = if step.agent_name.is_empty() {
                "Agent".to_string()
            } else {
                step.agent_name.clone()
            };
            let model = model_label(&step.model);
            let calls = step.tool_calls.clone();
            let (added, removed) = line_totals(&turn_files);
            let file_count = turn_files.len();
            let calls_title = format!("Thao tác · {}", who);
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
                        div { class: "ai-text", MarkdownView { text: step.content.clone() } }
                    }
                    if !calls.is_empty() || file_count > 0 {
                        div { class: "turn-actions",
                            if !calls.is_empty() {
                                button {
                                    class: "chip action",
                                    onclick: move |_| store.open_dialog(Dialog::Tools {
                                        title: calls_title.clone(),
                                        calls: calls.clone(),
                                    }),
                                    "{calls.len()} thao tác"
                                }
                            }
                            if file_count > 0 {
                                button {
                                    class: "chip action",
                                    onclick: move |_| store.open_dialog(Dialog::Files {
                                        title: "Tệp thay đổi".into(),
                                        files: turn_files.clone(),
                                    }),
                                    "{file_count} tệp thay đổi · +{added} −{removed}"
                                }
                            }
                        }
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

#[derive(Props, Clone, PartialEq)]
struct RetryBannerProps {
    retry: PendingRetry,
}

/// Lịch tự gửi lại sau rate limit, có nút hủy.
#[component]
fn RetryBanner(props: RetryBannerProps) -> Element {
    let store = use_context::<Store>();
    let retry = props.retry;
    let when = short_local_time(&retry.retry_at);
    let conversation_id = retry.conversation_id.clone();
    rsx! {
        div { class: "banner retry",
            span {
                "Tự gửi lại"
                if !when.is_empty() {
                    " lúc {when}"
                }
                " (lần {retry.attempt}/{retry.max_attempts})"
                if !retry.wait_detail.is_empty() {
                    " · {retry.wait_detail}"
                }
            }
            button {
                class: "link",
                onclick: move |_| store.cancel_retry(conversation_id.clone()),
                "Hủy lịch"
            }
        }
    }
}

#[derive(Props, Clone, PartialEq)]
struct PlanCardProps {
    conversation_id: String,
    plan: PendingPlan,
}

/// Thẻ kế hoạch chờ duyệt: duyệt và chạy, góp ý chỉnh sửa, hoặc hủy.
#[component]
fn PlanCard(props: PlanCardProps) -> Element {
    let store = use_context::<Store>();
    let mut feedback_open = use_signal(|| false);
    let mut feedback = use_signal(String::new);
    let plan = props.plan;
    let title = if plan.title.is_empty() {
        plan.file_name.clone()
    } else {
        plan.title.clone()
    };
    let conv_a = props.conversation_id.clone();
    let file_a = plan.file_name.clone();
    let conv_b = props.conversation_id.clone();
    let file_b = plan.file_name.clone();
    let conv_c = props.conversation_id.clone();
    let file_c = plan.file_name.clone();

    rsx! {
        div { class: "plan-card",
            div { class: "plan-title", "Kế hoạch: {title}" }
            if !plan.summary.is_empty() {
                p { class: "muted", "{plan.summary}" }
            }
            if feedback_open() {
                textarea {
                    class: "feedback",
                    rows: "3",
                    placeholder: "Góp ý để agent chỉnh sửa kế hoạch…",
                    value: "{feedback}",
                    oninput: move |e| feedback.set(e.value()),
                }
            }
            div { class: "plan-actions",
                button {
                    class: "send",
                    onclick: move |_| store.plan_action(conv_a.clone(), file_a.clone(), "approve", String::new()),
                    "Duyệt kế hoạch & Chạy ngay"
                }
                if feedback_open() {
                    button {
                        class: "secondary",
                        disabled: feedback().trim().is_empty(),
                        onclick: move |_| {
                            let text = feedback().trim().to_string();
                            store.plan_action(conv_b.clone(), file_b.clone(), "reject", text);
                            feedback.set(String::new());
                            feedback_open.set(false);
                        },
                        "Gửi góp ý"
                    }
                } else {
                    button {
                        class: "secondary",
                        onclick: move |_| feedback_open.set(true),
                        "Góp ý chỉnh sửa"
                    }
                }
                button {
                    class: "link",
                    onclick: move |_| store.plan_action(conv_c.clone(), file_c.clone(), "cancel", String::new()),
                    "Hủy kế hoạch"
                }
            }
        }
    }
}
