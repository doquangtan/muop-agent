// Chụp ảnh giao diện mà không cần màn hình: dùng renderer phần mềm của Slint.
// Dữ liệu là snapshot thật từ muop-agent-server, đi qua đúng các hàm render của app.
//
// Dùng:
//   MUOP_SCREENSHOT=/đường/dẫn/ảnh.png cargo run
//   tùy chọn: MUOP_SCREENSHOT_WIDTH (1280), MUOP_SCREENSHOT_HEIGHT (820),
//             MUOP_SCREENSHOT_LIGHT=1 (theme sáng), MUOP_SCREENSHOT_DRAFT="nội dung nháp",
//             MUOP_SCREENSHOT_HIDE_SIDEBAR=1 (ẩn sidebar như sau khi chọn chat trên màn hẹp)

use crate::{
    api, apply_bootstrap, apply_session_update, switch_selection, AppWindow, Palette, STATE,
};
use slint::platform::software_renderer::{MinimalSoftwareWindow, RepaintBufferType};
use slint::platform::WindowAdapter;
use slint::{ComponentHandle, PhysicalSize, Rgb8Pixel, SharedPixelBuffer};
use std::rc::Rc;

struct HeadlessPlatform {
    window: Rc<MinimalSoftwareWindow>,
}

impl slint::platform::Platform for HeadlessPlatform {
    fn create_window_adapter(&self) -> Result<Rc<dyn WindowAdapter>, slint::PlatformError> {
        Ok(self.window.clone())
    }
}

fn env_u32(name: &str, default: u32) -> u32 {
    std::env::var(name)
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(default)
}

pub fn run(path: &str, base: &str) -> Result<(), String> {
    let width = env_u32("MUOP_SCREENSHOT_WIDTH", 1280);
    let height = env_u32("MUOP_SCREENSHOT_HEIGHT", 820);
    let light = std::env::var("MUOP_SCREENSHOT_LIGHT").is_ok();

    let window = MinimalSoftwareWindow::new(RepaintBufferType::NewBuffer);
    slint::platform::set_platform(Box::new(HeadlessPlatform {
        window: window.clone(),
    }))
    .map_err(|e| format!("Không đặt được platform: {e}"))?;
    window.set_size(PhysicalSize::new(width, height));

    let ui = AppWindow::new().map_err(|e| e.to_string())?;
    ui.show().map_err(|e| e.to_string())?;
    let palette = ui.global::<Palette>();
    palette.set_dark(false);
    palette.set_dark(true);
    if light {
        palette.set_dark(false);
    }

    let sessions = api::get_sessions(base)?;
    let meta = api::get_meta(base)?;
    let streams = api::get_streams(base)?;
    // Mở conversation mới nhất để khung chat có nội dung
    let target = sessions
        .iter()
        .max_by(|a, b| a.updated_at.cmp(&b.updated_at))
        .map(|s| s.id.clone());
    apply_bootstrap(&ui, sessions, meta, streams);
    if let Some(id) = target {
        let detail = api::get_session_detail(base, &id)?;
        apply_session_update(&ui, detail);
        STATE.with(|s| switch_selection(&ui, &mut s.borrow_mut(), Some(id)));
    }
    if std::env::var("MUOP_SCREENSHOT_HIDE_SIDEBAR").is_ok() {
        ui.set_sidebar_visible(false);
    }
    if let Ok(draft) = std::env::var("MUOP_SCREENSHOT_DRAFT") {
        ui.set_draft(draft.into());
    }

    let mut buffer = SharedPixelBuffer::<Rgb8Pixel>::new(width, height);
    let stride = width as usize;
    // Chạy timer và vẽ lại vài vòng, như vòng lặp sự kiện thật: đo chiều cao mục, bám đáy khung chat
    let mut drawn = false;
    for _ in 0..12 {
        slint::platform::update_timers_and_animations();
        crate::poll_scroll(&ui);
        window.request_redraw();
        drawn |= window.draw_if_needed(|renderer| {
            renderer.render(buffer.make_mut_slice(), stride);
        });
    }
    // Tùy chọn: cuộn lên đầu rồi vẽ lại, để kiểm tra cửa sổ mục khi cuộn
    if std::env::var("MUOP_SCREENSHOT_SCROLL_TOP").is_ok() {
        ui.invoke_set_scroll(0.0);
        for _ in 0..12 {
            slint::platform::update_timers_and_animations();
            crate::poll_scroll(&ui);
            window.request_redraw();
            window.draw_if_needed(|renderer| {
                renderer.render(buffer.make_mut_slice(), stride);
            });
        }
    }
    if !drawn {
        return Err("Renderer không vẽ khung hình nào".to_string());
    }

    let bytes: Vec<u8> = buffer
        .as_slice()
        .iter()
        .flat_map(|p| [p.r, p.g, p.b])
        .collect();
    let img = image::RgbImage::from_raw(width, height, bytes)
        .ok_or_else(|| "Kích thước buffer không khớp".to_string())?;
    img.save(path)
        .map_err(|e| format!("Không lưu được {path}: {e}"))
}
