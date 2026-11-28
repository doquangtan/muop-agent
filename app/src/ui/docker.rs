//! Panel Docker: chọn máy, xem container đang chạy theo project Compose, khởi động lại hoặc dừng.

use std::time::Duration;

use dioxus::prelude::*;

use crate::data::models::DockerContainer;
use crate::data::rt;
use crate::store::Store;

/// Nhãn nhóm cho container không thuộc project Compose nào.
pub const NO_PROJECT_LABEL: &str = "Không thuộc Compose";

/// Nhóm container theo project Compose: project có tên theo thứ tự chữ cái, nhóm không có project đứng cuối.
pub fn group_containers(containers: &[DockerContainer]) -> Vec<(String, Vec<DockerContainer>)> {
    let mut named: Vec<(String, Vec<DockerContainer>)> = Vec::new();
    let mut loose: Vec<DockerContainer> = Vec::new();
    for c in containers {
        if c.project.is_empty() {
            loose.push(c.clone());
            continue;
        }
        match named.iter_mut().find(|(p, _)| *p == c.project) {
            Some((_, list)) => list.push(c.clone()),
            None => named.push((c.project.clone(), vec![c.clone()])),
        }
    }
    named.sort_by_key(|a| a.0.to_lowercase());
    if !loose.is_empty() {
        named.push((NO_PROJECT_LABEL.to_string(), loose));
    }
    named
}

/// Container đang chạy (màu chấm xanh).
pub fn is_running(c: &DockerContainer) -> bool {
    c.state == "running"
}

#[component]
pub fn DockerPanel() -> Element {
    let store = use_context::<Store>();

    // Quét lại mỗi 10 giây khi panel đang mở (dừng khi panel đóng)
    use_future(move || async move {
        loop {
            rt::sleep(Duration::from_secs(10)).await;
            store.scan_docker();
        }
    });

    let hosts = store.docker_hosts.read().clone();
    let session = store.docker.read().clone();
    let selected_host = session.as_ref().map(|s| s.host_id).unwrap_or(0);

    rsx! {
        header { class: "conv-header",
            div { class: "conv-title",
                h2 { "Docker" }
                p { class: "muted",
                    if let Some(s) = session.as_ref() {
                        "{s.host_name}"
                    } else {
                        "Chọn một máy"
                    }
                }
            }
            div { class: "conv-stats",
                button { class: "toggle", onclick: move |_| store.scan_docker(), "Làm mới" }
                button { class: "toggle", onclick: move |_| store.close_docker_panel(), "Đóng" }
            }
        }
        section { class: "docker-body",
            div { class: "host-chips",
                for host in hosts.iter() {
                    button {
                        key: "{host.id}",
                        class: if host.id == selected_host { "chip active" } else { "chip" },
                        onclick: {
                            let id = host.id;
                            move |_| store.open_docker(id)
                        },
                        "{host.name}"
                    }
                }
            }
            if let Some(s) = session.clone() {
                if !s.error.is_empty() {
                    div { class: "banner error", "{s.error}" }
                }
                if s.containers.is_empty() {
                    p { class: "muted center", "Không có container nào đang chạy." }
                }
                for (project, items) in group_containers(&s.containers) {
                    section { key: "{project}", class: "docker-group",
                        h3 { class: "docker-project", "{project}" }
                        for c in items {
                            ContainerRow { key: "{c.id}", container: c.clone() }
                        }
                    }
                }
            } else {
                p { class: "muted center", "Chưa có phiên Docker. Chọn máy ở trên." }
            }
        }
    }
}

#[derive(Props, Clone, PartialEq)]
struct ContainerRowProps {
    container: DockerContainer,
}

#[component]
fn ContainerRow(props: ContainerRowProps) -> Element {
    let store = use_context::<Store>();
    let c = props.container;
    let dot = if is_running(&c) {
        "dot ok small"
    } else {
        "dot small"
    };
    let id = c.id.clone();
    let id2 = c.id.clone();
    rsx! {
        div { class: "container-row",
            span { class: "{dot}" }
            div { class: "container-main",
                div { class: "container-name", "{c.name}" }
                div { class: "muted mono", "{c.image}" }
                div { class: "muted", "{c.status}" }
            }
            div { class: "container-actions",
                button { class: "toggle", onclick: move |_| store.docker_action("restart", vec![id.clone()]), "Khởi động lại" }
                button { class: "stop", onclick: move |_| store.docker_action("stop", vec![id2.clone()]), "Dừng" }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn c(name: &str, project: &str, state: &str) -> DockerContainer {
        DockerContainer {
            id: name.into(),
            name: name.into(),
            project: project.into(),
            state: state.into(),
            ..Default::default()
        }
    }

    #[test]
    fn groups_by_project_with_loose_containers_last() {
        let list = vec![
            c("a", "zeta", "running"),
            c("b", "", "running"),
            c("c", "Alpha", "running"),
            c("d", "zeta", "exited"),
        ];
        let groups = group_containers(&list);
        let titles: Vec<&str> = groups.iter().map(|(t, _)| t.as_str()).collect();
        assert_eq!(titles, vec!["Alpha", "zeta", NO_PROJECT_LABEL]);
        assert_eq!(groups[1].1.len(), 2);
    }

    #[test]
    fn running_state_is_detected() {
        assert!(is_running(&c("x", "", "running")));
        assert!(!is_running(&c("x", "", "exited")));
    }
}
