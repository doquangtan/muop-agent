use super::*;

/// Kết quả lấy quota Antigravity gần nhất, kèm thời gian giữ.
/// Từ hub: 10 giây. Từ màn `/usage` (phải mở TUI): 5 phút. Lỗi: 10 giây.
pub(super) struct QuotaCache {
    pub(super) at: Instant,
    pub(super) ttl: Duration,
    pub(super) result: Result<Vec<ModelQuotaGroup>, String>,
}

pub(super) static QUOTA_CACHE: OnceLock<Mutex<QuotaCache>> = OnceLock::new();

/// Giữ quota đọc từ màn `/usage`: mở TUI tốn khoảng 30 giây nên không hỏi lại liên tục
const USAGE_TTL: Duration = Duration::from_secs(300);
/// Giữ kết quả từ hub và kết quả lỗi
const SHORT_TTL: Duration = Duration::from_secs(10);

/// Mục cache đã hết hạn (lần hỏi kế tiếp sẽ tính lại)
fn expired_entry() -> QuotaCache {
    QuotaCache {
        at: Instant::now() - Duration::from_secs(3600),
        ttl: Duration::ZERO,
        result: Ok(Vec::new()),
    }
}

/// Quota của mọi provider. `allow_host` = true cho phép mở TUI agy để đọc màn `/usage` khi không có hub.
/// Socket `quotas:update` và watcher định kỳ dùng `false` để không bao giờ mở TUI.
pub fn quota_snapshot(allow_host: bool) -> QuotaSnapshot {
    QuotaSnapshot {
        agy: agy_quota_report(allow_host),
        claude: claude_quota_report(),
    }
}

/// Quota Antigravity (`GET /api/quota/agy` dùng `allow_host` = true)
pub fn agy_quota_report(allow_host: bool) -> QuotaReport {
    agy_report_from(fetch_antigravity_model_quotas(allow_host))
}

/// Quota Claude Code CLI (`GET /api/quota/claude`)
pub fn claude_quota_report() -> QuotaReport {
    claude_report_from(crate::claude::code::fetch_limit_group())
}

/// Dựng báo cáo agy từ kết quả lấy quota: nhóm rỗng cũng là lỗi (không có dữ liệu để hiển thị)
pub(super) fn agy_report_from(result: Result<Vec<ModelQuotaGroup>, String>) -> QuotaReport {
    let (groups, error) = match result {
        Ok(groups) if !groups.is_empty() => (groups, String::new()),
        Ok(_) => (Vec::new(), "Chưa có quota agy nào".to_string()),
        Err(msg) => (Vec::new(), msg),
    };
    QuotaReport {
        provider: "agy".to_string(),
        groups,
        error,
    }
}

/// Dựng báo cáo Claude từ nhóm limit (`None` là chưa đăng nhập Claude Code CLI).
/// Nhóm không có cửa sổ nào thì `description` của nhóm là lý do không có dữ liệu.
pub(super) fn claude_report_from(group: Option<ModelQuotaGroup>) -> QuotaReport {
    let (groups, error) = match group {
        None => (Vec::new(), "Chưa đăng nhập Claude Code CLI".to_string()),
        Some(g) if g.buckets.is_empty() => (Vec::new(), g.description),
        Some(g) => (vec![g], String::new()),
    };
    QuotaReport {
        provider: "claude".to_string(),
        groups,
        error,
    }
}

/// Xóa cache quota Antigravity (khi đăng xuất, hoặc khi đăng nhập xong để lấy số liệu tài khoản mới)
pub fn clear_antigravity_quota_cache() {
    if let Some(cache) = QUOTA_CACHE.get() {
        if let Ok(mut guard) = cache.lock() {
            *guard = expired_entry();
        }
    }
}

/// Quota Antigravity từ hub đang chạy (RPC). Không mở TUI.
fn fetch_from_hub() -> Result<Vec<ModelQuotaGroup>, String> {
    match crate::agy_auth::hub_logged_in(crate::agy_auth::host::Need::Background) {
        Ok(true) => match query_daemon_quota_summary() {
            Some(mut groups) if !groups.is_empty() => {
                // Gắn gói của tài khoản vào tên nhóm, giống nhãn "(pro)" của Claude
                if let Some((_, plan)) = query_agy_account() {
                    if !plan.is_empty() {
                        for g in &mut groups {
                            g.display_name = format!("{} ({})", g.display_name, plan);
                        }
                    }
                }
                Ok(groups)
            }
            _ => Err("Hub agy không trả về quota".to_string()),
        },
        Ok(false) => Err("Chưa đăng nhập agy".to_string()),
        Err(msg) => Err(msg),
    }
}

/// Tính quota agy và thời gian giữ kết quả. Ưu tiên hub đang chạy; không có hub thì đọc màn `/usage`
/// của TUI agy khi `allow_host`, còn không thì lỗi (không mở gì).
fn compute_antigravity(allow_host: bool) -> (Result<Vec<ModelQuotaGroup>, String>, Duration) {
    if crate::chat::context_window::discover_hub().is_some() {
        return (fetch_from_hub(), SHORT_TTL);
    }
    if !allow_host {
        return (
            Err("Chưa có tiến trình agy đang chạy để đọc quota".to_string()),
            SHORT_TTL,
        );
    }
    let result = crate::agy_auth::host::read_usage_screen()
        .and_then(|screen| crate::agy_auth::usage::parse_usage_screen(&screen, chrono::Utc::now()));
    let ttl = if result.is_ok() { USAGE_TTL } else { SHORT_TTL };
    (result, ttl)
}

/// Quota Antigravity, có cache. Chỉ dữ liệu thật: không dùng số cũ hay số mặc định.
/// Lỗi trong cache chỉ được trả lại khi không được phép mở TUI; khi được phép thì hỏi lại.
pub(super) fn fetch_antigravity_model_quotas(
    allow_host: bool,
) -> Result<Vec<ModelQuotaGroup>, String> {
    let cache = QUOTA_CACHE.get_or_init(|| Mutex::new(expired_entry()));
    if let Ok(guard) = cache.lock() {
        let usable = guard.result.is_ok() || !allow_host;
        if guard.at.elapsed() < guard.ttl && usable {
            return guard.result.clone();
        }
    }
    let (result, ttl) = compute_antigravity(allow_host);
    let Ok(mut guard) = cache.lock() else {
        return result;
    };
    // Lần hỏi không mở TUI (watcher định kỳ) không ghi đè kết quả thành công còn hạn bằng lỗi
    if result.is_err() && !allow_host && guard.result.is_ok() && guard.at.elapsed() < guard.ttl {
        return guard.result.clone();
    }
    *guard = QuotaCache {
        at: Instant::now(),
        ttl,
        result: result.clone(),
    };
    result
}

#[cfg(test)]
mod quota_report_tests {
    use super::*;

    fn group(name: &str, buckets: usize) -> ModelQuotaGroup {
        ModelQuotaGroup {
            display_name: name.to_string(),
            description: "mô tả".to_string(),
            buckets: (0..buckets)
                .map(|i| ModelQuotaBucket {
                    bucket_id: format!("b{i}"),
                    display_name: "b".to_string(),
                    description: String::new(),
                    window: "weekly".to_string(),
                    remaining_fraction: 0.5,
                    remaining_percent: 50.0,
                    reset_time: String::new(),
                })
                .collect(),
        }
    }

    #[test]
    fn agy_error_or_empty_has_no_groups() {
        let err = agy_report_from(Err("Chưa đăng nhập agy".to_string()));
        assert_eq!(err.provider, "agy");
        assert!(err.groups.is_empty());
        assert_eq!(err.error, "Chưa đăng nhập agy");

        let empty = agy_report_from(Ok(Vec::new()));
        assert!(empty.groups.is_empty());
        assert!(!empty.error.is_empty());
    }

    #[test]
    fn agy_groups_are_returned_without_error() {
        let ok = agy_report_from(Ok(vec![group("Gemini", 2)]));
        assert_eq!(ok.groups.len(), 1);
        assert!(ok.error.is_empty());
    }

    #[test]
    fn claude_missing_login_or_no_windows_reports_error() {
        let none = claude_report_from(None);
        assert_eq!(none.provider, "claude");
        assert!(none.groups.is_empty());
        assert!(none.error.contains("Chưa đăng nhập"));

        let mut empty = group("Claude Code CLI", 0);
        empty.description = "Chưa có dữ liệu limit".to_string();
        let r = claude_report_from(Some(empty));
        assert!(r.groups.is_empty());
        assert_eq!(r.error, "Chưa có dữ liệu limit");
    }

    #[test]
    fn claude_with_windows_has_one_group() {
        let r = claude_report_from(Some(group("Claude Code CLI (pro)", 2)));
        assert_eq!(r.groups.len(), 1);
        assert!(r.error.is_empty());
    }
}

/// Email và gói (ví dụ "Pro") của tài khoản agy đang đăng nhập, lấy từ hub (`GetUserStatus`).
/// Trả về `None` khi hub không trả lời hoặc chưa đăng nhập.
pub fn query_agy_account() -> Option<(String, String)> {
    let (port, token) = crate::chat::context_window::discover_hub()?;
    let value = crate::chat::context_window::rpc_post(
        port,
        &token,
        "/exa.language_server_pb.LanguageServerService/GetUserStatus",
        "{}",
    )
    .ok()?;
    let status = value.get("userStatus")?;
    let email = status
        .get("email")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    let plan = status
        .pointer("/planStatus/planInfo/planName")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    Some((email, plan))
}

pub(super) fn query_daemon_quota_summary() -> Option<Vec<ModelQuotaGroup>> {
    let entries = fs::read_dir(DAEMON_DIR_PATH).ok()?;
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().to_string();
        if !name.starts_with("hub_") || !name.ends_with(".json") {
            continue;
        }
        let raw = fs::read_to_string(entry.path()).ok()?;
        let val: Value = serde_json::from_str(&raw).ok()?;
        let port = val.get("httpPort").and_then(|v| v.as_u64())? as u16;
        let csrf = val
            .get("csrfToken")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        if port == 0 || csrf.is_empty() {
            continue;
        }
        if let Some(groups) = call_retrieve_user_quota_summary(port, &csrf) {
            if !groups.is_empty() {
                return Some(groups);
            }
        }
    }
    None
}

pub(super) fn call_retrieve_user_quota_summary(
    port: u16,
    csrf_token: &str,
) -> Option<Vec<ModelQuotaGroup>> {
    let addr = SocketAddr::from(([127, 0, 0, 1], port));
    let mut stream = TcpStream::connect_timeout(&addr, Duration::from_millis(600)).ok()?;
    let _ = stream.set_read_timeout(Some(Duration::from_millis(900)));
    let _ = stream.set_write_timeout(Some(Duration::from_millis(600)));

    let req = format!(
        "POST /exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary HTTP/1.1\r\n\
         Host: 127.0.0.1:{}\r\n\
         Content-Type: application/json\r\n\
         Connect-Protocol-Version: 1\r\n\
         x-codeium-csrf-token: {}\r\n\
         Content-Length: 2\r\n\
         Connection: close\r\n\r\n{{}}",
        port, csrf_token
    );

    stream.write_all(req.as_bytes()).ok()?;
    let mut resp_bytes = Vec::new();
    stream.read_to_end(&mut resp_bytes).ok()?;
    let resp_str = String::from_utf8_lossy(&resp_bytes);
    let (_, body) = resp_str.split_once("\r\n\r\n")?;
    let body_trimmed = body.trim();
    // Handle chunked or direct JSON
    let json_start = body_trimmed.find('{')?;
    let json_end = body_trimmed.rfind('}')?;
    let json_slice = &body_trimmed[json_start..=json_end];

    let root: Value = serde_json::from_str(json_slice).ok()?;
    let groups_arr = root
        .get("response")
        .and_then(|r| r.get("groups"))
        .and_then(|g| g.as_array())?;

    let mut result = Vec::new();
    for g in groups_arr {
        let display_name = g
            .get("displayName")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        let description = g
            .get("description")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        let mut buckets = Vec::new();
        if let Some(b_arr) = g.get("buckets").and_then(|v| v.as_array()) {
            for b in b_arr {
                let bucket_id = b
                    .get("bucketId")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string();
                let b_name = b
                    .get("displayName")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string();
                let b_desc = b
                    .get("description")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string();
                let window = b
                    .get("window")
                    .and_then(|v| v.as_str())
                    .unwrap_or("weekly")
                    .to_string();
                let frac = b
                    .get("remainingFraction")
                    .and_then(|v| v.as_f64())
                    .unwrap_or(1.0)
                    .clamp(0.0, 1.0);
                let pct = (frac * 100.0).round();
                let reset_time = b
                    .get("resetTime")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string();
                buckets.push(ModelQuotaBucket {
                    bucket_id,
                    display_name: b_name,
                    description: b_desc,
                    window,
                    remaining_fraction: frac,
                    remaining_percent: pct,
                    reset_time,
                });
            }
        }
        result.push(ModelQuotaGroup {
            display_name,
            description,
            buckets,
        });
    }
    Some(result)
}
