//! Lưu cấu hình app giữa các lần mở: máy đang dùng và danh sách máy đã kết nối.
//!
//! Desktop: `$XDG_CONFIG_HOME/muop-agent/app.json` (hoặc `~/.config/...`).
//! Web sẽ đổi sang localStorage khi làm nền tảng đó (hiện là no-op).

use serde::{Deserialize, Serialize};

use super::config::DEFAULT_SERVER_ADDRESS;

const MAX_SAVED_SERVERS: usize = 10;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct SavedConfig {
    pub server_address: String,
    /// Máy đã kết nối, mới nhất đứng đầu
    pub servers: Vec<String>,
    /// `dark` (mặc định) hoặc `light`
    pub theme: String,
}

impl Default for SavedConfig {
    fn default() -> Self {
        Self {
            server_address: DEFAULT_SERVER_ADDRESS.to_string(),
            servers: Vec::new(),
            theme: "dark".to_string(),
        }
    }
}

impl SavedConfig {
    /// Ghi nhận một địa chỉ vừa dùng: đưa lên đầu, bỏ trùng, giới hạn số lượng.
    pub fn remember(&mut self, address: &str) {
        self.server_address = address.to_string();
        self.servers.retain(|s| s != address);
        self.servers.insert(0, address.to_string());
        self.servers.truncate(MAX_SAVED_SERVERS);
    }
}

#[cfg(not(target_arch = "wasm32"))]
fn config_path() -> Option<std::path::PathBuf> {
    let base = std::env::var_os("XDG_CONFIG_HOME")
        .filter(|v| !v.is_empty())
        .map(std::path::PathBuf::from)
        .or_else(|| {
            std::env::var_os("HOME").map(|h| std::path::PathBuf::from(h).join(".config"))
        })?;
    Some(base.join("muop-agent").join("app.json"))
}

/// Đọc cấu hình đã lưu. Không có hoặc lỗi thì trả mặc định.
pub fn load() -> SavedConfig {
    #[cfg(not(target_arch = "wasm32"))]
    {
        if let Some(path) = config_path() {
            if let Ok(text) = std::fs::read_to_string(path) {
                if let Ok(config) = serde_json::from_str::<SavedConfig>(&text) {
                    return config;
                }
            }
        }
    }
    SavedConfig::default()
}

/// Ghi cấu hình. Lỗi ghi file không làm app dừng; cấu hình chỉ mất khi mở lại.
pub fn save(config: &SavedConfig) {
    #[cfg(not(target_arch = "wasm32"))]
    {
        let Some(path) = config_path() else { return };
        if let Some(dir) = path.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        if let Ok(text) = serde_json::to_string_pretty(config) {
            let _ = std::fs::write(path, text);
        }
    }
    #[cfg(target_arch = "wasm32")]
    let _ = config;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn remember_moves_to_front_dedupes_and_caps() {
        let mut c = SavedConfig::default();
        for i in 0..12 {
            c.remember(&format!("http://10.0.0.{i}:8787"));
        }
        assert_eq!(c.servers.len(), MAX_SAVED_SERVERS);
        assert_eq!(c.servers[0], "http://10.0.0.11:8787");
        c.remember("http://10.0.0.5:8787");
        assert_eq!(c.servers[0], "http://10.0.0.5:8787");
        assert_eq!(
            c.servers
                .iter()
                .filter(|s| *s == "http://10.0.0.5:8787")
                .count(),
            1
        );
    }

    #[test]
    fn theme_defaults_to_dark_and_survives_roundtrip() {
        let c: SavedConfig = serde_json::from_str("{}").unwrap();
        assert_eq!(c.theme, "dark");
        let light = SavedConfig {
            theme: "light".into(),
            ..Default::default()
        };
        let text = serde_json::to_string(&light).unwrap();
        let back: SavedConfig = serde_json::from_str(&text).unwrap();
        assert_eq!(back.theme, "light");
    }

    #[test]
    fn missing_fields_use_defaults() {
        let c: SavedConfig = serde_json::from_str("{}").unwrap();
        assert_eq!(c.server_address, DEFAULT_SERVER_ADDRESS);
        assert!(c.servers.is_empty());
    }
}
