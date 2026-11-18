use super::*;

pub(super) static QUOTA_CACHE: OnceLock<Mutex<(Instant, Vec<ModelQuotaGroup>)>> = OnceLock::new();

/// Toàn bộ quota/limit hiển thị trên UI: Antigravity + limit tài khoản Claude Code CLI
pub fn fetch_all_model_quotas() -> Vec<ModelQuotaGroup> {
    let mut groups = fetch_antigravity_model_quotas();
    if let Some(claude) = crate::claude::code::fetch_limit_group() {
        groups.push(claude);
    }
    groups
}

pub fn fetch_antigravity_model_quotas() -> Vec<ModelQuotaGroup> {
    let cache = QUOTA_CACHE.get_or_init(|| {
        Mutex::new((
            Instant::now() - Duration::from_secs(60),
            default_fallback_quotas(),
        ))
    });

    if let Ok(guard) = cache.lock() {
        if guard.0.elapsed() < Duration::from_secs(10) && !guard.1.is_empty() {
            return guard.1.clone();
        }
    }

    if let Some(live) = query_daemon_quota_summary() {
        if !live.is_empty() {
            if let Ok(mut guard) = cache.lock() {
                *guard = (Instant::now(), live.clone());
            }
            return live;
        }
    }

    if let Ok(guard) = cache.lock() {
        return guard.1.clone();
    }
    default_fallback_quotas()
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

pub(super) fn default_fallback_quotas() -> Vec<ModelQuotaGroup> {
    vec![ModelQuotaGroup {
        display_name: "Gemini Models".to_string(),
        description: "Models within this group: Gemini Flash, Gemini Pro".to_string(),
        buckets: vec![
            ModelQuotaBucket {
                bucket_id: "gemini-weekly".to_string(),
                display_name: "Weekly Limit Remaining".to_string(),
                description: "Weekly limit remaining".to_string(),
                window: "weekly".to_string(),
                remaining_fraction: 0.70,
                remaining_percent: 70.0,
                reset_time: String::new(),
            },
            ModelQuotaBucket {
                bucket_id: "gemini-5h".to_string(),
                display_name: "Five Hour Limit Remaining".to_string(),
                description: "5-hour limit remaining".to_string(),
                window: "5h".to_string(),
                remaining_fraction: 0.95,
                remaining_percent: 95.0,
                reset_time: String::new(),
            },
        ],
    }]
}
