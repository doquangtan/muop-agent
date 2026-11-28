//! Kiểm tra giao diện bằng render HTML (SSR): nạp dữ liệu như từ socket, rồi xem DOM có đủ không.
//! Không mở cửa sổ, không gọi mạng.

use dioxus::prelude::*;
use serde_json::json;

use crate::data::models::{
    ConversationSession, PendingPlan, PendingRetry, QuotaBucket, QuotaGroup, QuotaReport,
    QuotaSnapshot,
};
use crate::data::socket::Incoming;
use crate::store::Store;
use crate::ui::composer::Composer;
use crate::ui::conversation::Conversation;
use crate::ui::sidebar::Sidebar;

fn seeded_store() -> Store {
    let store = Store::create();
    store.handle(Incoming::Connected);
    store.handle(Incoming::Event {
        name: "meta:update".into(),
        data: json!({
            "hostname": "may-test",
            "projects": [{"id": "p1", "name": "alpha", "path": "/x/alpha"}],
            "availableModels": ["claude-cli:claude-sonnet-5-5", "agy:gemini-4-argon-low", "agy:gemini-4-argon-high"],
            "modelLabels": {"agy:gemini-4-argon-high": "Gemini 4 Argon (High)"},
            "effortLevels": ["low", "medium", "high"]
        }),
    });
    store.handle(Incoming::Event {
        name: "sessions:list".into(),
        data: json!({"sessions": [
            {"id": "s1", "title": "Phiên một", "projectName": "alpha", "projectPath": "/x/alpha",
             "status": "completed", "updatedAt": "2026-11-27T10:00:00+00:00"},
            {"id": "s2", "title": "Phiên hai", "projectName": "beta", "projectPath": "/x/beta",
             "status": "completed", "updatedAt": "2026-11-26T10:00:00+00:00"}
        ]}),
    });
    store.handle(Incoming::Event {
        name: "streams:update".into(),
        data: json!({"activeStreams": {"s1": {"conversationId": "s1", "isRunning": true,
            "userPrompt": "câu đang chạy", "streamingText": "đang viết dở"}}}),
    });
    store
}

#[test]
fn sidebar_lists_sessions_grouped_by_project() {
    #[component]
    fn Harness() -> Element {
        let store = seeded_store();
        use_context_provider(|| store);
        rsx! { Sidebar {} }
    }
    let mut dom = VirtualDom::new(Harness);
    dom.rebuild_in_place();
    let html = dioxus_ssr::render(&dom);
    assert!(html.contains("Phiên một"), "thiếu session s1: {html}");
    assert!(html.contains("Phiên hai"), "thiếu session s2");
    assert!(
        html.contains("alpha") && html.contains("beta"),
        "thiếu nhóm project"
    );
    assert!(
        html.contains("Đã kết nối · may-test"),
        "thiếu tên máy từ meta"
    );
}

#[test]
fn conversation_shows_steps_stream_retry_plan_and_quota() {
    #[component]
    fn Harness() -> Element {
        let store = seeded_store();
        use_context_provider(|| store);
        // Mở s1 và nạp chi tiết (như sau khi gọi REST)
        let mut selected = store.selected;
        selected.set(Some("s1".into()));
        let mut detail = store.detail;
        detail.set(Some(ConversationSession {
            id: "s1".into(),
            title: "Phiên một".into(),
            project_name: "alpha".into(),
            status: "completed".into(),
            selected_model: "claude-cli:claude-sonnet-5-5".into(),
            steps: vec![
                crate::data::models::AgentStep {
                    step_index: 1,
                    kind: "USER_INPUT".into(),
                    content: "câu hỏi lịch sử".into(),
                    ..Default::default()
                },
                crate::data::models::AgentStep {
                    step_index: 2,
                    kind: "PLANNER_RESPONSE".into(),
                    agent_name: "Coordinator".into(),
                    content: "câu trả lời lịch sử".into(),
                    ..Default::default()
                },
            ],
            pending_plans: vec![PendingPlan {
                file_name: "plan.md".into(),
                title: "Kế hoạch A".into(),
                request_feedback: true,
                ..Default::default()
            }],
            ..Default::default()
        }));
        let mut retries = store.retries;
        retries.set(vec![PendingRetry {
            conversation_id: "s1".into(),
            attempt: 2,
            max_attempts: 8,
            wait_detail: "Chờ reset quota".into(),
            ..Default::default()
        }]);
        let mut quota = store.quota;
        quota.set(Some(QuotaSnapshot {
            claude: QuotaReport {
                provider: "claude".into(),
                groups: vec![QuotaGroup {
                    display_name: "Claude".into(),
                    buckets: vec![QuotaBucket {
                        window: "5h".into(),
                        remaining_percent: 58.0,
                        ..Default::default()
                    }],
                }],
                error: String::new(),
            },
            ..Default::default()
        }));
        rsx! { Conversation {} Composer {} }
    }
    let mut dom = VirtualDom::new(Harness);
    dom.rebuild_in_place();
    let html = dioxus_ssr::render(&dom);
    for expected in [
        "câu hỏi lịch sử",
        "câu trả lời lịch sử",
        "câu đang chạy",
        "đang viết dở",
        "Tự gửi lại",
        "Chờ reset quota",
        "Kế hoạch: Kế hoạch A",
        "Duyệt kế hoạch",
        "5 giờ 58%",
        "Claude Sonnet 5 5",
    ] {
        assert!(html.contains(expected), "thiếu '{expected}' trong:\n{html}");
    }
}

#[test]
fn model_menu_shows_effort_choices_for_grouped_models() {
    #[component]
    fn Harness() -> Element {
        let store = seeded_store();
        use_context_provider(|| store);
        let mut model = store.model;
        model.set("agy:gemini-4-argon-high".into());
        rsx! { Composer {} }
    }
    let mut dom = VirtualDom::new(Harness);
    dom.rebuild_in_place();
    let html = dioxus_ssr::render(&dom);
    assert!(html.contains("Gemini 4 Argon"), "thiếu nhãn nhóm model");
    assert!(html.contains("effort-select"), "thiếu chọn mức suy luận");
    assert!(html.contains("High"), "thiếu mức High");
}

#[test]
fn explorer_lists_projects_and_marks_selected_root() {
    #[component]
    fn Harness() -> Element {
        let store = seeded_store();
        use_context_provider(|| store);
        let mut project = store.project;
        project.set("/x/alpha".into());
        rsx! { crate::ui::explorer::Explorer {} }
    }
    let mut dom = VirtualDom::new(Harness);
    dom.rebuild_in_place();
    let html = dioxus_ssr::render(&dom);
    assert!(
        html.contains("project-row active"),
        "thiếu project đang chọn"
    );
    assert!(html.contains("alpha"), "thiếu danh sách project");
    // Thư mục gốc của cây là tên thư mục cuối của project đã chọn
    assert!(
        html.contains("tree-name\">alpha<") || html.contains(">alpha</span>"),
        "thiếu gốc cây tệp"
    );
}

#[test]
fn turn_shows_tool_and_file_actions_and_user_images() {
    use crate::data::models::{FileTouched, ToolCall};

    #[component]
    fn Harness() -> Element {
        let store = seeded_store();
        use_context_provider(|| store);
        let mut selected = store.selected;
        selected.set(Some("s1".into()));
        let mut detail = store.detail;
        detail.set(Some(ConversationSession {
            id: "s1".into(),
            steps: vec![
                crate::data::models::AgentStep {
                    step_index: 1,
                    kind: "USER_INPUT".into(),
                    content: "xem ảnh này".into(),
                    image_count: 1,
                    image_urls: vec!["/api/chat/attachment?path=%2Fx.png".into()],
                    ..Default::default()
                },
                crate::data::models::AgentStep {
                    step_index: 2,
                    kind: "PLANNER_RESPONSE".into(),
                    content: "đã sửa".into(),
                    tool_calls: vec![ToolCall {
                        name: "edit_file".into(),
                        summary_label: "edit_file".into(),
                        ..Default::default()
                    }],
                    ..Default::default()
                },
            ],
            files_touched: vec![FileTouched {
                path: "/x/a.rs".into(),
                action: "EDIT".into(),
                added_lines: 4,
                removed_lines: 1,
                step_index: 2,
                ..Default::default()
            }],
            ..Default::default()
        }));
        rsx! { Conversation {} }
    }
    let mut dom = VirtualDom::new(Harness);
    dom.rebuild_in_place();
    let html = dioxus_ssr::render(&dom);
    for expected in [
        "/api/chat/attachment?path=",
        "1 thao tác",
        "1 tệp thay đổi · +4 −1",
    ] {
        assert!(html.contains(expected), "thiếu '{expected}' trong:\n{html}");
    }
}

#[test]
fn composer_offers_attach_button() {
    #[component]
    fn Harness() -> Element {
        let store = seeded_store();
        use_context_provider(|| store);
        rsx! { Composer {} }
    }
    let mut dom = VirtualDom::new(Harness);
    dom.rebuild_in_place();
    let html = dioxus_ssr::render(&dom);
    assert!(html.contains("+ Ảnh"), "thiếu nút đính kèm ảnh");
}

#[test]
fn claude_question_and_agy_question_render_with_actions() {
    use crate::data::models::{AiQuestion, ClaudeOption, ClaudePending, ClaudeQuestion};

    #[component]
    fn Harness() -> Element {
        let store = seeded_store();
        use_context_provider(|| store);
        let mut selected = store.selected;
        selected.set(Some("s1".into()));
        let mut pending = store.claude_pending;
        pending.set(Some(ClaudePending {
            conversation_id: "s1".into(),
            tool_use_id: "toolu_1".into(),
            kind: "question".into(),
            questions: vec![ClaudeQuestion {
                question: "Dùng thư viện nào?".into(),
                header: "Thư viện".into(),
                multi_select: false,
                options: vec![ClaudeOption {
                    label: "serde".into(),
                    description: "chuẩn".into(),
                }],
            }],
            ..Default::default()
        }));
        let mut questions = store.ai_questions;
        questions.set(vec![AiQuestion {
            id: "q1".into(),
            question: "Tên file là gì?".into(),
            is_pending: true,
            ..Default::default()
        }]);
        rsx! { Conversation {} }
    }
    let mut dom = VirtualDom::new(Harness);
    dom.rebuild_in_place();
    let html = dioxus_ssr::render(&dom);
    for expected in [
        "Claude cần bạn trả lời",
        "Dùng thư viện nào?",
        "serde",
        "Gửi trả lời",
        "Agent hỏi",
        "Tên file là gì?",
    ] {
        assert!(html.contains(expected), "thiếu '{expected}'");
    }
}

#[test]
fn plan_from_claude_offers_approve_feedback_cancel() {
    use crate::data::models::ClaudePending;

    #[component]
    fn Harness() -> Element {
        let store = seeded_store();
        use_context_provider(|| store);
        let mut selected = store.selected;
        selected.set(Some("s1".into()));
        let mut pending = store.claude_pending;
        pending.set(Some(ClaudePending {
            tool_use_id: "toolu_2".into(),
            kind: "plan".into(),
            plan: "# Bước 1\n\nLàm **gì** đó".into(),
            ..Default::default()
        }));
        rsx! { Conversation {} }
    }
    let mut dom = VirtualDom::new(Harness);
    dom.rebuild_in_place();
    let html = dioxus_ssr::render(&dom);
    for expected in [
        "Kế hoạch của Claude",
        "Duyệt và chạy",
        "Góp ý chỉnh sửa",
        "Bước 1",
    ] {
        assert!(html.contains(expected), "thiếu '{expected}'");
    }
}

#[test]
fn model_menu_shows_provider_sections_like_flutter() {
    #[component]
    fn Harness() -> Element {
        let store = seeded_store();
        use_context_provider(|| store);
        let groups = crate::ui::model_groups::group_models(
            &[
                "claude-cli:claude-sonnet-5-5".to_string(),
                "agy:gemini-4-argon-high".to_string(),
            ],
            &std::collections::HashMap::new(),
            &crate::ui::model_groups::resolve_levels(&[]),
        );
        rsx! {
            crate::ui::composer::ModelMenu {
                groups: groups,
                current_group_id: "claude-cli:claude-sonnet-5-5".to_string(),
                current_effort: None,
                on_pick: move |_: String| {},
            }
        }
    }
    let mut dom = VirtualDom::new(Harness);
    dom.rebuild_in_place();
    let html = dioxus_ssr::render(&dom);
    for expected in [
        "Claude Code CLI · limit tài khoản Claude",
        "Antigravity (agy) · quota Gemini/Claude",
        "Claude Sonnet 5 5",
        "Gemini 4 Argon",
    ] {
        assert!(html.contains(expected), "thiếu '{expected}' trong {html}");
    }
    assert!(
        html.contains("model-item picked"),
        "thiếu đánh dấu model đang chọn"
    );
}

#[test]
fn file_view_renders_numbered_lines() {
    use crate::store::ViewedFile;

    #[component]
    fn Harness() -> Element {
        let store = seeded_store();
        use_context_provider(|| store);
        let mut viewed = store.viewed_file;
        viewed.set(Some(ViewedFile {
            path: "/x/alpha/main.rs".into(),
            name: "main.rs".into(),
            size: 2048,
            content: "fn main() {}\nprintln!(\"xin chào\");".into(),
            binary: false,
            error: None,
            loading: false,
        }));
        rsx! { crate::ui::file_view::FileView {} }
    }
    let mut dom = VirtualDom::new(Harness);
    dom.rebuild_in_place();
    let html = dioxus_ssr::render(&dom);
    for expected in ["main.rs", "fn main() {}", "xin chào", "Đóng tệp", "2 KB"] {
        assert!(html.contains(expected), "thiếu '{expected}'");
    }
}

#[test]
fn sidebar_shows_auth_pills_and_theme_toggle() {
    use crate::data::models::ClaudeAuthStatus;

    #[component]
    fn Harness() -> Element {
        let store = seeded_store();
        use_context_provider(|| store);
        let mut agy = store.agy_logged_in;
        agy.set(Some(true));
        let mut claude = store.claude_auth;
        claude.set(Some(ClaudeAuthStatus {
            logged_in: true,
            email: "a@b.c".into(),
            subscription_type: "pro".into(),
        }));
        rsx! { Sidebar {} }
    }
    let mut dom = VirtualDom::new(Harness);
    dom.rebuild_in_place();
    let html = dioxus_ssr::render(&dom);
    for expected in ["agy: ", "đã đăng nhập", "a@b.c", "(pro)", "theme-toggle"] {
        assert!(html.contains(expected), "thiếu '{expected}'");
    }
}

#[test]
fn ssh_panel_lists_hosts_and_command_box() {
    use crate::data::models::SshHost;

    #[component]
    fn Harness() -> Element {
        let store = seeded_store();
        use_context_provider(|| store);
        let mut panel = store.ssh_panel;
        panel.set(true);
        let mut hosts = store.ssh_hosts;
        hosts.set(vec![
            SshHost {
                id: 1,
                name: "Máy này".into(),
                username: "john".into(),
                auth_type: "password".into(),
                builtin: true,
                ..Default::default()
            },
            SshHost {
                id: 2,
                name: "Lab".into(),
                host: "10.0.0.5".into(),
                port: 22,
                username: "root".into(),
                auth_type: "key".into(),
                has_key: true,
                ..Default::default()
            },
        ]);
        rsx! { crate::ui::ssh::SshPanel {} }
    }
    let mut dom = VirtualDom::new(Harness);
    dom.rebuild_in_place();
    let html = dioxus_ssr::render(&dom);
    // Máy đầu tiên (mặc định) hiện chi tiết; máy có host hiện địa chỉ đầy đủ; không có nút Sửa/Xóa cho "Máy này"
    for expected in ["Máy này", "Lab", "Thêm máy", "Chạy", "Máy này · john"] {
        assert!(html.contains(expected), "thiếu '{expected}'");
    }
    assert!(!html.contains("Xác nhận xóa"));
}

#[test]
fn docker_panel_lists_containers_grouped_by_project() {
    use crate::data::models::{DockerContainer, DockerSession};

    #[component]
    fn Harness() -> Element {
        let store = seeded_store();
        use_context_provider(|| store);
        let mut panel = store.docker_panel;
        panel.set(true);
        let mut session = store.docker;
        session.set(Some(DockerSession {
            session_id: "dock-1".into(),
            host_id: 8,
            host_name: "Máy này".into(),
            connected: true,
            containers: vec![
                DockerContainer {
                    id: "a1".into(),
                    name: "web".into(),
                    image: "nginx:latest".into(),
                    state: "running".into(),
                    status: "Up 2 days".into(),
                    project: "shop".into(),
                    ..Default::default()
                },
                DockerContainer {
                    id: "b2".into(),
                    name: "tool".into(),
                    image: "busybox".into(),
                    state: "running".into(),
                    project: String::new(),
                    ..Default::default()
                },
            ],
            ..Default::default()
        }));
        rsx! { crate::ui::docker::DockerPanel {} }
    }
    let mut dom = VirtualDom::new(Harness);
    dom.rebuild_in_place();
    let html = dioxus_ssr::render(&dom);
    for expected in [
        "Máy này",
        "shop",
        "web",
        "nginx:latest",
        "Khởi động lại",
        "Không thuộc Compose",
        "tool",
    ] {
        assert!(html.contains(expected), "thiếu '{expected}'");
    }
}

#[test]
fn git_history_panel_lists_commits_with_refs() {
    use crate::data::models::{GitCommit, GitHistoryResponse};

    #[component]
    fn Harness() -> Element {
        let store = seeded_store();
        use_context_provider(|| store);
        let mut history = store.git_history;
        history.set(Some(GitHistoryResponse {
            ok: true,
            error: String::new(),
            current_branch: "main".into(),
            total_commits: 2,
            commits: vec![GitCommit {
                short_hash: "ae5d288".into(),
                subject: "Merge branch 'feature/dioxus-app'".into(),
                author_name: "Tác giả".into(),
                relative_time: "1 hour ago".into(),
                refs: vec!["HEAD -> main".into()],
                is_head: true,
            }],
        }));
        rsx! { crate::ui::git::GitHistoryPanel {} }
    }
    let mut dom = VirtualDom::new(Harness);
    dom.rebuild_in_place();
    let html = dioxus_ssr::render(&dom);
    for expected in [
        "Lịch sử commit",
        "nhánh main",
        "ae5d288",
        "Merge branch",
        "HEAD -&#62; main",
    ] {
        assert!(html.contains(expected), "thiếu '{expected}' trong {html}");
    }
}
