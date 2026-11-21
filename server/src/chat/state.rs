use super::*;

/// Khoảng tối thiểu giữa hai lần phát `chat:stream` của cùng một lượt
pub(super) const STREAM_EMIT_INTERVAL: Duration = Duration::from_millis(120);

#[derive(Default)]
pub(super) struct StreamThrottle {
    pub(super) last: Option<Instant>,
    pub(super) trailing: bool,
}

pub(super) static STREAM_THROTTLE: std::sync::OnceLock<Mutex<HashMap<String, StreamThrottle>>> =
    std::sync::OnceLock::new();

pub(super) fn stream_throttle() -> &'static Mutex<HashMap<String, StreamThrottle>> {
    STREAM_THROTTLE.get_or_init(|| Mutex::new(HashMap::new()))
}

#[derive(Clone)]
pub struct AppState {
    pub io: SocketIo,
    pub active_streams: Arc<Mutex<HashMap<String, ChatTurnStreamState>>>,
    pub running_pids: Arc<Mutex<HashMap<String, u32>>>,
    /// Lượt đang chạy được nhận lại sau khi server khởi động lại: key = conversation_id, value = pid
    /// value = (pid, thời điểm bắt đầu của tiến trình) để nhận diện đúng tiến trình
    pub adopted_turns: Arc<Mutex<HashMap<String, (u32, u64)>>>,
    /// Bản quota đã phát gần nhất (JSON) để chỉ phát `quotas:update` khi có thay đổi
    pub last_quotas_json: Arc<Mutex<String>>,
    /// Câu hỏi từ AI: key = conversation_id, value = danh sách câu hỏi
    pub ai_questions: Arc<Mutex<HashMap<String, Vec<crate::models::AIQuestion>>>>,
    /// Quay màn hình và phát luồng về app (bật bằng checkbox trên tray)
    pub screen: Arc<crate::screen::ScreenManager>,
}

impl AppState {
    pub fn new(io: SocketIo) -> Self {
        let screen = crate::screen::ScreenManager::new(io.clone());
        Self {
            io,
            screen,
            active_streams: Arc::new(Mutex::new(HashMap::new())),
            running_pids: Arc::new(Mutex::new(HashMap::new())),
            adopted_turns: Arc::new(Mutex::new(HashMap::new())),
            last_quotas_json: Arc::new(Mutex::new(String::new())),
            ai_questions: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    pub fn broadcast_stream_state(&self, state: &ChatTurnStreamState) {
        if let Ok(val) = serde_json::to_value(state) {
            if let Some(ns) = self.io.of("/") {
                let _ = ns.emit("chat:stream", &val);
            }
        }
    }

    /// Phát `chat:stream` của một lượt đang stream, giới hạn tần suất.
    /// Mỗi token không còn gửi một event (vốn kèm toàn bộ văn bản đã tích lũy):
    /// tối đa một event mỗi `STREAM_EMIT_INTERVAL`, phần còn lại được gom vào một lần phát muộn
    /// với trạng thái mới nhất. Lượt đã kết thúc thì không phát lại.
    pub fn broadcast_stream_throttled(&self, cid: &str) {
        let now = Instant::now();
        let wait = {
            let mut map = match stream_throttle().lock() {
                Ok(m) => m,
                Err(_) => return,
            };
            let entry = map.entry(cid.to_string()).or_default();
            match entry.last {
                Some(last) if now.duration_since(last) < STREAM_EMIT_INTERVAL => {
                    if entry.trailing {
                        return;
                    }
                    entry.trailing = true;
                    Some(STREAM_EMIT_INTERVAL - now.duration_since(last))
                }
                _ => {
                    entry.last = Some(now);
                    None
                }
            }
        };
        match wait {
            None => self.emit_latest_stream(cid),
            Some(delay) => {
                let st = self.clone();
                let cid = cid.to_string();
                let key = format!("stream:{cid}");
                crate::infra::jobs::submit_after(key, delay, move || {
                    if let Ok(mut map) = stream_throttle().lock() {
                        if let Some(entry) = map.get_mut(&cid) {
                            entry.trailing = false;
                            entry.last = Some(Instant::now());
                        }
                    }
                    st.emit_latest_stream(&cid);
                });
            }
        }
    }

    /// Phát trạng thái mới nhất của lượt; bỏ qua nếu lượt đã kết thúc hoặc đã bị xoá
    pub(super) fn emit_latest_stream(&self, cid: &str) {
        let latest = match self.active_streams.lock() {
            Ok(streams) => streams.get(cid).cloned(),
            Err(_) => None,
        };
        if let Some(state) = latest.filter(|s| s.is_running) {
            self.broadcast_stream_state(&state);
        }
    }

    /// Phát event cập nhật chỉ riêng cho 1 session cụ thể (Granular Event)
    pub fn broadcast_session_update(&self, session_id: &str) {
        let streams = self
            .active_streams
            .lock()
            .map(|g| g.clone())
            .unwrap_or_default();
        if let Some(session) = scanner::get_single_session_with_streams(session_id, &streams) {
            if let Ok(val) = serde_json::to_value(&session) {
                if let Some(ns) = self.io.of("/") {
                    let _ = ns.emit("session:update", &val);
                }
            }
        }
    }

    /// Phát files change vào room conversation (để chỉ UI client trong conversation đó nhận)
    pub fn emit_session_files_to_room(&self, session_id: &str) {
        let streams = self
            .active_streams
            .lock()
            .map(|g| g.clone())
            .unwrap_or_default();
        if let Some(session) = scanner::get_single_session_with_streams(session_id, &streams) {
            if let Ok(val) = serde_json::to_value(&session) {
                let room = format!("conv:{}", session.id);
                if let Some(ns) = self.io.of("/") {
                    let _ = ns.to(room).emit("fileschange", &val);
                }
            }
        }
    }

    /// Phát event cập nhật danh sách projects khi có thay đổi
    pub fn broadcast_projects_update(&self) {
        let streams = self
            .active_streams
            .lock()
            .map(|g| g.clone())
            .unwrap_or_default();
        let sessions = scanner::scan_all_sessions(&streams, None, 500);
        let projects = scanner::discover_projects(&sessions);
        if let Ok(val) = serde_json::to_value(&projects) {
            if let Some(ns) = self.io.of("/") {
                let _ = ns.emit("projects:update", &val);
            }
        }
    }

    /// Lấy quota/limit mới nhất (Antigravity + Claude Code) và chỉ phát `quotas:update` nếu thay đổi.
    /// Payload giống `GET /api/quota`. Hàm có I/O đồng bộ (daemon TCP, curl) nên phải được gọi trong `spawn_blocking`.
    /// Trả về `true` nếu đã phát event.
    pub fn broadcast_quotas_update(&self, force: bool) -> bool {
        let quotas = scanner::quota_snapshot(false);
        let val = match serde_json::to_value(&quotas) {
            Ok(v) => v,
            Err(_) => return false,
        };
        let serialized = val.to_string();
        if let Ok(mut last) = self.last_quotas_json.lock() {
            if !force && *last == serialized {
                return false;
            }
            *last = serialized;
        }
        if let Some(ns) = self.io.of("/") {
            let _ = ns.emit("quotas:update", &val);
        }
        true
    }

    /// Chạy `broadcast_quotas_update` ở thread blocking (an toàn khi gọi từ async context)
    pub fn spawn_quotas_update(&self, invalidate_cache: bool, force: bool) {
        let st = self.clone();
        tokio::task::spawn_blocking(move || {
            if invalidate_cache {
                scanner::invalidate_quota_cache();
            }
            st.broadcast_quotas_update(force);
        });
    }

    /// Phát file changes vào room conversation riêng (để chỉ clients trong conversation đó nhận)
    pub fn emit_conversation_files_change(&self, conversation_id: &str, files_change: Value) {
        let room = format!("conv:{}", conversation_id);
        if let Some(ns) = self.io.of("/") {
            let _ = ns.to(room).emit("fileschange", &files_change);
        }
    }
}
