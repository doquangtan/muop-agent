use ksni::menu::*;
use ksni::{Icon, MenuItem, ToolTip, Tray, TrayMethods};
use std::sync::LazyLock;

pub struct MuopAgentTray;

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

    fn icon_theme_path(&self) -> String {
        let home = std::env::var("HOME").unwrap_or_else(|_| "/home/john".to_string());
        format!("{}/.local/share/icons/muop-agent", home)
    }

    fn tool_tip(&self) -> ToolTip {
        ToolTip {
            title: "Mướp Agent Server Engine".to_string(),
            description: "📡 Cổng: 0.0.0.0:8787 • Socket.IO Realtime Active".to_string(),
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
                label: "🦀 Mướp Agent Server (0.0.0.0:8787)".to_string(),
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
                        .arg("http://localhost:8787/api/meta")
                        .spawn();
                }),
                ..Default::default()
            }
            .into(),
            StandardItem {
                label: "📂 Mở Thư mục muop-agent".to_string(),
                icon_name: "folder".to_string(),
                activate: Box::new(|_| {
                    let _ = std::process::Command::new("xdg-open")
                        .arg("/home/john/Documents/muop-ecosystem/muop-agent")
                        .spawn();
                }),
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
                    std::process::exit(0);
                }),
                ..Default::default()
            }
            .into(),
        ]
    }
}

fn launch_linux_app() {
    let app_path =
        "/home/john/Documents/muop-ecosystem/muop-agent/build/linux/x64/release/bundle/muop_agent";
    if std::path::Path::new(app_path).exists() {
        let _ = std::process::Command::new("systemd-run")
            .args(["--user", app_path])
            .spawn();
    } else {
        let _ = std::process::Command::new("xdg-open")
            .arg("/home/john/Documents/muop-ecosystem/muop-agent")
            .spawn();
    }
}

const TRAY_MAX_ATTEMPTS: u32 = 60;
const TRAY_RETRY_INTERVAL: tokio::time::Duration = tokio::time::Duration::from_secs(5);

/// Chờ D-Bus / StatusNotifierWatcher xuất hiện: thử lại mãi, khoảng cách tăng dần đến tối đa 30 giây.
/// Server khởi động lúc boot thường đi trước phiên đồ họa (GNOME/AppIndicator), nên không được bỏ cuộc.
const TRAY_RETRY_MIN: tokio::time::Duration = tokio::time::Duration::from_secs(5);
const TRAY_RETRY_MAX: tokio::time::Duration = tokio::time::Duration::from_secs(30);

pub fn spawn_system_tray() {
    tokio::spawn(async move {
        tokio::time::sleep(tokio::time::Duration::from_millis(500)).await;
        let mut delay = TRAY_RETRY_MIN;
        let mut announced = false;
        loop {
            // assume_sni_available: nếu watcher chưa có, ksni vẫn giữ service và tự đăng ký lại
            // khi org.kde.StatusNotifierWatcher xuất hiện (khi đăng nhập), thay vì trả lỗi.
            match MuopAgentTray.assume_sni_available(true).spawn().await {
                Ok(handle) => {
                    tracing::info!("✅ System Tray Icon đã khởi chạy trên khay hệ thống Linux");
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
