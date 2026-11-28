//! Trạng thái dùng chung của app và các hành động (chọn, gửi, dừng).
//!
//! Dữ liệu realtime đi vào qua `handle` (từ luồng Socket.IO). Hành động của người dùng
//! gọi REST qua `data::api`, kết quả ghi lại vào các Signal.

use std::collections::HashMap;

use dioxus::prelude::*;
use serde_json::Value;

use crate::data::api::{self, ClaudeReply, OutgoingImage};
use crate::data::config::normalize_server_address;
use crate::data::images;
use crate::data::models::{
    parse_retries, parse_session_list, parse_streams, AiQuestion, ClaudePending,
    ConversationSession, FileTouched, PendingRetry, QuotaSnapshot, ServerMeta, SessionSummary,
    StreamState, ToolCall,
};
use crate::data::persist;
use crate::data::socket::{Incoming, SocketClient};
use crate::ui::model_groups::default_model;

/// Ảnh đã chọn, chờ gửi cùng lượt chat tiếp theo.
#[derive(Clone, Debug, PartialEq)]
pub struct DraftImage {
    pub id: u64,
    pub name: String,
    pub mime_type: String,
    pub data_base64: String,
}

/// Tệp đang mở trong khung chính.
#[derive(Clone, Debug, PartialEq)]
pub struct ViewedFile {
    pub path: String,
    pub name: String,
    pub size: u64,
    pub content: String,
    pub binary: bool,
    pub error: Option<String>,
    pub loading: bool,
}

/// Hộp thoại xem chi tiết của một lượt (tool call hoặc tệp đã đổi).
#[derive(Clone, Debug, PartialEq)]
pub enum Dialog {
    Tools {
        title: String,
        calls: Vec<ToolCall>,
    },
    Files {
        title: String,
        files: Vec<FileTouched>,
    },
}

/// Lượt vừa gửi, hiển thị ngay trước khi server đẩy `session:update`.
#[derive(Clone, Debug, PartialEq)]
pub struct PendingTurn {
    /// Rỗng khi là conversation mới chưa có id
    pub conversation_id: String,
    pub prompt: String,
}

#[derive(Clone, Copy)]
pub struct Store {
    pub address: Signal<String>,
    pub connected: Signal<bool>,
    pub notice: Signal<Option<String>>,
    pub sessions: Signal<Vec<SessionSummary>>,
    pub meta: Signal<Option<ServerMeta>>,
    pub streams: Signal<HashMap<String, StreamState>>,
    pub selected: Signal<Option<String>>,
    pub detail: Signal<Option<ConversationSession>>,
    pub detail_error: Signal<Option<String>>,
    pub pending: Signal<Option<PendingTurn>>,
    pub sending: Signal<bool>,
    pub model: Signal<String>,
    pub project: Signal<String>,
    pub socket: Signal<Option<SocketClient>>,
    pub quota: Signal<Option<QuotaSnapshot>>,
    pub retries: Signal<Vec<PendingRetry>>,
    /// Còn lịch sử cũ hơn chưa tải (nút "Tải lịch sử trước đó")
    pub has_older: Signal<bool>,
    pub loading_older: Signal<bool>,
    /// Phiên truy cập file của máy server (mở lần đầu khi cần duyệt thư mục)
    pub explorer_session: Signal<Option<String>>,
    /// Hiện cột workspace + cây thư mục
    pub explorer_open: Signal<bool>,
    /// Tương tác Claude (câu hỏi hoặc kế hoạch) đang chờ với conversation đang mở
    pub claude_pending: Signal<Option<ClaudePending>>,
    /// Câu hỏi của agy trong conversation đang mở
    pub ai_questions: Signal<Vec<AiQuestion>>,
    /// Nháp chưa gửi, theo khóa conversation (`new` khi chưa chọn conversation nào)
    pub drafts: Signal<HashMap<String, String>>,
    pub draft_images: Signal<Vec<DraftImage>>,
    pub dialog: Signal<Option<Dialog>>,
    /// Theme sáng (false = tối)
    pub theme_light: Signal<bool>,
    /// Tệp đang xem trong khung chính (`None` = xem hội thoại)
    pub viewed_file: Signal<Option<ViewedFile>>,
    /// Tệp đã đổi trong project đang xem (đường dẫn tuyệt đối → loại thay đổi)
    pub git_kinds: Signal<HashMap<String, String>>,
    /// Project đang xem có phải repo git không
    pub git_repo: Signal<bool>,
    /// Agy đã đăng nhập chưa (`None` = chưa hỏi được)
    pub agy_logged_in: Signal<Option<bool>>,
    /// Trạng thái đăng nhập Claude Code CLI
    pub claude_auth: Signal<Option<crate::data::models::ClaudeAuthStatus>>,
    /// Panel Docker đang mở (thay khung hội thoại)
    pub docker_panel: Signal<bool>,
    /// Máy để chọn cho Docker (danh sách SSH đã lưu)
    pub docker_hosts: Signal<Vec<crate::data::models::SshHost>>,
    /// Phiên Docker của máy đang chọn
    pub docker: Signal<Option<crate::data::models::DockerSession>>,
    /// Panel SSH đang mở (danh sách máy, chạy lệnh)
    pub ssh_panel: Signal<bool>,
    /// Danh sách máy SSH đã lưu ("Máy này" đứng đầu)
    pub ssh_hosts: Signal<Vec<crate::data::models::SshHost>>,
    /// Panel lịch sử git đang mở
    pub git_panel: Signal<bool>,
    /// Lịch sử commit của project đang xem
    pub git_history: Signal<Option<crate::data::models::GitHistoryResponse>>,
}

pub(crate) fn put<T: 'static>(sig: Signal<T>, value: T) {
    let mut s = sig;
    s.set(value);
}

impl Store {
    /// Tạo toàn bộ Signal. Chỉ gọi trong thân component (dùng hook).
    pub fn create() -> Self {
        Self {
            address: use_signal(|| persist::load().server_address),
            connected: use_signal(|| false),
            notice: use_signal(|| None),
            sessions: use_signal(Vec::new),
            meta: use_signal(|| None),
            streams: use_signal(HashMap::new),
            selected: use_signal(|| None),
            detail: use_signal(|| None),
            detail_error: use_signal(|| None),
            pending: use_signal(|| None),
            sending: use_signal(|| false),
            model: use_signal(String::new),
            project: use_signal(String::new),
            socket: use_signal(|| None),
            quota: use_signal(|| None),
            retries: use_signal(Vec::new),
            has_older: use_signal(|| false),
            loading_older: use_signal(|| false),
            explorer_session: use_signal(|| None),
            explorer_open: use_signal(|| true),
            claude_pending: use_signal(|| None),
            ai_questions: use_signal(Vec::new),
            drafts: use_signal(HashMap::new),
            draft_images: use_signal(Vec::new),
            dialog: use_signal(|| None),
            theme_light: use_signal(|| persist::load().theme == "light"),
            viewed_file: use_signal(|| None),
            git_kinds: use_signal(HashMap::new),
            git_repo: use_signal(|| false),
            agy_logged_in: use_signal(|| None),
            claude_auth: use_signal(|| None),
            docker_panel: use_signal(|| false),
            docker_hosts: use_signal(Vec::new),
            docker: use_signal(|| None),
            ssh_panel: use_signal(|| false),
            ssh_hosts: use_signal(Vec::new),
            git_panel: use_signal(|| false),
            git_history: use_signal(|| None),
        }
    }

    pub fn base(&self) -> String {
        self.address.peek().clone()
    }

    /// Xóa dữ liệu của máy cũ khi đổi địa chỉ. Model và project đã chọn được giữ lại.
    pub fn reset_for_new_server(&self) {
        put(self.connected, false);
        put(self.sessions, Vec::new());
        put(self.meta, None);
        put(self.streams, HashMap::new());
        put(self.selected, None);
        put(self.detail, None);
        put(self.detail_error, None);
        put(self.pending, None);
        put(self.notice, None);
        put(self.retries, Vec::new());
        put(self.quota, None);
        put(self.draft_images, Vec::new());
        put(self.dialog, None);
        put(self.claude_pending, None);
        put(self.ai_questions, Vec::new());
        put(self.has_older, false);
        put(self.loading_older, false);
        put(self.explorer_session, None);
        put(self.ssh_hosts, Vec::new());
        put(self.ssh_panel, false);
    }

    fn emit(&self, event: &str, data: Value) {
        if let Some(client) = self.socket.peek().clone() {
            client.emit(event, data);
        }
    }

    /// Đưa một sự kiện từ luồng Socket.IO vào trạng thái.
    pub fn handle(&self, incoming: Incoming) {
        match incoming {
            Incoming::Connected => {
                put(self.connected, true);
                put(self.notice, None);
                self.emit("request-meta", Value::Null);
                self.emit("request-sessions", Value::Null);
                self.emit("request-streams", Value::Null);
                self.refresh_quota();
                self.refresh_auth();
            }
            Incoming::Disconnected(reason) => {
                put(self.connected, false);
                put(
                    self.notice,
                    Some(format!("Mất kết nối: {reason}. Đang thử lại…")),
                );
            }
            Incoming::Event { name, data } => self.on_event(&name, data),
        }
    }

    fn on_event(&self, name: &str, data: Value) {
        match name {
            "sessions:list" => {
                if let Ok(list) = parse_session_list(data) {
                    put(self.sessions, list);
                }
            }
            "meta:update" => {
                if let Ok(meta) = serde_json::from_value::<ServerMeta>(data) {
                    self.apply_meta(meta);
                }
            }
            "streams:update" => {
                if let Ok(streams) = parse_streams(data) {
                    put(self.streams, streams);
                }
            }
            "chat:stream" => {
                if let Ok(stream) = serde_json::from_value::<StreamState>(data) {
                    self.apply_stream(stream);
                }
            }
            "session:update" => {
                if let Ok(session) = serde_json::from_value::<ConversationSession>(data) {
                    self.apply_session(session);
                }
            }
            "quotas:update" => self.refresh_quota(),
            "retry:update" => {
                if let Ok(list) = parse_retries(data) {
                    put(self.retries, list);
                }
            }
            "session:removed" => {
                let id = data
                    .get("id")
                    .and_then(|v| v.as_str())
                    .unwrap_or_default()
                    .to_string();
                if id.is_empty() {
                    return;
                }
                let mut sessions = self.sessions.peek().clone();
                sessions.retain(|s| s.id != id);
                put(self.sessions, sessions);
                if self.selected.peek().as_deref() == Some(id.as_str()) {
                    self.new_conversation();
                }
            }
            _ => {}
        }
    }

    fn apply_meta(&self, meta: ServerMeta) {
        // Chọn model và project mặc định khi chưa có lựa chọn hợp lệ
        let current = self.model.peek().clone();
        if current.is_empty() || !meta.available_models.contains(&current) {
            if let Some(model) = default_model(&meta.available_models) {
                put(self.model, model);
            }
        }
        let project = self.project.peek().clone();
        if project.is_empty() {
            if let Some(first) = meta.projects.first() {
                put(self.project, first.path.clone());
                self.refresh_git(first.path.clone());
            }
        }
        put(self.meta, Some(meta));
    }

    fn apply_stream(&self, stream: StreamState) {
        let mut streams = self.streams.peek().clone();
        if stream.is_running {
            if !stream.error.is_empty()
                && self.selected.peek().as_deref() == Some(stream.conversation_id.as_str())
            {
                put(self.notice, Some(stream.error.clone()));
            }
            streams.insert(stream.conversation_id.clone(), stream);
        } else {
            streams.remove(&stream.conversation_id);
        }
        put(self.streams, streams);
    }

    fn apply_session(&self, session: ConversationSession) {
        let id = session.id.clone();
        let summary = SessionSummary::from_session(&session);
        let mut sessions = self.sessions.peek().clone();
        match sessions.iter_mut().find(|s| s.id == id) {
            Some(existing) => *existing = summary,
            None => sessions.insert(0, summary),
        }
        put(self.sessions, sessions);

        // Lượt đang chờ đã được ghi vào lịch sử thì không cần hiển thị tạm nữa
        let pending = self.pending.peek().clone();
        if let Some(turn) = pending {
            let saved = session
                .steps
                .iter()
                .any(|s| s.kind == "USER_INPUT" && s.content.trim() == turn.prompt.trim());
            if turn.conversation_id == id && saved {
                put(self.pending, None);
            }
        }

        if self.selected.peek().as_deref() == Some(id.as_str()) {
            let mut session = session;
            if let Some(previous) = self.detail.peek().as_ref().filter(|d| d.id == id) {
                session.steps = merge_steps(&previous.steps, session.steps);
            }
            put(self.detail, Some(session));
            put(self.detail_error, None);
            self.refresh_interactions(id.clone());
        }
        // Lượt vừa kết thúc có thể đã đổi tệp: làm mới trạng thái git của project đang xem
        let current = self.project.peek().clone();
        if !current.is_empty() && session_project_matches(&current, &id, &self.sessions.peek()) {
            self.refresh_git(current);
        }
    }

    /// Tải lại tương tác Claude đang chờ và câu hỏi agy của conversation.
    pub fn refresh_interactions(&self, id: String) {
        let base = self.base();
        let store = *self;
        dioxus::prelude::spawn(async move {
            let (b1, i1) = (base.clone(), id.clone());
            let pending = api::on_io(async move { api::claude_pending(&b1, &i1).await }).await;
            if store.selected.peek().as_deref() == Some(id.as_str()) {
                if let Ok(resp) = pending {
                    put(store.claude_pending, resp.pending);
                }
            }
            let (b2, i2) = (base, id.clone());
            let questions = api::on_io(async move { api::ai_questions(&b2, &i2).await }).await;
            if store.selected.peek().as_deref() == Some(id.as_str()) {
                if let Ok(resp) = questions {
                    put(store.ai_questions, resp.questions);
                }
            }
        });
    }

    /// Trả lời câu hỏi `AskUserQuestion` (`answers`) hoặc quyết định kế hoạch (`decision`).
    pub fn respond_claude(
        &self,
        answers: Vec<(String, String)>,
        decision: &'static str,
        feedback: String,
    ) {
        let Some(pending) = self.claude_pending.peek().clone() else {
            return;
        };
        let Some(id) = self.selected.peek().clone() else {
            return;
        };
        let project = self
            .detail
            .peek()
            .as_ref()
            .map(|d| d.project_path.clone())
            .unwrap_or_default();
        let reply = ClaudeReply {
            conversation_id: id.clone(),
            tool_use_id: pending.tool_use_id.clone(),
            project_path: project,
            model: self.model.peek().clone(),
            answers,
            decision: decision.to_string(),
            feedback,
        };
        let base = self.base();
        let store = *self;
        dioxus::prelude::spawn(async move {
            let result = api::on_io(async move { api::claude_respond(&base, &reply).await }).await;
            match result {
                Ok(value) if value.get("ok").and_then(|v| v.as_bool()).unwrap_or(true) => {
                    put(store.claude_pending, None);
                    store.refresh_interactions(id);
                }
                Ok(value) => put(
                    store.notice,
                    Some(
                        value
                            .get("error")
                            .and_then(|v| v.as_str())
                            .unwrap_or("Không gửi được trả lời")
                            .to_string(),
                    ),
                ),
                Err(e) => put(store.notice, Some(e.to_string())),
            }
        });
    }

    /// Ghi câu trả lời cho một câu hỏi của agy.
    pub fn answer_ai(&self, question_id: String, answer: String) {
        let Some(id) = self.selected.peek().clone() else {
            return;
        };
        let base = self.base();
        let store = *self;
        dioxus::prelude::spawn(async move {
            let result =
                api::on_io(async move { api::ai_answer(&base, &question_id, &answer).await }).await;
            match result {
                Ok(_) => store.refresh_interactions(id),
                Err(e) => put(store.notice, Some(e.to_string())),
            }
        });
    }

    /// Nháp của một khóa (conversation hoặc `new`).
    pub fn draft_for(&self, key: &str) -> String {
        self.drafts.peek().get(key).cloned().unwrap_or_default()
    }

    /// Đổi theme sáng/tối và lưu lựa chọn cho lần mở sau.
    pub fn toggle_theme(&self) {
        let light = !*self.theme_light.peek();
        put(self.theme_light, light);
        let mut saved = persist::load();
        saved.theme = if light { "light" } else { "dark" }.to_string();
        persist::save(&saved);
    }

    pub fn set_draft(&self, key: &str, text: String) {
        let mut map = self.drafts.peek().clone();
        if text.is_empty() {
            map.remove(key);
        } else {
            map.insert(key.to_string(), text);
        }
        put(self.drafts, map);
    }

    /// Tải thêm 50 bước cũ hơn bước đầu tiên đang hiển thị.
    pub fn load_older(&self) {
        if *self.loading_older.peek() || !*self.has_older.peek() {
            return;
        }
        let Some(detail) = self.detail.peek().clone() else {
            return;
        };
        let Some(first) = detail.steps.first().map(|s| s.step_index) else {
            return;
        };
        let id = detail.id.clone();
        let base = self.base();
        let store = *self;
        put(self.loading_older, true);
        dioxus::prelude::spawn(async move {
            let id2 = id.clone();
            let result =
                api::on_io(async move { api::session_steps(&base, &id2, first, 50).await }).await;
            put(store.loading_older, false);
            match result {
                Ok(page) => {
                    if store.selected.peek().as_deref() != Some(id.as_str()) {
                        return;
                    }
                    let current = store.detail.peek().clone();
                    if let Some(mut current) = current {
                        current.steps = merge_steps(&page.steps, current.steps);
                        put(store.detail, Some(current));
                    }
                    put(store.has_older, page.has_more);
                }
                Err(e) => put(store.notice, Some(e.to_string())),
            }
        });
    }

    /// Chọn một conversation (`None` = conversation mới).
    pub fn select(&self, id: Option<String>) {
        self.hide_side_panels();
        put(self.claude_pending, None);
        put(self.ai_questions, Vec::new());
        put(self.selected, id.clone());
        put(self.detail, None);
        put(self.detail_error, None);
        let pending_conv = self
            .pending
            .peek()
            .as_ref()
            .map(|p| p.conversation_id.clone());
        let keep_pending = match (&id, pending_conv) {
            (None, Some(c)) => c.is_empty(),
            (Some(id), Some(c)) => id == &c,
            _ => false,
        };
        if !keep_pending {
            put(self.pending, None);
        }
        put(self.notice, None);

        let Some(id) = id else { return };
        // Dùng model và project của conversation đã mở
        let summary = self.sessions.peek().iter().find(|s| s.id == id).cloned();
        if let Some(summary) = summary {
            if !summary.selected_model.is_empty() {
                put(self.model, summary.selected_model.clone());
            }
            if !summary.project_path.is_empty() {
                put(self.project, summary.project_path.clone());
                self.refresh_git(summary.project_path.clone());
            }
        }
        self.load_detail(id);
    }

    fn load_detail(&self, id: String) {
        let base = self.base();
        let store = *self;
        dioxus::prelude::spawn(async move {
            let result = api::on_io({
                let id = id.clone();
                async move { api::session(&base, &id).await }
            })
            .await;
            if store.selected.peek().as_deref() != Some(id.as_str()) {
                return; // Người dùng đã chọn conversation khác trong lúc chờ
            }
            match result {
                Ok(session) => {
                    if !session.selected_model.is_empty() {
                        put(store.model, session.selected_model.clone());
                    }
                    // Server trả tối đa 100 bước gần nhất: còn có thể có lịch sử cũ hơn
                    put(store.has_older, session.steps.len() >= 100);
                    put(store.detail, Some(session));
                    put(store.detail_error, None);
                    store.refresh_interactions(id.clone());
                }
                Err(e) => put(store.detail_error, Some(e.to_string())),
            }
        });
    }

    pub fn new_conversation(&self) {
        self.select(None);
    }

    /// Gửi một lượt chat. Conversation mới khi chưa chọn conversation nào.
    pub fn send(&self, prompt: String) {
        let prompt = prompt.trim().to_string();
        let drafts = self.draft_images.peek().clone();
        if (prompt.is_empty() && drafts.is_empty()) || *self.sending.peek() {
            return;
        }
        let outgoing: Vec<OutgoingImage> = drafts
            .iter()
            .map(|d| OutgoingImage {
                name: d.name.clone(),
                mime_type: d.mime_type.clone(),
                data_base64: d.data_base64.clone(),
            })
            .collect();
        let selected = self.selected.peek().clone();
        let conversation_id = selected.clone().unwrap_or_default();
        let project = match &selected {
            Some(id) => self
                .detail
                .peek()
                .as_ref()
                .map(|d| d.project_path.clone())
                .filter(|p| !p.is_empty())
                .or_else(|| {
                    self.sessions
                        .peek()
                        .iter()
                        .find(|s| &s.id == id)
                        .map(|s| s.project_path.clone())
                })
                .unwrap_or_default(),
            None => self.project.peek().clone(),
        };
        if project.is_empty() {
            put(self.notice, Some("Chọn một project trước khi gửi".into()));
            return;
        }
        let model = self.model.peek().clone();
        let base = self.base();
        let store = *self;

        put(self.sending, true);
        put(self.notice, None);
        put(
            self.pending,
            Some(PendingTurn {
                conversation_id: conversation_id.clone(),
                prompt: prompt.clone(),
            }),
        );

        dioxus::prelude::spawn(async move {
            let (p, c, m) = (prompt.clone(), conversation_id.clone(), model.clone());
            let result =
                api::on_io(
                    async move { api::chat_send(&base, &p, &project, &c, &m, &outgoing).await },
                )
                .await;
            put(store.sending, false);
            match result {
                Ok(resp) if resp.ok => {
                    put(store.draft_images, Vec::new());
                    let new_id = resp.conversation_id.clone();
                    if conversation_id.is_empty() {
                        // Conversation mới: chuyển sang conversation vừa tạo
                        put(
                            store.pending,
                            Some(PendingTurn {
                                conversation_id: new_id.clone(),
                                prompt,
                            }),
                        );
                        if store.selected.peek().is_none() {
                            put(store.selected, Some(new_id.clone()));
                            store.load_detail(new_id);
                        }
                    }
                    put(store.notice, None);
                }
                Ok(resp) => {
                    put(store.pending, None);
                    put(
                        store.notice,
                        Some(if resp.error.is_empty() {
                            "Máy chủ từ chối lượt chat".into()
                        } else {
                            resp.error
                        }),
                    );
                }
                Err(e) => {
                    put(store.pending, None);
                    put(store.notice, Some(e.to_string()));
                }
            }
        });
    }

    /// Dừng lượt đang chạy của conversation đang mở.
    pub fn stop(&self) {
        let Some(id) = self.selected.peek().clone() else {
            return;
        };
        let base = self.base();
        let store = *self;
        dioxus::prelude::spawn(async move {
            let result = api::on_io(async move { api::chat_stop(&base, &id).await }).await;
            match result {
                Ok(true) => {}
                Ok(false) => put(
                    store.notice,
                    Some("Không có lượt nào đang chạy để dừng".into()),
                ),
                Err(e) => put(store.notice, Some(e.to_string())),
            }
        });
    }

    /// Đổi địa chỉ máy chủ. Luồng Socket.IO được mở lại trong `Shell`.
    pub fn connect_to(&self, input: &str) -> Result<(), String> {
        let normalized = normalize_server_address(input)?;
        let mut saved = persist::load();
        saved.remember(&normalized);
        persist::save(&saved);
        put(self.address, normalized);
        self.reset_for_new_server();
        Ok(())
    }

    /// Địa chỉ đã kết nối trước đây (mới nhất đứng đầu), để chọn lại nhanh.
    pub fn saved_servers(&self) -> Vec<String> {
        persist::load().servers
    }

    /// Đổi project đang xem (cây thư mục và project của conversation mới).
    pub fn set_project(&self, path: String) {
        put(self.project, path.clone());
        self.refresh_git(path);
        if *self.git_panel.peek() {
            put(self.git_history, None);
            self.load_git_history();
        }
    }

    /// Mở hoặc đóng panel Docker. Khi mở, chọn máy đầu tiên (ưu tiên "Máy này") và quét container.
    pub fn toggle_docker_panel(&self) {
        if *self.docker_panel.peek() {
            self.close_docker_panel();
            return;
        }
        self.hide_side_panels();
        put(self.docker_panel, true);
        let base = self.base();
        let store = *self;
        dioxus::prelude::spawn(async move {
            let hosts = api::on_io(async move { api::ssh_hosts(&base).await }).await;
            let Ok(hosts) = hosts else {
                put(store.notice, Some("Không tải được danh sách máy".into()));
                return;
            };
            let first = hosts
                .iter()
                .find(|h| h.builtin)
                .or_else(|| hosts.first())
                .map(|h| h.id);
            put(store.docker_hosts, hosts);
            if store.docker.peek().is_none() {
                if let Some(id) = first {
                    store.open_docker(id);
                }
            }
        });
    }

    /// Mở phiên Docker của một máy (đóng phiên máy trước nếu khác máy).
    pub fn open_docker(&self, host_id: u64) {
        let base = self.base();
        let store = *self;
        let previous = self.docker.peek().clone();
        put(self.docker, None);
        dioxus::prelude::spawn(async move {
            if let Some(old) = previous.filter(|s| s.host_id != host_id) {
                let (b, sid) = (base.clone(), old.session_id.clone());
                let _ = api::on_io(async move { api::docker_close(&b, &sid).await }).await;
            }
            let b = base.clone();
            match api::on_io(async move { api::docker_open(&b, host_id).await }).await {
                Ok(resp) if resp.ok => put(store.docker, resp.session),
                Ok(resp) => put(store.notice, Some(resp.error)),
                Err(e) => put(store.notice, Some(e.to_string())),
            }
        });
    }

    /// Quét lại container của phiên Docker đang mở.
    pub fn scan_docker(&self) {
        let Some(session) = self.docker.peek().clone() else {
            return;
        };
        let base = self.base();
        let store = *self;
        dioxus::prelude::spawn(async move {
            let sid = session.session_id.clone();
            match api::on_io(async move { api::docker_scan(&base, &sid).await }).await {
                Ok(resp) if resp.ok => put(store.docker, resp.session),
                Ok(resp) => {
                    // Phiên đã kết thúc (404): bỏ phiên, người dùng mở lại máy
                    put(store.docker, None);
                    put(store.notice, Some(resp.error));
                }
                Err(e) => put(store.notice, Some(e.to_string())),
            }
        });
    }

    /// Khởi động lại (`restart`) hoặc dừng (`stop`) các container đã chọn.
    pub fn docker_action(&self, action: &'static str, ids: Vec<String>) {
        let Some(session) = self.docker.peek().clone() else {
            return;
        };
        let base = self.base();
        let store = *self;
        dioxus::prelude::spawn(async move {
            let sid = session.session_id.clone();
            match api::on_io(async move { api::docker_action(&base, &sid, action, &ids).await })
                .await
            {
                Ok(resp) if resp.ok => put(store.docker, resp.session),
                Ok(resp) => put(store.notice, Some(resp.error)),
                Err(e) => put(store.notice, Some(e.to_string())),
            }
        });
    }

    /// Đóng panel Docker và kết thúc phiên của máy đang xem.
    pub fn close_docker_panel(&self) {
        put(self.docker_panel, false);
        let session = self.docker.peek().clone();
        put(self.docker, None);
        if let Some(session) = session {
            let base = self.base();
            dioxus::prelude::spawn(async move {
                let sid = session.session_id.clone();
                let _ = api::on_io(async move { api::docker_close(&base, &sid).await }).await;
            });
        }
    }

    /// Tải lại trạng thái đăng nhập agy và Claude (chỉ đọc, không mở OAuth).
    pub fn refresh_auth(&self) {
        let base = self.base();
        let store = *self;
        dioxus::prelude::spawn(async move {
            let (b1, b2) = (base.clone(), base);
            if let Ok(agy) = api::on_io(async move { api::agy_auth_status(&b1).await }).await {
                put(store.agy_logged_in, Some(agy.logged_in));
            }
            if let Ok(claude) = api::on_io(async move { api::claude_auth_status(&b2).await }).await
            {
                put(store.claude_auth, Some(claude));
            }
        });
    }

    /// Mở hoặc đóng lịch sử git của project đang xem.
    pub fn toggle_git_panel(&self) {
        if *self.git_panel.peek() {
            put(self.git_panel, false);
            return;
        }
        self.hide_side_panels();
        put(self.git_panel, true);
        self.load_git_history();
    }

    /// Đóng các panel phụ (Docker, SSH, lịch sử git, xem tệp) để hiện khung hội thoại hoặc panel khác.
    /// Không kết thúc phiên Docker/SSH: mở lại panel vẫn thấy phiên cũ (giống Flutter).
    pub fn hide_side_panels(&self) {
        put(self.docker_panel, false);
        put(self.ssh_panel, false);
        put(self.git_panel, false);
        put(self.viewed_file, None);
    }

    /// Mở hoặc đóng panel SSH. Khi mở, tải lại danh sách máy.
    pub fn toggle_ssh_panel(&self) {
        if *self.ssh_panel.peek() {
            put(self.ssh_panel, false);
            return;
        }
        self.hide_side_panels();
        put(self.ssh_panel, true);
        self.reload_ssh_hosts();
    }

    /// Tải lại danh sách máy SSH đã lưu.
    pub fn reload_ssh_hosts(&self) {
        let base = self.base();
        let store = *self;
        dioxus::prelude::spawn(async move {
            match api::on_io(async move { api::ssh_hosts(&base).await }).await {
                Ok(hosts) => put(store.ssh_hosts, hosts),
                Err(e) => put(store.notice, Some(e.to_string())),
            }
        });
    }

    /// Tải lại lịch sử commit của project đang xem (100 commit gần nhất).
    pub fn load_git_history(&self) {
        let project = self.project.peek().clone();
        if project.is_empty() {
            return;
        }
        let base = self.base();
        let store = *self;
        dioxus::prelude::spawn(async move {
            let p = project.clone();
            let result = api::on_io(async move { api::git_history(&base, &p, 100).await }).await;
            if *store.project.peek() != project {
                return;
            }
            match result {
                Ok(resp) if resp.ok => put(store.git_history, Some(resp)),
                Ok(resp) => put(store.notice, Some(resp.error)),
                Err(e) => put(store.notice, Some(e.to_string())),
            }
        });
    }

    /// Tải lại tệp đã đổi của project (sau khi đổi project hoặc khi một lượt chat kết thúc).
    pub fn refresh_git(&self, project_path: String) {
        if project_path.is_empty() {
            return;
        }
        let base = self.base();
        let store = *self;
        dioxus::prelude::spawn(async move {
            let p = project_path.clone();
            if let Ok(resp) = api::on_io(async move { api::git_status(&base, &p).await }).await {
                if *store.project.peek() != project_path {
                    return; // Đã đổi project trong lúc chờ
                }
                put(store.git_repo, resp.is_repo);
                put(
                    store.git_kinds,
                    if resp.ok { resp.kinds } else { HashMap::new() },
                );
            }
        });
    }

    /// Phiên truy cập file của máy server: mở khi chưa có, dùng lại khi còn hiệu lực.
    async fn explorer_session_id(self) -> Result<String, String> {
        if let Some(id) = self.explorer_session.peek().clone() {
            return Ok(id);
        }
        let base = self.base();
        let opened = api::on_io(async move { api::sftp_local(&base).await })
            .await
            .map_err(|e| e.to_string())?;
        if !opened.ok || opened.session.session_id.is_empty() {
            return Err(if opened.error.is_empty() {
                "Không mở được phiên file của máy chủ".into()
            } else {
                opened.error
            });
        }
        put(
            self.explorer_session,
            Some(opened.session.session_id.clone()),
        );
        Ok(opened.session.session_id)
    }

    /// Liệt kê một thư mục của máy server. Mở lại phiên một lần khi phiên đã hết hạn.
    pub async fn list_dir(self, path: String) -> Result<Vec<crate::data::models::FsEntry>, String> {
        for attempt in 0..2 {
            let session = self.explorer_session_id().await?;
            let (base, p, s) = (self.base(), path.clone(), session);
            let listing = api::on_io(async move { api::sftp_list(&base, &s, &p).await })
                .await
                .map_err(|e| e.to_string())?;
            if listing.ok {
                return Ok(listing.entries);
            }
            if listing.session_gone && attempt == 0 {
                put(self.explorer_session, None);
                continue;
            }
            return Err(if listing.error.is_empty() {
                "Không đọc được thư mục".into()
            } else {
                listing.error
            });
        }
        Err("Không đọc được thư mục".into())
    }

    /// Đọc nội dung một tệp của máy server (tối đa 1MB, tệp nhị phân trả `binary`).
    pub async fn read_file(
        self,
        path: String,
    ) -> Result<crate::data::models::SftpReadResponse, String> {
        for attempt in 0..2 {
            let session = self.explorer_session_id().await?;
            let (base, p, s) = (self.base(), path.clone(), session);
            let read = api::on_io(async move { api::sftp_read(&base, &s, &p).await })
                .await
                .map_err(|e| e.to_string())?;
            if read.ok {
                return Ok(read);
            }
            if read.session_gone && attempt == 0 {
                put(self.explorer_session, None);
                continue;
            }
            return Err(if read.error.is_empty() {
                "Không đọc được tệp".into()
            } else {
                read.error
            });
        }
        Err("Không đọc được tệp".into())
    }

    /// Mở một tệp trong khung chính. Nội dung tải nền; lỗi hiện ngay trong khung.
    pub fn open_file(&self, path: String) {
        let name = path.rsplit('/').next().unwrap_or_default().to_string();
        self.hide_side_panels();
        put(
            self.viewed_file,
            Some(ViewedFile {
                path: path.clone(),
                name,
                size: 0,
                content: String::new(),
                binary: false,
                error: None,
                loading: true,
            }),
        );
        let store = *self;
        dioxus::prelude::spawn(async move {
            let result = store.read_file(path.clone()).await;
            let mut current = store.viewed_file.peek().clone();
            if let Some(file) = current.as_mut().filter(|f| f.path == path) {
                file.loading = false;
                match result {
                    Ok(read) => {
                        file.size = read.size;
                        file.binary = read.binary;
                        file.content = read.content;
                        file.error = None;
                    }
                    Err(message) => file.error = Some(message),
                }
                put(store.viewed_file, current);
            }
        });
    }

    pub fn close_file(&self) {
        put(self.viewed_file, None);
    }

    /// Thêm ảnh đã đọc từ đĩa vào danh sách chờ gửi. Ảnh không hợp lệ được báo lỗi, không dừng cả lô.
    pub fn add_images(&self, picked: Vec<(String, Vec<u8>)>) {
        let existing = self.draft_images.peek().len();
        let sizes: Vec<(String, usize)> =
            picked.iter().map(|(n, b)| (n.clone(), b.len())).collect();
        let checked = images::check_new(existing, &sizes);
        let mut next_id = existing as u64 + 1;
        let mut list = self.draft_images.peek().clone();
        for index in checked.accepted {
            let (name, bytes) = &picked[index];
            let Some(mime) = images::mime_for_name(name) else {
                continue;
            };
            list.push(DraftImage {
                id: next_id,
                name: name.clone(),
                mime_type: mime.to_string(),
                data_base64: images::encode_base64(bytes),
            });
            next_id += 1;
        }
        put(self.draft_images, list);
        if !checked.errors.is_empty() {
            put(self.notice, Some(checked.errors.join("; ")));
        }
    }

    pub fn remove_image(&self, id: u64) {
        let mut list = self.draft_images.peek().clone();
        list.retain(|d| d.id != id);
        put(self.draft_images, list);
    }

    pub fn open_dialog(&self, dialog: Dialog) {
        put(self.dialog, Some(dialog));
    }

    pub fn close_dialog(&self) {
        put(self.dialog, None);
    }

    /// Tải lại quota của mọi provider. Lỗi giữ số liệu cũ, không tự đoán số.
    pub fn refresh_quota(&self) {
        let base = self.base();
        let store = *self;
        dioxus::prelude::spawn(async move {
            if let Ok(snapshot) = api::on_io(async move { api::quota(&base).await }).await {
                put(store.quota, Some(snapshot));
            }
        });
    }

    /// Hủy lịch tự gửi lại đang chờ của conversation.
    pub fn cancel_retry(&self, conversation_id: String) {
        let base = self.base();
        let store = *self;
        dioxus::prelude::spawn(async move {
            let result =
                api::on_io(async move { api::retry_cancel(&base, &conversation_id).await }).await;
            if let Err(e) = result {
                put(store.notice, Some(e.to_string()));
            }
        });
    }

    /// Duyệt (`approve`), từ chối kèm góp ý (`reject`) hoặc hủy (`cancel`) một kế hoạch.
    pub fn plan_action(
        &self,
        conversation_id: String,
        file_name: String,
        action: &'static str,
        feedback: String,
    ) {
        let base = self.base();
        let model = self.model.peek().clone();
        let store = *self;
        dioxus::prelude::spawn(async move {
            let result = api::on_io(async move {
                api::plan_action(
                    &base,
                    &conversation_id,
                    &file_name,
                    action,
                    &feedback,
                    &model,
                )
                .await
            })
            .await;
            match result {
                Ok(value) if value.get("ok").and_then(|v| v.as_bool()).unwrap_or(true) => {}
                Ok(value) => put(
                    store.notice,
                    Some(
                        value
                            .get("error")
                            .and_then(|v| v.as_str())
                            .unwrap_or("Không thực hiện được hành động")
                            .to_string(),
                    ),
                ),
                Err(e) => put(store.notice, Some(e.to_string())),
            }
        });
    }
}

/// Ghép bước cũ (đã tải thêm) với bước mới từ snapshot: giữ mọi bước có chỉ số
/// nhỏ hơn bước đầu của snapshot, rồi lấy snapshot. Bước trùng chỉ số lấy bản mới.
pub fn merge_steps(
    older: &[crate::data::models::AgentStep],
    newer: Vec<crate::data::models::AgentStep>,
) -> Vec<crate::data::models::AgentStep> {
    let Some(first_new) = newer.first().map(|s| s.step_index) else {
        return older.to_vec();
    };
    let mut merged: Vec<_> = older
        .iter()
        .filter(|s| s.step_index < first_new)
        .cloned()
        .collect();
    merged.extend(newer);
    merged
}

/// Conversation `id` có thuộc project `project` không (theo danh sách session đã biết).
pub fn session_project_matches(project: &str, id: &str, sessions: &[SessionSummary]) -> bool {
    sessions
        .iter()
        .any(|s| s.id == id && s.project_path == project)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::data::models::AgentStep;

    fn step(i: u64, content: &str) -> AgentStep {
        AgentStep {
            step_index: i,
            content: content.into(),
            ..Default::default()
        }
    }

    #[test]
    fn merge_keeps_older_pages_and_takes_newer_snapshot() {
        let older = vec![step(1, "a"), step(2, "b"), step(5, "e-cũ")];
        let newer = vec![step(5, "e-mới"), step(6, "f")];
        let merged = merge_steps(&older, newer);
        let contents: Vec<_> = merged.iter().map(|s| s.content.as_str()).collect();
        assert_eq!(contents, vec!["a", "b", "e-mới", "f"]);
    }

    #[test]
    fn merge_with_empty_snapshot_keeps_older() {
        let older = vec![step(1, "a")];
        assert_eq!(merge_steps(&older, Vec::new()), older);
    }
}
