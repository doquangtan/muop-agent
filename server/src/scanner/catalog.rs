use super::*;

/// Danh sách model gửi xuống UI. Id có tiền tố provider để chọn đúng backend:
/// - `agy:<model>` → Antigravity CLI (`agy`)
/// - `claude-cli:<model-id>` → Claude Code CLI (`claude --model <model-id>`, ID đầy đủ có version)
pub fn default_models() -> Vec<String> {
    // Model Claude chỉ hiện khi Claude Code CLI đã đăng nhập: chưa đăng nhập thì chọn sẽ không chạy được
    let mut models = if claude_cli_logged_in() {
        crate::claude::code::claude_model_ids()
    } else {
        Vec::new()
    };
    models.extend(agy_model_ids());
    models
}

/// Trạng thái đăng nhập Claude Code CLI, cache ngắn để không gọi `claude auth status` ở mỗi snapshot
static CLAUDE_LOGIN_CACHE: std::sync::Mutex<Option<(std::time::Instant, bool)>> =
    std::sync::Mutex::new(None);
const CLAUDE_LOGIN_TTL: Duration = Duration::from_secs(30);

fn claude_cli_logged_in() -> bool {
    if let Ok(guard) = CLAUDE_LOGIN_CACHE.lock() {
        if let Some((at, logged_in)) = guard.as_ref() {
            if at.elapsed() < CLAUDE_LOGIN_TTL {
                return *logged_in;
            }
        }
    }
    // Không đọc được CLI (chưa cài, lỗi) thì coi như chưa đăng nhập
    let logged_in = crate::claude_auth::status()
        .map(|view| view.logged_in)
        .unwrap_or(false);
    if let Ok(mut guard) = CLAUDE_LOGIN_CACHE.lock() {
        *guard = Some((std::time::Instant::now(), logged_in));
    }
    logged_in
}

pub(super) const AGY_MODELS_TTL: Duration = Duration::from_secs(600);

/// Một model Antigravity lấy từ ACP (`agy acp`): id đầy đủ (`agy:<id>`) và nhãn hiển thị
#[derive(Debug, Clone)]
pub(super) struct AgyModel {
    pub(super) id: String,
    pub(super) label: String,
}

pub(super) struct AgyModelsCache {
    pub(super) fetched_at: Option<Instant>,
    /// Sau khi lấy model lỗi, chỉ thử lại sau mốc này
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

/// Danh sách model của tài khoản hiện tại, hỏi qua ACP (`session/new`, xem `agy_auth::acp::list_models`).
/// Chưa đăng nhập hoặc lỗi thì trả `None`.
pub(super) fn run_agy_models() -> Option<Vec<AgyModel>> {
    let models: Vec<AgyModel> = crate::agy_auth::acp::list_models()
        .ok()?
        .into_iter()
        .map(|(id, label)| AgyModel {
            id: format!("agy:{id}"),
            label,
        })
        .collect();
    (!models.is_empty()).then_some(models)
}

/// Cập nhật cache danh sách model (lấy từ ACP). Danh sách rỗng thì giữ danh sách cũ. Trả về true nếu đã cập nhật.
pub(super) fn set_agy_models(models: Vec<AgyModel>) -> bool {
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

/// Lấy lại danh sách model ngay, bỏ qua TTL. Dùng sau khi đổi tài khoản agy: tài khoản khác có thể có model khác.
/// Lỗi thì giữ danh sách cũ.
pub fn reload_agy_models() {
    if let Some(models) = run_agy_models() {
        set_agy_models(models);
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
    let mut labels: HashMap<String, String> =
        agy_models().into_iter().map(|m| (m.id, m.label)).collect();
    // Nhãn model Claude suy ra từ id (không bảng cố định); khóa là id đầy đủ có mức suy luận
    for id in crate::claude::code::claude_model_ids() {
        let model = id.strip_prefix("claude-cli:").unwrap_or(&id);
        let (base, _) = crate::claude::code::split_effort(model);
        labels.insert(id.clone(), crate::claude::code::claude_display_name(&base));
    }
    labels
}

pub fn default_agents() -> Vec<String> {
    vec!["Coordinator".to_string()]
}

#[cfg(test)]
mod refresh_tests {
    use super::*;

    #[test]
    fn set_models_replaces_cache_and_ignores_empty_list() {
        assert!(!set_agy_models(Vec::new()));
        assert!(set_agy_models(vec![AgyModel {
            id: "agy:gemini-test-x".to_string(),
            label: "Gemini Test X".to_string(),
        }]));
        let ids: Vec<String> = agy_models().into_iter().map(|m| m.id).collect();
        assert_eq!(ids, vec!["agy:gemini-test-x".to_string()]);
    }
}
