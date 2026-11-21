use super::*;

/// Danh sách model gửi xuống UI. Id có tiền tố provider để chọn đúng backend:
/// - `agy:<model>` → Antigravity CLI (`agy`)
/// - `claude-cli:<model-id>` → Claude Code CLI (`claude --model <model-id>`, ID đầy đủ có version)
pub fn default_models() -> Vec<String> {
    let mut models = crate::claude::code::claude_model_ids();
    models.extend(agy_model_ids());
    models
}

pub(super) const AGY_MODELS_TTL: Duration = Duration::from_secs(600);

/// Một model Antigravity lấy từ `agy models`: id đầy đủ (`agy:<id>`) và nhãn hiển thị
#[derive(Debug, Clone)]
pub(super) struct AgyModel {
    pub(super) id: String,
    pub(super) label: String,
}

pub(super) struct AgyModelsCache {
    pub(super) fetched_at: Option<Instant>,
    /// Sau khi `agy models` lỗi, chỉ thử lại sau mốc này
    pub(super) retry_at: Option<Instant>,
    pub(super) models: Vec<AgyModel>,
    pub(super) refreshing: bool,
}

pub(super) static AGY_MODELS: OnceLock<Mutex<AgyModelsCache>> = OnceLock::new();

pub(super) fn agy_models_cache() -> &'static Mutex<AgyModelsCache> {
    AGY_MODELS.get_or_init(|| {
        Mutex::new(AgyModelsCache {
            fetched_at: None,
            retry_at: None,
            models: Vec::new(),
            refreshing: false,
        })
    })
}

/// Đọc output của `agy models` (mỗi dòng `<id>\t<tên hiển thị>`)
pub(super) fn parse_agy_models(output: &str) -> Vec<AgyModel> {
    output
        .lines()
        .filter_map(|line| {
            let (id, label) = line.split_once('\t')?;
            let id = id.trim();
            let valid = !id.is_empty()
                && id
                    .chars()
                    .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '.' | '_'));
            valid.then(|| AgyModel {
                id: format!("agy:{}", id),
                label: label.trim().to_string(),
            })
        })
        .collect()
}

pub(super) fn run_agy_models() -> Option<Vec<AgyModel>> {
    let output = Command::new(crate::chat::agy_bin())
        .arg("models")
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let models = parse_agy_models(&String::from_utf8_lossy(&output.stdout));
    (!models.is_empty()).then_some(models)
}

/// Cập nhật danh sách model từ output của `agy models` vừa chạy (mỗi lần kiểm tra đăng nhập).
/// Output không có dòng model (chưa đăng nhập, lỗi) thì giữ danh sách cũ. Trả về true nếu đã cập nhật.
pub fn refresh_agy_models(output: &str) -> bool {
    let models = parse_agy_models(output);
    if models.is_empty() {
        return false;
    }
    match agy_models_cache().lock() {
        Ok(mut cache) => {
            cache.models = models;
            cache.fetched_at = Some(Instant::now());
            cache.retry_at = None;
            true
        }
        Err(_) => false,
    }
}

/// Chờ lần lấy đầu tiên, hoặc tự lấy ngay nếu chưa có ai lấy. Nếu không có cái này, `meta` gửi ngay sau khi
/// server khởi động sẽ thiếu model agy (cache còn rỗng, lần lấy chỉ chạy nền): app nhận danh sách thiếu và
/// không hỏi lại. Giới hạn 15 giây chờ; lỗi thì đợi `retry_at` (1 phút) như đường nền.
fn wait_or_fetch_first() {
    let started = Instant::now();
    loop {
        let claimed = match agy_models_cache().lock() {
            Ok(mut cache) => {
                if cache.fetched_at.is_some() || cache.retry_at.is_some_and(|t| Instant::now() < t)
                {
                    return;
                }
                if cache.refreshing {
                    false
                } else {
                    cache.refreshing = true;
                    true
                }
            }
            Err(_) => return,
        };
        if claimed {
            let fetched = run_agy_models();
            if let Ok(mut cache) = agy_models_cache().lock() {
                match fetched {
                    Some(models) => {
                        cache.models = models;
                        cache.fetched_at = Some(Instant::now());
                        cache.retry_at = None;
                    }
                    None => cache.retry_at = Some(Instant::now() + Duration::from_secs(60)),
                }
                cache.refreshing = false;
            }
            return;
        }
        if started.elapsed() >= Duration::from_secs(15) {
            return;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
}

/// Danh sách model Antigravity lấy từ `agy models`. Trả về ngay bản đã cache (rỗng nếu chưa lấy được),
/// và làm mới nền khi cache quá 10 phút, để không chặn snapshot khi CLI chậm.
pub(super) fn agy_models() -> Vec<AgyModel> {
    wait_or_fetch_first();
    let Ok(mut cache) = agy_models_cache().lock() else {
        return Vec::new();
    };
    let now = Instant::now();
    let stale = cache
        .fetched_at
        .map(|t| now.duration_since(t) >= AGY_MODELS_TTL)
        .unwrap_or(true);
    let retry_ok = cache.retry_at.map(|t| now >= t).unwrap_or(true);
    if stale && retry_ok && !cache.refreshing {
        cache.refreshing = true;
        crate::infra::jobs::submit("agy-models", || {
            let fetched = run_agy_models();
            if let Ok(mut cache) = agy_models_cache().lock() {
                match fetched {
                    Some(models) => {
                        cache.models = models;
                        cache.fetched_at = Some(Instant::now());
                        cache.retry_at = None;
                    }
                    // Lỗi: giữ danh sách cũ và chỉ thử lại sau 1 phút
                    None => cache.retry_at = Some(Instant::now() + Duration::from_secs(60)),
                }
                cache.refreshing = false;
            }
        });
    }
    cache.models.clone()
}

/// Id model Antigravity hiện có (`agy:<id>`), dùng cho lượt chat khi chưa chọn model
pub fn agy_model_ids() -> Vec<String> {
    agy_models().into_iter().map(|m| m.id).collect()
}

/// Context đang dùng của một conversation agy (kèm model đã tạo ra lượt gần nhất)
pub(super) fn agy_context_for(
    conversation_id: &str,
    conversation_updated_at: &str,
) -> crate::chat::context_window::AgyContextUsage {
    let label_to_id: HashMap<String, String> =
        agy_models().into_iter().map(|m| (m.label, m.id)).collect();
    crate::chat::context_window::agy_context_usage(
        conversation_id,
        &label_to_id,
        conversation_updated_at,
    )
    .unwrap_or_default()
}

/// Nhãn hiển thị của mọi model, key là id đầy đủ (ví dụ `agy:gemini-4-argon-medium`)
pub fn model_labels() -> HashMap<String, String> {
    agy_models().into_iter().map(|m| (m.id, m.label)).collect()
}

pub fn default_agents() -> Vec<String> {
    vec!["Coordinator".to_string()]
}

#[cfg(test)]
mod refresh_tests {
    use super::*;

    #[test]
    fn refresh_replaces_cached_models_and_ignores_output_without_models() {
        assert!(!refresh_agy_models(
            "Please sign in to view available models."
        ));
        assert!(refresh_agy_models("gemini-test-x\tGemini Test X\n"));
        let ids: Vec<String> = agy_models().into_iter().map(|m| m.id).collect();
        assert_eq!(ids, vec!["agy:gemini-test-x".to_string()]);
    }
}
