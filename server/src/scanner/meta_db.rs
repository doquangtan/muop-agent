use super::*;

/// Lần đọc thành công gần nhất: dùng khi bản sao tạm thời không đọc được (agy đang ghi)
static LAST_GOOD_SUMMARY_META: Mutex<Option<HashMap<String, DbConversationMeta>>> =
    Mutex::new(None);

/// Bản sao đọc được của DB tóm tắt của agy. Khi agy đã đóng, SQLite ở chế độ WAL xóa `-shm`/`-wal`,
/// và một kết nối chỉ-đọc không mở được (`unable to open database file`), làm mất project của mọi
/// conversation agy. Nên sao chép DB cùng WAL sang thư mục cache của muop-agent (chỉ khi nguồn đổi)
/// rồi đọc bản sao; bản sao là file của mình nên SQLite được phép khôi phục WAL trên đó.
fn summary_db_readable() -> Option<PathBuf> {
    static SIGNATURE: Mutex<Option<String>> = Mutex::new(None);
    let src = summary_db_path();
    if !src.exists() {
        return None;
    }
    let src_wal = PathBuf::from(format!("{}-wal", src.display()));
    let dir = crate::infra::paths::app_data_dir().join("cache");
    fs::create_dir_all(&dir).ok()?;
    let dst = dir.join("agy-conversation-summaries.db");
    let dst_wal = PathBuf::from(format!("{}-wal", dst.display()));
    let dst_shm = PathBuf::from(format!("{}-shm", dst.display()));
    let stamp = |p: &Path| {
        fs::metadata(p)
            .ok()
            .map(|m| format!("{}:{:?}", m.len(), m.modified().ok()))
            .unwrap_or_default()
    };
    let signature = format!("{}|{}", stamp(&src), stamp(&src_wal));
    let mut guard = SIGNATURE.lock().unwrap_or_else(|e| e.into_inner());
    if guard.as_deref() != Some(signature.as_str()) || !dst.exists() {
        fs::copy(&src, &dst).ok()?;
        if src_wal.exists() {
            fs::copy(&src_wal, &dst_wal).ok()?;
        } else {
            let _ = fs::remove_file(&dst_wal);
        }
        let _ = fs::remove_file(&dst_shm);
        *guard = Some(signature);
    }
    Some(dst)
}

pub(super) fn load_conversation_summary_meta() -> HashMap<String, DbConversationMeta> {
    let last_good = || {
        LAST_GOOD_SUMMARY_META
            .lock()
            .ok()
            .and_then(|g| g.clone())
            .unwrap_or_default()
    };
    let Some(db) = summary_db_readable() else {
        return last_good();
    };
    let mut map = HashMap::new();
    let conn = match Connection::open_with_flags(
        &db,
        OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    ) {
        Ok(c) => c,
        Err(_) => return last_good(),
    };

    let mut stmt = match conn.prepare(
        "SELECT conversation_id, COALESCE(title, ''), COALESCE(workspace_uris, '[]'), COALESCE(status, ''), COALESCE(parent_conversation_id, ''), COALESCE(agent_name, '') FROM conversation_summaries",
    ) {
        Ok(s) => s,
        Err(_) => return last_good(),
    };

    let rows = stmt.query_map([], |row| {
        let id: String = row.get(0)?;
        let title: String = row.get(1)?;
        let uris_raw: String = row.get(2)?;
        let status: String = row.get(3)?;
        let parent_id: String = row.get(4)?;
        let agent_name: String = row.get(5)?;
        Ok((id, title, uris_raw, status, parent_id, agent_name))
    });

    if let Ok(iter) = rows {
        for item in iter.flatten() {
            let (id, title, uris_raw, status, parent_id, agent_name) = item;
            let (project_name, project_path) = resolve_project_from_workspace_uris(&uris_raw);
            map.insert(
                id,
                DbConversationMeta {
                    title: title.trim().to_string(),
                    project_name,
                    project_path,
                    status,
                    parent_id: parent_id.trim().to_string(),
                    agent_name: agent_name.trim().to_string(),
                },
            );
        }
    }

    if map.is_empty() {
        return last_good();
    }
    if let Ok(mut g) = LAST_GOOD_SUMMARY_META.lock() {
        *g = Some(map.clone());
    }
    map
}

pub(super) fn resolve_project_from_workspace_uris(uris_json: &str) -> (String, String) {
    if let Ok(Value::Array(arr)) = serde_json::from_str::<Value>(uris_json) {
        if let Some(Value::String(first)) = arr.first() {
            let cleaned = first.replacen("file://", "", 1).trim().to_string();
            if !cleaned.is_empty() {
                return normalize_project_path(&cleaned);
            }
        }
    }
    ("(không rõ project)".to_string(), String::new())
}

pub(super) fn normalize_project_path(raw_path: &str) -> (String, String) {
    let name = raw_path
        .split('/')
        .filter(|s| !s.is_empty())
        .last()
        .unwrap_or("(không rõ project)")
        .to_string();
    if let Some(root) = crate::setup::workspace_root() {
        let candidate = root.join(&name);
        if candidate.exists() {
            return (name, candidate.to_string_lossy().into_owned());
        }
    }
    (name, raw_path.to_string())
}
