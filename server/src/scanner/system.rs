use super::*;

/// Tên máy: `/etc/hostname` nếu có (Linux), rồi lệnh `hostname` (macOS và các hệ khác)
pub fn local_hostname() -> Option<String> {
    if let Ok(h) = fs::read_to_string("/etc/hostname") {
        let trimmed = h.trim().to_string();
        if !trimmed.is_empty() {
            return Some(trimmed);
        }
    }
    let out = Command::new("hostname").output().ok()?;
    let name = String::from_utf8_lossy(&out.stdout).trim().to_string();
    (out.status.success() && !name.is_empty()).then_some(name)
}

pub fn detect_hostname() -> String {
    local_hostname().unwrap_or_else(|| "linux-pc".to_string())
}

/// Các địa chỉ (IPv4 và IPv6, chưa lọc) đang gắn trên máy: `hostname -I` trên Linux, `ifconfig` trên macOS
fn interface_addresses() -> Vec<String> {
    if crate::infra::platform::IS_MACOS {
        // Mỗi giao diện in một dòng "inet <địa chỉ> netmask ..."
        let Ok(out) = Command::new("ifconfig").output() else {
            return Vec::new();
        };
        return String::from_utf8_lossy(&out.stdout)
            .lines()
            .filter_map(|line| {
                let mut parts = line.split_whitespace();
                if parts.next() != Some("inet") {
                    return None;
                }
                parts.next().map(str::to_string)
            })
            .collect();
    }
    let Ok(out) = Command::new("hostname").arg("-I").output() else {
        return Vec::new();
    };
    if !out.status.success() {
        return Vec::new();
    }
    String::from_utf8_lossy(&out.stdout)
        .split_whitespace()
        .map(str::to_string)
        .collect()
}

pub fn detect_lan_ips() -> Vec<String> {
    let mut ips = Vec::new();
    for part in interface_addresses() {
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
        if !ips.contains(&part) {
            ips.push(part);
        }
    }
    // Không đoán IP khi không đọc được: danh sách rỗng, client tự dùng loopback/IP đã biết
    ips
}
