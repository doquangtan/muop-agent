use super::*;

/// Kết quả so sánh thay đổi file session Claude Code giữa hai lần quét
#[derive(Debug, Default)]
pub struct ClaudeChanges {
    pub changed_ids: Vec<String>,
    pub removed: bool,
    /// Id các session đã bị xoá khỏi đĩa
    pub removed_ids: Vec<String>,
    pub added: bool,
}

/// So sánh fingerprint hiện tại với lần trước (lưu trong `fingerprints`)
pub fn detect_changes(fingerprints: &mut HashMap<String, (u64, u64)>) -> ClaudeChanges {
    let mut changes = ClaudeChanges::default();
    let mut seen: HashSet<String> = HashSet::new();
    for (path, fp) in list_session_files() {
        let Some(id) = path.file_stem().and_then(|s| s.to_str()).map(String::from) else {
            continue;
        };
        seen.insert(id.clone());
        match fingerprints.get(&id) {
            Some(prev) if *prev == fp => {}
            Some(_) => changes.changed_ids.push(id.clone()),
            None => {
                changes.added = true;
                changes.changed_ids.push(id.clone());
            }
        }
        fingerprints.insert(id, fp);
    }
    let removed: Vec<String> = fingerprints
        .keys()
        .filter(|id| !seen.contains(*id))
        .cloned()
        .collect();
    if !removed.is_empty() {
        changes.removed = true;
        fingerprints.retain(|id, _| seen.contains(id));
        changes.removed_ids = removed;
    }
    changes
}
