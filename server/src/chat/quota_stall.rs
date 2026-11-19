//! Watchdog cho lượt agy bị kẹt vì hết quota.
//!
//! Khi model báo `RESOURCE_EXHAUSTED (429)`, agy không thoát: tiến trình vẫn sống nhưng transcript
//! không đổi nữa. Khi đó stream vẫn "đang chạy" và cơ chế tự gửi lại (`rate_retry`) không kích hoạt,
//! vì lượt không bao giờ kết thúc với lỗi.
//!
//! Watchdog kiểm tra định kỳ: lượt agy đang chạy, transcript im quá [`STALL_AFTER`], và log CLI của
//! tiến trình có lỗi 429 xảy ra sau lần ghi cuối của transcript. Khi đó nó dừng tiến trình, đánh dấu
//! stream là lỗi, và xếp lịch gửi lại đúng lúc quota reset.

use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use chrono::{DateTime, Datelike, Local, NaiveDate, NaiveDateTime, TimeZone};
use regex::Regex;

use crate::chat::retry;
use crate::chat::AppState;
use crate::infra::store;
use crate::models::ChatSendRequest;

/// Transcript không đổi quá khoảng này thì coi là kẹt
pub const STALL_AFTER: Duration = Duration::from_secs(5 * 60);
/// Lỗi quota được coi là liên quan nếu nằm trong khoảng này quanh lần ghi cuối của transcript
const ERROR_MARGIN: Duration = Duration::from_secs(60);

const BRAIN_DIR: &str = crate::scanner::BRAIN_DIR_PATH;
const LOG_DIR: &str = "/home/john/.gemini/antigravity/log";

/// Một lỗi quota tìm thấy trong log CLI
struct QuotaError {
    /// Thời điểm quota reset: thời điểm lỗi + `Resets in ...`
    reset_at: DateTime<Local>,
    /// Dòng lỗi gốc, để ghi vào stream và log
    message: String,
}

/// Quét các lượt agy đang chạy, dừng lượt bị kẹt vì quota và xếp lịch gửi lại.
/// Trả về các conversation id đã xử lý. Gọi trong `spawn_blocking` (đọc file).
pub fn check(state: &AppState) -> Vec<String> {
    let running: Vec<(String, u32)> = match state.running_pids.lock() {
        Ok(m) => m.iter().map(|(k, v)| (k.clone(), *v)).collect(),
        Err(_) => return Vec::new(),
    };
    let mut handled = Vec::new();
    for (cid, pid) in running {
        if !is_agy_process(pid) {
            continue;
        }
        let transcript = Path::new(BRAIN_DIR)
            .join(&cid)
            .join(".system_generated/logs/transcript.jsonl");
        let Some(last_write) = mtime(&transcript) else {
            continue;
        };
        let quiet = SystemTime::now()
            .duration_since(last_write)
            .unwrap_or_default();
        if quiet < STALL_AFTER {
            continue;
        }
        let Some(err) = find_quota_error(&cid, last_write) else {
            continue;
        };
        // Chỉ tự gửi lại khi quota chưa reset; lượt kẹt đã quá lâu thì chỉ dừng, người dùng gửi lại tay
        let remaining = (err.reset_at - Local::now()).num_seconds();
        tracing::warn!(
            "Lượt agy kẹt vì hết quota: conversation={cid} pid={pid}, quota reset sau {remaining}s: {}",
            err.message
        );
        let request = ChatSendRequest {
            prompt: last_user_request(&transcript).unwrap_or_default(),
            project_path: process_cwd(pid),
            conversation_id: cid.clone(),
            agent_name: String::new(),
            model: store::conversation_model(&cid).unwrap_or_default(),
            images: Vec::new(),
        };
        stop_stalled(state, &cid, pid, &err.message);
        if remaining > 0 && !request.prompt.is_empty() {
            let reason = format!("RESOURCE_EXHAUSTED 429 quota reached. retry in {remaining}s");
            retry::schedule(state, request, "agy", &reason, 1);
        }
        handled.push(cid);
    }
    handled
}

/// Dừng tiến trình kẹt và đánh dấu stream là lỗi (không còn coi là đang chạy)
fn stop_stalled(state: &AppState, cid: &str, pid: u32, message: &str) {
    if let Ok(mut pids) = state.running_pids.lock() {
        if pids.get(cid) == Some(&pid) {
            pids.remove(cid);
        }
    }
    if let Ok(mut adopted) = state.adopted_turns.lock() {
        adopted.remove(cid);
    }
    store::delete_running_turn(cid);
    let _ = std::process::Command::new("kill")
        .arg("-TERM")
        .arg(pid.to_string())
        .status();

    let updated = match state.active_streams.lock() {
        Ok(mut streams) => streams.get_mut(cid).map(|s| {
            s.is_running = false;
            s.active_step_type = "quota".to_string();
            s.error = format!("Hết quota, sẽ tự gửi lại khi reset: {message}");
            s.clone()
        }),
        Err(_) => None,
    };
    if let Some(st) = updated {
        state.broadcast_stream_state(&st);
    }
    state.broadcast_session_update(cid);
    state.spawn_quotas_update(true, false);
}

fn is_agy_process(pid: u32) -> bool {
    fs::read(format!("/proc/{pid}/cmdline"))
        .map(|raw| {
            raw.split(|b| *b == 0)
                .next()
                .map(|argv0| String::from_utf8_lossy(argv0).contains("agy"))
                .unwrap_or(false)
        })
        .unwrap_or(false)
}

fn process_cwd(pid: u32) -> String {
    fs::read_link(format!("/proc/{pid}/cwd"))
        .map(|p| p.to_string_lossy().to_string())
        .unwrap_or_default()
}

fn mtime(path: &Path) -> Option<SystemTime> {
    fs::metadata(path).and_then(|m| m.modified()).ok()
}

/// Tìm lỗi quota trong log CLI của conversation, xảy ra sau thời điểm [`since`].
/// Log CLI đặt tên `cli-YYYYMMDD_HHMMSS.log` cho mỗi tiến trình, dòng lỗi có dạng
/// `E1119 06:49:50.336819 ... RESOURCE_EXHAUSTED (code 429): ... Resets in 1h23m31s.`
fn find_quota_error(cid: &str, since: SystemTime) -> Option<QuotaError> {
    let line_re = Regex::new(r"^[EWF](\d{4}) (\d{2}:\d{2}:\d{2})").ok()?;
    let reset_re = Regex::new(r"Resets in ((?:\d+h)?(?:\d+m)?(?:[\d.]+s)?)").ok()?;
    let file_re = Regex::new(r"^cli-(\d{8})_\d{6}\.log$").ok()?;

    let mut best: Option<(DateTime<Local>, QuotaError)> = None;
    for entry in fs::read_dir(LOG_DIR).ok()?.flatten() {
        let name = entry.file_name().to_string_lossy().to_string();
        let Some(caps) = file_re.captures(&name) else {
            continue;
        };
        let path: PathBuf = entry.path();
        // Chỉ xét log được ghi sau khi transcript đứng yên
        if mtime(&path).is_none_or(|m| m < since) {
            continue;
        }
        let Ok(text) = fs::read_to_string(&path) else {
            continue;
        };
        if !text.contains(cid) {
            continue;
        }
        let Ok(file_day) = NaiveDate::parse_from_str(&caps[1], "%Y%m%d") else {
            continue;
        };
        for line in text.lines().rev() {
            if !line.contains("RESOURCE_EXHAUSTED") {
                continue;
            }
            let Some(lc) = line_re.captures(line) else {
                continue;
            };
            let Some(at) = local_time(file_day, &lc[1], &lc[2]) else {
                continue;
            };
            // Lỗi có thể nằm ngay trước lần ghi cuối của transcript (subagent vẫn gửi tin sau đó),
            // nên cho phép sai lệch [`ERROR_MARGIN`] quanh thời điểm transcript đứng yên
            if at
                < DateTime::<Local>::from(since)
                    - chrono::Duration::from_std(ERROR_MARGIN).unwrap_or_default()
            {
                break;
            }
            let retry_secs = reset_re
                .captures(line)
                .map(|c| parse_duration_secs(&c[1]))
                .unwrap_or(0);
            let err = QuotaError {
                reset_at: at + chrono::Duration::seconds(retry_secs),
                message: line.trim().chars().take(300).collect(),
            };
            if best.as_ref().is_none_or(|(b, _)| at > *b) {
                best = Some((at, err));
            }
            break;
        }
    }
    best.map(|(_, e)| e)
}

/// Ghép ngày của file log (`YYYYMMDD`) với `MMDD` và `HH:MM:SS` của dòng log, theo giờ địa phương
fn local_time(day: NaiveDate, mmdd: &str, hms: &str) -> Option<DateTime<Local>> {
    let month: u32 = mmdd.get(0..2)?.parse().ok()?;
    let dom: u32 = mmdd.get(2..4)?.parse().ok()?;
    let date = NaiveDate::from_ymd_opt(day.year(), month, dom)?;
    let time = chrono::NaiveTime::parse_from_str(hms, "%H:%M:%S").ok()?;
    Local
        .from_local_datetime(&NaiveDateTime::new(date, time))
        .single()
}

/// `1h23m31s` → giây
fn parse_duration_secs(text: &str) -> i64 {
    let re = Regex::new(r"(?:(\d+)h)?(?:(\d+)m)?(?:([\d.]+)s)?").ok();
    let Some(caps) = re.and_then(|r| r.captures(text)) else {
        return 0;
    };
    let h: i64 = caps
        .get(1)
        .and_then(|m| m.as_str().parse().ok())
        .unwrap_or(0);
    let m: i64 = caps
        .get(2)
        .and_then(|m| m.as_str().parse().ok())
        .unwrap_or(0);
    let s: f64 = caps
        .get(3)
        .and_then(|m| m.as_str().parse().ok())
        .unwrap_or(0.0);
    h * 3600 + m * 60 + s.ceil() as i64
}

/// Nội dung yêu cầu gần nhất của user trong transcript (bỏ phần metadata bọc quanh)
fn last_user_request(transcript: &Path) -> Option<String> {
    let text = fs::read_to_string(transcript).ok()?;
    let line = text
        .lines()
        .rev()
        .find(|l| l.contains("\"type\":\"USER_INPUT\""))?;
    let value: serde_json::Value = serde_json::from_str(line).ok()?;
    let content = value.get("content")?.as_str()?;
    let body = match (
        content.find("<USER_REQUEST>"),
        content.find("</USER_REQUEST>"),
    ) {
        (Some(s), Some(e)) if e > s => &content[s + "<USER_REQUEST>".len()..e],
        _ => content,
    };
    let trimmed = body.trim();
    (!trimmed.is_empty()).then(|| trimmed.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_reset_durations() {
        assert_eq!(parse_duration_secs("1h23m31s"), 3600 + 23 * 60 + 31);
        assert_eq!(parse_duration_secs("45m"), 45 * 60);
        assert_eq!(parse_duration_secs("30s"), 30);
        assert_eq!(parse_duration_secs(""), 0);
    }

    #[test]
    fn local_time_uses_file_year_and_line_date() {
        let day = NaiveDate::from_ymd_opt(2026, 11, 19).unwrap();
        let at = local_time(day, "1119", "06:49:50").unwrap();
        assert_eq!(
            at.format("%Y-%m-%d %H:%M:%S").to_string(),
            "2026-11-19 06:49:50"
        );
    }

    #[test]
    fn extracts_user_request_from_wrapper() {
        let dir = std::env::temp_dir().join(format!("quota-stall-test-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("transcript.jsonl");
        fs::write(
            &path,
            "{\"type\":\"USER_INPUT\",\"content\":\"<USER_REQUEST>\\nlàm đi\\n</USER_REQUEST>\\n<ADDITIONAL_METADATA>x</ADDITIONAL_METADATA>\"}\n",
        )
        .unwrap();
        assert_eq!(last_user_request(&path).as_deref(), Some("làm đi"));
        let _ = fs::remove_dir_all(&dir);
    }
}
