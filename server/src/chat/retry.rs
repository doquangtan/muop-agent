//! Tự động gửi lại lượt chat khi CLI báo rate limit / hết quota.
//!
//! Luồng: lượt chat kết thúc với lỗi khớp `is_rate_limit_error` → `schedule` xếp lịch gửi lại
//! theo thời điểm đọc được trong thông điệp (hoặc mặc định 5 phút) → một task nền chờ rồi gọi lại
//! `start_chat_turn_attempt` với cùng prompt và conversation. Mỗi thay đổi phát `retry:update`.
//! Gửi tin nhắn thủ công cho cùng conversation sẽ hủy lịch đang chờ.

use crate::chat::{self, AppState};
use crate::models::{ChatSendRequest, PendingRetryDto};
use chrono::{DateTime, Duration as ChronoDuration, Utc};
use regex::Regex;
use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};

/// Số lần tự gửi lại tối đa cho một lượt
pub const MAX_ATTEMPTS: u32 = 8;
const DEFAULT_DELAY_SECS: i64 = 300;
const MIN_DELAY_SECS: i64 = 15;
const MAX_DELAY_SECS: i64 = 6 * 3600;

struct PendingRetry {
    request: ChatSendRequest,
    provider: String,
    reason: String,
    retry_at: DateTime<Utc>,
    attempt: u32,
    /// Để task nền cũ không gửi lại khi lịch đã bị hủy hoặc thay thế
    generation: u64,
}

static RETRIES: OnceLock<Mutex<HashMap<String, PendingRetry>>> = OnceLock::new();
static NEXT_GENERATION: AtomicU64 = AtomicU64::new(1);

fn retries() -> &'static Mutex<HashMap<String, PendingRetry>> {
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

/// Thời gian chờ đọc được trong thông điệp: `retry in 30s`, `retry-after: 120`, hoặc epoch reset.
/// Không đọc được thì dùng mặc định. Kết quả được giới hạn trong [MIN, MAX].
pub fn retry_delay(text: &str, now: DateTime<Utc>) -> ChronoDuration {
    let secs = relative_delay_secs(text)
        .or_else(|| epoch_delay_secs(text, now))
        .unwrap_or(DEFAULT_DELAY_SECS)
        .clamp(MIN_DELAY_SECS, MAX_DELAY_SECS);
    ChronoDuration::seconds(secs)
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

/// Xếp lịch gửi lại. Chỉ xử lý khi đã có conversation id (lượt chưa có id thì không theo dõi được).
pub fn schedule(
    state: &AppState,
    request: ChatSendRequest,
    provider: &str,
    reason: &str,
    attempt: u32,
) {
    let conversation_id = request.conversation_id.trim().to_string();
    if conversation_id.is_empty() || attempt > MAX_ATTEMPTS {
        return;
    }
    let now = Utc::now();
    let generation = NEXT_GENERATION.fetch_add(1, Ordering::SeqCst);
    let retry_at = now + retry_delay(reason, now);
    let delay = (retry_at - now).to_std().unwrap_or_default();

    if let Ok(mut map) = retries().lock() {
        map.insert(
            conversation_id.clone(),
            PendingRetry {
                request,
                provider: provider.to_string(),
                reason: reason.to_string(),
                retry_at,
                attempt,
                generation,
            },
        );
    }
    emit_update(state);

    let state = state.clone();
    tokio::spawn(async move {
        tokio::time::sleep(delay).await;
        fire(state, conversation_id, generation).await;
    });
}

async fn fire(state: AppState, conversation_id: String, generation: u64) {
    let taken = retries()
        .lock()
        .ok()
        .and_then(|mut map| match map.get(&conversation_id) {
            Some(r) if r.generation == generation => map.remove(&conversation_id),
            _ => None,
        });
    let Some(pending) = taken else {
        return;
    };
    emit_update(&state);

    let mut request = pending.request.clone();
    request.conversation_id = conversation_id.clone();
    let res = chat::start_chat_turn_attempt(state.clone(), request.clone(), pending.attempt).await;
    state.broadcast_session_update(&res.conversation_id);
    if !res.ok && is_rate_limit_error(&res.error) {
        schedule(
            &state,
            request,
            &pending.provider,
            &res.error,
            pending.attempt + 1,
        );
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
        .map(|(cid, r)| PendingRetryDto {
            conversation_id: cid.clone(),
            provider: r.provider.clone(),
            reason: r.reason.clone(),
            retry_at: r.retry_at.to_rfc3339(),
            attempt: r.attempt,
            max_attempts: MAX_ATTEMPTS,
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
    fn reads_relative_and_epoch_delays() {
        let now = Utc.timestamp_opt(1_700_000_000, 0).unwrap();
        assert_eq!(
            retry_delay("please retry in 90s", now),
            ChronoDuration::seconds(90)
        );
        assert_eq!(
            retry_delay("retry-after: 120", now),
            ChronoDuration::seconds(120)
        );
        assert_eq!(
            retry_delay("retry in 2 minutes", now),
            ChronoDuration::seconds(120)
        );
        assert_eq!(
            retry_delay("Usage limit reached|1700003600", now),
            ChronoDuration::seconds(3600)
        );
        assert_eq!(
            retry_delay("rate limited", now),
            ChronoDuration::seconds(DEFAULT_DELAY_SECS)
        );
        assert_eq!(
            retry_delay("retry in 1s", now),
            ChronoDuration::seconds(MIN_DELAY_SECS)
        );
    }
}
