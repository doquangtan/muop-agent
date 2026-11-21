use super::*;

/// Ghi nhận kết quả của tool `Agent`/`Task`: `toolUseResult.agentId` trỏ tới transcript con.
///
/// Subagent chạy nền (`isAsync` / `async_launched`) trả kết quả khởi chạy ngay, nên tool_result
/// đó KHÔNG có nghĩa là subagent đã xong. Khi xong, Claude gửi tin nhắn `<task-notification>`
/// (chuỗi) có `<tool-use-id>` và `<status>`; chỉ khi đó lane mới được đánh dấu hoàn tất.
pub(super) fn record_agent_results(v: &Value, spawns: &mut [SpawnedAgent]) {
    if let Some(text) = v
        .get("message")
        .and_then(|m| m.get("content"))
        .and_then(|c| c.as_str())
    {
        record_task_notification(text, spawns);
        return;
    }
    let Some(Value::Array(blocks)) = v.get("message").and_then(|m| m.get("content")) else {
        return;
    };
    let result = v.get("toolUseResult");
    let agent_id = result
        .and_then(|r| r.get("agentId"))
        .and_then(|x| x.as_str())
        .map(String::from);
    let is_async = result.is_some_and(|r| {
        r.get("isAsync").and_then(|x| x.as_bool()) == Some(true)
            || r.get("status").and_then(|x| x.as_str()) == Some("async_launched")
    });
    for block in blocks {
        if block.get("type").and_then(|x| x.as_str()) != Some("tool_result") {
            continue;
        }
        let Some(tool_use_id) = block.get("tool_use_id").and_then(|x| x.as_str()) else {
            continue;
        };
        if let Some(spawn) = spawns.iter_mut().find(|s| s.tool_use_id == tool_use_id) {
            if !is_async {
                spawn.completed = true;
            }
            if spawn.agent_id.is_none() {
                spawn.agent_id = agent_id.clone();
            }
        }
    }
}

/// Đọc thông báo hoàn tất của subagent chạy nền: `<tool-use-id>` và `<status>` (kết thúc khi
/// `completed`, `failed`, `killed`...). Đánh dấu lane tương ứng là đã xong.
fn record_task_notification(text: &str, spawns: &mut [SpawnedAgent]) {
    if !text.contains("<task-notification>") {
        return;
    }
    let tag = |name: &str| -> Option<&str> {
        let open = format!("<{name}>");
        let close = format!("</{name}>");
        let start = text.find(&open)? + open.len();
        let end = text[start..].find(&close)? + start;
        Some(text[start..end].trim())
    };
    let (Some(tool_use_id), Some(status)) = (tag("tool-use-id"), tag("status")) else {
        return;
    };
    if !matches!(status, "completed" | "failed" | "killed" | "stopped") {
        return;
    }
    if let Some(spawn) = spawns.iter_mut().find(|s| s.tool_use_id == tool_use_id) {
        spawn.completed = true;
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

/// Số tầng sub-agent lồng nhau tối đa được dựng (agent con spawn agent cháu...)
const MAX_LANE_DEPTH: usize = 4;
/// Số lane tối đa của một session, để một session có quá nhiều sub-agent không làm chậm snapshot
const MAX_LANES: usize = 200;

/// Dựng cây sub-agent của một session. Transcript con nằm phẳng trong
/// `<session>/subagents/agent-<id>.jsonl`, kể cả agent cháu; quan hệ cha-con lấy từ
/// transcript đã gọi tool `Agent` (`parent_id` của lane). Sub-agent đang chạy chưa có
/// `agentId` nên được ghép theo prompt giao việc.
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
    let mut builder = LaneBuilder {
        dir,
        files,
        used: HashSet::new(),
        project_name,
        out: Vec::new(),
    };
    builder.add_level(spawns, "", 1);
    builder.out
}

struct LaneBuilder<'a> {
    dir: PathBuf,
    files: Vec<PathBuf>,
    used: HashSet<PathBuf>,
    project_name: &'a str,
    out: Vec<SubagentLane>,
}

impl LaneBuilder<'_> {
    /// Dựng lane cho các sub-agent của một tầng (con của `parent_id`), rồi đệ quy xuống agent cháu
    fn add_level(&mut self, spawns: &[SpawnedAgent], parent_id: &str, depth: usize) {
        let transcripts = self.resolve_transcripts(spawns);
        for (spawn, transcript) in spawns.iter().zip(transcripts) {
            if self.out.len() >= MAX_LANES {
                return;
            }
            let child = transcript.and_then(|p| parse_session_parts(&p, true));
            let (child_session, child_spawns) = match child {
                Some((session, spawns)) => (Some(session), spawns),
                None => (None, Vec::new()),
            };
            let lane = build_lane(spawn, child_session.as_ref(), self.project_name, parent_id);
            let lane_id = lane.id.clone();
            self.out.push(lane);
            if depth < MAX_LANE_DEPTH && !child_spawns.is_empty() {
                self.add_level(&child_spawns, &lane_id, depth + 1);
            }
        }
    }

    /// Ghép mỗi spawn với transcript con: theo `agentId` trước, còn lại theo prompt giao việc
    fn resolve_transcripts(&mut self, spawns: &[SpawnedAgent]) -> Vec<Option<PathBuf>> {
        let mut transcripts: Vec<Option<PathBuf>> = spawns
            .iter()
            .map(|spawn| {
                spawn
                    .agent_id
                    .as_ref()
                    .map(|id| self.dir.join(format!("agent-{}.jsonl", id)))
                    .filter(|p| p.is_file())
            })
            .collect();
        for path in transcripts.iter().flatten() {
            self.used.insert(path.clone());
        }
        for (spawn, slot) in spawns.iter().zip(transcripts.iter_mut()) {
            if slot.is_some() {
                continue;
            }
            let wanted = spawn.prompt.trim();
            *slot = self
                .files
                .iter()
                .find(|f| {
                    !self.used.contains(*f) && first_user_prompt(f).as_deref() == Some(wanted)
                })
                .cloned();
            if let Some(p) = slot {
                self.used.insert(p.clone());
            }
        }
        transcripts
    }
}

/// Lane của một sub-agent từ lần gọi tool (`spawn`) và transcript con đã parse (nếu có)
fn build_lane(
    spawn: &SpawnedAgent,
    child: Option<&ConversationSession>,
    project_name: &str,
    parent_id: &str,
) -> SubagentLane {
    let mut steps = child.map(|c| c.steps.clone()).unwrap_or_default();
    if steps.len() > SNAPSHOT_STEP_LIMIT {
        steps = steps.split_off(steps.len() - SNAPSHOT_STEP_LIMIT);
    }
    let last = steps.last();
    let last_tool = last.and_then(|s| s.tool_calls.last());
    let completed = spawn.completed;
    let files_modified = child
        .map(|c| {
            let mut out: Vec<String> = Vec::new();
            for f in &c.files_touched {
                if (f.action == "created" || f.action == "modified") && !out.contains(&f.path) {
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
        last_updated: child.map(|c| c.updated_at.clone()),
        parent_id: parent_id.to_string(),
        spawned: true,
    }
}

#[cfg(test)]
mod lane_tree_tests {
    use super::*;

    fn user_line(text: &str) -> String {
        serde_json::json!({"type": "user", "message": {"role": "user", "content": text}})
            .to_string()
    }

    fn spawn_line(tool_id: &str, prompt: &str) -> String {
        serde_json::json!({
            "type": "assistant",
            "message": {"id": format!("m-{tool_id}"), "role": "assistant", "stop_reason": "tool_use",
                "content": [{"type": "tool_use", "id": tool_id, "name": "Agent",
                    "input": {"prompt": prompt, "description": prompt, "subagent_type": "general-purpose"}}]}
        })
        .to_string()
    }

    fn result_line(tool_id: &str, agent_id: &str) -> String {
        serde_json::json!({
            "type": "user",
            "toolUseResult": {"agentId": agent_id},
            "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": tool_id, "content": "done"}]}
        })
        .to_string()
    }

    #[test]
    fn nested_subagent_gets_parent_lane_id() {
        let root = std::env::temp_dir().join(format!("muop-lane-test-{}", std::process::id()));
        let session = root.join("sess.jsonl");
        let sub_dir = root.join("sess").join("subagents");
        fs::create_dir_all(&sub_dir).unwrap();
        fs::write(&session, format!("{}\n", user_line("main"))).unwrap();
        // Agent A: spawns agent B (cháu), and B has finished
        fs::write(
            sub_dir.join("agent-A1.jsonl"),
            [
                user_line("Build A"),
                spawn_line("toolB", "Build B"),
                result_line("toolB", "B1"),
            ]
            .join("\n"),
        )
        .unwrap();
        fs::write(sub_dir.join("agent-B1.jsonl"), user_line("Build B")).unwrap();

        let spawns = vec![SpawnedAgent {
            tool_use_id: "toolA".into(),
            name: "general-purpose".into(),
            role: "A".into(),
            prompt: "Build A".into(),
            agent_id: Some("A1".into()),
            completed: false,
        }];
        let lanes = build_subagent_lanes(&session, &spawns, "proj");
        let _ = fs::remove_dir_all(&root);

        assert_eq!(lanes.len(), 2);
        let a = lanes.iter().find(|l| l.id == "toolA").unwrap();
        let b = lanes.iter().find(|l| l.id == "toolB").unwrap();
        assert_eq!(a.parent_id, "");
        assert_eq!(b.parent_id, "toolA");
        assert_eq!(a.status, "running");
        assert_eq!(b.status, "completed");
    }
}
