//! Khung xem tệp trong khung chính: nội dung có số dòng, cắt bớt khi quá dài.

use dioxus::prelude::*;

use crate::store::Store;

/// Số dòng tối đa được vẽ; tệp dài hơn chỉ hiện phần đầu để giao diện không chậm.
pub const MAX_RENDER_LINES: usize = 2000;

/// Các dòng cần vẽ và cờ cho biết có bị cắt không.
pub fn visible_lines(content: &str, max: usize) -> (Vec<&str>, bool) {
    let total = content.lines().count();
    let lines: Vec<&str> = content.lines().take(max).collect();
    (lines, total > max)
}

#[component]
pub fn FileView() -> Element {
    let store = use_context::<Store>();
    let file = store.viewed_file.read().clone();
    let Some(file) = file else {
        return rsx! {};
    };
    let (lines, truncated) = visible_lines(&file.content, MAX_RENDER_LINES);
    let size_text = format!("{} KB", file.size.div_ceil(1024));

    rsx! {
        header { class: "conv-header file-head",
            div { class: "conv-title",
                h2 { "{file.name}" }
                p { class: "muted mono", "{file.path}" }
            }
            div { class: "conv-stats muted",
                span { "{size_text}" }
                button { class: "toggle", onclick: move |_| store.close_file(), "Đóng tệp" }
            }
        }
        section { class: "file-body",
            if file.loading {
                p { class: "muted center", "Đang đọc tệp…" }
            } else if let Some(message) = file.error.clone() {
                div { class: "banner error", "{message}" }
            } else if file.binary {
                p { class: "muted center", "Tệp nhị phân, không hiển thị nội dung." }
            } else {
                pre { class: "code",
                    for (i, line) in lines.iter().enumerate() {
                        div { key: "{i}", class: "code-line",
                            span { class: "ln", "{i + 1}" }
                            span { class: "code-text", "{line}" }
                        }
                    }
                }
                if truncated {
                    p { class: "muted center", "Chỉ hiện {MAX_RENDER_LINES} dòng đầu của tệp." }
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn visible_lines_caps_long_files() {
        let text = (1..=5)
            .map(|i| format!("l{i}"))
            .collect::<Vec<_>>()
            .join("\n");
        let (lines, truncated) = visible_lines(&text, 3);
        assert_eq!(lines, vec!["l1", "l2", "l3"]);
        assert!(truncated);
        let (all, cut) = visible_lines(&text, 10);
        assert_eq!(all.len(), 5);
        assert!(!cut);
    }
}
