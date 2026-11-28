//! Mướp Agent — client Dioxus.
//!
//! Điểm vào. Toàn bộ logic giao diện nằm trong `ui`, dữ liệu trong `data`.

mod data;
mod store;
mod ui;

use dioxus::prelude::*;

const MAIN_CSS: Asset = asset!("/assets/main.css");

fn main() {
    #[cfg(feature = "desktop")]
    {
        // Kích thước gần với cửa sổ Flutter; bỏ thanh menu mặc định (Window/Edit) của Dioxus.
        use dioxus::desktop::{Config, LogicalSize, WindowBuilder};
        let window = WindowBuilder::new()
            .with_title("Mướp Agent")
            .with_inner_size(LogicalSize::new(1360.0, 860.0))
            .with_min_inner_size(LogicalSize::new(640.0, 480.0));
        dioxus::LaunchBuilder::desktop()
            .with_cfg(Config::new().with_window(window).with_menu(None))
            .launch(App);
    }
    #[cfg(not(feature = "desktop"))]
    dioxus::launch(App);
}

#[component]
fn App() -> Element {
    let store = store::Store::create();
    use_context_provider(|| store);
    let theme_class = if *store.theme_light.read() {
        "theme-root theme-light"
    } else {
        "theme-root theme-dark"
    };
    rsx! {
        document::Stylesheet { href: MAIN_CSS }
        document::Title { "Mướp Agent" }
        div { class: "{theme_class}",
            ui::shell::Shell {}
        }
    }
}
