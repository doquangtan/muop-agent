use super::*;

/// Đường dẫn binary `claude`. Ưu tiên biến môi trường `MUOP_CLAUDE_BIN` (dùng khi phát triển),
/// rồi dò bằng `which` hoặc đường dẫn người dùng đã chọn trong Khởi tạo.
pub fn claude_bin() -> Result<String, String> {
    if let Ok(p) = std::env::var("MUOP_CLAUDE_BIN") {
        if !p.trim().is_empty() {
            return Ok(p.trim().to_string());
        }
    }
    crate::infra::tools::require("claude")
}

/// Model mặc định của Claude Code CLI (ID đầy đủ có version)
pub const CLAUDE_DEFAULT_MODEL: &str = "claude-sonnet-5-5";

pub(super) const EFFORT_CACHE_TTL: Duration = Duration::from_secs(600);
pub(super) const EFFORT_RETRY_TTL: Duration = Duration::from_secs(60);

pub(super) static EFFORT_CACHE: Mutex<Option<(Instant, Vec<String>)>> = Mutex::new(None);

/// Đọc danh sách mức suy nghĩ (`--effort`) từ dòng trợ giúp của CLI `claude`, ví dụ
/// `(low, medium, high, xhigh, max)`. Không khai báo cứng: CLI thêm/bớt mức thì app tự theo.
/// Trả về rỗng nếu không chạy được CLI; khi đó model không có hậu tố mức.
pub fn effort_levels() -> Vec<String> {
    if let Ok(guard) = EFFORT_CACHE.lock() {
        if let Some((at, levels)) = guard.as_ref() {
            let ttl = if levels.is_empty() {
                EFFORT_RETRY_TTL
            } else {
                EFFORT_CACHE_TTL
            };
            if at.elapsed() < ttl {
                return levels.clone();
            }
        }
    }
    let levels = claude_bin()
        .ok()
        .and_then(|bin| Command::new(bin).arg("--help").output().ok())
        .map(|out| parse_effort_levels(&String::from_utf8_lossy(&out.stdout)))
        .unwrap_or_default();
    if let Ok(mut guard) = EFFORT_CACHE.lock() {
        *guard = Some((Instant::now(), levels.clone()));
    }
    levels
}

/// Tách danh sách mức từ nội dung `claude --help`
pub fn parse_effort_levels(help: &str) -> Vec<String> {
    let Some(pos) = help.find("--effort <level>") else {
        return Vec::new();
    };
    let tail = &help[pos..];
    let Some(open) = tail.find('(') else {
        return Vec::new();
    };
    // Dấu ngoặc phải nằm trong mô tả của đúng tuỳ chọn --effort
    if open > 300 {
        return Vec::new();
    }
    let Some(close) = tail[open..].find(')') else {
        return Vec::new();
    };
    tail[open + 1..open + close]
        .split(',')
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty() && s.chars().all(|c| c.is_ascii_lowercase()))
        .collect()
}

/// Id model Claude phát cho UI: `claude-cli:<model>-<mức>` cho từng mức CLI hỗ trợ,
/// hoặc `claude-cli:<model>` nếu không đọc được mức nào. Danh sách model lấy từ API (xem `claude_base_models`).
pub fn claude_model_ids() -> Vec<String> {
    let levels = effort_levels();
    let mut ids = Vec::new();
    for base in claude_base_models() {
        if levels.is_empty() {
            ids.push(format!("claude-cli:{base}"));
        } else {
            for level in &levels {
                ids.push(format!("claude-cli:{base}-{level}"));
            }
        }
    }
    ids
}

/// Tách hậu tố mức suy nghĩ khỏi id model: `claude-sonnet-5-5-high` → (`claude-sonnet-5-5`, Some(`high`))
pub fn split_effort(model: &str) -> (String, Option<String>) {
    split_effort_with(model, &effort_levels())
}

/// Tách hậu tố mức khỏi id model theo danh sách mức đã biết (hàm thuần, không gọi CLI)
pub fn split_effort_with(model: &str, levels: &[String]) -> (String, Option<String>) {
    for level in levels {
        if let Some(base) = model.strip_suffix(&format!("-{level}")) {
            if !base.is_empty() {
                return (base.to_string(), Some(level.clone()));
            }
        }
    }
    (model.to_string(), None)
}

/// Chuẩn hoá tên model gửi xuống CLI.
/// Alias ngắn (`sonnet`/`opus`/`haiku`) được ánh xạ sang ID đầy đủ có version,
/// vì CLI tự phân giải alias sang bản model cũ (vd. `haiku` → claude-haiku-4-5).
/// Rỗng, `default` hoặc model cũ của Antigravity (gemini-*) → model mặc định.
pub fn normalize_model(raw: &str) -> String {
    let m = raw.trim();
    match m {
        "" | "default" => CLAUDE_DEFAULT_MODEL.to_string(),
        "sonnet" => "claude-sonnet-5-5".to_string(),
        "opus" => "claude-opus-5-5".to_string(),
        "haiku" => "claude-haiku-5-5".to_string(),
        _ if m.starts_with("gemini") => CLAUDE_DEFAULT_MODEL.to_string(),
        _ => m.to_string(),
    }
}

#[cfg(test)]
mod effort_tests {
    use super::*;

    #[test]
    fn parses_effort_levels_from_help() {
        let help = "  --effort <level>                      Effort level for the current session\n                                        (low, medium, high, xhigh, max)\n  --environment <environment_id>        Create a new cloud session";
        assert_eq!(
            parse_effort_levels(help),
            vec!["low", "medium", "high", "xhigh", "max"]
        );
    }

    #[test]
    fn missing_option_gives_no_levels() {
        assert!(parse_effort_levels("  --model <model>  Model").is_empty());
    }

    #[test]
    fn ignores_parenthesis_far_from_effort_option() {
        let help = format!(
            "  --effort <level>  Effort level\n{}\n(low, high)",
            "x".repeat(400)
        );
        assert!(parse_effort_levels(&help).is_empty());
    }
}

// ---------------------------------------------------------------------------
// Danh sách model lấy từ API Anthropic (không hardcode)
// ---------------------------------------------------------------------------

const CLAUDE_MODELS_URL: &str = "https://api.anthropic.com/v1/models?limit=100";
const CLAUDE_MODELS_TTL: Duration = Duration::from_secs(600);
const CLAUDE_MODELS_EMPTY_TTL: Duration = Duration::from_secs(60);

static CLAUDE_MODELS_CACHE: std::sync::Mutex<Option<(Instant, Vec<String>, Duration)>> =
    std::sync::Mutex::new(None);

/// Model gốc của Claude (ID đầy đủ có version, không kèm mức), lấy từ `GET /v1/models` bằng token OAuth của
/// Claude Code CLI. Chưa đăng nhập, không đọc được token hoặc API lỗi thì trả về rỗng (không có model Claude).
/// Kết quả được cache: 10 phút khi có dữ liệu, 1 phút khi rỗng.
pub fn claude_base_models() -> Vec<String> {
    if let Ok(guard) = CLAUDE_MODELS_CACHE.lock() {
        if let Some((at, ids, ttl)) = guard.as_ref() {
            if at.elapsed() < *ttl {
                return ids.clone();
            }
        }
    }
    let ids = fetch_claude_base_models().unwrap_or_default();
    let ttl = if ids.is_empty() {
        CLAUDE_MODELS_EMPTY_TTL
    } else {
        CLAUDE_MODELS_TTL
    };
    if let Ok(mut guard) = CLAUDE_MODELS_CACHE.lock() {
        *guard = Some((Instant::now(), ids.clone(), ttl));
    }
    ids
}

fn fetch_claude_base_models() -> Option<Vec<String>> {
    let token = claude_oauth_token()?;
    // curl thay vì reqwest: reqwest của dự án không bật TLS. Token đi qua stdin (`-K -`), không lộ trên dòng lệnh.
    let config = format!(
        "url = \"{CLAUDE_MODELS_URL}\"\n\
         header = \"Authorization: Bearer {token}\"\n\
         header = \"anthropic-version: 2023-06-01\"\n\
         header = \"anthropic-beta: oauth-2025-04-20\"\n"
    );
    let mut child = std::process::Command::new("curl")
        .args(["-s", "-f", "-m", "10", "-K", "-"])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn()
        .ok()?;
    if let Some(mut stdin) = child.stdin.take() {
        use std::io::Write;
        let _ = stdin.write_all(config.as_bytes());
    }
    let out = child.wait_with_output().ok()?;
    if !out.status.success() {
        return None;
    }
    let body: Value = serde_json::from_slice(&out.stdout).ok()?;
    Some(parse_claude_model_ids(&body))
}

/// Access token OAuth của Claude Code CLI. Trên macOS CLI giữ token thật trong Keychain (mục
/// "Claude Code-credentials"); file `~/.claude/.credentials.json` là bản sao không được CLI ghi lại khi làm mới,
/// nên hết hạn sớm (đã gặp: 401 trên Mac trong khi CLI vẫn đăng nhập). Thử Keychain trước, rồi file;
/// token hết hạn hoặc không hợp lệ thì bỏ qua. Keychain khóa (ví dụ phiên SSH) thì không đọc được và dùng file.
fn claude_oauth_token() -> Option<String> {
    let mut sources = Vec::new();
    if crate::infra::platform::IS_MACOS {
        sources.extend(keychain_credentials());
    }
    sources.extend(file_credentials());
    sources
        .iter()
        .find_map(|raw| token_from_credentials(raw, chrono::Utc::now().timestamp_millis()))
}

/// Nội dung `.credentials.json` từ file của CLI
fn file_credentials() -> Option<String> {
    let path = crate::infra::paths::home_dir().join(".claude/.credentials.json");
    std::fs::read_to_string(path).ok()
}

/// Nội dung mục Keychain "Claude Code-credentials" (JSON có cùng cấu trúc với file). Lỗi (khóa, không có mục) thì None.
pub(crate) fn keychain_credentials() -> Option<String> {
    let out = std::process::Command::new("security")
        .args([
            "find-generic-password",
            "-s",
            "Claude Code-credentials",
            "-w",
        ])
        .stdin(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    String::from_utf8(out.stdout).ok()
}

/// Lấy access token còn hạn từ nội dung credentials (hàm thuần; `now_ms` là thời điểm hiện tại tính bằng ms)
pub(crate) fn token_from_credentials(raw: &str, now_ms: i64) -> Option<String> {
    let v: Value = serde_json::from_str(raw.trim()).ok()?;
    let oauth = v.get("claudeAiOauth")?;
    let token = oauth.get("accessToken")?.as_str()?.to_string();
    let expires_ms = oauth.get("expiresAt")?.as_i64()?;
    // Token được ghép vào file cấu hình của curl: chỉ nhận ký tự an toàn
    let token_ok = !token.is_empty()
        && token
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'));
    if expires_ms <= now_ms || !token_ok {
        return None;
    }
    Some(token)
}

/// Lọc phản hồi `GET /v1/models`: chỉ id `claude-*`, bỏ bản ghi có hậu tố ngày (`-20251101`, trùng alias), giữ thứ tự, bỏ trùng
pub(crate) fn parse_claude_model_ids(body: &Value) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let Some(data) = body.get("data").and_then(Value::as_array) else {
        return out;
    };
    for item in data {
        let Some(id) = item.get("id").and_then(Value::as_str) else {
            continue;
        };
        if !id.starts_with("claude-") || is_dated_snapshot(id) {
            continue;
        }
        if !out.iter().any(|x| x == id) {
            out.push(id.to_string());
        }
    }
    // Từ cao xuống thấp: phiên bản mới nhất trước, cùng phiên bản thì tên giảm dần
    out.sort_by(|a, b| {
        claude_version_key(b)
            .cmp(&claude_version_key(a))
            .then_with(|| b.cmp(a))
    });
    out
}

/// Các số trong id model, ví dụ `claude-opus-4-8` → [4, 8]. Dùng để sắp xếp từ cao xuống thấp.
fn claude_version_key(id: &str) -> Vec<u64> {
    id.split('-')
        .filter(|p| !p.is_empty() && p.bytes().all(|b| b.is_ascii_digit()))
        .filter_map(|p| p.parse::<u64>().ok())
        .collect()
}

/// Tên hiển thị của model gốc, suy ra từ id (không cần bảng cố định):
/// `claude-fable-5-2` → `Claude Fable 5.2`
pub fn claude_display_name(base: &str) -> String {
    let rest = base.strip_prefix("claude-").unwrap_or(base);
    let mut family = String::new();
    let mut version: Vec<&str> = Vec::new();
    for part in rest.split('-').filter(|p| !p.is_empty()) {
        if part.bytes().all(|b| b.is_ascii_digit()) {
            version.push(part);
        } else if family.is_empty() {
            let mut chars = part.chars();
            if let Some(first) = chars.next() {
                family = first.to_uppercase().chain(chars).collect();
            }
        }
    }
    let mut name = String::from("Claude");
    if !family.is_empty() {
        name.push(' ');
        name.push_str(&family);
    }
    if !version.is_empty() {
        name.push(' ');
        name.push_str(&version.join("."));
    }
    name
}

/// `claude-sonnet-4-5-20250929`: hậu tố 8 chữ số là bản ghi theo ngày
fn is_dated_snapshot(id: &str) -> bool {
    id.rsplit('-')
        .next()
        .is_some_and(|s| s.len() == 8 && s.bytes().all(|b| b.is_ascii_digit()))
}

#[cfg(test)]
mod claude_model_list_tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn keeps_claude_ids_in_order_and_drops_dated_snapshots() {
        let body = json!({"data": [
            {"id": "claude-sonnet-5-5"},
            {"id": "claude-haiku-4-5-20251001"},
            {"id": "claude-opus-5-5"},
            {"id": "gpt-4o"},
            {"id": "claude-sonnet-5-5"},
            {"type": "model"},
        ]});
        assert_eq!(
            parse_claude_model_ids(&body),
            vec![
                "claude-sonnet-5-5".to_string(),
                "claude-opus-5-5".to_string()
            ]
        );
    }

    #[test]
    fn sorts_newest_version_first() {
        let body = json!({"data": [
            {"id": "claude-opus-4-8"},
            {"id": "claude-fable-5"},
            {"id": "claude-haiku-5-5"},
            {"id": "claude-fable-5-2"},
        ]});
        assert_eq!(
            parse_claude_model_ids(&body),
            vec![
                "claude-haiku-5-5".to_string(),
                "claude-fable-5-2".to_string(),
                "claude-fable-5".to_string(),
                "claude-opus-4-8".to_string(),
            ]
        );
    }

    #[test]
    fn display_name_from_id() {
        assert_eq!(claude_display_name("claude-fable-5-2"), "Claude Fable 5.2");
        assert_eq!(
            claude_display_name("claude-sonnet-5-5"),
            "Claude Sonnet 5.5"
        );
        assert_eq!(claude_display_name("claude-opus-5"), "Claude Opus 5");
    }

    #[test]
    fn missing_data_gives_no_models() {
        assert!(parse_claude_model_ids(&json!({"error": "x"})).is_empty());
    }

    #[test]
    fn dated_suffix_detection() {
        assert!(is_dated_snapshot("claude-opus-4-5-20251101"));
        assert!(!is_dated_snapshot("claude-opus-4-5"));
        assert!(!is_dated_snapshot("claude-fable-5-2"));
    }
}

#[cfg(test)]
mod credential_tests {
    use super::*;

    fn creds(token: &str, expires_ms: i64) -> String {
        format!(r#"{{"claudeAiOauth":{{"accessToken":"{token}","expiresAt":{expires_ms}}}}}"#)
    }

    #[test]
    fn fresh_token_is_used() {
        assert_eq!(
            token_from_credentials(&creds("sk-ant-oat01-abc", 2_000), 1_000).as_deref(),
            Some("sk-ant-oat01-abc")
        );
    }

    #[test]
    fn expired_token_is_rejected() {
        assert_eq!(token_from_credentials(&creds("abc", 1_000), 1_000), None);
        assert_eq!(token_from_credentials(&creds("abc", 500), 1_000), None);
    }

    #[test]
    fn unsafe_token_chars_are_rejected() {
        assert_eq!(token_from_credentials(&creds("a b", 2_000), 1_000), None);
        assert_eq!(token_from_credentials(&creds("a\"b", 2_000), 1_000), None);
    }

    #[test]
    fn bad_json_is_rejected() {
        assert_eq!(token_from_credentials("not json", 1_000), None);
        assert_eq!(token_from_credentials("{}", 1_000), None);
    }
}
