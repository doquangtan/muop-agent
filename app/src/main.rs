//! Mướp Agent — client Dioxus.
//!
//! Điểm vào. Toàn bộ logic giao diện nằm trong `ui`, dữ liệu trong `data`.

mod data;
mod ui;

use dioxus::prelude::*;

const MAIN_CSS: Asset = asset!("/assets/main.css");

fn main() {
    dioxus::launch(App);
}

#[component]
fn App() -> Element {
    rsx! {
        document::Stylesheet { href: MAIN_CSS }
        document::Title { "Mướp Agent" }
        ui::shell::Shell {}
    }
}
