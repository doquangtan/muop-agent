use super::*;

/// Xử lý một dòng stream-json của Antigravity CLI (`agy`)
pub(super) fn handle_agy_event(ctx: &TurnCtx, st: &mut TurnState, map: &Value) {
    match map.get("event").and_then(|v| v.as_str()).unwrap_or("") {
        "init" => {
            let cid = map
                .get("conversation_id")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .trim()
                .to_string();
            if !cid.is_empty() {
                ctx.register(&cid);
                crate::scanner::record_agy_turn_model(&cid, &ctx.started_at, &ctx.model);
                st.set_init(cid.clone());
                ctx.emit(&cid, st.committed.clone(), "init", String::new());
            }
        }
        "step_update" => {
            let Some(su) = map.get("step_update") else {
                return;
            };
            let cid = su
                .get("conversation_id")
                .and_then(|v| v.as_str())
                .unwrap_or(&st.tracked_id)
                .trim()
                .to_string();
            if !cid.is_empty() && cid != st.tracked_id {
                st.set_init(cid);
            }
            let step_type = su
                .get("step_type")
                .and_then(|v| v.as_str())
                .unwrap_or("agent_response")
                .to_string();
            // Suy nghĩ của agy (proto `thinking_delta`): chèn vào văn bản đang stream theo đúng vị trí
            if let Some(delta) = su.get("thinking_delta").and_then(|v| v.as_str()) {
                push_agy_thought(&mut st.thoughts, st.committed.len(), delta);
            }
            if let Some(delta) = su.get("text_delta").and_then(|v| v.as_str()) {
                let step = su.get("step_index").and_then(|v| v.as_u64());
                append_agy_text(&mut st.committed, &mut st.text_step, step, delta);
            }
            if !st.tracked_id.is_empty() {
                let tid = st.tracked_id.clone();
                let shown = with_thoughts(&st.committed, &st.thoughts);
                ctx.emit(&tid, shown, &step_type, String::new());
            }
        }
        "result" => {
            if let Some(res) = map.get("result") {
                let resp_text = res
                    .get("response")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .trim();
                if !resp_text.is_empty() && st.committed.is_empty() {
                    st.committed.push_str(resp_text);
                }
            }
        }
        _ => {}
    }
}

/// Xử lý một dòng stream-json của Claude Code CLI (`claude -p --output-format stream-json`)
pub(super) fn handle_claude_event(ctx: &TurnCtx, st: &mut TurnState, map: &Value) {
    let kind = map.get("type").and_then(|v| v.as_str()).unwrap_or("");
    match kind {
        // Limit tài khoản (phiên 5 giờ, tuần) mà CLI báo sau mỗi lượt: cập nhật quota ngay
        "rate_limit_event" => {
            crate::claude::code::ingest_rate_limit_event(map);
        }
        // Đầu tiên: session_id của Claude Code
        "system" => {
            let subtype = map.get("subtype").and_then(|v| v.as_str());
            // Tiến độ suy nghĩ khi nội dung thinking không được gửi về (Claude 5.x)
            if subtype == Some("thinking_tokens") {
                if !st.tracked_id.is_empty() {
                    let tokens = map
                        .get("estimated_tokens")
                        .and_then(|v| v.as_u64())
                        .unwrap_or(0);
                    let tid = st.tracked_id.clone();
                    ctx.set_thinking_tokens(&tid, tokens);
                }
                return;
            }
            if subtype != Some("init") {
                return;
            }
            let cid = map
                .get("session_id")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .trim()
                .to_string();
            if cid.is_empty() {
                return;
            }
            ctx.register(&cid);
            crate::infra::store::mark_claude_muop_conversation(&cid);
            st.set_init(cid.clone());
            ctx.emit(
                &cid,
                compose_text(&st.committed, &st.live),
                "init",
                st.thinking_text.clone(),
            );
        }
        // Token-level streaming (cần --include-partial-messages)
        "stream_event" => {
            let Some(ev) = map.get("event") else {
                return;
            };
            match ev.get("type").and_then(|v| v.as_str()).unwrap_or("") {
                "message_start" => {
                    st.live.clear();
                    st.thinking_text.clear();
                    st.current_block_type.clear();
                }
                "content_block_start" => {
                    let block_type = ev
                        .get("content_block")
                        .and_then(|b| b.get("type"))
                        .and_then(|v| v.as_str())
                        .unwrap_or("")
                        .to_string();
                    st.current_block_type = block_type.clone();
                    let step = match block_type.as_str() {
                        "tool_use" => "tool_use",
                        "thinking" => "thinking",
                        _ => "agent_response",
                    };
                    if !st.tracked_id.is_empty() {
                        let tid = st.tracked_id.clone();
                        // Block thinking mới bắt đầu từ 0 token
                        if step == "thinking" {
                            ctx.set_thinking_tokens(&tid, 0);
                        }
                        ctx.emit(
                            &tid,
                            compose_text(&st.committed, &st.live),
                            step,
                            st.thinking_text.clone(),
                        );
                    }
                }
                "content_block_delta" => {
                    let Some(delta) = ev.get("delta") else {
                        return;
                    };
                    if delta.get("type").and_then(|v| v.as_str()) == Some("text_delta") {
                        if let Some(t) = delta.get("text").and_then(|v| v.as_str()) {
                            if st.current_block_type == "thinking" {
                                st.thinking_text.push_str(t);
                            } else {
                                st.live.push_str(t);
                            }
                        }
                        if !st.tracked_id.is_empty() {
                            let tid = st.tracked_id.clone();
                            let step = if st.current_block_type == "thinking" {
                                "thinking"
                            } else {
                                "agent_response"
                            };
                            ctx.emit(
                                &tid,
                                compose_text(&st.committed, &st.live),
                                step,
                                st.thinking_text.clone(),
                            );
                        }
                    }
                }
                _ => {}
            }
        }
        // Message hoàn chỉnh của assistant: chốt text và ghi nhận tool_use
        "assistant" => {
            let blocks = map
                .get("message")
                .and_then(|m| m.get("content"))
                .and_then(|c| c.as_array())
                .cloned()
                .unwrap_or_default();
            let mut step = "agent_response";
            for b in &blocks {
                match b.get("type").and_then(|v| v.as_str()).unwrap_or("") {
                    "text" => {
                        if let Some(t) = b.get("text").and_then(|v| v.as_str()) {
                            if !t.trim().is_empty() {
                                if !st.committed.is_empty() {
                                    st.committed.push_str("\n\n");
                                }
                                st.committed.push_str(t.trim_end());
                            }
                        }
                    }
                    "thinking" => {
                        if let Some(t) = b.get("thinking").and_then(|v| v.as_str()) {
                            if !st.thinking_text.is_empty() {
                                st.thinking_text.push_str("\n\n");
                            }
                            st.thinking_text.push_str(t.trim_end());
                        }
                    }
                    "tool_use" => step = "tool_use",
                    _ => {}
                }
            }
            st.live.clear();
            if !st.tracked_id.is_empty() {
                let tid = st.tracked_id.clone();
                ctx.emit(
                    &tid,
                    compose_text(&st.committed, &st.live),
                    step,
                    st.thinking_text.clone(),
                );
            }
        }
        // Kết quả tool trả về cho Claude
        "user" => {
            if !st.tracked_id.is_empty() {
                let tid = st.tracked_id.clone();
                ctx.emit(
                    &tid,
                    compose_text(&st.committed, &st.live),
                    "tool_result",
                    st.thinking_text.clone(),
                );
            }
        }
        "result" => {
            let is_error = map
                .get("is_error")
                .and_then(|v| v.as_bool())
                .unwrap_or(false);
            let text = map
                .get("result")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .trim()
                .to_string();
            if is_error {
                st.result_error = Some(if text.is_empty() {
                    "Claude Code CLI báo lỗi".to_string()
                } else {
                    text
                });
            } else if st.committed.is_empty() && !text.is_empty() {
                st.committed = text;
            }
            st.live.clear();
        }
        _ => {}
    }
}
