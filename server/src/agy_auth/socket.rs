//! Lệnh và trạng thái đăng nhập agy qua Socket.IO.
//!
//! - Client hỏi bằng ack: `agy:auth:status`, `agy:auth:check`, `agy:auth:start`, `agy:auth:submit` `{code}`,
//!   `agy:auth:cancel`, `agy:auth:logout`. `agy:auth:check` kiểm tra agy đã đăng nhập chưa (xem `agy_auth::check`).
//!   Mỗi ack trả trạng thái hiện tại (`AgyAuthEvent`).
//! - Server đẩy `agy:auth:update` mỗi khi trạng thái đổi, và đẩy trạng thái hiện tại khi client kết nối.

use crate::agy_auth;
use crate::models::{AgyAuthEvent, AgyLoginSubmitRequest};
use socketioxide::extract::{AckSender, Data, SocketRef};

/// Gắn các handler agy vào socket vừa kết nối và đẩy trạng thái hiện tại cho client
pub fn register(socket: &SocketRef) {
    let _ = socket.emit("agy:auth:update", &agy_auth::current());

    socket.on("agy:auth:status", move |ack: AckSender| async move {
        let ev = match tokio::task::spawn_blocking(agy_auth::query).await {
            Ok(ev) => ev,
            Err(_) => agy_auth::current(),
        };
        let _ = ack.send(&ev);
    });

    // Kiểm tra agy đã đăng nhập chưa (đọc màn hình terminal đăng nhập nếu đang mở)
    socket.on("agy:auth:check", move |ack: AckSender| async move {
        let ev = match tokio::task::spawn_blocking(agy_auth::check).await {
            Ok(ev) => ev,
            Err(_) => agy_auth::current(),
        };
        let _ = ack.send(&ev);
    });

    socket.on("agy:auth:start", move |ack: AckSender| async move {
        let ev = run(|| {
            let _ = agy_auth::begin_login();
        })
        .await;
        let _ = ack.send(&ev);
    });

    socket.on(
        "agy:auth:submit",
        move |Data::<AgyLoginSubmitRequest>(req), ack: AckSender| async move {
            let ev =
                match tokio::task::spawn_blocking(move || agy_auth::submit_code(&req.code)).await {
                    Ok(ev) => ev,
                    Err(_) => agy_auth::current(),
                };
            let _ = ack.send(&ev);
        },
    );

    socket.on("agy:auth:cancel", move |ack: AckSender| async move {
        let ev = run(agy_auth::cancel_login).await;
        let _ = ack.send(&ev);
    });

    // Trạng thái tài khoản agy + Claude Code CLI (màn hình Tài khoản)
    socket.on("accounts:status", move |ack: AckSender| async move {
        let res = match tokio::task::spawn_blocking(agy_auth::accounts_status).await {
            Ok(res) => res,
            Err(_) => return,
        };
        let _ = ack.send(&res);
    });

    socket.on("agy:auth:logout", move |ack: AckSender| async move {
        let ev = run(|| {
            let _ = agy_auth::logout();
        })
        .await;
        let _ = ack.send(&ev);
    });
}

/// Chạy việc chặn luồng ngoài event loop, rồi trả trạng thái hiện tại
async fn run<F: FnOnce() + Send + 'static>(job: F) -> AgyAuthEvent {
    let _ = tokio::task::spawn_blocking(job).await;
    agy_auth::current()
}
