use super::*;

/// Trạng thái đường dẫn LSP của một ngôn ngữ, để hiển thị trong màn cài đặt
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LspStatus {
    pub language: String,
    pub label: String,
    /// Đường dẫn người dùng đã đặt (rỗng nếu không đặt)
    pub configured_path: String,
    /// Đường dẫn tự dò được (rỗng nếu không tìm thấy)
    pub detected_path: String,
    /// Đường dẫn đang dùng thực tế
    pub effective_path: String,
    /// `config` | `auto` | `none`
    pub source: String,
    pub available: bool,
    /// Ghi chú cho người dùng (ví dụ đường dẫn đã lưu nhưng không chạy được)
    pub note: String,
}

pub fn status(lang: Lang) -> LspStatus {
    let saved = crate::infra::store::get_lsp_path(lang.key()).unwrap_or_default();
    let mut note = String::new();
    let configured = if saved.is_empty() {
        String::new()
    } else if runs(lang, Path::new(&saved)) {
        saved.clone()
    } else {
        note =
            format!("Đường dẫn đã lưu không chạy được ({saved}), đang dùng đường dẫn tự dò nếu có");
        String::new()
    };
    let detected = candidate_paths(lang)
        .into_iter()
        .find(|p| is_executable(p) && runs(lang, p))
        .map(|p| p.to_string_lossy().to_string())
        .unwrap_or_default();
    let (effective, source) = if !configured.is_empty() {
        (configured.clone(), "config")
    } else if !detected.is_empty() {
        (detected.clone(), "auto")
    } else {
        (String::new(), "none")
    };
    LspStatus {
        language: lang.key().to_string(),
        label: lang.label().to_string(),
        configured_path: configured,
        detected_path: detected,
        available: !effective.is_empty(),
        effective_path: effective,
        source: source.to_string(),
        note,
    }
}

pub fn all_status() -> Vec<LspStatus> {
    Lang::ALL.into_iter().map(status).collect()
}

/// Đường dẫn thực thi đang dùng cho một ngôn ngữ (cấu hình trước, rồi tự dò)
pub(super) fn effective_exe(lang: Lang) -> Option<PathBuf> {
    let st = status(lang);
    if st.effective_path.is_empty() {
        None
    } else {
        Some(PathBuf::from(st.effective_path))
    }
}

// ---------------------------------------------------------------------------
// Giao thức JSON-RPC
// ---------------------------------------------------------------------------
