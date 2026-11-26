//! Khởi tạo muop-agent-server: kiểm tra và cài tool trên máy đang chạy server, chọn CLI (agy / claude),
//! và đánh dấu đã khởi tạo xong để app vào màn hình chính.
//!
//! Client chỉ gửi lệnh (socket ack `setup:*` hoặc REST `/api/setup/*`). Mọi lệnh shell do server tự chạy.
//! Trạng thái đẩy cho mọi client qua `setup:update`.

pub mod browse;
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
const KEY_WORKSPACE: &str = "workspace_root";

/// Thư mục project (workspace) do người dùng chọn khi khởi tạo. Không có mặc định trong code.
/// Chỉ trả về sau khi khởi tạo xong: trước đó (hoặc chưa cấu hình) không quét project và không đọc/ghi file project.
pub fn workspace_root() -> Option<std::path::PathBuf> {
    if store::get_app_setting(KEY_COMPLETED).as_deref() != Some("1") {
        return None;
    }
    let raw = store::get_app_setting(KEY_WORKSPACE)?;
    let raw = raw.trim();
    if raw.is_empty() {
        None
    } else {
        Some(std::path::PathBuf::from(raw))
    }
}

/// Thư mục project đã lưu (kể cả khi chưa khởi tạo xong), để wizard hiển thị
pub fn configured_workspace() -> String {
    store::get_app_setting(KEY_WORKSPACE).unwrap_or_default()
}

/// Kiểm tra và lưu thư mục project: đường dẫn tuyệt đối, không có `..`, tồn tại và là thư mục.
/// Lưu đường dẫn đã giải symlink. Chỉ lưu; việc quét bắt đầu sau khi khởi tạo xong.
pub fn set_workspace(raw: &str) -> Result<SetupStatus, String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err("Hãy nhập đường dẫn thư mục project".into());
    }
    let path = std::path::Path::new(trimmed);
    if !path.is_absolute() {
        return Err("Đường dẫn thư mục project phải là đường dẫn tuyệt đối".into());
    }
    if path
        .components()
        .any(|c| matches!(c, std::path::Component::ParentDir))
    {
        return Err("Đường dẫn không được chứa '..'".into());
    }
    let canonical = path
        .canonicalize()
        .map_err(|e| format!("Không mở được thư mục: {e}"))?;
    if !canonical.is_dir() {
        return Err("Đường dẫn không phải là thư mục".into());
    }
    if !store::set_app_setting(KEY_WORKSPACE, &canonical.to_string_lossy()) {
        return Err("Không lưu được thư mục project".into());
    }
    publish();
    Ok(status(true, ""))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceRequest {
    pub path: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SetupStatus {
    pub ok: bool,
    pub error: String,
    /// Nền tảng của máy chạy server (`linux` | `macos` | `other`): client chọn nội dung hiển thị theo đây
    pub platform: &'static str,
    pub completed: bool,
    pub selected_clis: Vec<String>,
    pub tools: Vec<install::ToolStatus>,
    /// Danh sách gói apt server quản lý (xem `install::APT_PACKAGES`)
    pub apt_packages: Vec<install::AptPackageStatus>,
    /// Lệnh cài các gói apt còn thiếu (rỗng nếu đủ). Client chạy trong terminal, không tự ghép lệnh.
    pub apt_install_command: String,
    /// Danh sách cask Homebrew server quản lý trên macOS (xem `install::BREW_PACKAGES`); rỗng ở nơi khác
    pub brew_packages: Vec<install::AptPackageStatus>,
    /// Lệnh `brew install --cask ...` cho các cask còn thiếu (rỗng nếu đủ hoặc chưa có Homebrew)
    pub brew_install_command: String,
    pub job: Option<install::JobStatus>,
    /// SSH của máy này: điều kiện bắt buộc của màn cài đặt (`ssh.ready`)
    pub ssh: ssh::SshStatus,
    /// Thư mục project đã lưu (rỗng nếu chưa chọn)
    pub workspace_root: String,
    /// Đã khởi tạo xong và có thư mục project: đang quét project
    pub workspace_ready: bool,
    /// Thư mục home của user đang chạy server (gốc để duyệt file khi chưa chọn project)
    pub home_dir: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ToolPathRequest {
    /// `id` của công cụ trong danh sách Khởi tạo (ví dụ `agy`, `claude`, `python3`)
    pub tool: String,
    /// Đường dẫn tuyệt đối tới tệp thực thi; chuỗi rỗng = bỏ lựa chọn, dò lại bằng `which`
    pub path: String,
}

/// Lưu đường dẫn công cụ người dùng chọn khi `which` không tìm thấy (hoặc muốn dùng bản khác)
pub fn set_tool_path(req: &ToolPathRequest) -> Result<SetupStatus, String> {
    let bin =
        install::tool_bin(req.tool.trim()).ok_or_else(|| "Công cụ không hợp lệ".to_string())?;
    crate::infra::tools::set_override(bin, &req.path)?;
    publish();
    Ok(status(true, ""))
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
    let apt_packages = install::probe_apt();
    let apt_install_command = install::apt_install_command(&apt_packages);
    let brew_packages = install::probe_brew();
    let brew_available = install::find_bin("brew").is_some();
    let brew_install_command = install::brew_install_command(&brew_packages, brew_available);
    let workspace_root = configured_workspace();
    let workspace_ready = completed && !workspace_root.is_empty();
    SetupStatus {
        ok,
        error: error.into(),
        platform: crate::infra::platform::name(),
        completed,
        selected_clis,
        workspace_root,
        workspace_ready,
        home_dir: crate::infra::paths::home_dir().display().to_string(),
        tools: install::probe_all(),
        apt_packages,
        apt_install_command,
        brew_packages,
        brew_install_command,
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
    // Bắt buộc có thư mục project trước khi khởi tạo xong: từ đây mới bắt đầu quét project
    if configured_workspace().is_empty() {
        return Err("Hãy chọn thư mục project trước khi hoàn tất khởi tạo".into());
    }
    // Gói Homebrew bắt buộc (FUSE-T trên macOS) phải cài qua wizard trước khi hoàn tất
    if install::probe_brew()
        .iter()
        .any(|p| p.required && !p.installed)
    {
        return Err("Cần cài FUSE-T (mục Gói Homebrew) trước khi hoàn tất khởi tạo".into());
    }
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
        "setup:workspace",
        move |Data::<WorkspaceRequest>(req), ack: AckSender| async move {
            let res = match set_workspace(&req.path) {
                Ok(s) => s,
                Err(e) => to_ack_error(e),
            };
            let _ = ack.send(&res);
        },
    );

    // Duyệt thư mục trên máy server để chọn project (cây thư mục, chỉ thư mục)
    socket.on(
        "setup:browse",
        move |Data::<browse::BrowseRequest>(req), ack: AckSender| async move {
            match tokio::task::spawn_blocking(move || browse::list_dirs(&req.path)).await {
                Ok(listing) => {
                    let _ = ack.send(&listing);
                }
                Err(e) => {
                    let _ = ack.send(&serde_json::json!({
                        "ok": false,
                        "error": format!("Lỗi nội bộ khi đọc thư mục: {e}"),
                        "path": "",
                        "parent": "",
                        "home": "",
                        "dirs": [],
                    }));
                }
            }
        },
    );

    socket.on(
        "setup:tool-path",
        move |Data::<ToolPathRequest>(req), ack: AckSender| async move {
            let res = match set_tool_path(&req) {
                Ok(s) => s,
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
