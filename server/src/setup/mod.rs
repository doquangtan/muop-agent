//! Khởi tạo muop-agent-server: kiểm tra và cài tool trên máy đang chạy server, chọn CLI (agy / claude),
//! và đánh dấu đã khởi tạo xong để app vào màn hình chính.
//!
//! Client chỉ gửi lệnh (socket ack `setup:*` hoặc REST `/api/setup/*`). Mọi lệnh shell do server tự chạy.
//! Trạng thái đẩy cho mọi client qua `setup:update`.

pub mod install;
pub mod ssh;

use crate::infra::store;
use serde::{Deserialize, Serialize};
use socketioxide::{
    extract::{AckSender, Data, SocketRef},
    SocketIo,
};
use std::sync::OnceLock;

static IO: OnceLock<SocketIo> = OnceLock::new();

const KEY_COMPLETED: &str = "setup_completed";
const KEY_CLIS: &str = "setup_selected_clis";

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SetupStatus {
    pub ok: bool,
    pub error: String,
    pub completed: bool,
    pub selected_clis: Vec<String>,
    pub tools: Vec<install::ToolStatus>,
    pub job: Option<install::JobStatus>,
    /// SSH của máy này: điều kiện bắt buộc của màn cài đặt (`ssh.ready`)
    pub ssh: ssh::SshStatus,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InstallRequest {
    pub tool: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SelectRequest {
    pub clis: Vec<String>,
}

/// Socket.IO của server (để mở phiên terminal phát dữ liệu). None nếu chưa khởi tạo.
pub fn io() -> Option<SocketIo> {
    IO.get().cloned()
}

pub fn init(io: SocketIo) {
    let _ = IO.set(io);
    // Đọc PATH của shell user ngay khi khởi động để lần kiểm tra đầu tiên không phải chờ
    std::thread::spawn(|| {
        install::user_shell_path_dirs();
    });
}

/// Trạng thái hiện tại (probe tool tại chỗ, nhanh vì chỉ kiểm tra file)
pub fn status(ok: bool, error: impl Into<String>) -> SetupStatus {
    let completed = store::get_app_setting(KEY_COMPLETED).as_deref() == Some("1");
    let selected_clis = store::get_app_setting(KEY_CLIS)
        .unwrap_or_default()
        .split(',')
        .filter(|s| install::CLI_IDS.contains(s))
        .map(str::to_string)
        .collect();
    SetupStatus {
        ok,
        error: error.into(),
        completed,
        selected_clis,
        tools: install::probe_all(),
        job: install::current(),
        ssh: ssh::status(),
    }
}

/// Phát trạng thái cho mọi client đang kết nối
pub fn publish() {
    if let Some(io) = IO.get() {
        if let Some(ns) = io.of("/") {
            let _ = ns.emit("setup:update", &status(true, ""));
        }
    }
}

/// Lưu danh sách CLI người dùng chọn. Chỉ nhận `agy` và `claude`.
pub fn select_clis(clis: &[String]) -> Result<SetupStatus, String> {
    let mut picked: Vec<&str> = Vec::new();
    for c in clis {
        let id = c.trim();
        if !install::CLI_IDS.contains(&id) {
            return Err(format!("CLI không hợp lệ: {id}"));
        }
        if !picked.contains(&id) {
            picked.push(id);
        }
    }
    if picked.is_empty() {
        return Err("Hãy chọn ít nhất một CLI".into());
    }
    if !store::set_app_setting(KEY_CLIS, &picked.join(",")) {
        return Err("Không lưu được lựa chọn CLI".into());
    }
    publish();
    Ok(status(true, ""))
}

pub fn complete() -> Result<SetupStatus, String> {
    if !store::set_app_setting(KEY_COMPLETED, "1") {
        return Err("Không lưu được trạng thái khởi tạo".into());
    }
    publish();
    Ok(status(true, ""))
}

fn to_ack_error(err: String) -> SetupStatus {
    status(false, err)
}

/// Đăng ký lệnh socket cho một client vừa kết nối
pub fn register(socket: &SocketRef) {
    let _ = socket.emit("setup:update", &status(true, ""));

    socket.on("setup:status", move |ack: AckSender| async move {
        let res = tokio::task::spawn_blocking(|| status(true, ""))
            .await
            .unwrap_or_else(|e| status(false, e.to_string()));
        let _ = ack.send(&res);
    });

    socket.on(
        "setup:install",
        move |Data::<InstallRequest>(req), ack: AckSender| async move {
            let res = match install::start(req.tool.trim()) {
                Ok(()) => status(true, ""),
                Err(e) => to_ack_error(e),
            };
            let _ = ack.send(&res);
        },
    );

    socket.on(
        "setup:select",
        move |Data::<SelectRequest>(req), ack: AckSender| async move {
            let res = match select_clis(&req.clis) {
                Ok(s) => s,
                Err(e) => to_ack_error(e),
            };
            let _ = ack.send(&res);
        },
    );

    // SSH của máy này: user, tự thiết lập khóa, và xác nhận khóa người dùng đã publish
    socket.on(
        "setup:ssh:configure",
        move |Data::<ssh::SshConfigureRequest>(req), ack: AckSender| async move {
            let res = match ssh::configure(&req.username) {
                Ok(()) => status(true, ""),
                Err(e) => status(false, e),
            };
            let _ = ack.send(&res);
        },
    );

    socket.on("setup:ssh:auto", move |ack: AckSender| async move {
        let res = match tokio::task::spawn_blocking(ssh::auto_setup).await {
            Ok(Ok(())) => status(true, ""),
            Ok(Err(e)) => status(false, e),
            Err(e) => status(false, e.to_string()),
        };
        let _ = ack.send(&res);
    });

    socket.on(
        "setup:ssh:verify",
        move |Data::<ssh::SshVerifyRequest>(req), ack: AckSender| async move {
            let res = match tokio::task::spawn_blocking(move || ssh::verify_pasted(&req.public_key))
                .await
            {
                Ok(Ok(())) => status(true, ""),
                Ok(Err(e)) => status(false, e),
                Err(e) => status(false, e.to_string()),
            };
            let _ = ack.send(&res);
        },
    );

    socket.on("setup:complete", move |ack: AckSender| async move {
        let res = match complete() {
            Ok(s) => s,
            Err(e) => to_ack_error(e),
        };
        let _ = ack.send(&res);
    });
}
