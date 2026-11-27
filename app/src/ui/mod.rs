//! Giao diện Dioxus: layout, sidebar, khung hội thoại. Không gọi REST trực tiếp
//! từ component con; dữ liệu đi qua `shell` và `data::api`.

pub mod conversation;
pub mod format;
pub mod shell;
pub mod sidebar;
