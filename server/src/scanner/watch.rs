use super::*;

/// Bộ theo dõi dấu vết thay đổi từng session độc lập để phát event nhỏ gọn (Granular Events)
#[derive(Debug, Clone, Default)]
pub struct SessionChangeTracker {
    pub transcript_fingerprints: HashMap<String, (u64, u64)>, // id -> (mtime_ms, file_size)
    pub sqlite_mtime: u64,
    /// Fingerprint (mtime, size) của các file session Claude Code CLI
    pub claude_fingerprints: HashMap<String, (u64, u64)>,
}

pub fn init_session_change_tracker() -> SessionChangeTracker {
    let mut tracker = SessionChangeTracker::default();
    let brain_dir = Path::new(BRAIN_DIR_PATH);
    if let Ok(entries) = fs::read_dir(brain_dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                if let Some(id) = path.file_name().and_then(|n| n.to_str()) {
                    if id != "tempmediaStorage" && !id.starts_with('.') {
                        let transcript_path = path.join(".system_generated/logs/transcript.jsonl");
                        if let Ok(meta) = fs::metadata(&transcript_path) {
                            let mtime = meta
                                .modified()
                                .unwrap_or(SystemTime::UNIX_EPOCH)
                                .duration_since(SystemTime::UNIX_EPOCH)
                                .map(|d| d.as_millis() as u64)
                                .unwrap_or(0);
                            let size = meta.len();
                            tracker
                                .transcript_fingerprints
                                .insert(id.to_string(), (mtime, size));
                        }
                    }
                }
            }
        }
    }

    if let Ok(meta) = fs::metadata(SUMMARY_DB_PATH) {
        tracker.sqlite_mtime = meta
            .modified()
            .unwrap_or(SystemTime::UNIX_EPOCH)
            .duration_since(SystemTime::UNIX_EPOCH)
            .map(|d| d.as_millis() as u64)
            .unwrap_or(0);
    }

    tracker
}

/// Kết quả phát hiện thay đổi của watcher: mỗi loại thay đổi map vào một event riêng
#[derive(Debug, Clone, Default)]
pub struct DetectedChanges {
    /// Các conversation top-level có thay đổi -> `session:update` cho từng conversation
    pub changed_sessions: Vec<String>,
    /// Id các conversation bị xoá khỏi đĩa
    pub removed_ids: Vec<String>,
    /// Metadata project thay đổi -> `projects:update`
    pub projects_changed: bool,
}

/// Xoá cache quota để lần fetch kế tiếp lấy dữ liệu mới nhất từ daemon
pub fn invalidate_quota_cache() {
    crate::claude::code::invalidate_limits_cache();
    if let Some(cache) = QUOTA_CACHE.get() {
        if let Ok(mut guard) = cache.lock() {
            guard.at = Instant::now() - Duration::from_secs(3600);
        }
    }
}

/// Phát hiện danh sách các conversation có thay đổi thực tế (chỉ scan và gửi event mỗi conversation đó)
pub fn detect_changed_sessions(tracker: &mut SessionChangeTracker) -> DetectedChanges {
    let mut changed_top_ids = HashSet::new();
    let mut projects_changed = false;
    let mut seen_ids: HashSet<String> = HashSet::new();

    let brain_dir = Path::new(BRAIN_DIR_PATH);
    if !brain_dir.exists() {
        return DetectedChanges::default();
    }

    let db_meta_map = load_conversation_summary_meta();

    // Map to quickly find parent ID for subagents
    let mut child_to_parent: HashMap<String, String> = HashMap::new();
    let mut subagent_ids: HashSet<String> = HashSet::new();
    for (id, m) in &db_meta_map {
        if !m.parent_id.is_empty() {
            child_to_parent.insert(id.clone(), m.parent_id.clone());
            subagent_ids.insert(id.clone());
        } else if !m.agent_name.is_empty()
            && m.agent_name != "Coordinator"
            && m.agent_name != "user"
        {
            subagent_ids.insert(id.clone());
        }
    }

    // 1. Quét các directory trong brain
    if let Ok(entries) = fs::read_dir(brain_dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            if !path.is_dir() {
                continue;
            }
            let id = match path.file_name().and_then(|n| n.to_str()) {
                Some(s) => s.to_string(),
                None => continue,
            };
            if id == "tempmediaStorage" || id.starts_with('.') {
                continue;
            }

            let transcript_path = path.join(".system_generated/logs/transcript.jsonl");
            if let Ok(meta) = fs::metadata(&transcript_path) {
                seen_ids.insert(id.clone());
                let mtime = meta
                    .modified()
                    .unwrap_or(SystemTime::UNIX_EPOCH)
                    .duration_since(SystemTime::UNIX_EPOCH)
                    .map(|d| d.as_millis() as u64)
                    .unwrap_or(0);
                let size = meta.len();

                let changed = match tracker.transcript_fingerprints.get(&id) {
                    Some(&(old_mtime, old_size)) => old_mtime != mtime || old_size != size,
                    None => true,
                };

                if changed {
                    tracker
                        .transcript_fingerprints
                        .insert(id.clone(), (mtime, size));
                    // Nếu id là subagent, trigger cập nhật session cha
                    if let Some(parent) = child_to_parent.get(&id) {
                        changed_top_ids.insert(parent.clone());
                    } else if !subagent_ids.contains(&id) {
                        // Nếu là top-level session
                        changed_top_ids.insert(id.clone());
                    }
                }
            }
        }
    }

    // 1b. Phát hiện conversation đã bị xoá khỏi đĩa
    let removed_brain: Vec<String> = tracker
        .transcript_fingerprints
        .keys()
        .filter(|id| !seen_ids.contains(*id))
        .cloned()
        .collect();
    tracker
        .transcript_fingerprints
        .retain(|id, _| seen_ids.contains(id));
    let mut removed_ids = removed_brain;

    // 1c. Session của Claude Code CLI
    let claude_changes = crate::claude::code::detect_changes(&mut tracker.claude_fingerprints);
    changed_top_ids.extend(claude_changes.changed_ids);
    if claude_changes.removed {
        removed_ids.extend(claude_changes.removed_ids.iter().cloned());
    }
    if claude_changes.added {
        projects_changed = true;
    }

    // 2. Kiểm tra SQLite db mtime
    let db_path = Path::new(SUMMARY_DB_PATH);
    if let Ok(meta) = fs::metadata(db_path) {
        let db_mtime = meta
            .modified()
            .unwrap_or(SystemTime::UNIX_EPOCH)
            .duration_since(SystemTime::UNIX_EPOCH)
            .map(|d| d.as_millis() as u64)
            .unwrap_or(0);
        if tracker.sqlite_mtime != db_mtime {
            tracker.sqlite_mtime = db_mtime;
            for (id, m) in &db_meta_map {
                if m.parent_id.is_empty()
                    && (m.agent_name.is_empty() || m.agent_name == "Coordinator")
                {
                    if !tracker.transcript_fingerprints.contains_key(id) {
                        changed_top_ids.insert(id.clone());
                    }
                }
            }
            projects_changed = true;
        }
    }

    DetectedChanges {
        changed_sessions: changed_top_ids.into_iter().collect(),
        removed_ids,
        projects_changed,
    }
}
