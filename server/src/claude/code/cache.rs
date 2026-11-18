use super::*;

/// Cache session đã parse: chỉ giữ `SNAPSHOT_STEP_LIMIT` step cuối để giới hạn RAM.
pub(super) struct CachedSession {
    pub(super) fingerprint: (u64, u64),
    pub(super) session: ConversationSession,
}

pub(super) static CACHE: OnceLock<Mutex<HashMap<PathBuf, CachedSession>>> = OnceLock::new();

pub(super) fn cache() -> &'static Mutex<HashMap<PathBuf, CachedSession>> {
    CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

pub(super) fn trim_for_snapshot(mut session: ConversationSession) -> ConversationSession {
    let total = session.steps.len();
    if total > SNAPSHOT_STEP_LIMIT {
        session.steps = session.steps.split_off(total - SNAPSHOT_STEP_LIMIT);
    }
    session
}

/// Lấy session từ cache nếu file không đổi, ngược lại parse lại.
pub(super) fn load_cached(path: &Path, fp: (u64, u64)) -> Option<ConversationSession> {
    if let Ok(map) = cache().lock() {
        if let Some(entry) = map.get(path) {
            if entry.fingerprint == fp {
                return Some(entry.session.clone());
            }
        }
    }
    let session = trim_for_snapshot(parse_session_file(path, false)?);
    if let Ok(mut map) = cache().lock() {
        map.insert(
            path.to_path_buf(),
            CachedSession {
                fingerprint: fp,
                session: session.clone(),
            },
        );
    }
    Some(session)
}
