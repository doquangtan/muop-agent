use super::*;

/// Số file session tối đa được quét (mới nhất trước)
pub(super) const MAX_SESSION_FILES: usize = 200;
/// Số step tối đa gửi kèm trong snapshot (giống session Antigravity)
pub(super) const SNAPSHOT_STEP_LIMIT: usize = 100;

pub(super) fn home_dir() -> PathBuf {
    crate::infra::paths::home_dir()
}

pub fn projects_dir() -> PathBuf {
    home_dir().join(".claude/projects")
}
