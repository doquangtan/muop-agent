use super::*;

pub(super) fn load_conversation_summary_meta() -> HashMap<String, DbConversationMeta> {
    let mut map = HashMap::new();
    if !Path::new(SUMMARY_DB_PATH).exists() {
        return map;
    }

    let conn = match Connection::open_with_flags(
        SUMMARY_DB_PATH,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    ) {
        Ok(c) => c,
        Err(_) => return map,
    };

    let mut stmt = match conn.prepare(
        "SELECT conversation_id, COALESCE(title, ''), COALESCE(workspace_uris, '[]'), COALESCE(status, ''), COALESCE(parent_conversation_id, ''), COALESCE(agent_name, '') FROM conversation_summaries",
    ) {
        Ok(s) => s,
        Err(_) => return map,
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
    (
        "muop-erp-server".to_string(),
        format!("{}/muop-erp-server", ECOSYSTEM_DIR_PATH),
    )
}

pub(super) fn normalize_project_path(raw_path: &str) -> (String, String) {
    let name = raw_path
        .split('/')
        .filter(|s| !s.is_empty())
        .last()
        .unwrap_or("muop-erp-server")
        .to_string();
    let candidate = format!("{}/{}", ECOSYSTEM_DIR_PATH, name);
    if Path::new(&candidate).exists() {
        return (name, candidate);
    }
    (name, raw_path.to_string())
}
