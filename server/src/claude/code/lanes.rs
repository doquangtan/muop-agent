use super::*;

/// Ghi nhận kết quả của tool `Agent`/`Task`: `toolUseResult.agentId` trỏ tới transcript con
pub(super) fn record_agent_results(v: &Value, spawns: &mut [SpawnedAgent]) {
    let Some(Value::Array(blocks)) = v.get("message").and_then(|m| m.get("content")) else {
        return;
    };
    let agent_id = v
        .get("toolUseResult")
        .and_then(|r| r.get("agentId"))
        .and_then(|x| x.as_str())
        .map(String::from);
    for block in blocks {
        if block.get("type").and_then(|x| x.as_str()) != Some("tool_result") {
            continue;
        }
        let Some(tool_use_id) = block.get("tool_use_id").and_then(|x| x.as_str()) else {
            continue;
        };
        if let Some(spawn) = spawns.iter_mut().find(|s| s.tool_use_id == tool_use_id) {
            spawn.completed = true;
            if spawn.agent_id.is_none() {
                spawn.agent_id = agent_id.clone();
            }
        }
    }
}

/// Lấy nội dung prompt đầu tiên trong transcript con (dòng đầu là prompt được giao cho sub-agent)
pub(super) fn first_user_prompt(path: &Path) -> Option<String> {
    let file = fs::File::open(path).ok()?;
    let mut line = String::new();
    BufReader::new(file).read_line(&mut line).ok()?;
    let v: Value = serde_json::from_str(&line).ok()?;
    match v.get("message")?.get("content")? {
        Value::String(s) => Some(s.trim().to_string()),
        Value::Array(blocks) => blocks
            .iter()
            .find(|b| b.get("type").and_then(|x| x.as_str()) == Some("text"))
            .and_then(|b| b.get("text"))
            .and_then(|x| x.as_str())
            .map(|s| s.trim().to_string()),
        _ => None,
    }
}

/// Dựng lane cho từng sub-agent. Transcript con nằm ở `<session>/subagents/agent-<id>.jsonl`;
/// sub-agent đang chạy chưa có `agentId` nên được ghép theo prompt giao việc.
pub(super) fn build_subagent_lanes(
    session_path: &Path,
    spawns: &[SpawnedAgent],
    project_name: &str,
) -> Vec<SubagentLane> {
    if spawns.is_empty() {
        return Vec::new();
    }
    let dir = subagent_dir(session_path);
    let files: Vec<PathBuf> = fs::read_dir(&dir)
        .map(|rd| {
            rd.flatten()
                .map(|e| e.path())
                .filter(|p| p.extension().and_then(|e| e.to_str()) == Some("jsonl"))
                .collect()
        })
        .unwrap_or_default();

    let mut used: HashSet<PathBuf> = HashSet::new();
    let mut transcripts: Vec<Option<PathBuf>> = Vec::with_capacity(spawns.len());
    for spawn in spawns {
        let path = spawn
            .agent_id
            .as_ref()
            .map(|id| dir.join(format!("agent-{}.jsonl", id)));
        if let Some(p) = &path {
            used.insert(p.clone());
        }
        transcripts.push(path);
    }
    for (spawn, slot) in spawns.iter().zip(transcripts.iter_mut()) {
        if slot.is_some() {
            continue;
        }
        let wanted = spawn.prompt.trim();
        *slot = files
            .iter()
            .find(|f| !used.contains(*f) && first_user_prompt(f).as_deref() == Some(wanted))
            .cloned();
        if let Some(p) = slot {
            used.insert(p.clone());
        }
    }

    spawns
        .iter()
        .zip(transcripts)
        .map(|(spawn, transcript)| {
            let child = transcript.and_then(|p| parse_session_file(&p, true));
            let mut steps = child.as_ref().map(|c| c.steps.clone()).unwrap_or_default();
            if steps.len() > SNAPSHOT_STEP_LIMIT {
                steps = steps.split_off(steps.len() - SNAPSHOT_STEP_LIMIT);
            }
            let last = steps.last();
            let last_tool = last.and_then(|s| s.tool_calls.last());
            let completed = spawn.completed;
            let files_modified = child
                .as_ref()
                .map(|c| {
                    let mut out: Vec<String> = Vec::new();
                    for f in &c.files_touched {
                        if (f.action == "created" || f.action == "modified")
                            && !out.contains(&f.path)
                        {
                            out.push(f.path.clone());
                        }
                    }
                    out
                })
                .unwrap_or_default();
            let progress = if completed {
                1.0
            } else if !steps.is_empty() {
                (steps.len() as f64 / (steps.len() + 4) as f64).clamp(0.25, 0.9)
            } else {
                0.15
            };

            SubagentLane {
                id: spawn.tool_use_id.clone(),
                name: spawn.name.clone(),
                role: spawn.role.clone(),
                target_repo: project_name.to_string(),
                status: if completed { "completed" } else { "running" }.to_string(),
                current_phase: if completed { "completed" } else { "running" }.to_string(),
                current_step_index: last.map(|s| s.step_index).unwrap_or(0),
                current_action_text: last_tool
                    .map(|t| t.summary_label.clone())
                    .or_else(|| last.map(|s| s.content.lines().next().unwrap_or("").to_string()))
                    .unwrap_or_default(),
                current_tool_name: last_tool.map(|t| t.name.clone()).unwrap_or_default(),
                prompt_brief: spawn.prompt.chars().take(500).collect(),
                steps,
                progress,
                files_modified,
                last_updated: child.as_ref().map(|c| c.updated_at.clone()),
            }
        })
        .collect()
}
