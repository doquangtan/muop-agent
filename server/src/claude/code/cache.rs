use super::*;

/// Metadata session Claude (không bước, lanes, lệnh) từ chỉ mục SQLite. Đọc chỉ mục nếu file đổi.
pub(super) fn load_meta(path: &Path, _fp: (u64, u64)) -> Option<(ConversationSession, usize)> {
    meta_indexed(path)
}

/// Session đầy đủ cho chi tiết và lanes (tối đa `TAIL_STEPS` bước cuối). Dựng từ chỉ mục, không giữ trong RAM.
pub(super) fn load_full(path: &Path, _fp: (u64, u64)) -> Option<ConversationSession> {
    session_indexed(path, false, true, TAIL_STEPS).map(|(session, _)| session)
}
