use crate::chat::AppState;
use crate::models::*;
use crate::{chat, scanner};
use serde_json::json;
use socketioxide::{
    extract::{AckSender, Data, SocketRef},
    SocketIo,
};

pub fn setup_socket_handlers(io: &SocketIo, state: AppState) {
    let connect_state = state.clone();
    io.ns("/", move |socket: SocketRef| {
        tracing::info!("⚡ Socket.IO Client connected: {}", socket.id);

        // Không gửi snapshot đầy đủ khi kết nối: client tự yêu cầu các event nhỏ
        // (`request-sessions`, `request-meta`, `request-streams`) hoặc `request-snapshot` (client cũ)
        if let Ok(val) = serde_json::to_value(crate::chat::retry::list()) {
            let _ = socket.emit("retry:update", &val);
        }

        // Trạng thái quay màn hình (có URL RTSP khi đang bật) cho client vừa kết nối
        let _ = socket.emit("screen:status", &connect_state.screen.status());

        // Quota hiện tại cho client vừa kết nối: server chỉ phát `quotas:update` khi số liệu thay đổi,
        // nên nếu không gửi ngay, client mới (hoặc app mở lại) sẽ không thấy quota cho tới lần đổi kế tiếp.
        connect_state.spawn_quotas_update(false, true);

        // ── Event nhỏ, thay cho snapshot đầy đủ ──
        let list_state = connect_state.clone();
        socket.on("request-sessions", move |s: SocketRef| {
            let st = list_state.clone();
            async move {
                let streams = st
                    .active_streams
                    .lock()
                    .map(|g| g.clone())
                    .unwrap_or_default();
                let summaries = tokio::task::spawn_blocking(move || {
                    let sessions = scanner::scan_all_sessions(&streams, None, 500);
                    scanner::summarize_sessions(&sessions, &streams)
                })
                .await;
                // Bọc trong object: socket.io tách mảng cấp cao nhất thành nhiều đối số
                if let Ok(list) = summaries {
                    let _ = s.emit("sessions:list", &json!({ "sessions": list }));
                }
            }
        });

        let meta_state = connect_state.clone();
        socket.on("request-meta", move |s: SocketRef| {
            let st = meta_state.clone();
            async move {
                let streams = st
                    .active_streams
                    .lock()
                    .map(|g| g.clone())
                    .unwrap_or_default();
                let meta = tokio::task::spawn_blocking(move || {
                    let sessions = scanner::scan_all_sessions(&streams, None, 500);
                    scanner::build_meta(&sessions)
                })
                .await;
                if let Ok(meta) = meta {
                    if let Ok(val) = serde_json::to_value(&meta) {
                        let _ = s.emit("meta:update", &val);
                    }
                }
            }
        });

        // Màn hình mở sau khi kết nối: client hỏi lại trạng thái quay màn hình
        let screen_req_state = connect_state.clone();
        socket.on("request-screen-status", move |s: SocketRef| {
            let st = screen_req_state.clone();
            async move {
                let _ = s.emit("screen:status", &st.screen.status());
            }
        });

        let streams_state = connect_state.clone();
        socket.on("request-streams", move |s: SocketRef| {
            let st = streams_state.clone();
            async move {
                let streams = st
                    .active_streams
                    .lock()
                    .map(|g| g.clone())
                    .unwrap_or_default();
                let _ = s.emit("streams:update", &json!({ "activeStreams": streams }));
            }
        });

        let send_state = connect_state.clone();
        socket.on(
            "chat:send",
            move |Data::<ChatSendRequest>(req), ack: AckSender| {
                let st = send_state.clone();
                async move {
                    let res = chat::start_chat_turn(st.clone(), req).await;
                    st.broadcast_session_update(&res.conversation_id);
                    st.emit_session_files_to_room(&res.conversation_id);
                    let _ = ack.send(&res);
                }
            },
        );

        // Terminal SSH tương tác: socket join room của phiên trước khi mở PTY để không mất đầu ra
        let term_open_state = connect_state.clone();
        socket.on(
            "ssh:open",
            move |s: SocketRef, Data::<SshTerminalOpenRequest>(req), ack: AckSender| {
                let st = term_open_state.clone();
                async move {
                    let sid = crate::ssh::terminal::new_session_id();
                    let room = crate::ssh::terminal::room_for(&sid);
                    let _ = s.join(room.clone());
                    let result = match crate::infra::store::get_ssh_host(req.host_id) {
                        Some(row) => {
                            crate::ssh::terminal::open(&st, &sid, &row, req.cols, req.rows)
                        }
                        None => Err("Không tìm thấy máy SSH".to_string()),
                    };
                    let res = match result {
                        Ok(()) => SshTerminalOpenResponse {
                            ok: true,
                            session_id: sid,
                            error: String::new(),
                        },
                        Err(e) => {
                            let _ = s.leave(room);
                            SshTerminalOpenResponse {
                                ok: false,
                                session_id: String::new(),
                                error: e,
                            }
                        }
                    };
                    let _ = ack.send(&res);
                }
            },
        );
        // Danh sách phiên đang chạy (để app gắn lại sau khi thoát)
        socket.on("ssh:list", move |ack: AckSender| async move {
            let _ = ack.send(&crate::ssh::terminal::list());
        });
        // Gắn socket vào phiên đang chạy và trả đầu ra đã đệm. Join room trước để không lỡ đầu ra mới.
        socket.on(
            "ssh:attach",
            move |s: SocketRef, Data::<SshTerminalSessionRequest>(req), ack: AckSender| async move {
                let room = crate::ssh::terminal::room_for(&req.session_id);
                let _ = s.join(room.clone());
                let res = match crate::ssh::terminal::attach(&req.session_id) {
                    Ok((host_name, bytes)) => SshTerminalAttachResponse {
                        ok: true,
                        session_id: req.session_id.clone(),
                        host_name,
                        buffer: base64::Engine::encode(
                            &base64::engine::general_purpose::STANDARD,
                            bytes,
                        ),
                        error: String::new(),
                    },
                    Err(e) => {
                        let _ = s.leave(room);
                        SshTerminalAttachResponse {
                            ok: false,
                            session_id: String::new(),
                            host_name: String::new(),
                            buffer: String::new(),
                            error: e,
                        }
                    }
                };
                let _ = ack.send(&res);
            },
        );
        socket.on(
            "ssh:input",
            move |Data::<SshTerminalInputRequest>(req)| async move {
                if let Err(e) = crate::ssh::terminal::write_input(&req.session_id, &req.data) {
                    tracing::warn!("ssh:input lỗi: {e}");
                }
            },
        );
        socket.on(
            "ssh:resize",
            move |Data::<SshTerminalResizeRequest>(req)| async move {
                let _ = crate::ssh::terminal::resize(&req.session_id, req.cols, req.rows);
            },
        );
        socket.on(
            "ssh:close",
            move |Data::<SshTerminalSessionRequest>(req)| async move {
                let _ = crate::ssh::terminal::close(&req.session_id);
            },
        );

        // Xem log container: socket join room của luồng trước khi bắt đầu để không mất dòng đầu tiên
        let logs_open_state = connect_state.clone();
        socket.on(
            "docker:logs:open",
            move |s: SocketRef, Data::<DockerLogsOpenRequest>(req), ack: AckSender| {
                let st = logs_open_state.clone();
                async move {
                    let stream_id = crate::docker::logs::new_stream_id();
                    let room = crate::docker::logs::room_for(&stream_id);
                    let _ = s.join(room.clone());
                    let res = match crate::docker::logs::start(
                        st,
                        stream_id.clone(),
                        &req.session_id,
                        &req.container_id,
                        req.tail,
                    )
                    .await
                    {
                        Ok(()) => DockerLogsOpenResponse {
                            ok: true,
                            stream_id,
                            error: String::new(),
                        },
                        Err(e) => {
                            let _ = s.leave(room);
                            DockerLogsOpenResponse {
                                ok: false,
                                stream_id: String::new(),
                                error: e,
                            }
                        }
                    };
                    let _ = ack.send(&res);
                }
            },
        );
        socket.on(
            "docker:logs:ping",
            move |Data::<DockerLogsStreamRequest>(req)| async move {
                crate::docker::logs::ping(&req.stream_id);
            },
        );
        socket.on(
            "docker:logs:close",
            move |Data::<DockerLogsStreamRequest>(req)| async move {
                crate::docker::logs::stop(&req.stream_id);
            },
        );

        let stop_state = connect_state.clone();
        socket.on(
            "chat:stop",
            move |Data::<ChatStopRequest>(req), ack: AckSender| {
                let st = stop_state.clone();
                async move {
                    let stopped = chat::stop_chat_turn(&st, &req.conversation_id);
                    let _ = ack.send(&json!({ "ok": true, "stopped": stopped }));
                }
            },
        );

        // Join vào room conversation để nhận file changes updates
        socket.on(
            "join-conversation",
            move |s: SocketRef, Data::<serde_json::Value>(data)| async move {
                if let Some(conv_id) = data.get("conversationId").and_then(|x| x.as_str()) {
                    let room = format!("conv:{}", conv_id);
                    let _ = s.join(room.clone());
                    tracing::info!("📍 Socket {} joined room: {}", s.id, room);
                    let _ = s.emit(
                        "joined-conversation",
                        &json!({
                            "ok": true,
                            "conversationId": conv_id,
                        }),
                    );
                }
            },
        );

        // Leave khỏi room conversation
        socket.on(
            "leave-conversation",
            move |s: SocketRef, Data::<serde_json::Value>(data)| async move {
                if let Some(conv_id) = data.get("conversationId").and_then(|x| x.as_str()) {
                    let room = format!("conv:{}", conv_id);
                    let _ = s.leave(room.clone());
                    tracing::info!("📍 Socket {} left room: {}", s.id, room);
                }
            },
        );
    });
}
