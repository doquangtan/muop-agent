//! Giao diện Dioxus. Component đọc dữ liệu từ `Store` (qua context) và gọi hành động của store.

pub mod composer;
pub mod conversation;
pub mod dialog;
pub mod docker;
pub mod explorer;
pub mod file_view;
pub mod format;
pub mod git;
pub mod interactions;
pub mod markdown;
pub mod model_groups;
pub mod shell;
pub mod sidebar;
pub mod ssh;
pub mod turns;

#[cfg(test)]
mod render_tests;
