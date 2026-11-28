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
    /// Project gốc của máy gửi (khi lượt chạy qua mount); rỗng nếu là project của máy này
    pub(super) origin_project: String,
}

impl TurnCtx {
    pub(super) fn emit(&self, cid: &str, text: String, step: &str, thinking: String) {
        // Số token thinking chỉ có ý nghĩa trong block thinking: giữ giá trị đang có khi còn
        // ở bước thinking, ngoài ra đặt lại về 0
        let mut thinking_tokens = 0;
        if let Ok(mut streams) = self.state.active_streams.lock() {
            if step == "thinking" {
                thinking_tokens = streams.get(cid).map_or(0, |s| s.thinking_tokens);
            }
            streams.insert(
                cid.to_string(),
                ChatTurnStreamState {
                    conversation_id: cid.to_string(),
                    project_path: self.cwd.clone(),
                    user_prompt: self.prompt.clone(),
                    streaming_text: text,
                    is_running: true,
                    active_step_type: step.to_string(),
                    started_at: self.started_at.clone(),
                    error: String::new(),
                    thinking_text: thinking,
                    thinking_tokens,
                },
            );
        }
        self.state.broadcast_stream_throttled(cid);
    }

    /// Cập nhật số token thinking ước lượng của lượt đang chạy (không đổi nội dung khác)
    pub(super) fn set_thinking_tokens(&self, cid: &str, tokens: u64) {
        if let Ok(mut streams) = self.state.active_streams.lock() {
            if let Some(s) = streams.get_mut(cid) {
                s.thinking_tokens = tokens;
            }
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
        // Ghi project của lượt: lượt từ máy khác lấy tên project gốc, không lấy tên thư mục mount.
        // Lượt gửi lại (không còn project gốc) chạy trên mount thì giữ nguyên bản ghi cũ.
        let shown = if self.origin_project.is_empty() {
            if crate::fsmount::is_mount_path(&self.cwd) {
                String::new()
            } else {
                self.cwd.clone()
            }
        } else {
            self.origin_project.clone()
        };
        if let Some(name) = std::path::Path::new(&shown)
            .file_name()
            .and_then(|n| n.to_str())
            .filter(|n| !n.is_empty())
        {
            crate::infra::store::set_conversation_project(cid, name, &self.cwd);
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
    /// Suy nghĩ của agy trong lượt, kèm vị trí trong `committed` lúc suy nghĩ bắt đầu.
    /// Chỉ dùng để hiện trong văn bản đang stream (`with_thoughts`), không lưu vào nội dung cuối.
    pub(super) thoughts: Vec<(usize, String)>,
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

/// Ghi một `thinking_delta` của agy vào danh sách suy nghĩ. Các delta liên tiếp (không có text mới
/// xen vào) được nối vào cùng một khối.
pub(super) fn push_agy_thought(
    thoughts: &mut Vec<(usize, String)>,
    committed_len: usize,
    delta: &str,
) {
    if delta.is_empty() {
        return;
    }
    match thoughts.last_mut() {
        Some((pos, text)) if *pos == committed_len => text.push_str(delta),
        _ => thoughts.push((committed_len, delta.to_string())),
    }
}

/// Văn bản hiển thị khi đang stream: `committed` với các khối suy nghĩ chèn đúng vị trí, dạng trích dẫn.
pub(super) fn with_thoughts(committed: &str, thoughts: &[(usize, String)]) -> String {
    if thoughts.is_empty() {
        return committed.to_string();
    }
    let mut out = String::with_capacity(committed.len() + thoughts.len() * 64);
    let mut last = 0usize;
    for (pos, text) in thoughts {
        let pos = (*pos).min(committed.len());
        out.push_str(&committed[last..pos]);
        last = pos;
        if !out.is_empty() && !out.ends_with("\n\n") {
            out.push_str(if out.ends_with('\n') { "\n" } else { "\n\n" });
        }
        out.push_str("> *💭 Suy nghĩ*\n");
        for line in text.trim().lines() {
            out.push_str("> ");
            out.push_str(line);
            out.push('\n');
        }
        out.push('\n');
    }
    out.push_str(&committed[last..]);
    out
}

impl TurnState {
    pub(super) fn set_init(&mut self, cid: String) {
        self.tracked_id = cid.clone();
        if let Some(sender) = self.init_tx.take() {
            let _ = sender.send(cid);
        }
    }
}

#[cfg(test)]
mod thought_tests {
    use super::*;

    #[test]
    fn consecutive_thought_deltas_merge_into_one_block() {
        let mut thoughts = Vec::new();
        push_agy_thought(&mut thoughts, 0, "Tôi cần ");
        push_agy_thought(&mut thoughts, 0, "cộng hai số.");
        assert_eq!(thoughts, vec![(0, "Tôi cần cộng hai số.".to_string())]);
    }

    #[test]
    fn thought_after_text_starts_a_new_block_at_that_position() {
        let mut thoughts = Vec::new();
        let mut committed = String::from("Đang đọc file.");
        push_agy_thought(&mut thoughts, committed.len(), "Cần xem nội dung.");
        committed.push_str(" Đã xong.");
        push_agy_thought(&mut thoughts, committed.len(), "Kiểm tra lại.");
        assert_eq!(thoughts.len(), 2);
        assert_eq!(thoughts[0].0, "Đang đọc file.".len());
        assert_eq!(thoughts[1].0, committed.len());
    }

    #[test]
    fn with_thoughts_interleaves_quotes_and_keeps_committed_clean() {
        let committed = "Đang đọc file. Đã xong.";
        let thoughts = vec![
            (0, "Cần đọc trước.".to_string()),
            (
                "Đang đọc file.".len(),
                "Kiểm tra lại\nnội dung.".to_string(),
            ),
        ];
        let shown = with_thoughts(committed, &thoughts);
        assert!(shown.starts_with("> *💭 Suy nghĩ*\n> Cần đọc trước.\n\n"));
        assert!(shown.contains(
            "Đang đọc file.\n\n> *💭 Suy nghĩ*\n> Kiểm tra lại\n> nội dung.\n\n Đã xong."
        ));
        // Nội dung cuối (committed) không bị lẫn suy nghĩ
        assert_eq!(committed, "Đang đọc file. Đã xong.");
    }

    #[test]
    fn with_thoughts_without_thoughts_returns_committed() {
        assert_eq!(with_thoughts("Xin chào", &[]), "Xin chào");
    }
}
