//! Cấu hình kết nối tới máy chủ muop-agent.

use reqwest::Url;

/// Cổng mặc định của `muop-agent-server` (AGENTS.md mục 1).
pub const DEFAULT_PORT: u16 = 8787;
pub const DEFAULT_SERVER_ADDRESS: &str = "http://127.0.0.1:8787";

/// Chuẩn hóa ô nhập của người dùng thành base URL, ví dụ
/// `192.168.31.96` → `http://192.168.31.96:8787`.
pub fn normalize_server_address(input: &str) -> Result<String, String> {
    let trimmed = input.trim();
    if trimmed.is_empty() {
        return Err("Nhập địa chỉ máy chủ, ví dụ 192.168.1.10".into());
    }
    let with_scheme = if trimmed.contains("://") {
        trimmed.to_string()
    } else {
        format!("http://{trimmed}")
    };
    let mut url = Url::parse(&with_scheme).map_err(|e| format!("Địa chỉ không hợp lệ: {e}"))?;
    if url.scheme() != "http" && url.scheme() != "https" {
        return Err("Chỉ hỗ trợ http hoặc https".into());
    }
    if url.host_str().is_none() {
        return Err("Thiếu máy chủ trong địa chỉ".into());
    }
    if url.port().is_none() {
        url.set_port(Some(DEFAULT_PORT))
            .map_err(|_| "Không đặt được cổng mặc định".to_string())?;
    }
    let host = url.host_str().unwrap_or_default();
    let port = url.port().unwrap_or(DEFAULT_PORT);
    Ok(format!("{}://{}:{}", url.scheme(), host, port))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bare_ip_gets_scheme_and_default_port() {
        assert_eq!(
            normalize_server_address("192.168.31.96").unwrap(),
            "http://192.168.31.96:8787"
        );
    }

    #[test]
    fn explicit_port_and_trailing_slash_are_kept_clean() {
        assert_eq!(
            normalize_server_address("  http://10.0.0.5:9000/ ").unwrap(),
            "http://10.0.0.5:9000"
        );
    }

    #[test]
    fn empty_input_is_rejected() {
        assert!(normalize_server_address("   ").is_err());
    }

    #[test]
    fn non_http_scheme_is_rejected() {
        assert!(normalize_server_address("ftp://10.0.0.5").is_err());
    }
}
