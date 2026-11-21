//! Lệnh và trạng thái đăng nhập Claude CLI qua Socket.IO.
//!
//! - Client hỏi bằng ack: `claude:auth:status`, `claude:auth:start`, `claude:auth:submit` `{code}`,
//!   `claude:auth:cancel`, `claude:auth:logout`. Mỗi ack trả trạng thái hiện tại (`ClaudeAuthEvent`).
//! - Server đẩy `claude:auth:update` mỗi khi trạng thái đổi, và đẩy trạng thái hiện tại khi client kết nối.

use crate::claude_auth;
use crate::models::{ClaudeAuthEvent, ClaudeLoginSubmitRequest};
use socketioxide::extract::{AckSender, Data, SocketRef};

/// Gắn các handler claude vào socket vừa kết nối và đẩy trạng thái hiện tại cho client
pub fn register(socket: &SocketRef) {
    let _ = socket.emit("claude:auth:update", &claude_auth::current());

    socket.on("claude:auth:status", move |ack: AckSender| async move {
        let ev = match tokio::task::spawn_blocking(claude_auth::query).await {
            Ok(ev) => ev,
            Err(_) => claude_auth::current(),
        };
        let _ = ack.send(&ev);
    });

    socket.on("claude:auth:start", move |ack: AckSender| async move {
        let ev = run(|| {
            let _ = claude_auth::begin_login();
        })
        .await;
        let _ = ack.send(&ev);
    });

    socket.on(
        "claude:auth:submit",
        move |Data::<ClaudeLoginSubmitRequest>(req), ack: AckSender| async move {
            let ev = run(move || {
                let _ = claude_auth::submit_code(&req.code);
            })
            .await;
            let _ = ack.send(&ev);
        },
    );

    socket.on("claude:auth:cancel", move |ack: AckSender| async move {
        let ev = run(claude_auth::login_cancel).await;
        let _ = ack.send(&ev);
    });

    socket.on("claude:auth:logout", move |ack: AckSender| async move {
        let ev = run(|| {
            let _ = claude_auth::logout();
        })
        .await;
        let _ = ack.send(&ev);
    });
}

/// Chạy việc chặn luồng ngoài event loop, rồi trả trạng thái hiện tại
async fn run<F: FnOnce() + Send + 'static>(job: F) -> ClaudeAuthEvent {
    let _ = tokio::task::spawn_blocking(job).await;
    claude_auth::current()
}
