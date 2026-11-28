//! Cột workspace và cây thư mục của project đang chọn (tải lười từng thư mục).
//! Dữ liệu từ `POST /api/sftp/list` của máy server; ẩn mục bắt đầu bằng "." mặc định.

use dioxus::prelude::*;

use crate::data::models::FsEntry;
use crate::store::Store;

/// Tên thư mục cuối của một đường dẫn: `/a/b/c` → `c`.
pub fn basename(path: &str) -> String {
    let trimmed = path.trim_end_matches('/');
    match trimmed.rsplit_once('/') {
        Some((_, name)) if !name.is_empty() => name.to_string(),
        _ if trimmed.is_empty() => "/".to_string(),
        _ => trimmed.to_string(),
    }
}

/// Class CSS của một dòng trong cây theo trạng thái git. Thư mục có tệp đổi bên trong được đánh dấu chung.
pub fn git_class(
    path: &str,
    kinds: &std::collections::HashMap<String, String>,
    is_dir: bool,
) -> &'static str {
    if is_dir {
        let prefix = format!("{}/", path.trim_end_matches('/'));
        return if kinds.keys().any(|k| k.starts_with(&prefix)) {
            "git-dir"
        } else {
            ""
        };
    }
    match kinds.get(path).map(String::as_str) {
        Some("modified") => "git-modified",
        Some("created") => "git-created",
        Some("deleted") => "git-deleted",
        Some(_) => "git-other",
        None => "",
    }
}

/// Mục hiển thị trong cây: thư mục trước, rồi theo tên; bỏ mục ẩn nếu `show_hidden` là false.
pub fn visible_entries(entries: &[FsEntry], show_hidden: bool) -> Vec<FsEntry> {
    let mut list: Vec<FsEntry> = entries
        .iter()
        .filter(|e| show_hidden || !e.name.starts_with('.'))
        .cloned()
        .collect();
    list.sort_by(|a, b| {
        b.is_dir
            .cmp(&a.is_dir)
            .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
    });
    list
}

/// Số tệp đã đổi trong project (hiện ở tiêu đề cột tệp).
pub fn changed_count(kinds: &std::collections::HashMap<String, String>) -> usize {
    kinds.len()
}

#[component]
pub fn Explorer() -> Element {
    let store = use_context::<Store>();
    let meta = store.meta.read().clone();
    let root = store.project.read().clone();
    let _ = store.git_kinds.read();
    let projects = meta.map(|m| m.projects).unwrap_or_default();

    rsx! {
        aside { class: "explorer",
            div { class: "explorer-header",
                span { "Workspace" }
            }
            div { class: "project-list",
                if projects.is_empty() {
                    p { class: "muted pad", "Chưa có project." }
                }
                for project in projects.iter() {
                    button {
                        key: "{project.path}",
                        class: if project.path == root { "project-row active" } else { "project-row" },
                        onclick: {
                            let path = project.path.clone();
                            move |_| store.set_project(path.clone())
                        },
                        span { class: "project-name", "{project.name}" }
                        span { class: "project-count muted",
                            if project.running_count > 0 {
                                span { class: "dot ok small" }
                            }
                            "{project.session_count}"
                        }
                    }
                }
            }
            div { class: "explorer-header",
                span { "Tệp" }
                if *store.git_repo.read() {
                    span { class: "git-count", "{changed_count(&store.git_kinds.read())} đã đổi" }
                    button {
                        class: "link git-history-btn",
                        title: "Xem lịch sử commit của project",
                        onclick: move |_| store.toggle_git_panel(),
                        "Lịch sử"
                    }
                }
            }
            div { class: "tree",
                if root.is_empty() {
                    p { class: "muted pad", "Chọn một project để xem tệp." }
                } else {
                    DirTree {
                        key: "{root}",
                        path: root.clone(),
                        name: basename(&root),
                        depth: 0,
                        is_dir: true,
                    }
                }
            }
        }
    }
}

#[derive(Props, Clone, PartialEq)]
pub struct DirTreeProps {
    pub path: String,
    pub name: String,
    pub depth: usize,
    pub is_dir: bool,
}

/// Một nút của cây. Thư mục gốc mở sẵn; thư mục khác tải danh sách khi được mở.
#[component]
pub fn DirTree(props: DirTreeProps) -> Element {
    let store = use_context::<Store>();
    let mut expanded = use_signal(|| props.depth == 0 && props.is_dir);
    let mut children = use_signal(|| None::<Result<Vec<FsEntry>, String>>);
    let mut loading = use_signal(|| false);

    let path = props.path.clone();
    use_effect(move || {
        if expanded() && children.peek().is_none() && !*loading.peek() {
            loading.set(true);
            let p = path.clone();
            dioxus::prelude::spawn(async move {
                let result = store.list_dir(p).await;
                loading.set(false);
                children.set(Some(result));
            });
        }
    });

    let indent = format!("padding-left: {}px", 8 + props.depth * 14);
    let icon = if !props.is_dir {
        "·"
    } else if expanded() {
        "▾"
    } else {
        "▸"
    };
    let git_cls = {
        let kinds = store.git_kinds.read();
        git_class(&props.path, &kinds, props.is_dir)
    };
    let file_path = props.path.clone();
    let row_class = if props.is_dir {
        "tree-row dir"
    } else {
        "tree-row file"
    };
    let is_dir = props.is_dir;
    let depth = props.depth;

    rsx! {
        div { class: "tree-node",
            button {
                class: "{row_class} {git_cls}",
                style: "{indent}",
                onclick: move |_| {
                    if is_dir {
                        let open = expanded();
                        expanded.set(!open);
                    } else {
                        store.open_file(file_path.clone());
                    }
                },
                span { class: "tree-icon", "{icon}" }
                span { class: "tree-name", "{props.name}" }
            }
            if is_dir && expanded() {
                if loading() && children.read().is_none() {
                    p { class: "muted tree-status", style: "padding-left: {8 + (depth + 1) * 14}px", "Đang tải…" }
                }
                match children.read().clone() {
                    Some(Err(message)) => rsx! {
                        p { class: "form-error tree-status", style: "padding-left: {8 + (depth + 1) * 14}px", "{message}" }
                    },
                    Some(Ok(entries)) => rsx! {
                        for entry in visible_entries(&entries, false) {
                            DirTree {
                                key: "{entry.path}",
                                path: entry.path.clone(),
                                name: entry.name.clone(),
                                depth: depth + 1,
                                is_dir: entry.is_dir,
                            }
                        }
                    },
                    None => rsx! {},
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn git_class_marks_files_and_parent_dirs() {
        let mut kinds = std::collections::HashMap::new();
        kinds.insert("/p/lib/a.rs".to_string(), "modified".to_string());
        kinds.insert("/p/new.txt".to_string(), "created".to_string());
        assert_eq!(git_class("/p/lib/a.rs", &kinds, false), "git-modified");
        assert_eq!(git_class("/p/new.txt", &kinds, false), "git-created");
        assert_eq!(git_class("/p/other.rs", &kinds, false), "");
        assert_eq!(git_class("/p/lib", &kinds, true), "git-dir");
        assert_eq!(git_class("/p/app", &kinds, true), "");
        assert_eq!(changed_count(&kinds), 2);
    }

    fn entry(name: &str, is_dir: bool) -> FsEntry {
        FsEntry {
            name: name.into(),
            path: format!("/p/{name}"),
            is_dir,
            size: 0,
        }
    }

    #[test]
    fn basename_takes_last_segment() {
        assert_eq!(basename("/home/john/muop-agent"), "muop-agent");
        assert_eq!(basename("/home/john/muop-agent/"), "muop-agent");
        assert_eq!(basename("/"), "/");
    }

    #[test]
    fn folders_come_first_and_hidden_are_filtered() {
        let entries = vec![
            entry("zeta.txt", false),
            entry(".git", true),
            entry("lib", true),
            entry("Alpha.md", false),
        ];
        let names: Vec<_> = visible_entries(&entries, false)
            .into_iter()
            .map(|e| e.name)
            .collect();
        assert_eq!(names, vec!["lib", "Alpha.md", "zeta.txt"]);
        let all = visible_entries(&entries, true);
        assert_eq!(all.len(), 4);
        // Mọi thư mục đứng trước mọi tệp, kể cả khi hiện mục ẩn
        assert!(all[..2].iter().all(|e| e.is_dir));
        assert!(all.iter().any(|e| e.name == ".git"));
    }
}
