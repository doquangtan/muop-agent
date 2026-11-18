use super::*;

/// Thời gian giữ dữ liệu usage lấy từ endpoint OAuth trước khi gọi lại
pub(super) const LIMITS_CACHE_TTL: Duration = Duration::from_secs(60);
/// Sau khi endpoint usage trả rate limit, không gọi lại trong khoảng này
pub(super) const USAGE_RATE_LIMIT_BACKOFF: Duration = Duration::from_secs(300);
/// Sau lỗi khác (mạng, định dạng), chờ ngắn trước khi thử lại
pub(super) const USAGE_ERROR_BACKOFF: Duration = Duration::from_secs(60);
pub(super) const USAGE_URL: &str = "https://api.anthropic.com/api/oauth/usage";

/// Một cửa sổ limit của tài khoản Claude (phiên 5 giờ, tuần, tuần Sonnet, theo model...)
#[derive(Clone, Debug, PartialEq)]
pub struct LimitWindow {
    /// `five_hour`, `seven_day`, `seven_day_sonnet`, `seven_day_opus`, hoặc `model:<tên>`
    pub key: String,
    pub label: String,
    /// `5h` hoặc `weekly`, khớp với `ModelQuotaBucket.window` phía Flutter
    pub window: String,
    /// Phần trăm đã dùng (0–100)
    pub utilization: f64,
    /// Thời điểm reset dạng RFC3339 (UTC), None nếu chưa có
    pub resets_at: Option<String>,
    /// Thời điểm dữ liệu được lấy (ms, epoch). Bản mới hơn thay bản cũ của cùng cửa sổ.
    pub updated_at_ms: i64,
}

#[derive(Default)]
pub(super) struct LimitsState {
    pub(super) windows: Vec<LimitWindow>,
    pub(super) usage_fetched_at: Option<Instant>,
    pub(super) backoff_until: Option<Instant>,
    pub(super) last_error: String,
}

pub(super) static LIMITS_STATE: OnceLock<Mutex<LimitsState>> = OnceLock::new();

pub(super) fn limits_state() -> &'static Mutex<LimitsState> {
    LIMITS_STATE.get_or_init(|| Mutex::new(LimitsState::default()))
}

/// Xoá TTL của usage để lần lấy kế tiếp gọi lại API (dùng sau mỗi lượt chat Claude).
/// Không xoá backoff: lượt chat không làm endpoint usage hết bị giới hạn.
pub fn invalidate_limits_cache() {
    if let Ok(mut s) = limits_state().lock() {
        s.usage_fetched_at = None;
    }
}

/// Nhãn và loại cửa sổ theo khoá của `rate_limit_info.unifiedWindows` / `rate_limits`
pub(super) fn window_meta(key: &str) -> (String, String) {
    match key {
        "five_hour" => ("Phiên 5 giờ".to_string(), "5h".to_string()),
        "seven_day" => ("Tuần (tất cả model)".to_string(), "weekly".to_string()),
        "seven_day_sonnet" => ("Tuần (Sonnet)".to_string(), "weekly".to_string()),
        "seven_day_opus" => ("Tuần (Opus)".to_string(), "weekly".to_string()),
        other => (other.replace('_', " "), "weekly".to_string()),
    }
}

pub(super) fn epoch_secs_to_rfc3339(secs: i64) -> Option<String> {
    chrono::DateTime::<chrono::Utc>::from_timestamp(secs, 0).map(|t| t.to_rfc3339())
}

pub(super) fn iso_to_rfc3339(s: &str) -> Option<String> {
    chrono::DateTime::parse_from_rfc3339(s)
        .ok()
        .map(|t| t.with_timezone(&chrono::Utc).to_rfc3339())
}

/// Ghi một cửa sổ vào danh sách; bản mới hơn (theo `updated_at_ms`) thay bản cũ
pub(super) fn upsert_window(windows: &mut Vec<LimitWindow>, w: LimitWindow) {
    match windows.iter_mut().find(|x| x.key == w.key) {
        Some(existing) => {
            if w.updated_at_ms >= existing.updated_at_ms {
                *existing = w;
            }
        }
        None => windows.push(w),
    }
}

/// Các cửa sổ từ sự kiện `rate_limit_event` của stream-json (CLI gửi sau mỗi lượt chat).
/// `utilization` là phân số 0–1 và `resetsAt` là epoch giây. Cửa sổ thiếu dữ liệu bị bỏ qua.
pub fn windows_from_rate_limit_event(event: &Value, now_ms: i64) -> Vec<LimitWindow> {
    let Some(windows) = event
        .get("rate_limit_info")
        .and_then(|i| i.get("unifiedWindows"))
        .and_then(|w| w.as_object())
    else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for (key, v) in windows {
        let Some(fraction) = v.get("utilization").and_then(|x| x.as_f64()) else {
            continue;
        };
        let (label, window) = window_meta(key);
        out.push(LimitWindow {
            key: key.clone(),
            label,
            window,
            utilization: (fraction * 100.0).clamp(0.0, 100.0),
            resets_at: v
                .get("resetsAt")
                .and_then(|x| x.as_i64())
                .and_then(epoch_secs_to_rfc3339),
            updated_at_ms: now_ms,
        });
    }
    out
}

/// Xử lý sự kiện `rate_limit_event` trong stream-json của Claude CLI (gọi sau mỗi lượt chat)
pub fn ingest_rate_limit_event(event: &Value) {
    let now_ms = chrono::Utc::now().timestamp_millis();
    let windows = windows_from_rate_limit_event(event, now_ms);
    if windows.is_empty() {
        return;
    }
    if let Ok(mut s) = limits_state().lock() {
        for w in windows {
            upsert_window(&mut s.windows, w);
        }
    }
}

/// Các cửa sổ từ phản hồi endpoint usage. Định dạng mới: `five_hour`, `seven_day`,
/// `seven_day_sonnet`, `model_scoped` với `utilization` là phần trăm và `resets_at` là ISO.
/// Định dạng cũ (mảng `limits` với `kind`, `group`, `percent`) được đọc khi không có định dạng mới.
pub fn windows_from_usage(usage: &Value, now_ms: i64) -> Vec<LimitWindow> {
    let mut out = Vec::new();
    for key in [
        "five_hour",
        "seven_day",
        "seven_day_sonnet",
        "seven_day_opus",
    ] {
        let Some(obj) = usage.get(key).filter(|v| v.is_object()) else {
            continue;
        };
        let Some(util) = obj.get("utilization").and_then(|x| x.as_f64()) else {
            continue;
        };
        let (label, window) = window_meta(key);
        out.push(LimitWindow {
            key: key.to_string(),
            label,
            window,
            utilization: util.clamp(0.0, 100.0),
            resets_at: obj
                .get("resets_at")
                .and_then(|x| x.as_str())
                .and_then(iso_to_rfc3339),
            updated_at_ms: now_ms,
        });
    }
    if let Some(scoped) = usage.get("model_scoped").and_then(|x| x.as_array()) {
        for item in scoped {
            let Some(util) = item.get("utilization").and_then(|x| x.as_f64()) else {
                continue;
            };
            let name = item
                .get("display_name")
                .and_then(|x| x.as_str())
                .unwrap_or("model")
                .to_string();
            out.push(LimitWindow {
                key: format!("model:{name}"),
                label: format!("Tuần ({name})"),
                window: "weekly".to_string(),
                utilization: util.clamp(0.0, 100.0),
                resets_at: item
                    .get("resets_at")
                    .and_then(|x| x.as_str())
                    .and_then(iso_to_rfc3339),
                updated_at_ms: now_ms,
            });
        }
    }
    if !out.is_empty() {
        return out;
    }
    // Định dạng cũ
    if let Some(items) = usage.get("limits").and_then(|x| x.as_array()) {
        for item in items {
            let kind = item.get("kind").and_then(|x| x.as_str()).unwrap_or("limit");
            let group = item.get("group").and_then(|x| x.as_str()).unwrap_or("");
            let Some(percent) = item.get("percent").and_then(|x| x.as_f64()) else {
                continue;
            };
            let label = match kind {
                "session" => "Phiên 5 giờ".to_string(),
                "weekly_all" => "Tuần (tất cả model)".to_string(),
                other => other.replace('_', " "),
            };
            out.push(LimitWindow {
                key: kind.to_string(),
                label,
                window: if group == "session" {
                    "5h".to_string()
                } else {
                    "weekly".to_string()
                },
                utilization: percent.clamp(0.0, 100.0),
                resets_at: item
                    .get("resets_at")
                    .and_then(|x| x.as_str())
                    .and_then(iso_to_rfc3339),
                updated_at_ms: now_ms,
            });
        }
    }
    out
}

/// Gọi endpoint usage nếu đã đến lúc: không trong TTL, không trong backoff.
/// Không giữ lock khi gọi mạng (curl có thể mất tới 15 giây).
pub(super) fn refresh_usage_if_due(token: &str) {
    let now = Instant::now();
    {
        let Ok(s) = limits_state().lock() else {
            return;
        };
        if s.backoff_until.is_some_and(|t| now < t) {
            return;
        }
        if s.usage_fetched_at
            .is_some_and(|t| now.duration_since(t) < LIMITS_CACHE_TTL)
        {
            return;
        }
    }
    let result = fetch_usage_json(token);
    let Ok(mut s) = limits_state().lock() else {
        return;
    };
    s.usage_fetched_at = Some(Instant::now());
    match result {
        Ok(usage) => {
            let now_ms = chrono::Utc::now().timestamp_millis();
            for w in windows_from_usage(&usage, now_ms) {
                upsert_window(&mut s.windows, w);
            }
            s.backoff_until = None;
            s.last_error.clear();
        }
        Err((msg, rate_limited)) => {
            let wait = if rate_limited {
                USAGE_RATE_LIMIT_BACKOFF
            } else {
                USAGE_ERROR_BACKOFF
            };
            s.backoff_until = Some(Instant::now() + wait);
            s.last_error = msg;
        }
    }
}

/// Đọc accessToken OAuth của Claude Code từ `~/.claude/.credentials.json`.
/// Trả về `(token, subscriptionType)`. Không ghi log token.
pub(super) fn read_oauth_credentials() -> Result<(String, String), String> {
    let path = home_dir().join(".claude/.credentials.json");
    let raw = fs::read_to_string(&path)
        .map_err(|_| "Chưa đăng nhập Claude Code CLI (không tìm thấy credentials)".to_string())?;
    let v: Value = serde_json::from_str(&raw)
        .map_err(|_| "File credentials của Claude Code CLI không hợp lệ".to_string())?;
    let oauth = v
        .get("claudeAiOauth")
        .ok_or_else(|| "Không có thông tin OAuth của Claude Code CLI".to_string())?;
    let token = oauth
        .get("accessToken")
        .and_then(|x| x.as_str())
        .ok_or_else(|| "Thiếu accessToken của Claude Code CLI".to_string())?
        .to_string();
    let expires_at = oauth.get("expiresAt").and_then(|x| x.as_i64()).unwrap_or(0);
    let now_ms = chrono::Utc::now().timestamp_millis();
    if expires_at > 0 && expires_at <= now_ms {
        return Err("Token Claude đã hết hạn — mở Claude Code CLI một lần để làm mới".to_string());
    }
    let plan = oauth
        .get("subscriptionType")
        .and_then(|x| x.as_str())
        .unwrap_or("")
        .to_string();
    Ok((token, plan))
}

/// Gọi endpoint usage (cùng nguồn với `/usage` của Claude Code). Token được đưa qua stdin của curl
/// (`-K -`) để không lộ trên dòng lệnh. Trả về Err(msg, is_rate_limited) để phân biệt.
pub(super) fn fetch_usage_json(token: &str) -> Result<Value, (String, bool)> {
    let config = format!(
        "header = \"Authorization: Bearer {}\"\nheader = \"anthropic-beta: oauth-2025-04-20\"\nuser-agent = \"muop-agent\"\n",
        token
    );
    let mut child = Command::new("curl")
        .args(["-s", "-m", "15", "-K", "-", USAGE_URL])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| (format!("Không chạy được curl: {}", e), false))?;
    if let Some(mut stdin) = child.stdin.take() {
        let _ = stdin.write_all(config.as_bytes());
    }
    let out = child
        .wait_with_output()
        .map_err(|e| (format!("curl lỗi: {}", e), false))?;
    let v: Value = serde_json::from_slice(&out.stdout).map_err(|_| {
        (
            "Không đọc được phản hồi usage từ Anthropic".to_string(),
            false,
        )
    })?;
    if let Some(err) = v.get("error") {
        let error_type = err
            .get("type")
            .and_then(|x| x.as_str())
            .unwrap_or("unknown");
        let error_msg = err
            .get("message")
            .and_then(|x| x.as_str())
            .unwrap_or(error_type);

        if error_type == "rate_limit_error" {
            return Err(("Anthropic API bị rate limit, thử lại sau".to_string(), true));
        }

        return Err((format!("Lỗi từ Anthropic: {}", error_msg), false));
    }
    Ok(v)
}

/// Thứ tự hiển thị các cửa sổ: phiên 5 giờ, tuần tất cả model, tuần Sonnet/Opus, theo model
pub(super) fn window_rank(key: &str) -> u8 {
    match key {
        "five_hour" => 0,
        "seven_day" => 1,
        "seven_day_sonnet" => 2,
        "seven_day_opus" => 3,
        _ => 4,
    }
}

/// Dựng nhóm quota từ danh sách cửa sổ tại thời điểm `now`. Cửa sổ đã qua thời điểm reset
/// được coi là vừa reset (0% đã dùng, không còn thời gian reset).
pub fn build_limit_group(
    windows: &[LimitWindow],
    plan: &str,
    now: chrono::DateTime<chrono::Utc>,
) -> ModelQuotaGroup {
    let mut sorted: Vec<&LimitWindow> = windows.iter().collect();
    sorted.sort_by_key(|w| window_rank(&w.key));
    let buckets = sorted
        .into_iter()
        .map(|w| {
            let reset_at = w
                .resets_at
                .as_deref()
                .and_then(|r| chrono::DateTime::parse_from_rfc3339(r).ok())
                .map(|t| t.with_timezone(&chrono::Utc));
            let expired = reset_at.is_some_and(|t| t <= now);
            let used = if expired { 0.0 } else { w.utilization };
            let remaining = (100.0 - used).clamp(0.0, 100.0);
            ModelQuotaBucket {
                bucket_id: w.key.clone(),
                display_name: w.label.clone(),
                description: format!("Đã dùng {:.0}%", used),
                window: w.window.clone(),
                remaining_fraction: remaining / 100.0,
                remaining_percent: remaining,
                reset_time: if expired {
                    String::new()
                } else {
                    w.resets_at.clone().unwrap_or_default()
                },
            }
        })
        .collect();
    let plan_label = if plan.is_empty() {
        String::new()
    } else {
        format!(" ({})", plan)
    };
    ModelQuotaGroup {
        display_name: format!("{}{}", CLAUDE_LIMIT_GROUP_PREFIX, plan_label),
        description: "Limit tài khoản Claude đồng bộ từ Claude Code CLI".to_string(),
        buckets,
    }
}

/// Limit Claude Code CLI dưới dạng `ModelQuotaGroup` để dùng chung luồng quota với Antigravity.
/// Dữ liệu gộp từ hai nguồn: sự kiện `rate_limit_event` của các lượt chat và endpoint usage
/// (gọi tối đa mỗi `LIMITS_CACHE_TTL`). Trả về `None` nếu chưa từng đăng nhập Claude Code CLI.
pub fn fetch_limit_group() -> Option<ModelQuotaGroup> {
    if !home_dir().join(".claude/.credentials.json").exists() {
        return None;
    }
    let creds = read_oauth_credentials();
    let plan = match &creds {
        Ok((_, plan)) => plan.clone(),
        Err(_) => String::new(),
    };
    if let Ok((token, _)) = &creds {
        refresh_usage_if_due(token);
    }
    let (windows, last_error) = match limits_state().lock() {
        Ok(s) => (s.windows.clone(), s.last_error.clone()),
        Err(_) => (Vec::new(), String::new()),
    };
    let mut group = build_limit_group(&windows, &plan, chrono::Utc::now());
    if group.buckets.is_empty() {
        group.description = match creds {
            Err(msg) => msg,
            Ok(_) if !last_error.is_empty() => last_error,
            Ok(_) => {
                "Chưa có dữ liệu limit — hãy chạy một lượt Claude Code CLI để cập nhật".to_string()
            }
        };
    }
    Some(group)
}

#[cfg(test)]
mod claude_limits_tests {
    use super::*;

    fn at(s: &str) -> chrono::DateTime<chrono::Utc> {
        chrono::DateTime::parse_from_rfc3339(s)
            .unwrap()
            .with_timezone(&chrono::Utc)
    }

    #[test]
    fn rate_limit_event_gives_percent_and_iso_reset() {
        let event = serde_json::json!({
            "type": "rate_limit_event",
            "rate_limit_info": {
                "unifiedWindows": {
                    "five_hour": {"utilization": 0.13, "resetsAt": 1795051800, "status": "allowed"},
                    "seven_day": {"utilization": 0.78, "resetsAt": 1795154400, "status": "allowed_warning"}
                }
            }
        });
        let ws = windows_from_rate_limit_event(&event, 1);
        let five = ws.iter().find(|w| w.key == "five_hour").unwrap();
        assert!((five.utilization - 13.0).abs() < 1e-9);
        assert_eq!(five.window, "5h");
        assert_eq!(five.resets_at.as_deref(), Some("2026-11-19T01:30:00+00:00"));
        let week = ws.iter().find(|w| w.key == "seven_day").unwrap();
        assert!((week.utilization - 78.0).abs() < 1e-9);
        assert_eq!(week.window, "weekly");
    }

    #[test]
    fn usage_object_shape_is_parsed() {
        let usage = serde_json::json!({
            "five_hour": {"utilization": 13.0, "resets_at": "2026-11-19T01:30:00.000Z"},
            "seven_day": {"utilization": 78.0, "resets_at": null},
            "seven_day_sonnet": {"utilization": 5.0, "resets_at": "2026-11-20T06:00:00Z"},
            "model_scoped": [{"display_name": "Opus", "utilization": 40.0, "resets_at": "2026-11-20T06:00:00Z"}]
        });
        let ws = windows_from_usage(&usage, 1);
        let keys: Vec<&str> = ws.iter().map(|w| w.key.as_str()).collect();
        assert_eq!(
            keys,
            ["five_hour", "seven_day", "seven_day_sonnet", "model:Opus"]
        );
        assert!((ws[0].utilization - 13.0).abs() < 1e-9);
        assert_eq!(ws[1].resets_at, None);
        assert_eq!(ws[3].label, "Tuần (Opus)");
    }

    #[test]
    fn legacy_limits_array_still_parsed() {
        let usage = serde_json::json!({
            "limits": [
                {"kind": "session", "group": "session", "percent": 20.0, "resets_at": "2026-11-19T01:30:00Z"},
                {"kind": "weekly_all", "group": "weekly", "percent": 60.0, "resets_at": null}
            ]
        });
        let ws = windows_from_usage(&usage, 1);
        assert_eq!(ws.len(), 2);
        assert_eq!(ws[0].window, "5h");
        assert_eq!(ws[1].window, "weekly");
    }

    #[test]
    fn newer_data_replaces_older_for_same_window() {
        let mut ws = Vec::new();
        upsert_window(
            &mut ws,
            LimitWindow {
                key: "five_hour".into(),
                label: "a".into(),
                window: "5h".into(),
                utilization: 10.0,
                resets_at: None,
                updated_at_ms: 100,
            },
        );
        upsert_window(
            &mut ws,
            LimitWindow {
                key: "five_hour".into(),
                label: "a".into(),
                window: "5h".into(),
                utilization: 50.0,
                resets_at: None,
                updated_at_ms: 50,
            },
        );
        assert_eq!(ws[0].utilization, 10.0, "bản cũ không được ghi đè");
        upsert_window(
            &mut ws,
            LimitWindow {
                key: "five_hour".into(),
                label: "a".into(),
                window: "5h".into(),
                utilization: 70.0,
                resets_at: None,
                updated_at_ms: 200,
            },
        );
        assert_eq!(ws.len(), 1);
        assert_eq!(ws[0].utilization, 70.0);
    }

    #[test]
    fn expired_window_counts_as_reset() {
        let ws = vec![LimitWindow {
            key: "five_hour".into(),
            label: "Phiên 5 giờ".into(),
            window: "5h".into(),
            utilization: 90.0,
            resets_at: Some("2026-11-19T01:30:00+00:00".into()),
            updated_at_ms: 1,
        }];
        let before = build_limit_group(&ws, "pro", at("2026-11-19T01:00:00Z"));
        assert!((before.buckets[0].remaining_percent - 10.0).abs() < 1e-9);
        assert_eq!(before.buckets[0].reset_time, "2026-11-19T01:30:00+00:00");

        let after = build_limit_group(&ws, "pro", at("2026-11-19T02:00:00Z"));
        assert!((after.buckets[0].remaining_percent - 100.0).abs() < 1e-9);
        assert_eq!(after.buckets[0].reset_time, "");
        assert_eq!(after.display_name, "Claude Code CLI (pro)");
    }

    #[test]
    fn groups_are_ordered_five_hour_first() {
        let mk = |k: &str| LimitWindow {
            key: k.into(),
            label: k.into(),
            window: "weekly".into(),
            utilization: 1.0,
            resets_at: None,
            updated_at_ms: 1,
        };
        let ws = vec![mk("model:Opus"), mk("seven_day"), mk("five_hour")];
        let g = build_limit_group(&ws, "", at("2026-11-19T00:00:00Z"));
        let ids: Vec<&str> = g.buckets.iter().map(|b| b.bucket_id.as_str()).collect();
        assert_eq!(ids, ["five_hour", "seven_day", "model:Opus"]);
    }
}
