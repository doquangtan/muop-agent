//! Tự động gửi lại lượt chat khi CLI báo rate limit / hết quota.
//!
//! Luồng: lượt chat kết thúc với lỗi khớp `is_rate_limit_error` → `schedule` đọc cấu hình của
//! conversation (`conversation_retry_config`, mặc định nếu chưa đặt) → chọn thời điểm gửi lại →
//! một task nền chờ rồi gọi lại `start_chat_turn_attempt`. Thời điểm lấy theo thứ tự:
//! 1. `quota`: mốc reset muộn nhất của các cửa sổ quota đã hết (đọc từ quota của provider),
//!    cộng thêm `RESET_MARGIN_SECS`. Chỉ khi cấu hình bật `useQuotaReset`.
//! 2. `message`: thời gian CLI ghi trong thông điệp (`retry in 90s`, `retry-after`, epoch reset).
//! 3. `interval`: khoảng phút trong cấu hình.
//!
//! Lịch được đăng ký ngay (`Slot::Computing`) trước khi đọc quota, nên gửi tay trong lúc đó vẫn hủy
//! được lịch. Mỗi thay đổi phát `retry:update`. Gửi tin nhắn thủ công cho cùng conversation sẽ hủy lịch.

use crate::chat::{self, AppState};
use crate::infra::store;
use crate::models::{
    ChatSendRequest, ModelQuotaGroup, PendingRetryDto, RetryConfigDto, RETRY_INTERVAL_MINUTES_MAX,
    RETRY_INTERVAL_MINUTES_MIN, RETRY_MAX_ATTEMPTS_LIMIT, RETRY_PROMPT_MAX_CHARS,
};
use chrono::{DateTime, Duration as ChronoDuration, Utc};
use regex::Regex;
use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};

/// Chờ tối thiểu giữa hai lần gửi lại (tránh gọi liên tục khi thông điệp báo thời gian rất ngắn)
const MIN_DELAY_SECS: i64 = 15;
/// Trần cho thời gian chờ đọc từ thông điệp
const MAX_MESSAGE_DELAY_SECS: i64 = 6 * 3600;
/// Cộng thêm sau mốc reset để quota chắc chắn đã được cấp lại
const RESET_MARGIN_SECS: i64 = 60;

/// Lịch của một conversation: đang đọc quota (`Computing`) hoặc đang chờ (`Waiting`)
enum Slot {
    Computing(u64),
    Waiting(PendingRetry),
}

struct PendingRetry {
    /// Yêu cầu gốc của người dùng (nội dung và ảnh đính kèm)
    request: ChatSendRequest,
    /// Nội dung sẽ gửi khi đến giờ: cấu hình `prompt` nếu có, không thì là nội dung gốc
    prompt: String,
    provider: String,
    reason: String,
    retry_at: DateTime<Utc>,
    attempt: u32,
    max_attempts: u32,
    wait_source: &'static str,
    wait_detail: String,
    reset_at: Option<DateTime<Utc>>,
    /// Để task nền cũ không gửi lại khi lịch đã bị hủy hoặc thay thế
    generation: u64,
}

static RETRIES: OnceLock<Mutex<HashMap<String, Slot>>> = OnceLock::new();
static NEXT_GENERATION: AtomicU64 = AtomicU64::new(1);

fn retries() -> &'static Mutex<HashMap<String, Slot>> {
    RETRIES.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Thông điệp có phải lỗi giới hạn tốc độ / quota không.
/// Các chuỗi lấy từ thông điệp thật của Claude CLI và agy (`Usage limit reached`, `MODEL_CAPACITY_EXHAUSTED`...).
pub fn is_rate_limit_error(text: &str) -> bool {
    let lower = text.to_lowercase();
    const PATTERNS: [&str; 12] = [
        "rate limit",
        "rate_limit",
        "ratelimit",
        "resource_exhausted",
        "resource has been exhausted",
        "quota",
        "too many requests",
        "usage limit",
        "hit your limit",
        "overloaded",
        "model_capacity_exhausted",
        "model capacity",
    ];
    if PATTERNS.iter().any(|p| lower.contains(p)) {
        return true;
    }
    Regex::new(r"\b429\b")
        .map(|re| re.is_match(text))
        .unwrap_or(false)
}

/// Kiểm tra cấu hình trước khi lưu. Trả về thông báo lỗi tiếng Việt.
pub fn validate(cfg: &RetryConfigDto) -> Result<(), String> {
    if cfg.max_attempts > RETRY_MAX_ATTEMPTS_LIMIT {
        return Err(format!(
            "Số lần gửi lại tối đa là {RETRY_MAX_ATTEMPTS_LIMIT}"
        ));
    }
    if !(RETRY_INTERVAL_MINUTES_MIN..=RETRY_INTERVAL_MINUTES_MAX).contains(&cfg.interval_minutes) {
        return Err(format!(
            "Khoảng chờ phải từ {RETRY_INTERVAL_MINUTES_MIN} đến {RETRY_INTERVAL_MINUTES_MAX} phút"
        ));
    }
    if cfg.prompt.chars().count() > RETRY_PROMPT_MAX_CHARS {
        return Err(format!(
            "Nội dung gửi lại tối đa {RETRY_PROMPT_MAX_CHARS} ký tự"
        ));
    }
    Ok(())
}

/// Nội dung sẽ gửi khi đến giờ: prompt trong cấu hình, rỗng thì dùng nội dung gốc
fn effective_prompt(cfg: &RetryConfigDto, original: &str) -> String {
    let custom = cfg.prompt.trim();
    if custom.is_empty() {
        original.to_string()
    } else {
        custom.to_string()
    }
}

/// Thời gian chờ đọc được trong thông điệp: `retry in 30s`, `retry-after: 120`, hoặc epoch reset.
/// Không đọc được thì `None`. Kết quả được giới hạn trong [MIN, MAX].
fn message_delay(text: &str, now: DateTime<Utc>) -> Option<ChronoDuration> {
    relative_delay_secs(text)
        .or_else(|| epoch_delay_secs(text, now))
        .map(|secs| ChronoDuration::seconds(secs.clamp(MIN_DELAY_SECS, MAX_MESSAGE_DELAY_SECS)))
}

fn relative_delay_secs(text: &str) -> Option<i64> {
    let re = Regex::new(
        r"(?i)retry[ _-]?(?:in|after)\W{0,3}(\d+)\s*(ms|s|secs?|seconds?|m|mins?|minutes?)?",
    )
    .ok()?;
    let caps = re.captures(text)?;
    let value: i64 = caps.get(1)?.as_str().parse().ok()?;
    let unit = caps
        .get(2)
        .map(|m| m.as_str().to_lowercase())
        .unwrap_or_default();
    Some(match unit.as_str() {
        "ms" => value / 1000,
        "m" | "min" | "mins" | "minute" | "minutes" => value * 60,
        _ => value,
    })
}

fn epoch_delay_secs(text: &str, now: DateTime<Utc>) -> Option<i64> {
    let re = Regex::new(r"\b(1[0-9]{9})\b").ok()?;
    let epoch: i64 = re.captures(text)?.get(1)?.as_str().parse().ok()?;
    let delta = epoch - now.timestamp();
    (delta > 0).then_some(delta)
}

/// Quota agy có nhóm theo họ model (Gemini; Claude và GPT). Trả về từ khóa để chọn nhóm khớp model.
fn agy_family_keywords(model: &str) -> Vec<&'static str> {
    let mut out = Vec::new();
    if model.contains("gemini") {
        out.push("gemini");
    }
    if model.contains("claude") {
        out.push("claude");
    }
    if model.contains("gpt") {
        out.push("gpt");
    }
    out
}

/// Cửa sổ Claude chỉ áp dụng cho model tương ứng (Sonnet/Opus/model cụ thể), các cửa sổ còn lại áp dụng cho mọi model.
fn claude_window_applies(bucket_id: &str, model_lower: &str) -> bool {
    match bucket_id {
        "seven_day_sonnet" => model_lower.contains("sonnet"),
        "seven_day_opus" => model_lower.contains("opus"),
        other => match other.strip_prefix("model:") {
            Some(name) if !name.is_empty() => model_lower.contains(&name.to_lowercase()),
            _ => true,
        },
    }
}

/// Mốc reset muộn nhất trong các cửa sổ đã hết quota (còn sau `now`) của provider, kèm tên cửa sổ.
/// Mọi cửa sổ đã hết đều phải reset thì lượt mới chạy được, nên lấy mốc muộn nhất.
/// `provider` là `claude-cli` hoặc `agy` (xem `chat::args::provider_source`).
pub(crate) fn quota_reset(
    groups: &[ModelQuotaGroup],
    provider: &str,
    model: &str,
    now: DateTime<Utc>,
) -> Option<(DateTime<Utc>, String)> {
    let model_lower = model.to_lowercase();
    let is_agy = provider == "agy";
    let candidates: Vec<&ModelQuotaGroup> = if is_agy {
        let keywords = agy_family_keywords(&model_lower);
        let matched: Vec<&ModelQuotaGroup> = groups
            .iter()
            .filter(|g| {
                let name = g.display_name.to_lowercase();
                keywords.iter().any(|k| name.contains(k))
            })
            .collect();
        if matched.is_empty() {
            groups.iter().collect()
        } else {
            matched
        }
    } else {
        groups.iter().collect()
    };

    let mut best: Option<(DateTime<Utc>, String)> = None;
    for group in candidates {
        for bucket in &group.buckets {
            if bucket.remaining_fraction > 0.0 || bucket.reset_time.trim().is_empty() {
                continue;
            }
            if !is_agy && !claude_window_applies(&bucket.bucket_id, &model_lower) {
                continue;
            }
            let Ok(reset) = DateTime::parse_from_rfc3339(bucket.reset_time.trim()) else {
                continue;
            };
            let reset = reset.with_timezone(&Utc);
            if reset <= now {
                continue;
            }
            if best.as_ref().map_or(true, |(t, _)| reset > *t) {
                best = Some((reset, bucket.display_name.clone()));
            }
        }
    }
    best
}

/// Kết quả chọn thời điểm gửi lại
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct WaitPlan {
    pub retry_at: DateTime<Utc>,
    pub source: &'static str,
    pub detail: String,
    pub reset_at: Option<DateTime<Utc>>,
}

/// Chọn thời điểm gửi lại theo cấu hình. `groups` là quota của provider (chỉ cần khi `use_quota_reset`).
pub(crate) fn plan_wait(
    cfg: &RetryConfigDto,
    provider: &str,
    model: &str,
    reason: &str,
    now: DateTime<Utc>,
    groups: &[ModelQuotaGroup],
) -> WaitPlan {
    if cfg.use_quota_reset {
        if let Some((reset_at, window)) = quota_reset(groups, provider, model, now) {
            return WaitPlan {
                retry_at: reset_at + ChronoDuration::seconds(RESET_MARGIN_SECS),
                source: "quota",
                detail: format!("Chờ reset quota · {window}"),
                reset_at: Some(reset_at),
            };
        }
        if let Some(delay) = message_delay(reason, now) {
            return WaitPlan {
                retry_at: now + delay,
                source: "message",
                detail: "Theo thời gian CLI báo".to_string(),
                reset_at: None,
            };
        }
    }
    let minutes = i64::from(cfg.interval_minutes.max(RETRY_INTERVAL_MINUTES_MIN));
    WaitPlan {
        retry_at: now + ChronoDuration::minutes(minutes),
        source: "interval",
        detail: format!("Chờ {minutes} phút (theo cấu hình)"),
        reset_at: None,
    }
}

/// Quota của provider để chọn thời điểm reset. Đọc trong luồng chặn vì có thể gọi HTTP.
fn quota_groups_for(provider: &str) -> Vec<ModelQuotaGroup> {
    let report = if provider == "agy" {
        // Không mở TUI: chỉ dùng snapshot đã lưu của server
        crate::scanner::agy_quota_report(false)
    } else {
        crate::scanner::claude_quota_report()
    };
    report.groups
}

/// Xếp lịch gửi lại theo cấu hình của conversation. Chỉ xử lý khi đã có conversation id.
/// `attempt` là lần gửi lại thứ mấy (1 = lần đầu sau lượt bị giới hạn).
pub fn schedule(
    state: &AppState,
    request: ChatSendRequest,
    provider: &str,
    reason: &str,
    attempt: u32,
) {
    let conversation_id = request.conversation_id.trim().to_string();
    if conversation_id.is_empty() {
        return;
    }
    let cfg = store::conversation_retry_config(&conversation_id).unwrap_or_else(|| RetryConfigDto {
        conversation_id: conversation_id.clone(),
        ..RetryConfigDto::default()
    });
    if !cfg.enabled || attempt > cfg.max_attempts {
        return;
    }

    let generation = NEXT_GENERATION.fetch_add(1, Ordering::SeqCst);
    if let Ok(mut map) = retries().lock() {
        map.insert(conversation_id.clone(), Slot::Computing(generation));
    }

    let state = state.clone();
    let provider = provider.to_string();
    let reason = reason.to_string();
    tokio::spawn(async move {
        let groups = if cfg.use_quota_reset {
            let provider_for_quota = provider.clone();
            tokio::task::spawn_blocking(move || quota_groups_for(&provider_for_quota))
                .await
                .unwrap_or_default()
        } else {
            Vec::new()
        };
        let now = Utc::now();
        let plan = plan_wait(&cfg, &provider, &request.model, &reason, now, &groups);
        let delay = (plan.retry_at - now).to_std().unwrap_or_default();

        // Chỉ đăng ký nếu lịch này vẫn là lịch hiện tại (chưa bị hủy hoặc thay bằng lịch mới)
        let registered = retries()
            .lock()
            .ok()
            .map(|mut map| match map.get(&conversation_id) {
                Some(Slot::Computing(g)) if *g == generation => {
                    let prompt = effective_prompt(&cfg, &request.prompt);
                    map.insert(
                        conversation_id.clone(),
                        Slot::Waiting(PendingRetry {
                            request,
                            prompt,
                            provider,
                            reason,
                            retry_at: plan.retry_at,
                            attempt,
                            max_attempts: cfg.max_attempts,
                            wait_source: plan.source,
                            wait_detail: plan.detail,
                            reset_at: plan.reset_at,
                            generation,
                        }),
                    );
                    true
                }
                _ => false,
            })
            .unwrap_or(false);
        if !registered {
            return;
        }
        emit_update(&state);

        tokio::time::sleep(delay).await;
        fire(state, conversation_id, generation).await;
    });
}

/// Lấy lịch đang chờ ra khỏi bảng nếu vẫn đúng thế hệ `generation`
fn take_waiting(conversation_id: &str, generation: u64) -> Option<PendingRetry> {
    let mut map = retries().lock().ok()?;
    match map.get(conversation_id) {
        Some(Slot::Waiting(r)) if r.generation == generation => match map.remove(conversation_id) {
            Some(Slot::Waiting(r)) => Some(r),
            _ => None,
        },
        _ => None,
    }
}

async fn fire(state: AppState, conversation_id: String, generation: u64) {
    let Some(pending) = take_waiting(&conversation_id, generation) else {
        return;
    };
    emit_update(&state);

    let mut request = pending.request.clone();
    request.conversation_id = conversation_id.clone();
    request.prompt = pending.prompt.clone();
    let res = chat::start_chat_turn_attempt(state.clone(), request, pending.attempt).await;
    state.broadcast_session_update(&res.conversation_id);
    if !res.ok && is_rate_limit_error(&res.error) {
        // Lịch kế tiếp vẫn dùng nội dung gốc; nội dung cấu hình được áp dụng lại khi xếp lịch
        schedule(
            &state,
            pending.request,
            &pending.provider,
            &res.error,
            pending.attempt + 1,
        );
    }
}

/// Áp dụng cấu hình vừa lưu cho lịch đang chờ: tắt thì hủy, đổi nội dung hoặc số lần thì cập nhật.
pub fn apply_config(state: &AppState, cfg: &RetryConfigDto) {
    let cid = cfg.conversation_id.trim();
    if cid.is_empty() {
        return;
    }
    let changed = retries()
        .lock()
        .ok()
        .map(|mut map| {
            let keep = match map.get_mut(cid) {
                None => return false,
                Some(Slot::Computing(_)) => cfg.enabled,
                Some(Slot::Waiting(r)) => {
                    if cfg.enabled && r.attempt <= cfg.max_attempts {
                        r.prompt = effective_prompt(cfg, &r.request.prompt);
                        r.max_attempts = cfg.max_attempts;
                        true
                    } else {
                        false
                    }
                }
            };
            if !keep {
                map.remove(cid);
            }
            true
        })
        .unwrap_or(false);
    if changed {
        emit_update(state);
    }
}

/// Hủy lịch gửi lại của một conversation. Trả về true nếu có lịch để hủy.
pub fn cancel(state: &AppState, conversation_id: &str) -> bool {
    let removed = retries()
        .lock()
        .ok()
        .and_then(|mut map| map.remove(conversation_id.trim()))
        .is_some();
    if removed {
        emit_update(state);
    }
    removed
}

/// Danh sách lịch đang chờ, dùng cho snapshot và event `retry:update`
pub fn list() -> Vec<PendingRetryDto> {
    let Ok(map) = retries().lock() else {
        return Vec::new();
    };
    let mut items: Vec<PendingRetryDto> = map
        .iter()
        .filter_map(|(cid, slot)| match slot {
            Slot::Waiting(r) => Some(PendingRetryDto {
                conversation_id: cid.clone(),
                provider: r.provider.clone(),
                reason: r.reason.clone(),
                retry_at: r.retry_at.to_rfc3339(),
                attempt: r.attempt,
                max_attempts: r.max_attempts,
                wait_source: r.wait_source.to_string(),
                wait_detail: r.wait_detail.clone(),
                reset_at: r.reset_at.map(|t| t.to_rfc3339()),
            }),
            Slot::Computing(_) => None,
        })
        .collect();
    items.sort_by(|a, b| a.retry_at.cmp(&b.retry_at));
    items
}

pub fn emit_update(state: &AppState) {
    if let Ok(val) = serde_json::to_value(list()) {
        if let Some(ns) = state.io.of("/") {
            let _ = ns.emit("retry:update", &val);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    fn at(secs: i64) -> DateTime<Utc> {
        Utc.timestamp_opt(secs, 0).unwrap()
    }

    fn bucket(id: &str, name: &str, remaining: f64, reset: &str) -> crate::models::ModelQuotaBucket {
        crate::models::ModelQuotaBucket {
            bucket_id: id.to_string(),
            display_name: name.to_string(),
            description: String::new(),
            window: "5h".to_string(),
            remaining_fraction: remaining,
            remaining_percent: remaining * 100.0,
            reset_time: reset.to_string(),
        }
    }

    fn group(name: &str, buckets: Vec<crate::models::ModelQuotaBucket>) -> ModelQuotaGroup {
        ModelQuotaGroup {
            display_name: name.to_string(),
            description: String::new(),
            buckets,
        }
    }

    const NOW: i64 = 1_700_000_000;

    #[test]
    fn detects_rate_limit_messages() {
        assert!(is_rate_limit_error("Usage limit reached · resets 3pm"));
        assert!(is_rate_limit_error("API Error: 429 Too Many Requests"));
        assert!(is_rate_limit_error("MODEL_CAPACITY_EXHAUSTED"));
        assert!(is_rate_limit_error(
            "Resource has been exhausted (e.g. check quota)."
        ));
        assert!(!is_rate_limit_error("Tool Bash failed: exit code 1"));
        assert!(!is_rate_limit_error("file 1429 not found"));
    }

    #[test]
    fn reads_relative_and_epoch_delays_from_message() {
        let now = at(NOW);
        assert_eq!(
            message_delay("please retry in 90s", now),
            Some(ChronoDuration::seconds(90))
        );
        assert_eq!(
            message_delay("retry-after: 120", now),
            Some(ChronoDuration::seconds(120))
        );
        assert_eq!(
            message_delay("retry in 2 minutes", now),
            Some(ChronoDuration::seconds(120))
        );
        assert_eq!(
            message_delay("Usage limit reached|1700003600", now),
            Some(ChronoDuration::seconds(3600))
        );
        assert_eq!(message_delay("rate limited", now), None);
        assert_eq!(
            message_delay("retry in 1s", now),
            Some(ChronoDuration::seconds(MIN_DELAY_SECS))
        );
    }

    #[test]
    fn quota_reset_picks_latest_exhausted_window() {
        let groups = vec![group(
            "Claude Code CLI",
            vec![
                bucket("five_hour", "Phiên 5 giờ", 0.0, "2023-11-14T23:00:00Z"),
                bucket("seven_day", "Tuần", 0.0, "2023-11-16T00:00:00Z"),
                bucket("seven_day_sonnet", "Tuần Sonnet", 0.0, "2023-11-20T00:00:00Z"),
            ],
        )];
        // Tuần Sonnet không áp dụng cho model Haiku; cửa sổ tuần còn lại hết quota và reset muộn nhất
        let (reset, window) =
            quota_reset(&groups, "claude-cli", "claude-cli:claude-haiku-5-5", at(NOW)).unwrap();
        assert_eq!(window, "Tuần");
        assert_eq!(reset.to_rfc3339(), "2023-11-16T00:00:00+00:00");

        // Với model Sonnet thì cửa sổ Sonnet mới là mốc muộn nhất
        let (_, window) =
            quota_reset(&groups, "claude-cli", "claude-cli:claude-sonnet-5-5", at(NOW)).unwrap();
        assert_eq!(window, "Tuần Sonnet");
    }

    #[test]
    fn quota_reset_ignores_windows_with_quota_left_or_past_reset() {
        let groups = vec![group(
            "Claude Code CLI",
            vec![
                bucket("five_hour", "Phiên 5 giờ", 0.4, "2023-11-14T23:00:00Z"),
                bucket("seven_day", "Tuần", 0.0, "2023-11-13T00:00:00Z"),
            ],
        )];
        assert!(quota_reset(&groups, "claude-cli", "haiku", at(NOW)).is_none());
    }

    #[test]
    fn agy_quota_reset_uses_matching_family_group() {
        let groups = vec![
            group(
                "Gemini Pro",
                vec![bucket("g-5h", "5h", 0.0, "2023-11-14T23:30:00Z")],
            ),
            group(
                "Claude and GPT models",
                vec![bucket("3p-weekly", "Tuần", 0.0, "2023-11-18T00:00:00Z")],
            ),
        ];
        let (reset, window) = quota_reset(&groups, "agy", "agy:gemini-4-argon-low", at(NOW)).unwrap();
        assert_eq!(window, "5h");
        assert_eq!(reset.to_rfc3339(), "2023-11-14T23:30:00+00:00");
    }

    #[test]
    fn plan_prefers_quota_then_message_then_interval() {
        let exhausted = vec![group(
            "Claude Code CLI",
            vec![bucket("five_hour", "Phiên 5 giờ", 0.0, "2023-11-14T23:00:00Z")],
        )];
        let cfg = RetryConfigDto {
            interval_minutes: 7,
            ..RetryConfigDto::default()
        };

        let quota = plan_wait(&cfg, "claude-cli", "haiku", "Usage limit reached", at(NOW), &exhausted);
        assert_eq!(quota.source, "quota");
        assert_eq!(quota.detail, "Chờ reset quota · Phiên 5 giờ");
        assert_eq!(
            quota.retry_at,
            DateTime::parse_from_rfc3339("2023-11-14T23:01:00Z")
                .unwrap()
                .with_timezone(&Utc)
        );

        // Không có quota hết: dùng thời gian CLI báo
        let msg = plan_wait(&cfg, "claude-cli", "haiku", "retry in 90s", at(NOW), &[]);
        assert_eq!(msg.source, "message");
        assert_eq!(msg.retry_at, at(NOW + 90));

        // Không có gì: khoảng phút cấu hình
        let interval = plan_wait(&cfg, "claude-cli", "haiku", "rate limited", at(NOW), &[]);
        assert_eq!(interval.source, "interval");
        assert_eq!(interval.retry_at, at(NOW + 7 * 60));
    }

    #[test]
    fn plan_skips_quota_when_disabled() {
        let exhausted = vec![group(
            "Claude Code CLI",
            vec![bucket("five_hour", "Phiên 5 giờ", 0.0, "2023-11-14T23:00:00Z")],
        )];
        let cfg = RetryConfigDto {
            use_quota_reset: false,
            interval_minutes: 3,
            ..RetryConfigDto::default()
        };
        let plan = plan_wait(&cfg, "claude-cli", "haiku", "retry in 90s", at(NOW), &exhausted);
        assert_eq!(plan.source, "interval");
        assert_eq!(plan.retry_at, at(NOW + 180));
    }

    #[test]
    fn validate_limits_config_values() {
        assert!(validate(&RetryConfigDto::default()).is_ok());
        let too_many = RetryConfigDto {
            max_attempts: RETRY_MAX_ATTEMPTS_LIMIT + 1,
            ..RetryConfigDto::default()
        };
        assert!(validate(&too_many).is_err());
        let zero_interval = RetryConfigDto {
            interval_minutes: 0,
            ..RetryConfigDto::default()
        };
        assert!(validate(&zero_interval).is_err());
        let long_prompt = RetryConfigDto {
            prompt: "x".repeat(RETRY_PROMPT_MAX_CHARS + 1),
            ..RetryConfigDto::default()
        };
        assert!(validate(&long_prompt).is_err());
    }

    #[test]
    fn custom_prompt_overrides_original_only_when_set() {
        let mut cfg = RetryConfigDto::default();
        assert_eq!(effective_prompt(&cfg, "viết tiếp"), "viết tiếp");
        cfg.prompt = "  tiếp tục  ".to_string();
        assert_eq!(effective_prompt(&cfg, "viết tiếp"), "tiếp tục");
    }
}
