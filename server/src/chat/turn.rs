use super::*;

/// Ghép phần đã chốt (committed) với phần đang stream dở (live).
pub(super) fn compose_text(committed: &str, live: &str) -> String {
    match (committed.is_empty(), live.is_empty()) {
        (_, true) => committed.to_string(),
        (true, false) => live.to_string(),
        (false, false) => format!("{}\n\n{}", committed, live),
    }
}

/// Ngữ cảnh chung của một lượt chat, dùng để phát `chat:stream`
pub(super) struct TurnCtx {
    pub(super) state: AppState,
    pub(super) pid: u32,
    pub(super) cwd: String,
    pub(super) prompt: String,
    pub(super) started_at: String,
    pub(super) model: String,
    /// Yêu cầu gốc, dùng để gửi lại khi bị rate limit
    pub(super) request: ChatSendRequest,
    /// Lần thử của lượt này (0 = người dùng gửi, >0 = tự gửi lại)
    pub(super) attempt: u32,
    /// Provider của lượt (`agy` hoặc `claude-cli`), ghi vào bảng `running_turns`
    pub(super) provider: Provider,
}

impl TurnCtx {
    pub(super) fn emit(&self, cid: &str, text: String, step: &str, thinking: String) {
        let stream_state = ChatTurnStreamState {
            conversation_id: cid.to_string(),
            project_path: self.cwd.clone(),
            user_prompt: self.prompt.clone(),
            streaming_text: text,
            is_running: true,
            active_step_type: step.to_string(),
            started_at: self.started_at.clone(),
            error: String::new(),
            thinking_text: thinking,
        };
        if let Ok(mut streams) = self.state.active_streams.lock() {
            streams.insert(cid.to_string(), stream_state);
        }
        self.state.broadcast_stream_throttled(cid);
    }

    /// Đăng ký session id khi CLI báo init (cũng ghi pid để có thể dừng)
    pub(super) fn register(&self, cid: &str) {
        // Lượt mới của server thay thế lượt đã nhận lại (nếu có) trên conversation này
        if let Ok(mut adopted) = self.state.adopted_turns.lock() {
            adopted.remove(cid);
        }
        // Lượt mới thay thế dấu "bị cắt" của lượt trước trên conversation này
        crate::infra::store::clear_cut_short_turn(cid);
        // Ghi model kèm mức đã dùng cho lượt này, để mở lại conversation vẫn hiện đúng model
        let requested = self.request.model.trim();
        if !requested.is_empty() && requested != "default" {
            crate::infra::store::set_conversation_model(cid, requested);
        }
        if self.pid > 0 {
            if let Ok(mut pids) = self.state.running_pids.lock() {
                pids.insert(cid.to_string(), self.pid);
            }
            // Ghi lại lượt để nhận lại được sau khi server restart (kể cả conversation mới)
            if let Some(row) = recovery::running_turn_row(
                cid,
                provider_source(self.provider),
                self.pid,
                &self.cwd,
                &self.started_at,
            ) {
                crate::infra::store::upsert_running_turn(&row);
            }
        }
    }
}

/// Trạng thái đọc một lượt chat (cập nhật liên tục khi đọc stdout)
pub(super) struct TurnState {
    pub(super) tracked_id: String,
    pub(super) committed: String,
    pub(super) live: String,
    pub(super) thinking_text: String,
    pub(super) current_block_type: String,
    pub(super) result_error: Option<String>,
    pub(super) init_tx: Option<oneshot::Sender<String>>,
    /// Chỉ số bước agy đang ghép `text_delta` vào (để biết khi nào sang bước mới)
    pub(super) text_step: Option<u64>,
}

/// Ghép một `text_delta` của agy vào văn bản đã chốt. Khi sang bước trả lời khác (chỉ số bước đổi),
/// chèn ngắt đoạn nếu đoạn trước chưa kết thúc bằng khoảng trắng, để các đoạn trước/sau tool không bị dính chữ.
pub(super) fn append_agy_text(
    committed: &mut String,
    current_step: &mut Option<u64>,
    step: Option<u64>,
    delta: &str,
) {
    if let Some(idx) = step {
        if let Some(prev) = *current_step {
            if prev != idx
                && !committed.is_empty()
                && !committed.ends_with(char::is_whitespace)
                && !delta.is_empty()
            {
                committed.push_str("\n\n");
            }
        }
        *current_step = Some(idx);
    }
    committed.push_str(delta);
}

impl TurnState {
    pub(super) fn set_init(&mut self, cid: String) {
        self.tracked_id = cid.clone();
        if let Some(sender) = self.init_tx.take() {
            let _ = sender.send(cid);
        }
    }
}
