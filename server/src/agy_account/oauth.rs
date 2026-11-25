//! Email và quota của agy lấy trực tiếp từ token OAuth trong thư mục dữ liệu agy, không cần hub.
//!
//! Lý do: trên macOS (server chạy qua SSH) hub không đọc được token, dù CLI đọc được
//! (`error getting token source: You are not logged into Antigravity`). Token nằm trong
//! `~/.gemini/antigravity/antigravity-oauth-token` (cùng thư mục với `chat::AGY_APP_DATA_ARG`):
//! - email: `id_token_email`;
//! - quota: `POST …/v1internal:retrieveUserQuotaSummary` với `Authorization: Bearer <access_token>`.
//!   Phải gửi `User-Agent: antigravity`, nếu không Google trả 403 `SUBSCRIPTION_REQUIRED`.
//!
//! Access token hết hạn sau khoảng 1 giờ. Khi sắp hết hạn, hỏi agy qua ACP (CLI tự làm mới token
//! khi dùng) rồi đọc lại file. Đây là API nội bộ, không có trong tài liệu chính thức nên có thể đổi.

use crate::models::ModelQuotaGroup;
use chrono::{DateTime, Duration as ChronoDuration, FixedOffset, Utc};
use serde_json::Value;
use std::path::PathBuf;
use std::process::{Command, Stdio};

const QUOTA_URL: &str =
    "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary";
/// Thư mục dữ liệu agy của server, tương đối so với `$HOME` (khớp `chat::AGY_APP_DATA_ARG`)
const DATA_DIR_REL: &str = ".gemini/antigravity";
const TOKEN_FILE: &str = "antigravity-oauth-token";
/// Làm mới khi còn ít hơn khoảng này trước khi hết hạn
const EXPIRY_MARGIN_SECS: i64 = 120;

struct OAuthToken {
    access_token: String,
    expiry: DateTime<FixedOffset>,
    email: String,
}

/// Email và quota lấy từ token (không qua hub)
pub fn account() -> Result<(String, Vec<ModelQuotaGroup>), String> {
    let token = load_fresh_token()?;
    let quota = fetch_quota(&token.access_token)?;
    Ok((token.email, quota))
}

/// Email của tài khoản đang đăng nhập, đọc từ log của agy (thư mục dữ liệu `~/.gemini/antigravity/log`).
/// agy ghi `applyAuthResult: email=<email>` mỗi khi xác thực thành công, nên dùng được khi token không nằm trong
/// file (Linux: token trong keyring). Chỉ gọi khi `agy acp` đã báo đăng nhập, để email là của tài khoản hiện tại.
pub fn email_from_logs() -> Option<String> {
    let home = crate::infra::paths::home_dir();
    let dir = home.join(DATA_DIR_REL).join("log");
    let mut files: Vec<(std::time::SystemTime, PathBuf)> = std::fs::read_dir(dir)
        .ok()?
        .flatten()
        .filter_map(|e| {
            let path = e.path();
            let modified = e.metadata().ok()?.modified().ok()?;
            Some((modified, path))
        })
        .collect();
    files.sort_by(|a, b| b.0.cmp(&a.0));
    // File mới nhất có thể là lần chạy không đăng nhập: lấy file gần nhất có dòng xác thực
    for (_, path) in files.iter().take(20) {
        if let Some(email) = std::fs::read(path)
            .ok()
            .and_then(|bytes| last_email(&tail(&bytes, LOG_TAIL_BYTES)))
        {
            return Some(email);
        }
    }
    None
}

/// Bytes cuối của log cần đọc (log có thể dài, dòng xác thực thường nằm gần cuối)
const LOG_TAIL_BYTES: usize = 1024 * 1024;

fn tail(bytes: &[u8], max: usize) -> String {
    let start = bytes.len().saturating_sub(max);
    String::from_utf8_lossy(&bytes[start..]).into_owned()
}

/// Email ở dòng xác thực cuối cùng trong log: `applyAuthResult: email=<email>` hoặc
/// `authenticated successfully as <email>`
fn last_email(text: &str) -> Option<String> {
    const KEYS: [&str; 2] = ["applyAuthResult: email=", "authenticated successfully as "];
    let mut found = None;
    for line in text.lines() {
        for key in KEYS {
            if let Some(pos) = line.find(key) {
                let email: String = line[pos + key.len()..]
                    .chars()
                    .take_while(|c| !c.is_whitespace() && *c != ',')
                    .collect();
                if email.contains('@') {
                    found = Some(email);
                }
            }
        }
    }
    found
}

fn token_path() -> PathBuf {
    crate::infra::paths::home_dir()
        .join(DATA_DIR_REL)
        .join(TOKEN_FILE)
}

fn read_token() -> Result<OAuthToken, String> {
    let path = token_path();
    let raw = std::fs::read_to_string(&path)
        .map_err(|_| format!("Không đọc được token agy ({})", path.display()))?;
    let v: Value =
        serde_json::from_str(&raw).map_err(|_| "Token agy không phải JSON".to_string())?;
    let token = v.get("token").ok_or("Token agy thiếu mục token")?;
    let access_token = token
        .get("access_token")
        .and_then(Value::as_str)
        .ok_or("Token agy thiếu access_token")?
        .to_string();
    let expiry = token
        .get("expiry")
        .and_then(Value::as_str)
        .and_then(|s| DateTime::parse_from_rfc3339(s).ok())
        .ok_or("Token agy thiếu hạn sử dụng")?;
    let email = v
        .get("id_token_email")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    Ok(OAuthToken {
        access_token,
        expiry,
        email,
    })
}

fn is_fresh(token: &OAuthToken) -> bool {
    token.expiry.with_timezone(&Utc) - ChronoDuration::seconds(EXPIRY_MARGIN_SECS) > Utc::now()
}

/// Token còn hạn; nếu sắp hết hạn thì nhờ CLI làm mới rồi đọc lại
fn load_fresh_token() -> Result<OAuthToken, String> {
    let token = read_token()?;
    if is_fresh(&token) {
        return ensure_email(token);
    }
    refresh_by_acp();
    let token = read_token()?;
    if !is_fresh(&token) {
        return Err("Token agy đã hết hạn, cần mở agy để làm mới".into());
    }
    ensure_email(token)
}

fn ensure_email(token: OAuthToken) -> Result<OAuthToken, String> {
    if token.email.is_empty() {
        return Err("Token agy không có email".into());
    }
    Ok(token)
}

/// Làm mới token bằng ACP (`agy acp`): CLI dùng token hiện tại và làm mới khi cần. Kết quả không quan trọng;
/// việc có làm mới được hay không được kiểm tra bằng hạn trong file token.
fn refresh_by_acp() {
    let _ = crate::agy_auth::acp::touch_auth();
}

/// Gọi `RetrieveUserQuotaSummary` qua API của Google. Dùng curl để không bật TLS trong reqwest.
/// Token đi qua stdin (`-K -`), không lộ trên dòng lệnh.
fn fetch_quota(access_token: &str) -> Result<Vec<ModelQuotaGroup>, String> {
    // Token được ghép vào file cấu hình của curl: chỉ nhận ký tự an toàn
    let token_ok = !access_token.is_empty()
        && access_token
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'));
    if !token_ok {
        return Err("Token agy có ký tự không hợp lệ".into());
    }
    let config = format!(
        "url = \"{QUOTA_URL}\"\n\
         request = \"POST\"\n\
         header = \"Authorization: Bearer {access_token}\"\n\
         header = \"Content-Type: application/json\"\n\
         user-agent = \"antigravity\"\n\
         data = \"{{}}\"\n"
    );
    let mut child = Command::new("curl")
        .args(["-s", "-f", "-m", "20", "-K", "-"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| format!("Không chạy được curl: {e}"))?;
    if let Some(mut stdin) = child.stdin.take() {
        use std::io::Write;
        let _ = stdin.write_all(config.as_bytes());
    }
    let out = child
        .wait_with_output()
        .map_err(|e| format!("Lỗi chờ curl: {e}"))?;
    if !out.status.success() {
        return Err("Không gọi được API quota của agy".into());
    }
    let body: Value =
        serde_json::from_slice(&out.stdout).map_err(|_| "API quota trả về không phải JSON")?;
    crate::scanner::parse_quota_groups(&body).ok_or_else(|| "API quota không có nhóm quota".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn last_email_takes_latest_auth_line() {
        let log = "I1 server_oauth.go:221] applyAuthResult: email=old@x.com, authMethod=consumer\n\
                   I2 keyring loaded\n\
                   I3 server_oauth.go:221] applyAuthResult: email=new@y.vn, authMethod=consumer\n";
        assert_eq!(last_email(log).as_deref(), Some("new@y.vn"));
    }

    #[test]
    fn last_email_none_without_auth_line() {
        assert_eq!(
            last_email("You are not logged into Antigravity\nAuth succeeded"),
            None
        );
    }

    #[test]
    fn last_email_reads_oauth_success_line() {
        let log = "consumerOAuth: authenticated successfully as johndylan1995@gmail.com\n";
        assert_eq!(last_email(log).as_deref(), Some("johndylan1995@gmail.com"));
    }

    fn token_expiring_in(secs: i64) -> OAuthToken {
        OAuthToken {
            access_token: "ya29.x".into(),
            expiry: (Utc::now() + ChronoDuration::seconds(secs)).fixed_offset(),
            email: "a@b.c".into(),
        }
    }

    #[test]
    fn token_with_margin_left_is_fresh() {
        assert!(is_fresh(&token_expiring_in(3600)));
    }

    #[test]
    fn token_inside_margin_is_not_fresh() {
        assert!(!is_fresh(&token_expiring_in(60)));
        assert!(!is_fresh(&token_expiring_in(-10)));
    }

    #[test]
    fn quota_parser_accepts_direct_api_shape() {
        let v: Value = serde_json::from_str(
            r#"{"groups":[{"displayName":"Claude and GPT models","description":"d",
            "buckets":[{"bucketId":"3p-weekly","displayName":"Weekly","window":"weekly",
            "resetTime":"2026-11-27T06:11:39Z","remainingFraction":0}]}]}"#,
        )
        .unwrap();
        let groups = crate::scanner::parse_quota_groups(&v).expect("có nhóm");
        assert_eq!(groups.len(), 1);
        assert_eq!(groups[0].buckets[0].remaining_percent, 0.0);
        assert_eq!(groups[0].buckets[0].reset_time, "2026-11-27T06:11:39Z");
    }

    #[test]
    fn quota_parser_accepts_hub_response_shape() {
        let v: Value = serde_json::from_str(
            r#"{"response":{"groups":[{"displayName":"G","buckets":[{"remainingFraction":0.5}]}]}}"#,
        )
        .unwrap();
        let groups = crate::scanner::parse_quota_groups(&v).expect("có nhóm");
        assert_eq!(groups[0].buckets[0].remaining_percent, 50.0);
    }
}
