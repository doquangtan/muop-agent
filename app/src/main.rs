// Mướp Agent Monitor — giao diện Slint (port của lib/ của Flutter).
// Client thuần UI: mọi dữ liệu đi qua REST của muop-agent-server (mặc định 127.0.0.1:8787).

slint::include_modules!();

mod api;
mod live;
mod model_groups;
mod screenshot;
mod turns;
mod window;

use api::{
    AiQuestion, Meta, PendingRetry, Plan, Project, Session, SessionSummary, Snapshot, Stream,
};
use model_groups::{effort_label, group_models, ModelGroup};
use slint::{Model, ModelRc, SharedString, VecModel};
use std::cell::{Cell, RefCell};
use std::collections::hash_map::DefaultHasher;
use std::collections::{HashMap, HashSet};
use std::hash::{Hash, Hasher};
use std::sync::OnceLock;
use std::time::Duration;
use turns::build_turns;
use window::VirtualList;

const DEFAULT_SERVER: &str = "http://127.0.0.1:8787";
const DEFAULT_MODEL: &str = "claude-cli:claude-sonnet-5-5";
const MAX_SESSIONS: usize = 300;
const MAX_MESSAGES: usize = 1000;
/// Đệm (px) trên và dưới vùng nhìn khi chọn mục để render
const CHAT_BUFFER: f32 = 900.0;
const SIDE_BUFFER: f32 = 300.0;
/// Khoảng đệm đầu/cuối khung chat (khớp spacer trong app.slint)
const CHAT_PAD: f32 = 8.0;
/// Cách đáy trong phạm vi này thì coi là đang bám đáy
const FOLLOW_SLACK: f32 = 120.0;
const NEW_CHAT_DRAFT_KEY: &str = "new";

#[derive(Default)]
struct UiState {
    snapshot: Snapshot,
    /// Conversation đang mở; None = cuộc trò chuyện mới
    selected: Option<String>,
    project_paths: Vec<String>,
    /// Project đang thu gọn (theo đường dẫn)
    collapsed: HashSet<String>,
    search: String,
    /// Nháp chưa gửi theo conversation (khóa: id hoặc "new")
    drafts: HashMap<String, String>,
    /// Model người dùng chọn theo conversation (trong bộ nhớ)
    model_by_conv: HashMap<String, String>,
    /// Model đang chọn trên composer
    model_id: String,
    groups: Vec<ModelGroup>,
    /// Plan chờ duyệt của conversation đang mở (theo thứ tự hiển thị)
    plans: Vec<Plan>,
    /// Câu hỏi AI đang chờ trả lời của conversation đang mở
    questions: Vec<AiQuestion>,
    /// Lượt đang chờ tự gửi lại (toàn bộ, lọc theo conversation khi hiển thị)
    retries: Vec<PendingRetry>,
    /// Ảo hóa sidebar: toàn bộ dòng, chiều cao, vị trí cuộn và khoảng đang hiển thị
    side_rows: Vec<SideRow>,
    side_list: VirtualList,
    side_scroll: f32,
    side_view: f32,
    side_window: (usize, usize),
    /// Ảo hóa khung chat: toàn bộ mục, chiều cao, khóa nội dung (để giữ chiều cao đã đo)
    chat_rows: Vec<MessageItem>,
    chat_list: VirtualList,
    chat_keys: Vec<u64>,
    chat_scroll: f32,
    chat_view: f32,
    /// Tổng chiều cao thật của nội dung khung chat (đọc từ giao diện sau layout)
    chat_content: f32,
    chat_follow: bool,
    chat_window: (usize, usize),
}

thread_local! {
    static STATE: RefCell<UiState> = RefCell::new(UiState::default());
}

/// Địa chỉ server, đặt một lần lúc khởi động (dùng được từ mọi luồng)
static BASE: OnceLock<String> = OnceLock::new();

fn base() -> String {
    BASE.get().cloned().unwrap_or_default()
}

fn string_model(items: impl IntoIterator<Item = String>) -> ModelRc<SharedString> {
    let v: Vec<SharedString> = items.into_iter().map(SharedString::from).collect();
    ModelRc::new(VecModel::from(v))
}

fn short_time(iso: &str) -> String {
    iso.get(..16).unwrap_or(iso).replace('T', " ")
}

fn display_title(title: &str, id: &str) -> String {
    let t = title.trim();
    if t.is_empty() {
        format!("Cuộc trò chuyện {}", id.get(..8).unwrap_or(id))
    } else {
        t.to_string()
    }
}

fn model_label(snap: &Snapshot, id: &str) -> String {
    snap.model_labels
        .get(id)
        .cloned()
        .unwrap_or_else(|| id.to_string())
}

fn fmt_tokens(n: u64) -> String {
    if n >= 1_000_000 {
        format!("{:.1}M", n as f64 / 1_000_000.0)
    } else if n >= 1_000 {
        format!("{:.1}K", n as f64 / 1_000.0)
    } else {
        n.to_string()
    }
}

fn is_session_running(snap: &Snapshot, s: &Session) -> bool {
    s.status == "running"
        || snap
            .active_streams
            .values()
            .any(|st| st.is_running && st.conversation_id == s.id)
}

/// Stream của conversation đang mở; cuộc trò chuyện mới khớp theo project và chưa có id
fn find_stream<'a>(snap: &'a Snapshot, cid: Option<&str>, project: &str) -> Option<&'a Stream> {
    match cid {
        Some(id) => snap
            .active_streams
            .values()
            .find(|s| s.conversation_id == id),
        None => snap
            .active_streams
            .values()
            .find(|s| s.conversation_id.is_empty() && s.project_path == project),
    }
}

fn draft_key(st: &UiState) -> String {
    st.selected
        .clone()
        .unwrap_or_else(|| NEW_CHAT_DRAFT_KEY.to_string())
}

fn session_of<'a>(snap: &'a Snapshot, id: Option<&String>) -> Option<&'a Session> {
    id.and_then(|id| snap.sessions.iter().find(|s| &s.id == id))
}

/// Model sẽ dùng khi mở một conversation: lựa chọn đã lưu → model của lượt gần nhất → mặc định
fn model_for_conversation(st: &UiState, cid: &str, context_model: &str) -> String {
    let available = &st.snapshot.available_models;
    let candidates = [
        st.model_by_conv.get(cid).cloned().unwrap_or_default(),
        context_model.to_string(),
        DEFAULT_MODEL.to_string(),
    ];
    for c in candidates {
        if !c.is_empty() && available.contains(&c) {
            return c;
        }
    }
    available.first().cloned().unwrap_or_default()
}

/// Vị trí nhóm và mức của `model_id` trong danh sách hiện tại
fn model_indices(groups: &[ModelGroup], model_id: &str) -> (usize, usize) {
    for (gi, g) in groups.iter().enumerate() {
        if let Some(ei) = g.options.iter().position(|o| o.id == model_id) {
            return (gi, ei);
        }
    }
    (0, 0)
}

fn build_side_rows(st: &UiState) -> Vec<SideRow> {
    let snap = &st.snapshot;
    let query = st.search.trim().to_lowercase();
    let matches = |s: &Session| {
        query.is_empty()
            || s.title.to_lowercase().contains(&query)
            || s.project_name.to_lowercase().contains(&query)
    };

    // Nhóm session theo project (giữ thứ tự project từ server)
    let mut sessions: Vec<&Session> = snap.sessions.iter().filter(|s| matches(s)).collect();
    sessions.sort_by(|a, b| b.updated_at.cmp(&a.updated_at));
    sessions.truncate(MAX_SESSIONS);

    let mut groups: Vec<(String, String, Vec<&Session>)> = Vec::new();
    for p in &snap.projects {
        groups.push((p.path.clone(), p.name.clone(), Vec::new()));
    }
    for s in sessions {
        match groups
            .iter_mut()
            .find(|(path, _, _)| *path == s.project_path)
        {
            Some(g) => g.2.push(s),
            None => groups.push((s.project_path.clone(), s.project_name.clone(), vec![s])),
        }
    }

    let mut rows = Vec::new();
    for (path, name, list) in groups {
        // Khi tìm kiếm, ẩn project không có kết quả
        if !query.is_empty() && list.is_empty() {
            continue;
        }
        let expanded = !st.collapsed.contains(&path);
        rows.push(SideRow {
            kind: "project".into(),
            key: path.clone().into(),
            title: name.clone().into(),
            meta: SharedString::default(),
            running: list.iter().any(|s| is_session_running(snap, s)),
            selected: false,
            expanded,
            claude: false,
            count: list.len() as i32,
        });
        if !expanded {
            continue;
        }
        if list.is_empty() {
            rows.push(SideRow {
                kind: "empty".into(),
                key: SharedString::default(),
                title: "Chưa có conversation".into(),
                meta: SharedString::default(),
                running: false,
                selected: false,
                expanded: false,
                claude: false,
                count: 0,
            });
        }
        for s in list {
            rows.push(SideRow {
                kind: "session".into(),
                key: s.id.clone().into(),
                title: display_title(&s.title, &s.id).into(),
                meta: format!("{} · {}", s.source, short_time(&s.updated_at)).into(),
                running: is_session_running(snap, s),
                selected: st.selected.as_deref() == Some(s.id.as_str()),
                expanded: false,
                claude: s.source == "claude-cli",
                count: 0,
            });
        }
    }
    if rows.is_empty() {
        rows.push(SideRow {
            kind: "empty".into(),
            key: SharedString::default(),
            title: "Không có kết quả".into(),
            meta: SharedString::default(),
            running: false,
            selected: false,
            expanded: false,
            claude: false,
            count: 0,
        });
    }
    rows
}

fn build_messages(
    session: Option<&Session>,
    stream: Option<&Stream>,
    running: bool,
) -> Vec<MessageItem> {
    let mut out: Vec<(String, String, Vec<String>, Vec<String>)> = Vec::new();
    if let Some(s) = session {
        for t in build_turns(s) {
            if let Some(u) = t.user {
                out.push(("user".into(), u, vec![], vec![]));
            }
            if !t.ai_texts.is_empty() || !t.tools.is_empty() || !t.files.is_empty() {
                out.push(("ai".into(), t.ai_texts.join("\n\n"), t.tools, t.files));
            }
        }
    }

    let mut has_stream_text = false;
    if let Some(st) = stream {
        let prompt = st.user_prompt.trim();
        let last_user = out
            .iter()
            .rev()
            .find(|m| m.0 == "user")
            .map(|m| m.1.as_str());
        if !prompt.is_empty() && last_user != Some(prompt) {
            out.push(("user".into(), prompt.to_string(), vec![], vec![]));
        }
        let text = st.streaming_text.trim();
        if !text.is_empty() {
            out.push(("ai".into(), text.to_string(), vec![], vec![]));
            has_stream_text = true;
        }
        if !st.error.is_empty() {
            out.push(("error".into(), st.error.clone(), vec![], vec![]));
        }
    }
    if running && !has_stream_text {
        out.push((
            "thinking".into(),
            "Agent đang xử lý…".into(),
            vec![],
            vec![],
        ));
    }

    let skip = out.len().saturating_sub(MAX_MESSAGES);
    out.into_iter()
        .skip(skip)
        .map(|(kind, text, tools, files)| MessageItem {
            idx: 0,
            kind: kind.into(),
            text: text.into(),
            tools: string_model(tools),
            files: string_model(files),
        })
        .collect()
}

/// Vẽ lại toàn bộ UI từ state. `selection_changed` = true thì luôn cuộn xuống cuối.
fn render(ui: &AppWindow, st: &mut UiState, selection_changed: bool) {
    let session = session_of(&st.snapshot, st.selected.as_ref());
    let active_project = match session {
        Some(s) => s.project_path.clone(),
        None => st
            .project_paths
            .get(ui.get_new_project_index() as usize)
            .cloned()
            .unwrap_or_default(),
    };
    let stream = find_stream(&st.snapshot, st.selected.as_deref(), &active_project);
    let running = stream.map(|s| s.is_running).unwrap_or(false)
        || session.map(|s| s.status == "running").unwrap_or(false);

    // Plan và câu hỏi AI
    st.plans = session.map(|s| s.pending_plans.clone()).unwrap_or_default();
    ui.set_plans(ModelRc::new(VecModel::from(
        st.plans
            .iter()
            .map(|p| PlanItem {
                title: p.title.clone().into(),
                summary: p.summary.clone().into(),
                feedback: p.request_feedback,
            })
            .collect::<Vec<_>>(),
    )));
    let retry_text = st
        .selected
        .as_ref()
        .and_then(|cid| st.retries.iter().find(|r| &r.conversation_id == cid))
        .map(retry_banner_text)
        .unwrap_or_default();
    ui.set_retry_text(retry_text.into());
    ui.set_question_texts(string_model(
        st.questions.iter().map(|q| q.question.clone()),
    ));

    // Sidebar: dữ liệu đầy đủ giữ trong bộ nhớ, giao diện chỉ nhận dòng trong vùng nhìn
    let side_rows = build_side_rows(st);
    st.side_list = VirtualList::new(
        side_rows
            .iter()
            .map(|r| side_height(r.kind.as_str()))
            .collect(),
    );
    st.side_rows = side_rows;

    // Header
    let (title, meta, context) = match session {
        Some(s) => {
            let mut meta = format!("{} · {}", s.project_name, s.source);
            if !s.context_model.is_empty() {
                meta.push_str(&format!(
                    " · {}",
                    model_label(&st.snapshot, &s.context_model)
                ));
            }
            let mut context = String::new();
            let mut level = 0;
            if s.context_tokens > 0 {
                let limit = st
                    .snapshot
                    .model_context_limits
                    .get(&s.context_model)
                    .copied()
                    .unwrap_or(0);
                context = if limit > 0 {
                    let ratio = s.context_tokens as f64 / limit as f64;
                    level = if ratio >= 0.9 {
                        2
                    } else if ratio >= 0.7 {
                        1
                    } else {
                        0
                    };
                    format!("{} / {}", fmt_tokens(s.context_tokens), fmt_tokens(limit))
                } else {
                    fmt_tokens(s.context_tokens)
                };
                ui.set_context_level(level);
            }
            (display_title(&s.title, &s.id), meta, context)
        }
        None => {
            let name = st
                .snapshot
                .projects
                .iter()
                .find(|p| p.path == active_project)
                .map(|p| p.name.clone())
                .unwrap_or_else(|| active_project.clone());
            (
                "Cuộc trò chuyện mới".to_string(),
                format!("Project: {name}"),
                String::new(),
            )
        }
    };
    ui.set_header_title(title.into());
    ui.set_header_meta(meta.into());
    ui.set_context_text(context.into());
    ui.set_has_session(session.is_some());
    ui.set_running(running);

    // Composer: nhóm và mức model
    let (gi, ei) = model_indices(&st.groups, &st.model_id);
    ui.set_group_names(string_model(st.groups.iter().map(|g| g.label.clone())));
    ui.set_group_index(gi as i32);
    let effort_names: Vec<String> = st
        .groups
        .get(gi)
        .map(|g| {
            if g.options.iter().all(|o| o.effort.is_none()) {
                Vec::new()
            } else {
                g.options
                    .iter()
                    .map(|o| effort_label(o.effort.as_deref().unwrap_or("")))
                    .collect()
            }
        })
        .unwrap_or_default();
    ui.set_effort_names(string_model(effort_names));
    ui.set_effort_index(ei as i32);

    // Khung chat: giữ đủ mục trong bộ nhớ, giao diện chỉ nhận các mục trong vùng nhìn
    let mut messages = build_messages(session, stream, running);
    for (i, m) in messages.iter_mut().enumerate() {
        m.idx = i as i32;
    }
    let keys: Vec<u64> = messages.iter().map(message_key).collect();
    let heights: Vec<f32> = messages
        .iter()
        .enumerate()
        .map(|(i, m)| {
            // Mục không đổi nội dung giữ nguyên chiều cao đã ước lượng
            if st.chat_keys.get(i) == Some(&keys[i]) {
                st.chat_list.height(i)
            } else {
                estimate_message_height(m)
            }
        })
        .collect();
    st.chat_list = VirtualList::new(heights);
    st.chat_keys = keys;
    st.chat_rows = messages;
    if selection_changed {
        st.chat_follow = true;
    }

    sync_side(ui, st, true);
    sync_chat(ui, st, true);
    if st.chat_follow {
        pin_bottom(ui, st);
    }
}

// ── Ảo hóa danh sách (kiểu ListView.builder của Flutter) ──

fn side_height(kind: &str) -> f32 {
    let h = match kind {
        "session" => 54.0,
        _ => 30.0,
    };
    // Cộng 2px khoảng cách dưới mỗi dòng
    h + 2.0
}

fn message_key(m: &MessageItem) -> u64 {
    let mut h = DefaultHasher::new();
    m.kind.as_str().hash(&mut h);
    m.text.as_str().hash(&mut h);
    m.tools.row_count().hash(&mut h);
    m.files.row_count().hash(&mut h);
    h.finish()
}

/// Chiều cao ước lượng của một mục chat, dùng đến khi mục được render và đo thật
fn estimate_message_height(m: &MessageItem) -> f32 {
    const CHARS_PER_LINE: f32 = 78.0;
    let lines: f32 = m
        .text
        .as_str()
        .lines()
        .map(|l| (l.chars().count() as f32 / CHARS_PER_LINE).ceil().max(1.0))
        .sum();
    let mut h = 24.0 + lines.max(1.0) * 20.0;
    if m.tools.row_count() > 0 || m.files.row_count() > 0 {
        h += 34.0;
    }
    // 12px khoảng cách dưới mỗi mục (đã cộng trong MessageView)
    h + 12.0
}

/// Đưa vào giao diện các dòng sidebar trong vùng nhìn; phần còn lại là spacer
fn sync_side(ui: &AppWindow, st: &mut UiState, force: bool) {
    let (start, end) = st
        .side_list
        .range(st.side_scroll, st.side_view, SIDE_BUFFER);
    let top = st.side_list.top(start);
    let bottom = st.side_list.total() - st.side_list.top(end);
    if force || (start, end) != st.side_window {
        st.side_window = (start, end);
        let window: Vec<SideRow> = st.side_rows[start..end].to_vec();
        ui.set_side_rows(ModelRc::new(VecModel::from(window)));
    }
    ui.set_side_top(top);
    ui.set_side_bottom(bottom);
}

/// Đưa vào giao diện các mục chat trong vùng nhìn; phần còn lại là spacer
fn sync_chat(ui: &AppWindow, st: &mut UiState, force: bool) {
    let (start, end) = st
        .chat_list
        .range(st.chat_scroll, st.chat_view, CHAT_BUFFER);
    let top = CHAT_PAD + st.chat_list.top(start);
    let bottom = CHAT_PAD + st.chat_list.total() - st.chat_list.top(end);
    if force || (start, end) != st.chat_window {
        st.chat_window = (start, end);
        let window: Vec<MessageItem> = st.chat_rows[start..end].to_vec();
        ui.set_messages(ModelRc::new(VecModel::from(window)));
    }
    ui.set_chat_top(top);
    ui.set_chat_bottom(bottom);
    ui.set_total_messages(st.chat_rows.len() as i32);
}

/// Đọc vị trí cuộn từ giao diện định kỳ và cập nhật cửa sổ mục khi có thay đổi.
/// Chạy trên luồng UI nên không cần khóa; chỉ làm việc khi vị trí thực sự đổi.
fn poll_scroll(ui: &AppWindow) {
    let chat_off = ui.get_chat_offset();
    let chat_vh = ui.get_chat_view_h();
    let chat_content = ui.get_chat_content_h();
    let side_off = ui.get_side_offset();
    let side_vh = ui.get_side_view_h();
    STATE.with(|s| {
        let mut st = s.borrow_mut();
        if (side_off - st.side_scroll).abs() > 0.5 || (side_vh - st.side_view).abs() > 0.5 {
            st.side_scroll = side_off;
            st.side_view = side_vh;
            sync_side(ui, &mut st, false);
        }
        if (chat_off - st.chat_scroll).abs() > 0.5
            || (chat_vh - st.chat_view).abs() > 0.5
            || (chat_content - st.chat_content).abs() > 0.5
        {
            st.chat_scroll = chat_off;
            st.chat_view = chat_vh;
            st.chat_content = chat_content;
            let max = (chat_content - chat_vh).max(0.0);
            st.chat_follow = chat_off >= max - FOLLOW_SLACK;
            if st.chat_follow && (chat_off - max).abs() > 1.0 {
                pin_bottom(ui, &mut st);
            }
            sync_chat(ui, &mut st, false);
        }
    });
}

/// Cuộn xuống cuối khung chat
fn pin_bottom(ui: &AppWindow, st: &mut UiState) {
    // Dùng tổng chiều cao thật khi đã có, để không đặt vị trí vượt quá giới hạn của giao diện
    let content = if st.chat_content > 0.0 {
        st.chat_content
    } else {
        st.chat_list.total() + 2.0 * CHAT_PAD
    };
    let y = (content - st.chat_view).max(0.0);
    st.chat_scroll = y;
    ui.invoke_set_scroll(y);
}

thread_local! {
    static RENDER_PENDING: Cell<bool> = const { Cell::new(false) };
}

/// Vẽ lại sau một khoảng ngắn để gộp các event dồn dập thành một lần render
fn request_render(ui: &AppWindow) {
    if RENDER_PENDING.with(|p| p.replace(true)) {
        return;
    }
    let weak = ui.as_weak();
    slint::Timer::single_shot(Duration::from_millis(60), move || {
        RENDER_PENDING.with(|p| p.set(false));
        let Some(ui) = weak.upgrade() else { return };
        STATE.with(|s| render(&ui, &mut s.borrow_mut(), false));
    });
}

fn update_status(ui: &AppWindow, st: &UiState) {
    ui.set_connected(true);
    ui.set_status_text(
        format!(
            "{} phiên · {} project · {}",
            st.snapshot.sessions.len(),
            st.snapshot.projects.len(),
            st.snapshot.hostname
        )
        .into(),
    );
}

/// Cập nhật phần suy ra từ metadata: danh sách project, nhóm model, model đang chọn
fn refresh_derived(ui: &AppWindow, st: &mut UiState) {
    st.project_paths = st
        .snapshot
        .projects
        .iter()
        .map(|p| p.path.clone())
        .collect();
    st.groups = group_models(&st.snapshot.available_models, &st.snapshot.model_labels);
    ui.set_project_names(string_model(
        st.snapshot.projects.iter().map(|p| p.name.clone()),
    ));
    // Model chưa có trong danh sách (ví dụ server đổi) → chọn lại
    if !st.snapshot.available_models.contains(&st.model_id) {
        st.model_id = session_of(&st.snapshot, st.selected.as_ref())
            .map(|s| model_for_conversation(st, &s.id, &s.context_model))
            .unwrap_or_else(|| model_for_conversation(st, "", ""));
    }
}

/// `sessions:list`: tóm tắt mới; giữ steps/files đã nạp của conversation còn tồn tại
fn apply_sessions_list(ui: &AppWindow, list: Vec<SessionSummary>) {
    let need_detail = STATE.with(|s| {
        let mut st = s.borrow_mut();
        let mut previous: HashMap<String, Session> = st
            .snapshot
            .sessions
            .drain(..)
            .map(|x| (x.id.clone(), x))
            .collect();
        st.snapshot.sessions = list
            .into_iter()
            .map(|sum| {
                let mut next = Session::from(sum);
                if let Some(prev) = previous.remove(&next.id) {
                    next.steps = prev.steps;
                    next.files_touched = prev.files_touched;
                }
                next
            })
            .collect();
        update_status(ui, &st);
        st.selected.clone().filter(|cid| {
            st.snapshot
                .sessions
                .iter()
                .any(|x| &x.id == cid && x.steps.is_empty())
        })
    });
    if let Some(cid) = need_detail {
        fetch_detail(ui, cid);
    }
    request_render(ui);
}

/// `session:update`: thay thế một conversation (đã có đủ steps)
fn apply_session_update(ui: &AppWindow, sess: Session) {
    STATE.with(|s| {
        let mut st = s.borrow_mut();
        let id = sess.id.clone();
        match st.snapshot.sessions.iter_mut().find(|x| x.id == id) {
            Some(slot) => *slot = sess,
            None => st.snapshot.sessions.push(sess),
        }
    });
    request_render(ui);
}

/// `session:removed`: bỏ conversation khỏi danh sách; nếu đang mở thì về cuộc trò chuyện mới
fn apply_session_removed(ui: &AppWindow, id: &str) {
    STATE.with(|s| {
        let mut st = s.borrow_mut();
        st.snapshot.sessions.retain(|x| x.id != id);
        if st.selected.as_deref() == Some(id) {
            st.selected = None;
        }
    });
    request_render(ui);
}

/// `meta:update`: project, danh sách model, nhãn và giới hạn context, thông tin máy
fn apply_meta(ui: &AppWindow, meta: Meta) {
    STATE.with(|s| {
        let mut st = s.borrow_mut();
        st.snapshot.projects = meta.projects;
        st.snapshot.available_models = meta.available_models;
        st.snapshot.model_labels = meta.model_labels;
        st.snapshot.model_context_limits = meta.model_context_limits;
        st.snapshot.hostname = meta.hostname;
        refresh_derived(ui, &mut st);
        update_status(ui, &st);
    });
    request_render(ui);
}

/// `projects:update`: danh sách project mới
fn apply_projects(ui: &AppWindow, list: Vec<Project>) {
    STATE.with(|s| {
        let mut st = s.borrow_mut();
        st.snapshot.projects = list;
        refresh_derived(ui, &mut st);
        update_status(ui, &st);
    });
    request_render(ui);
}

/// `streams:update`: các lượt chat đang chạy
fn apply_streams(ui: &AppWindow, streams: HashMap<String, Stream>) {
    STATE.with(|s| s.borrow_mut().snapshot.active_streams = streams);
    request_render(ui);
}

/// Đọc đầy đủ một conversation khi mở (luồng nền, cập nhật về UI)
fn fetch_detail(ui: &AppWindow, cid: String) {
    let base = base();
    let weak = ui.as_weak();
    std::thread::spawn(move || {
        if let Ok(sess) = api::get_session_detail(&base, &cid) {
            let _ = weak.upgrade_in_event_loop(move |ui| apply_session_update(&ui, sess));
        }
    });
}

/// Áp dữ liệu ban đầu (danh sách, metadata, lượt đang chạy) một lần, dùng cho chế độ chụp ảnh
fn apply_bootstrap(
    ui: &AppWindow,
    sessions: Vec<SessionSummary>,
    meta: Meta,
    streams: HashMap<String, Stream>,
) {
    apply_meta(ui, meta);
    apply_streams(ui, streams);
    apply_sessions_list(ui, sessions);
}

/// Lấy câu hỏi AI đang chờ của conversation đang mở (luồng nền, cập nhật về UI)
fn fetch_questions(ui: &AppWindow, cid: String) {
    let base = base();
    let weak = ui.as_weak();
    std::thread::spawn(move || {
        let result = api::get_ai_questions(&base, &cid);
        let _ = weak.upgrade_in_event_loop(move |ui| {
            if let Ok(qs) = result {
                STATE.with(|s| {
                    let mut st = s.borrow_mut();
                    if st.selected.as_deref() == Some(cid.as_str()) {
                        st.questions = qs;
                        render(&ui, &mut st, false);
                    }
                });
            }
        });
    });
}

/// Đổi conversation đang mở: lưu nháp cũ, nạp nháp và model của conversation mới
fn switch_selection(ui: &AppWindow, st: &mut UiState, next: Option<String>) {
    let old_key = draft_key(st);
    st.drafts.insert(old_key, ui.get_draft().to_string());

    st.selected = next;
    st.questions.clear();
    ui.set_answer_draft("".into());
    ui.set_feedback_plan(-1);
    ui.set_toast("".into());

    let new_key = draft_key(st);
    ui.set_draft(st.drafts.get(&new_key).cloned().unwrap_or_default().into());

    let context_model = session_of(&st.snapshot, st.selected.as_ref())
        .map(|s| (s.id.clone(), s.context_model.clone()));
    if let Some((cid, ctx)) = context_model {
        st.model_id = model_for_conversation(st, &cid, &ctx);
    }
    render(ui, st, true);
    if let Some(cid) = st.selected.clone() {
        // Chưa có steps (mới chỉ có tóm tắt từ sessions:list) thì đọc chi tiết
        let has_steps =
            session_of(&st.snapshot, st.selected.as_ref()).is_some_and(|s| !s.steps.is_empty());
        if !has_steps {
            fetch_detail(ui, cid.clone());
        }
        fetch_questions(ui, cid);
    }
}

fn set_toast(ui: &AppWindow, msg: impl Into<SharedString>) {
    ui.set_toast(msg.into());
}

fn wire_callbacks(ui: &AppWindow) {
    ui.on_row_activate({
        let weak = ui.as_weak();
        move |kind, key| {
            let Some(ui) = weak.upgrade() else { return };
            let key = key.to_string();
            match kind.as_str() {
                "project" => {
                    STATE.with(|s| {
                        let mut st = s.borrow_mut();
                        if !st.collapsed.remove(&key) {
                            st.collapsed.insert(key);
                        }
                        render(&ui, &mut st, false);
                    });
                }
                "session" => STATE.with(|s| switch_selection(&ui, &mut s.borrow_mut(), Some(key))),
                _ => {}
            }
        }
    });

    ui.on_row_add({
        let weak = ui.as_weak();
        move |path| {
            let Some(ui) = weak.upgrade() else { return };
            let path = path.to_string();
            STATE.with(|s| {
                let mut st = s.borrow_mut();
                if let Some(i) = st.project_paths.iter().position(|p| *p == path) {
                    ui.set_new_project_index(i as i32);
                }
                switch_selection(&ui, &mut st, None);
            });
        }
    });

    ui.on_new_chat({
        let weak = ui.as_weak();
        move || {
            let Some(ui) = weak.upgrade() else { return };
            STATE.with(|s| switch_selection(&ui, &mut s.borrow_mut(), None));
        }
    });

    ui.on_search_changed({
        let weak = ui.as_weak();
        move || {
            let Some(ui) = weak.upgrade() else { return };
            STATE.with(|s| {
                let mut st = s.borrow_mut();
                st.search = ui.get_search().to_string();
                render(&ui, &mut st, false);
            });
        }
    });

    ui.on_theme_toggled({
        let weak = ui.as_weak();
        move || {
            let Some(ui) = weak.upgrade() else { return };
            let palette = ui.global::<Palette>();
            palette.set_dark(!palette.get_dark());
        }
    });

    ui.on_group_picked({
        let weak = ui.as_weak();
        move |gi| {
            let Some(ui) = weak.upgrade() else { return };
            STATE.with(|s| {
                let mut st = s.borrow_mut();
                let (cur_gi, _) = model_indices(&st.groups, &st.model_id);
                let cur_effort = st
                    .groups
                    .get(cur_gi)
                    .and_then(|g| g.options.iter().find(|o| o.id == st.model_id))
                    .and_then(|o| o.effort.clone());
                let Some(group) = st.groups.get(gi as usize) else {
                    return;
                };
                let id = group.preferred_option(cur_effort.as_deref()).id.clone();
                choose_model(&ui, &mut st, id);
            });
        }
    });

    ui.on_effort_picked({
        let weak = ui.as_weak();
        move |ei| {
            let Some(ui) = weak.upgrade() else { return };
            STATE.with(|s| {
                let mut st = s.borrow_mut();
                let (gi, _) = model_indices(&st.groups, &st.model_id);
                let Some(id) = st
                    .groups
                    .get(gi)
                    .and_then(|g| g.options.get(ei as usize))
                    .map(|o| o.id.clone())
                else {
                    return;
                };
                choose_model(&ui, &mut st, id);
            });
        }
    });

    ui.on_send({
        let weak = ui.as_weak();
        move |prompt| {
            let Some(ui) = weak.upgrade() else { return };
            let prompt = prompt.trim().to_string();
            if prompt.is_empty() {
                return;
            }
            let (base, cid, project_path, model) = STATE.with(|s| {
                let st = s.borrow();
                let session = session_of(&st.snapshot, st.selected.as_ref());
                let project_path = session
                    .map(|s| s.project_path.clone())
                    .or_else(|| {
                        st.project_paths
                            .get(ui.get_new_project_index() as usize)
                            .cloned()
                    })
                    .unwrap_or_default();
                (
                    base(),
                    st.selected.clone().unwrap_or_default(),
                    project_path,
                    st.model_id.clone(),
                )
            });

            ui.set_draft("".into());
            STATE.with(|s| {
                s.borrow_mut().drafts.remove(&if cid.is_empty() {
                    NEW_CHAT_DRAFT_KEY.to_string()
                } else {
                    cid.clone()
                });
            });
            set_toast(&ui, "");

            let weak = ui.as_weak();
            let sent_prompt = prompt.clone();
            std::thread::spawn(move || {
                let result = api::send_chat(&base, &sent_prompt, &project_path, &cid, &model);
                let _ = weak.upgrade_in_event_loop(move |ui| match result {
                    Ok(resp) if resp.ok => {
                        STATE.with(|s| {
                            let mut st = s.borrow_mut();
                            if st.selected.is_none() && !resp.conversation_id.is_empty() {
                                st.selected = Some(resp.conversation_id.clone());
                                st.model_by_conv
                                    .insert(resp.conversation_id.clone(), model.clone());
                            }
                            render(&ui, &mut st, true);
                        });
                    }
                    other => {
                        let msg = match other {
                            Ok(resp) if !resp.error.is_empty() => resp.error,
                            Ok(_) => "Gửi thất bại".to_string(),
                            Err(e) => e,
                        };
                        // Trả lại nội dung để người dùng gửi lại
                        if ui.get_draft().is_empty() {
                            ui.set_draft(sent_prompt.into());
                        }
                        set_toast(&ui, msg);
                    }
                });
            });
        }
    });

    ui.on_stop({
        let weak = ui.as_weak();
        move || {
            let Some(ui) = weak.upgrade() else { return };
            let (base, cid) = STATE.with(|s| {
                let st = s.borrow();
                (base(), st.selected.clone().unwrap_or_default())
            });
            if cid.is_empty() {
                return;
            }
            let weak = ui.as_weak();
            std::thread::spawn(move || {
                let result = api::stop_chat(&base, &cid);
                let _ = weak.upgrade_in_event_loop(move |ui| {
                    if let Err(msg) = result {
                        set_toast(&ui, msg);
                    }
                });
            });
        }
    });

    ui.on_retry_cancel({
        let weak = ui.as_weak();
        move || {
            let Some(ui) = weak.upgrade() else { return };
            let cid = STATE.with(|s| s.borrow().selected.clone().unwrap_or_default());
            if cid.is_empty() {
                return;
            }
            let weak = ui.as_weak();
            std::thread::spawn(move || {
                let result = api::cancel_retry(&base(), &cid);
                let _ = weak.upgrade_in_event_loop(move |ui| match result {
                    Ok(()) => set_toast(&ui, "Đã hủy lịch gửi lại."),
                    Err(e) => set_toast(&ui, e),
                });
            });
        }
    });

    ui.on_plan_action({
        let weak = ui.as_weak();
        move |index, action, feedback| {
            let Some(ui) = weak.upgrade() else { return };
            let (base, cid, file, model) = STATE.with(|s| {
                let st = s.borrow();
                let file = st
                    .plans
                    .get(index as usize)
                    .map(|p| p.file_name.clone())
                    .unwrap_or_default();
                (
                    base(),
                    st.selected.clone().unwrap_or_default(),
                    file,
                    st.model_id.clone(),
                )
            });
            if file.is_empty() || cid.is_empty() {
                return;
            }
            let action = action.to_string();
            let feedback = feedback.to_string();
            let weak = ui.as_weak();
            std::thread::spawn(move || {
                let result = api::plan_action(&base, &cid, &file, &action, &feedback, &model);
                let _ = weak.upgrade_in_event_loop(move |ui| match result {
                    Ok(()) => {
                        let msg = match action.as_str() {
                            "approve" => "Đã duyệt kế hoạch. Các agent đang thực thi.",
                            "reject" => "Đã gửi góp ý cho kế hoạch. AI sẽ cập nhật lại.",
                            _ => "Đã hủy kế hoạch.",
                        };
                        set_toast(&ui, msg);
                    }
                    Err(e) => set_toast(&ui, format!("Thao tác kế hoạch thất bại: {e}")),
                });
            });
        }
    });

    ui.on_answer_question({
        let weak = ui.as_weak();
        move |answer| {
            let Some(ui) = weak.upgrade() else { return };
            let answer = answer.to_string();
            let (base, qid) = STATE.with(|s| {
                let st = s.borrow();
                (
                    base(),
                    st.questions
                        .first()
                        .map(|q| q.id.clone())
                        .unwrap_or_default(),
                )
            });
            if qid.is_empty() || answer.trim().is_empty() {
                return;
            }
            let weak = ui.as_weak();
            std::thread::spawn(move || {
                let result = api::answer_question(&base, &qid, &answer);
                let _ = weak.upgrade_in_event_loop(move |ui| match result {
                    Ok(()) => {
                        STATE.with(|s| {
                            let mut st = s.borrow_mut();
                            st.questions.retain(|q| q.id != qid);
                            render(&ui, &mut st, false);
                        });
                    }
                    Err(e) => set_toast(&ui, format!("Trả lời thất bại: {e}")),
                });
            });
        }
    });
}

/// Đổi model trên composer; lưu theo conversation đang mở
fn choose_model(ui: &AppWindow, st: &mut UiState, id: String) {
    if let Some(cid) = st.selected.clone() {
        st.model_by_conv.insert(cid, id.clone());
    }
    st.model_id = id;
    render(ui, st, false);
}

/// Áp danh sách retry từ socket `retry:update` lên giao diện
fn apply_retries(ui: &AppWindow, list: Vec<PendingRetry>) {
    STATE.with(|s| {
        let mut st = s.borrow_mut();
        st.retries = list;
        render(ui, &mut st, false);
    });
}

fn retry_banner_text(r: &PendingRetry) -> String {
    let when = chrono::DateTime::parse_from_rfc3339(&r.retry_at)
        .map(|d| d.with_timezone(&chrono::Local).format("%H:%M").to_string())
        .unwrap_or_else(|_| r.retry_at.clone());
    let reason: String = r.reason.chars().take(160).collect();
    format!(
        "Giới hạn lượt chat. Sẽ tự gửi lại lúc {when} (lần {}/{}). {reason}",
        r.attempt, r.max_attempts
    )
}

fn main() -> Result<(), slint::PlatformError> {
    let base = std::env::var("MUOP_SERVER_URL")
        .unwrap_or_else(|_| DEFAULT_SERVER.to_string())
        .trim_end_matches('/')
        .to_string();

    let _ = BASE.set(base.clone());
    if let Ok(path) = std::env::var("MUOP_SCREENSHOT") {
        // Chế độ chụp ảnh: render không cần màn hình rồi thoát
        match screenshot::run(&path, &base) {
            Ok(()) => println!("Đã lưu ảnh: {path}"),
            Err(e) => {
                eprintln!("Chụp ảnh thất bại: {e}");
                std::process::exit(1);
            }
        }
        return Ok(());
    }

    let ui = AppWindow::new()?;
    // Timer định kỳ đọc trạng thái cuộn (xem poll_scroll); giữ biến sống suốt vòng lặp sự kiện
    let scroll_timer = slint::Timer::default();
    {
        let weak = ui.as_weak();
        scroll_timer.start(
            slint::TimerMode::Repeated,
            Duration::from_millis(100),
            move || {
                if let Some(ui) = weak.upgrade() {
                    poll_scroll(&ui);
                }
            },
        );
    }
    // Đồng bộ màu của std-widgets với theme lúc khởi động (changed chỉ chạy khi giá trị đổi)
    let palette = ui.global::<Palette>();
    palette.set_dark(false);
    palette.set_dark(true);
    wire_callbacks(&ui);
    live::spawn(base, ui.as_weak());
    let result = ui.run();
    drop(scroll_timer);
    result
}
