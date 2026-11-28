//! Lớp dữ liệu: cấu hình kết nối, DTO và REST client tới `muop-agent-server`.
//!
//! Không có gì ở đây phụ thuộc Dioxus, để test được trên máy và tái sử dụng
//! khi đổi nền tảng. Không đọc file hệ thống, không chạy shell (AGENTS.md mục 4.1).

pub mod api;
pub mod config;
pub mod images;
pub mod models;
pub mod persist;
pub mod rt;
pub mod socket;
