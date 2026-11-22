//! Đường dẫn dữ liệu của server, suy ra từ thư mục home của user đang chạy.
//! Không có user hay đường dẫn cố định trong code: cùng một binary chạy được trên mọi máy.

use std::path::PathBuf;

/// Thư mục home: biến `HOME`, không có thì hỏi hệ thống (passwd). Không đoán user.
pub fn home_dir() -> PathBuf {
    if let Some(home) = std::env::var_os("HOME").filter(|h| !h.is_empty()) {
        return PathBuf::from(home);
    }
    std::env::home_dir().unwrap_or_else(|| PathBuf::from("/"))
}

/// Dữ liệu Antigravity (agy): `brain/`, `daemon/`, `log/`, `conversation_summaries.db`, `builtin/skills/`
pub fn antigravity_dir() -> PathBuf {
    home_dir().join(".gemini/antigravity")
}

/// Dữ liệu riêng của muop-agent (DB, uploads, mount, token màn hình)
pub fn app_data_dir() -> PathBuf {
    home_dir().join(".local/share/muop-agent")
}

/// SQLite chính của server
pub fn db_path() -> PathBuf {
    app_data_dir().join("muop-agent.db")
}
