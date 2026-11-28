//! Ô nhập tin nhắn: chọn project (conversation mới), model, mức suy luận, gửi và dừng.

use dioxus::html::Key;
use dioxus::prelude::*;

use crate::data::images::data_url;
use crate::data::models::QuotaReport;
use crate::store::Store;
use crate::ui::format::{model_label, short_local_time};
use crate::ui::model_groups::{
    effort_label, group_models, parse_model_id, resolve_levels, ModelGroup,
};
use crate::ui::model_groups::{model_sections, ModelSection};

#[component]
pub fn Composer() -> Element {
    let store = use_context::<Store>();

    let connected = *store.connected.read();
    let sending = *store.sending.read();
    let selected = store.selected.read().clone();
    let notice = store.notice.read().clone();
    let model = store.model.read().clone();
    let project = store.project.read().clone();
    let meta = store.meta.read().clone();
    let streams = store.streams.read().clone();
    let running = selected
        .as_ref()
        .map(|id| streams.contains_key(id))
        .unwrap_or(false);

    let levels = resolve_levels(
        &meta
            .as_ref()
            .map(|m| m.effort_levels.clone())
            .unwrap_or_default(),
    );
    let labels = meta
        .as_ref()
        .map(|m| m.model_labels.clone())
        .unwrap_or_default();
    let models = meta
        .as_ref()
        .map(|m| m.available_models.clone())
        .unwrap_or_default();
    let groups: Vec<ModelGroup> = group_models(&models, &labels, &levels);
    let (current_group_id, current_effort) = parse_model_id(&model, &levels);
    let current_group = groups.iter().find(|g| g.id == current_group_id).cloned();
    let mut menu_open = use_signal(|| false);
    let current_label = current_group
        .as_ref()
        .map(|g| g.label.clone())
        .unwrap_or_else(|| model_label(&model));

    // Nháp theo conversation: đổi conversation không làm mất chữ đang soạn dở
    let draft_key = selected.clone().unwrap_or_else(|| "new".to_string());
    let draft = store.draft_for(&draft_key);
    let drafts = store.draft_images.read().clone();
    let send_disabled = !connected || sending || (draft.trim().is_empty() && drafts.is_empty());
    let can_pick_project = selected.is_none();
    let projects = meta
        .as_ref()
        .map(|m| m.projects.clone())
        .unwrap_or_default();

    let submit = move || {
        let key = store
            .selected
            .peek()
            .clone()
            .unwrap_or_else(|| "new".to_string());
        let text = store.draft_for(&key);
        if text.trim().is_empty() && store.draft_images.peek().is_empty() {
            return;
        }
        store.send(text);
        store.set_draft(&key, String::new());
    };

    let attach = move |_| {
        dioxus::prelude::spawn(async move {
            if let Ok(picked) = pick_images().await {
                if !picked.is_empty() {
                    store.add_images(picked);
                }
            }
        });
    };

    rsx! {
        div { class: "composer-wrap",
            if let Some(message) = notice {
                div { class: "banner error", "{message}" }
            }
            div { class: "composer",
                if can_pick_project {
                    div { class: "composer-row",
                        label { class: "muted", "Project" }
                        select {
                            value: "{project}",
                            onchange: move |e| store.project.clone().set(e.value()),
                            if projects.is_empty() {
                                option { value: "", "Chưa có project" }
                            }
                            for p in projects.iter() {
                                option { key: "{p.path}", value: "{p.path}", "{p.name}" }
                            }
                        }
                    }
                }
                if !drafts.is_empty() {
                    div { class: "draft-images",
                        for image in drafts.iter() {
                            div { key: "{image.id}", class: "draft-thumb",
                                img {
                                    src: "{data_url(&image.mime_type, &image.data_base64)}",
                                    alt: "{image.name}",
                                }
                                span { class: "draft-name muted", "{image.name}" }
                                button {
                                    class: "link",
                                    title: "Bỏ ảnh này",
                                    onclick: {
                                        let id = image.id;
                                        move |_| store.remove_image(id)
                                    },
                                    "×"
                                }
                            }
                        }
                    }
                }
                textarea {
                    class: "prompt",
                    rows: "3",
                    placeholder: "Nhắn cho agent… (Enter gửi, Shift+Enter xuống dòng)",
                    value: "{draft}",
                    oninput: {
                        let key = draft_key.clone();
                        move |e: FormEvent| store.set_draft(&key, e.value())
                    },
                    onkeydown: move |e: KeyboardEvent| {
                        if e.key() == Key::Enter && !e.modifiers().shift() {
                            e.prevent_default();
                            if !send_disabled {
                                submit();
                            }
                        }
                    },
                }
                div { class: "composer-row",
                    div { class: "model-anchor",
                        button {
                            class: "model-button",
                            title: "Chọn model",
                            onclick: move |_| {
                                let open = menu_open();
                                menu_open.set(!open);
                            },
                            span { class: "model-button-label", "{current_label}" }
                            span { class: "muted", " ▾" }
                        }
                        if menu_open() {
                            div { class: "model-menu-backdrop", onclick: move |_| menu_open.set(false) }
                            ModelMenu {
                                groups: groups.clone(),
                                current_group_id: current_group_id.clone(),
                                current_effort: current_effort.clone(),
                                on_pick: move |id: String| {
                                    store.model.clone().set(id);
                                    menu_open.set(false);
                                },
                            }
                        }
                    }
                    if let Some(group) = current_group.clone() {
                        if group.has_effort_choices() {
                            select {
                                class: "effort-select",
                                value: "{current_effort.clone().unwrap_or_default()}",
                                onchange: move |e| {
                                    let value = e.value();
                                    if let Some(option) = group.option_with_effort(Some(value.as_str())) {
                                        store.model.clone().set(option.id.clone());
                                    }
                                },
                                for option in current_group.clone().map(|g| g.options).unwrap_or_default() {
                                    if let Some(effort) = option.effort.clone() {
                                        option { key: "{effort}", value: "{effort}", "{effort_label(&effort)}" }
                                    }
                                }
                            }
                        }
                    }
                    div { class: "spacer" }
                    QuotaChip { provider: provider_of(&model) }
                    button {
                        class: "secondary attach",
                        title: "Đính kèm ảnh (PNG, JPEG, WebP; tối đa 6 ảnh, 20MB mỗi ảnh)",
                        onclick: attach,
                        "+ Ảnh"
                    }
                    if running {
                        button { class: "stop", onclick: move |_| store.stop(), "Dừng" }
                    }
                    button {
                        class: "send",
                        disabled: send_disabled,
                        onclick: move |_| submit(),
                        if sending { "Đang gửi…" } else { "Gửi" }
                    }
                }
            }
        }
    }
}

/// Provider của id model: `agy:…` → `agy`, `claude-cli:…` → `claude`.
pub fn provider_of(model: &str) -> &'static str {
    if model.starts_with("agy:") {
        "agy"
    } else if model.starts_with("claude-cli:") {
        "claude"
    } else {
        ""
    }
}

/// Nhãn ngắn cho cửa sổ quota: `5h` → `5 giờ`, `weekly` → `Tuần`.
pub fn window_label(window: &str) -> &str {
    match window {
        "5h" => "5 giờ",
        "weekly" => "Tuần",
        other => other,
    }
}

#[component]
fn QuotaChip(provider: String) -> Element {
    let store = use_context::<Store>();
    let snapshot = store.quota.read().clone();
    let Some(report) = snapshot.as_ref().and_then(|s| s.report(&provider)).cloned() else {
        return rsx! {};
    };
    if provider.is_empty() {
        return rsx! {};
    }
    rsx! { QuotaSummary { report: report } }
}

#[component]
fn QuotaSummary(report: QuotaReport) -> Element {
    if !report.error.is_empty() {
        return rsx! { span { class: "muted quota", title: "{report.error}", "Không có dữ liệu quota" } };
    }
    let Some(group) = report.groups.first().cloned() else {
        return rsx! {};
    };
    rsx! {
        div { class: "quota",
            for bucket in sorted_buckets(&group.buckets) {
                {
                    let reset = short_local_time(&bucket.reset_time);
                    let tip = if reset.is_empty() {
                        bucket.description.clone()
                    } else {
                        format!("{} · reset {reset}", bucket.description)
                    };
                    let text = quota_label(&bucket);
                    rsx! {
                        span { key: "{bucket.window}", class: "quota-item", title: "{tip}", "{text}" }
                    }
                }
            }
        }
    }
}

/// Hộp thoại chọn ảnh của hệ điều hành. Trả về (tên, nội dung) của các file đã chọn.
/// Chạy trên runtime I/O để không phụ thuộc runtime của giao diện.
pub async fn pick_images() -> Result<Vec<(String, Vec<u8>)>, String> {
    crate::data::rt::run(async move {
        let handles = rfd::AsyncFileDialog::new()
            .set_title("Chọn ảnh đính kèm")
            .add_filter("Ảnh", &["png", "jpg", "jpeg", "webp"])
            .pick_files()
            .await
            .unwrap_or_default();
        let mut picked = Vec::with_capacity(handles.len());
        for handle in handles {
            let name = handle.file_name();
            let bytes = handle.read().await;
            picked.push((name, bytes));
        }
        picked
    })
    .await
}

#[derive(Props, Clone, PartialEq)]
pub struct ModelMenuProps {
    groups: Vec<ModelGroup>,
    current_group_id: String,
    current_effort: Option<String>,
    on_pick: EventHandler<String>,
}

/// Menu chọn model theo khối provider. Chọn một nhóm dùng mức hiện tại nếu có, không thì `medium`.
#[component]
pub fn ModelMenu(props: ModelMenuProps) -> Element {
    let sections: Vec<ModelSection> = model_sections(&props.groups);
    rsx! {
        div { class: "model-menu",
            for section in sections {
                div { key: "{section.title}", class: "model-section",
                    div { class: "model-section-title", "{section.title}" }
                    for group in section.groups.iter() {
                        {
                            let picked = group.id == props.current_group_id;
                            let preferred = group.preferred_option(props.current_effort.as_deref()).id.clone();
                            rsx! {
                                button {
                                    key: "{group.id}",
                                    class: if picked { "model-item picked" } else { "model-item" },
                                    onclick: move |_| props.on_pick.call(preferred.clone()),
                                    span { class: "model-item-label", "{group.label}" }
                                    if picked {
                                        span { class: "model-item-check", "✓" }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Thứ tự hiển thị cửa sổ quota: tuần trước, rồi 5 giờ, các cửa sổ khác sau cùng.
pub fn sorted_buckets(
    buckets: &[crate::data::models::QuotaBucket],
) -> Vec<crate::data::models::QuotaBucket> {
    let rank = |w: &str| match w {
        "weekly" => 0,
        "5h" => 1,
        _ => 2,
    };
    let mut list = buckets.to_vec();
    list.sort_by_key(|b| rank(&b.window));
    list
}

/// Nhãn một cửa sổ quota kèm phần trăm còn lại và thời điểm reset: `Tuần 24% (03/12 18:56)`.
pub fn quota_label(bucket: &crate::data::models::QuotaBucket) -> String {
    let reset = short_local_time(&bucket.reset_time);
    if reset.is_empty() {
        format!(
            "{} {:.0}%",
            window_label(&bucket.window),
            bucket.remaining_percent
        )
    } else {
        format!(
            "{} {:.0}% ({reset})",
            window_label(&bucket.window),
            bucket.remaining_percent
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::data::models::QuotaBucket;

    #[test]
    fn weekly_bucket_comes_before_five_hour() {
        let buckets = vec![
            QuotaBucket {
                window: "5h".into(),
                ..Default::default()
            },
            QuotaBucket {
                window: "weekly".into(),
                ..Default::default()
            },
        ];
        let sorted = sorted_buckets(&buckets);
        assert_eq!(sorted[0].window, "weekly");
        assert_eq!(sorted[1].window, "5h");
    }

    #[test]
    fn window_label_maps_known_windows() {
        assert_eq!(window_label("weekly"), "Tuần");
        assert_eq!(window_label("5h"), "5 giờ");
        assert_eq!(window_label("other"), "other");
    }

    #[test]
    fn quota_label_shows_percent_and_reset_when_known() {
        let with_reset = QuotaBucket {
            window: "weekly".into(),
            remaining_percent: 24.0,
            reset_time: "2026-12-03T11:56:13Z".into(),
            ..Default::default()
        };
        let label = quota_label(&with_reset);
        assert!(label.starts_with("Tuần 24% ("), "got {label}");
        let without = QuotaBucket {
            window: "5h".into(),
            remaining_percent: 0.0,
            ..Default::default()
        };
        assert_eq!(quota_label(&without), "5 giờ 0%");
    }
}
