use crate::screen::ScreenManager;
use ksni::menu::*;
use ksni::{Icon, MenuItem, ToolTip, Tray, TrayMethods};
use std::sync::{Arc, LazyLock, OnceLock};

/// Handle của tray đang chạy, để làm mới menu sau khi trạng thái quay màn hình đổi
static TRAY_HANDLE: OnceLock<ksni::Handle<MuopAgentTray>> = OnceLock::new();

pub struct MuopAgentTray {
    pub screen: Arc<ScreenManager>,
}

impl Tray for MuopAgentTray {
    fn id(&self) -> String {
        "muop-agent-server".to_string()
    }

    fn title(&self) -> String {
        "Mướp Agent Server".to_string()
    }

    fn icon_name(&self) -> String {
        "muop-agent-server".to_string()
    }

    /// Không đặt theme riêng: icon `muop-agent-server` được cài vào hicolor của hệ thống (xem `packaging/build-deb.sh`)
    fn icon_theme_path(&self) -> String {
        String::new()
    }

    fn tool_tip(&self) -> ToolTip {
        ToolTip {
            title: "Mướp Agent Server Engine".to_string(),
            description: format!(
                "📡 Cổng: 0.0.0.0:{} • Socket.IO Realtime Active",
                crate::scanner::listen_port()
            ),
            icon_name: "muop-agent-server".to_string(),
            icon_pixmap: Vec::new(),
        }
    }

    fn icon_pixmap(&self) -> Vec<Icon> {
        static ICONS: LazyLock<Vec<Icon>> = LazyLock::new(|| {
            let mut result = Vec::new();
            let raw_images: [&[u8]; 3] = [
                include_bytes!("../../assets/tray_icon_24.png"),
                include_bytes!("../../assets/tray_icon_32.png"),
                include_bytes!("../../assets/tray_icon.png"),
            ];
            for raw in raw_images {
                if let Ok(img) = image::load_from_memory_with_format(raw, image::ImageFormat::Png) {
                    let (width, height) = (img.width(), img.height());
                    let mut data = img.into_rgba8().into_vec();
                    if data.len() % 4 == 0 {
                        for pixel in data.chunks_exact_mut(4) {
                            pixel.rotate_right(1); // RGBA sang ARGB (chuẩn StatusNotifierItem)
                        }
                        result.push(Icon {
                            width: width as i32,
                            height: height as i32,
                            data,
                        });
                    }
                }
            }
            result
        });

        ICONS.clone()
    }

    fn activate(&mut self, _x: i32, _y: i32) {
        launch_linux_app();
    }

    fn menu(&self) -> Vec<MenuItem<Self>> {
        vec![
            StandardItem {
                label: format!(
                    "🦀 Mướp Agent Server (0.0.0.0:{})",
                    crate::scanner::listen_port()
                ),
                enabled: false,
                ..Default::default()
            }
            .into(),
            MenuItem::Separator,
            StandardItem {
                label: "🚀 Mở Ứng dụng Desktop (Linux)".to_string(),
                icon_name: "application-default".to_string(),
                activate: Box::new(|_| {
                    launch_linux_app();
                }),
                ..Default::default()
            }
            .into(),
            StandardItem {
                label: "🌐 Xem trạng thái server (/api/meta)".to_string(),
                icon_name: "web-browser".to_string(),
                activate: Box::new(|_| {
                    let _ = std::process::Command::new("xdg-open")
                        .arg(format!(
                            "http://localhost:{}/api/meta",
                            crate::scanner::listen_port()
                        ))
                        .spawn();
                }),
                ..Default::default()
            }
            .into(),
            CheckmarkItem {
                label: screen_label(&self.screen.status()),
                checked: self.screen.is_active(),
                enabled: true,
                activate: Box::new(|this: &mut Self| this.screen.toggle()),
                ..Default::default()
            }
            .into(),
            MenuItem::Separator,
            StandardItem {
                label: "🔄 Khởi động lại Server".to_string(),
                icon_name: "view-refresh".to_string(),
                activate: Box::new(|_| {
                    tokio::spawn(async {
                        let _ = tokio::process::Command::new("systemctl")
                            .args(["--user", "restart", "muop-agent-server"])
                            .spawn();
                    });
                }),
                ..Default::default()
            }
            .into(),
            StandardItem {
                label: "🛑 Thoát Server".to_string(),
                icon_name: "application-exit".to_string(),
                activate: Box::new(|_| {
                    eprintln!("🛑 Nhận lệnh Thoát từ System Tray Menu. Đang tắt server...");
                    // Thoát sạch (mã 0). Unit systemd dùng Restart=on-failure nên không bật lại.
                    std::process::exit(0);
                }),
                ..Default::default()
            }
            .into(),
        ]
    }
}

/// Nhãn checkbox quay màn hình: hiện trạng thái đang chờ xác nhận hoặc lỗi gần nhất
fn screen_label(status: &crate::screen::ScreenStatus) -> String {
    if status.starting {
        "📺 Quay màn hình — đang chờ xác nhận…".to_string()
    } else if status.streaming && !status.rtsp_url.is_empty() {
        // Đang phát: hiện địa chỉ để mở bằng VLC/mpv/ffplay
        format!("📺 Đang phát: {}", status.rtsp_url)
    } else if !status.error.is_empty() {
        format!("📺 Stream màn hình (lỗi: {})", status.error)
    } else {
        "📺 Stream màn hình (RTSP 720p)".to_string()
    }
}

/// Làm mới menu tray (checkbox) sau khi trạng thái đổi. Gọi từ trong runtime Tokio.
pub fn refresh() {
    if let Some(handle) = TRAY_HANDLE.get() {
        let handle = handle.clone();
        tokio::spawn(async move {
            handle.update(|_| {}).await;
        });
    }
}

/// Mở ứng dụng Linux Desktop: `muop-agent` trong PATH (bản .deb) hoặc bản build dev; không tìm thấy thì
/// ghi log hướng dẫn chọn đường dẫn trong Khởi tạo. Không mở thư mục thay thế.
fn launch_linux_app() {
    let Some(app_path) = crate::infra::tools::app_launcher() else {
        tracing::error!("{}", crate::infra::tools::missing_message("muop-agent"));
        return;
    };
    // systemd-run --user: app chạy trong user manager nên nhận DISPLAY/WAYLAND_DISPLAY của phiên đồ họa.
    // Không có systemd-run thì mở trực tiếp.
    let app = app_path.to_string_lossy().into_owned();
    let via_systemd = crate::infra::tools::resolve("systemd-run").and_then(|sr| {
        std::process::Command::new(sr)
            .args(["--user", &app])
            .spawn()
            .ok()
    });
    if via_systemd.is_none() {
        if let Err(e) = std::process::Command::new(&app_path).spawn() {
            tracing::error!("Không mở được ứng dụng {}: {}", app, e);
        }
    }
}

const TRAY_MAX_ATTEMPTS: u32 = 60;
const TRAY_RETRY_INTERVAL: tokio::time::Duration = tokio::time::Duration::from_secs(5);

/// Chờ D-Bus / StatusNotifierWatcher xuất hiện: thử lại mãi, khoảng cách tăng dần đến tối đa 30 giây.
/// Server khởi động lúc boot thường đi trước phiên đồ họa (GNOME/AppIndicator), nên không được bỏ cuộc.
const TRAY_RETRY_MIN: tokio::time::Duration = tokio::time::Duration::from_secs(5);
const TRAY_RETRY_MAX: tokio::time::Duration = tokio::time::Duration::from_secs(30);

/// Tên D-Bus mà shell đồ họa giữ trên session bus khi giao diện đã hiện: GNOME `org.gnome.Shell`, KDE `org.kde.plasmashell`.
/// Màn đăng nhập (GDM) dùng bus riêng nên không làm tên này xuất hiện trên bus của người dùng.
const DESKTOP_SHELL_NAMES: [&str; 2] = ["org.gnome.Shell", "org.kde.plasmashell"];
const GUI_PROBE_INTERVAL: tokio::time::Duration = tokio::time::Duration::from_secs(2);
/// Chờ thêm sau khi shell xuất hiện để panel và khay StatusNotifier kịp dựng xong
const GUI_SETTLE_DELAY: tokio::time::Duration = tokio::time::Duration::from_secs(3);

/// Chờ đến khi giao diện đồ họa của phiên người dùng đã hiện, rồi chờ thêm một chút.
/// Không đăng ký tray trước lúc này: lúc boot, server có thể chạy trước khi màn hình sẵn sàng và icon không hiện.
async fn wait_for_gui() {
    let conn = loop {
        match zbus::Connection::session().await {
            Ok(conn) => break conn,
            Err(_) => tokio::time::sleep(GUI_PROBE_INTERVAL).await,
        }
    };
    let mut announced = false;
    while !gui_shell_present(&conn).await {
        if !announced {
            tracing::info!("⏳ Chờ giao diện đồ họa hiện lên trước khi đăng ký System Tray...");
            announced = true;
        }
        tokio::time::sleep(GUI_PROBE_INTERVAL).await;
    }
    tracing::info!("🖥️ Giao diện đã hiện, đợi thêm rồi đăng ký System Tray");
    tokio::time::sleep(GUI_SETTLE_DELAY).await;
}

/// Có shell đồ họa nào đang giữ tên D-Bus trên session bus không
async fn gui_shell_present(conn: &zbus::Connection) -> bool {
    let Ok(dbus) = zbus::fdo::DBusProxy::new(conn).await else {
        return false;
    };
    for name in DESKTOP_SHELL_NAMES {
        let Ok(bus_name) = zbus::names::BusName::try_from(name) else {
            continue;
        };
        if dbus.name_has_owner(bus_name).await.unwrap_or(false) {
            return true;
        }
    }
    false
}

pub fn spawn_system_tray(screen: Arc<ScreenManager>) {
    tokio::spawn(async move {
        tokio::time::sleep(tokio::time::Duration::from_millis(500)).await;
        wait_for_gui().await;
        let mut delay = TRAY_RETRY_MIN;
        let mut announced = false;
        loop {
            // assume_sni_available: nếu watcher chưa có, ksni vẫn giữ service và tự đăng ký lại
            // khi org.kde.StatusNotifierWatcher xuất hiện (khi đăng nhập), thay vì trả lỗi.
            let tray = MuopAgentTray {
                screen: screen.clone(),
            };
            match tray.assume_sni_available(true).spawn().await {
                Ok(handle) => {
                    tracing::info!("✅ System Tray Icon đã khởi chạy trên khay hệ thống Linux");
                    let _ = TRAY_HANDLE.set(handle.clone());
                    // Tray đã đăng ký: tự bật stream nếu lần trước đã bật và đã được cấp quyền
                    let autostart_screen = screen.clone();
                    tokio::spawn(async move { autostart_screen.autostart().await });
                    // Handle phải sống suốt vòng đời server, nếu không ksni dừng service
                    let _keep_alive = handle;
                    std::future::pending::<()>().await;
                    return;
                }
                Err(e) => {
                    if !announced {
                        tracing::warn!(
                            "⚠️ Chưa kết nối được khay hệ thống, sẽ thử lại liên tục: {}",
                            e
                        );
                        announced = true;
                    }
                    tokio::time::sleep(delay).await;
                    delay = (delay * 2).min(TRAY_RETRY_MAX);
                }
            }
        }
    });
}
