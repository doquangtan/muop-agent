use super::*;

/// Đường dẫn binary `claude`. Ưu tiên biến môi trường `MUOP_CLAUDE_BIN`,
/// sau đó các vị trí cài đặt phổ biến, cuối cùng là tìm trong PATH.
pub fn claude_bin() -> String {
    if let Ok(p) = std::env::var("MUOP_CLAUDE_BIN") {
        if !p.trim().is_empty() {
            return p.trim().to_string();
        }
    }
    let home = home_dir();
    let candidates = [
        home.join(".local/bin/claude"),
        home.join(".nvm/versions/node/v22.21.1/bin/claude"),
        PathBuf::from("/usr/local/bin/claude"),
    ];
    for c in candidates.iter() {
        // `exists()` trả về false với symlink hỏng nên các đường dẫn hỏng sẽ bị bỏ qua
        if c.exists() {
            return c.to_string_lossy().to_string();
        }
    }
    "claude".to_string()
}

/// Model mặc định của Claude Code CLI (ID đầy đủ có version)
pub const CLAUDE_DEFAULT_MODEL: &str = "claude-sonnet-5-5";

/// Các model gốc của Claude Code (ID đầy đủ có version). Mức suy nghĩ được gắn thêm bằng hậu tố.
pub const CLAUDE_BASE_MODELS: [&str; 3] =
    ["claude-sonnet-5-5", "claude-opus-5-5", "claude-haiku-5-5"];

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
    let levels = Command::new(claude_bin())
        .arg("--help")
        .output()
        .ok()
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
/// hoặc `claude-cli:<model>` nếu không đọc được mức nào
pub fn claude_model_ids() -> Vec<String> {
    let levels = effort_levels();
    let mut ids = Vec::new();
    for base in CLAUDE_BASE_MODELS {
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
    let levels = effort_levels();
    for level in &levels {
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
