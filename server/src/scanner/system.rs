use super::*;

pub fn detect_hostname() -> String {
    if let Ok(h) = fs::read_to_string("/etc/hostname") {
        let trimmed = h.trim().to_string();
        if !trimmed.is_empty() {
            return trimmed;
        }
    }
    "linux-pc".to_string()
}

pub fn detect_lan_ips() -> Vec<String> {
    let mut ips = Vec::new();
    if let Ok(out) = Command::new("hostname").arg("-I").output() {
        if out.status.success() {
            let text = String::from_utf8_lossy(&out.stdout);
            for part in text.split_whitespace() {
                if part.contains(':') {
                    continue; // Skip IPv6
                }
                if part.starts_with("172.17.")
                    || part.starts_with("172.18.")
                    || part.starts_with("172.19.")
                    || part.starts_with("127.")
                {
                    continue;
                }
                if !ips.contains(&part.to_string()) {
                    ips.push(part.to_string());
                }
            }
        }
    }
    // Không đoán IP khi không đọc được: danh sách rỗng, client tự dùng loopback/IP đã biết
    ips
}
