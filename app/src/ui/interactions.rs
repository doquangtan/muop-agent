//! Tương tác đang chờ người dùng: câu hỏi `AskUserQuestion` và kế hoạch của Claude (`ExitPlanMode`),
//! cùng câu hỏi của agy. Logic ghép đáp án là hàm thuần có test.

use dioxus::prelude::*;

use crate::data::models::{AiQuestion, ClaudePending, ClaudeQuestion};
use crate::store::Store;
use crate::ui::markdown::MarkdownView;

/// Ghép đáp án cho mọi câu hỏi. Ưu tiên nội dung nhập tự do; không có thì dùng lựa chọn đã chọn.
/// Trả `None` khi còn câu chưa có đáp án.
pub fn build_answers(
    questions: &[ClaudeQuestion],
    selections: &[Vec<String>],
    free: &[String],
) -> Option<Vec<(String, String)>> {
    let mut out = Vec::with_capacity(questions.len());
    for (i, question) in questions.iter().enumerate() {
        let typed = free.get(i).map(|t| t.trim()).unwrap_or_default();
        let picked = selections.get(i).cloned().unwrap_or_default();
        let answer = if !typed.is_empty() {
            typed.to_string()
        } else if !picked.is_empty() {
            picked.join(", ")
        } else {
            return None;
        };
        out.push((question.question.clone(), answer));
    }
    Some(out)
}

/// Chọn hoặc bỏ chọn một lựa chọn. Câu một lựa chọn chỉ giữ đúng một đáp án.
pub fn toggle_option(current: &mut Vec<String>, label: &str, multi_select: bool) {
    if let Some(index) = current.iter().position(|c| c == label) {
        current.remove(index);
        return;
    }
    if !multi_select {
        current.clear();
    }
    current.push(label.to_string());
}

#[derive(Props, Clone, PartialEq)]
pub struct ClaudeInteractionProps {
    pub pending: ClaudePending,
}

/// Tương tác Claude đang chờ. Được đặt theo `toolUseId` để trạng thái chọn lại từ đầu với mỗi tương tác.
#[component]
pub fn ClaudeInteraction(props: ClaudeInteractionProps) -> Element {
    let pending = props.pending;
    if pending.kind == "plan" {
        return rsx! { PlanDecision { plan: pending.plan.clone() } };
    }
    rsx! { QuestionSet { questions: pending.questions.clone() } }
}

#[derive(Props, Clone, PartialEq)]
struct QuestionSetProps {
    questions: Vec<ClaudeQuestion>,
}

#[component]
fn QuestionSet(props: QuestionSetProps) -> Element {
    let store = use_context::<Store>();
    let questions = props.questions;
    let count = questions.len();
    let mut selections = use_signal(|| vec![Vec::<String>::new(); count]);
    let mut free = use_signal(|| vec![String::new(); count]);

    let answers = build_answers(&questions, &selections(), &free());

    rsx! {
        div { class: "plan-card claude-question",
            div { class: "plan-title", "Claude cần bạn trả lời" }
            for (qi, question) in questions.iter().enumerate() {
                div { key: "{qi}", class: "q-block",
                    if !question.header.is_empty() {
                        div { class: "q-header muted", "{question.header}" }
                    }
                    p { class: "q-text", "{question.question}" }
                    div { class: "q-options",
                        for option in question.options.iter() {
                            {
                                let label = option.label.clone();
                                let multi = question.multi_select;
                                let picked = selections()
                                    .get(qi)
                                    .map(|sel| sel.contains(&label))
                                    .unwrap_or(false);
                                rsx! {
                                    button {
                                        key: "{label}",
                                        class: if picked { "q-option picked" } else { "q-option" },
                                        title: "{option.description}",
                                        onclick: move |_| {
                                            let mut all = selections.peek().clone();
                                            if let Some(sel) = all.get_mut(qi) {
                                                toggle_option(sel, &label, multi);
                                            }
                                            selections.set(all);
                                        },
                                        span { class: "q-option-label", "{option.label}" }
                                        if !option.description.is_empty() {
                                            span { class: "q-option-desc muted", "{option.description}" }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    input {
                        class: "q-free",
                        r#type: "text",
                        placeholder: "Hoặc nhập câu trả lời khác",
                        value: "{free()[qi]}",
                        oninput: move |e| {
                            let mut all = free.peek().clone();
                            if let Some(slot) = all.get_mut(qi) {
                                *slot = e.value();
                            }
                            free.set(all);
                        },
                    }
                }
            }
            div { class: "plan-actions",
                button {
                    class: "send",
                    disabled: answers.is_none(),
                    onclick: move |_| {
                        if let Some(list) = answers.clone() {
                            store.respond_claude(list, "", String::new());
                        }
                    },
                    "Gửi trả lời"
                }
            }
        }
    }
}

#[derive(Props, Clone, PartialEq)]
struct PlanDecisionProps {
    plan: String,
}

#[component]
fn PlanDecision(props: PlanDecisionProps) -> Element {
    let store = use_context::<Store>();
    let mut feedback_open = use_signal(|| false);
    let mut feedback = use_signal(String::new);
    rsx! {
        div { class: "plan-card claude-plan",
            div { class: "plan-title", "Kế hoạch của Claude" }
            div { class: "plan-body", MarkdownView { text: props.plan.clone() } }
            if feedback_open() {
                textarea {
                    class: "feedback",
                    rows: "3",
                    placeholder: "Góp ý để Claude chỉnh sửa kế hoạch…",
                    value: "{feedback}",
                    oninput: move |e| feedback.set(e.value()),
                }
            }
            div { class: "plan-actions",
                button {
                    class: "send",
                    onclick: move |_| store.respond_claude(Vec::new(), "approve", String::new()),
                    "Duyệt và chạy"
                }
                if feedback_open() {
                    button {
                        class: "secondary",
                        disabled: feedback().trim().is_empty(),
                        onclick: move |_| {
                            let text = feedback().trim().to_string();
                            store.respond_claude(Vec::new(), "feedback", text);
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
                    onclick: move |_| store.respond_claude(Vec::new(), "cancel", String::new()),
                    "Hủy"
                }
            }
        }
    }
}

#[derive(Props, Clone, PartialEq)]
pub struct AiQuestionsProps {
    pub questions: Vec<AiQuestion>,
}

/// Câu hỏi của agy còn chờ trả lời.
#[component]
pub fn AiQuestions(props: AiQuestionsProps) -> Element {
    let pending: Vec<AiQuestion> = props
        .questions
        .into_iter()
        .filter(|q| q.is_pending)
        .collect();
    if pending.is_empty() {
        return rsx! {};
    }
    rsx! {
        div { class: "ai-questions",
            for question in pending {
                AiQuestionCard { key: "{question.id}", question: question.clone() }
            }
        }
    }
}

#[derive(Props, Clone, PartialEq)]
struct AiQuestionCardProps {
    question: AiQuestion,
}

#[component]
fn AiQuestionCard(props: AiQuestionCardProps) -> Element {
    let store = use_context::<Store>();
    let mut answer = use_signal(String::new);
    let id = props.question.id.clone();
    let text = props.question.question.clone();
    let ready = !answer().trim().is_empty();
    rsx! {
        div { class: "plan-card ai-question",
            div { class: "plan-title", "Agent hỏi" }
            p { class: "q-text", "{text}" }
            div { class: "composer-row",
                input {
                    class: "q-free",
                    r#type: "text",
                    placeholder: "Nhập câu trả lời…",
                    value: "{answer}",
                    oninput: move |e| answer.set(e.value()),
                }
                button {
                    class: "send",
                    disabled: !ready,
                    onclick: move |_| {
                        let value = answer().trim().to_string();
                        store.answer_ai(id.clone(), value);
                        answer.set(String::new());
                    },
                    "Trả lời"
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::data::models::ClaudeOption;

    fn question(text: &str, multi: bool) -> ClaudeQuestion {
        ClaudeQuestion {
            question: text.into(),
            multi_select: multi,
            options: vec![ClaudeOption {
                label: "A".into(),
                description: String::new(),
            }],
            ..Default::default()
        }
    }

    #[test]
    fn answers_need_every_question() {
        let qs = vec![question("Q1", false), question("Q2", false)];
        assert!(build_answers(&qs, &[vec!["A".into()], vec![]], &[]).is_none());
        let got = build_answers(&qs, &[vec!["A".into()], vec!["B".into()]], &[]).unwrap();
        assert_eq!(
            got,
            vec![("Q1".into(), "A".into()), ("Q2".into(), "B".into())]
        );
    }

    #[test]
    fn free_text_wins_over_selection_and_multi_joins() {
        let qs = vec![question("Q1", true)];
        let got =
            build_answers(&qs, &[vec!["A".into(), "B".into()]], &["  khác  ".into()]).unwrap();
        assert_eq!(got[0].1, "khác");
        let got = build_answers(&qs, &[vec!["A".into(), "B".into()]], &[String::new()]).unwrap();
        assert_eq!(got[0].1, "A, B");
    }

    #[test]
    fn single_select_keeps_one_choice_and_toggle_clears() {
        let mut sel: Vec<String> = Vec::new();
        toggle_option(&mut sel, "A", false);
        toggle_option(&mut sel, "B", false);
        assert_eq!(sel, vec!["B"]);
        toggle_option(&mut sel, "B", false);
        assert!(sel.is_empty());
        let mut multi: Vec<String> = Vec::new();
        toggle_option(&mut multi, "A", true);
        toggle_option(&mut multi, "B", true);
        assert_eq!(multi, vec!["A", "B"]);
    }
}
