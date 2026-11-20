use super::*;

pub(super) fn classify_step_agent(
    _step_type: &str,
    tool_calls: &[ToolCallInfo],
    content: &str,
    thinking: &str,
) -> String {
    for tc in tool_calls {
        if let Some(ref path) = tc.target_path {
            if path.contains("muop-erp-server") {
                return "erp-server-agent".to_string();
            }
            if path.contains("muop-erp-app") {
                return "erp-app-agent".to_string();
            }
        }
        if tc.name == "run_command" {
            let cmd = tc
                .args
                .get("CommandLine")
                .and_then(|v| v.as_str())
                .unwrap_or("");
            if cmd.contains("flutter analyze") || cmd.contains("flutter test") {
                return "erp-contract-verifier".to_string();
            }
            if cmd.contains("go build") || cmd.contains("go test") {
                return "erp-contract-verifier".to_string();
            }
            if cmd.contains("muop-erp-server") {
                return "erp-server-agent".to_string();
            }
            if cmd.contains("muop-erp-app") {
                return "erp-app-agent".to_string();
            }
        }
    }
    let lower_thinking = thinking.to_lowercase();
    if lower_thinking.contains("go build")
        || lower_thinking.contains("flutter analyze")
        || lower_thinking.contains("contract verifier")
    {
        return "erp-contract-verifier".to_string();
    }
    if lower_thinking.contains("muop-erp-server") && !lower_thinking.contains("muop-erp-app") {
        return "erp-server-agent".to_string();
    }
    if lower_thinking.contains("muop-erp-app") && !lower_thinking.contains("muop-erp-server") {
        return "erp-app-agent".to_string();
    }
    let lower_content = content.to_lowercase();
    if lower_content.contains("muop-erp-server") && !lower_content.contains("muop-erp-app") {
        return "erp-server-agent".to_string();
    }
    if lower_content.contains("muop-erp-app") && !lower_content.contains("muop-erp-server") {
        return "erp-app-agent".to_string();
    }
    "Coordinator".to_string()
}

/// Quá khoảng này không có hoạt động nào trong transcript thì coi như không còn đang chạy
/// (tiến trình có thể đã chết). Lệnh chạy lâu có thể im lặng nhiều phút, nên ngưỡng khá rộng.
const CHILD_STALE_AFTER: chrono::Duration = chrono::Duration::minutes(30);

/// Subagent còn đang thực thi hay không, suy ra từ cấu trúc bước trong transcript.
/// Transcript của agy chỉ được ghi khi bước xong, nên:
/// - bước cuối là gọi tool (chưa có kết quả), hoặc là kết quả/system (model chưa trả lời): đang chạy;
/// - bước cuối là câu trả lời không gọi tool: đã xong, trừ khi còn một công cụ chạy nền
///   (bước `RUNNING` không có `SYSTEM_MESSAGE` báo hoàn tất theo sau; bước `RUNNING` không tự đổi thành `DONE` trong file).
/// Không dùng ngưỡng vài giây như trạng thái session, vì nó làm subagent "tắt" khi chạy lệnh lâu.
fn child_is_active(child: &ParsedTranscript) -> bool {
    if Utc::now() - child.updated_at > CHILD_STALE_AFTER {
        return false;
    }
    let steps = &child.steps;
    let Some(last) = steps.last() else {
        return false;
    };
    if last.step_type != "PLANNER_RESPONSE" || !last.tool_calls.is_empty() {
        return true;
    }
    match steps.iter().rposition(|s| s.status == "RUNNING") {
        Some(idx) => !steps[idx + 1..]
            .iter()
            .any(|s| s.step_type == "SYSTEM_MESSAGE"),
        None => false,
    }
}

/// Trạng thái hiển thị của một subagent từ transcript con
fn child_status(child: &ParsedTranscript) -> String {
    if child_is_active(child) {
        "running".to_string()
    } else {
        child.status.clone()
    }
}

/// Số tầng subagent lồng nhau tối đa khi dựng lane (agent con gọi agent cháu...)
const MAX_SPAWN_DEPTH: usize = 4;

/// Thêm lane cho các subagent mà `parent` đã gọi (`invoke_subagent`). Với subagent có transcript,
/// đệ quy để thêm các agent cháu do nó gọi; `parentId` của lane là id lane của agent đã gọi.
fn push_spawned_lanes(
    lanes: &mut Vec<SubagentLane>,
    parent: &ParsedTranscript,
    parent_lane_id: &str,
    all_parsed: &HashMap<String, ParsedTranscript>,
    is_session_actually_running: bool,
    depth: usize,
) {
    for spawned in &parent.spawned_subagents {
        let child_transcript = if !spawned.id.is_empty() {
            all_parsed.get(&spawned.id)
        } else {
            None
        };
        let mut child_steps = child_transcript
            .map(|c| c.steps.clone())
            .unwrap_or_else(|| {
                parent
                    .steps
                    .iter()
                    .filter(|s| s.agent_name == spawned.name)
                    .cloned()
                    .collect()
            });
        if child_steps.len() > 25 {
            child_steps = child_steps[child_steps.len() - 25..].to_vec();
        }
        let last_child_step = child_steps.last();

        let status = if !is_session_actually_running {
            let st = child_transcript
                .map(child_status)
                .unwrap_or_else(|| spawned.status.clone());
            if st == "running" {
                "interrupted".to_string()
            } else {
                st
            }
        } else {
            child_transcript
                .map(child_status)
                .unwrap_or_else(|| spawned.status.clone())
        };

        let mut modified_files = Vec::new();
        if let Some(ct) = child_transcript {
            for f in &ct.files_touched {
                if (f.action == "WRITE" || f.action == "EDIT") && !modified_files.contains(&f.path)
                {
                    modified_files.push(f.path.clone());
                }
            }
        }

        let progress = if status == "completed" {
            1.0
        } else if !child_steps.is_empty() {
            ((child_steps.len() as f64) / ((child_steps.len() + 4) as f64)).clamp(0.25, 0.9)
        } else {
            0.15
        };

        let current_tool_name = last_child_step
            .and_then(|s| s.tool_calls.first().map(|t| t.name.clone()))
            .unwrap_or_else(|| spawned.tool_name.clone());

        let child_lane_id = if !spawned.id.is_empty() {
            spawned.id.clone()
        } else {
            spawned.name.clone()
        };
        lanes.push(SubagentLane {
            id: if !spawned.id.is_empty() {
                spawned.id.clone()
            } else {
                spawned.name.clone()
            },
            name: spawned.name.clone(),
            role: spawned.role.clone(),
            target_repo: infer_target_repo(&spawned.name, &spawned.role, &spawned.prompt),
            status,
            current_phase: last_child_step
                .map(|s| s.phase.clone())
                .unwrap_or_else(|| parent.current_phase.clone()),
            current_step_index: last_child_step
                .map(|s| s.step_index)
                .unwrap_or(spawned.step_index),
            current_action_text: last_child_step
                .map(|s| s.vietnamese_title.clone())
                .unwrap_or_else(|| spawned.last_action.clone()),
            current_tool_name,
            prompt_brief: spawned.prompt.clone(),
            steps: child_steps,
            progress,
            files_modified: modified_files,
            last_updated: Some(
                child_transcript
                    .map(|c| c.updated_at.to_rfc3339())
                    .unwrap_or_else(|| parent.updated_at.to_rfc3339()),
            ),
            parent_id: parent_lane_id.to_string(),
            spawned: true,
        });
        if depth < MAX_SPAWN_DEPTH {
            if let Some(ct) = child_transcript {
                push_spawned_lanes(
                    lanes,
                    ct,
                    &child_lane_id,
                    all_parsed,
                    is_session_actually_running,
                    depth + 1,
                );
            }
        }
    }
}

pub(super) fn build_subagent_lanes(
    parent: &ParsedTranscript,
    all_parsed: &HashMap<String, ParsedTranscript>,
    is_session_actually_running: bool,
) -> Vec<SubagentLane> {
    let mut lanes = Vec::new();
    let mut added_names = HashSet::new();
    let is_session_running = is_session_actually_running;

    // 0. Coordinator Orchestrator Lane
    let mut coordinator_steps: Vec<AgentStep> = parent
        .steps
        .iter()
        .filter(|s| s.agent_name == "Coordinator" || s.step_type == "USER_INPUT")
        .cloned()
        .collect();
    if coordinator_steps.len() > 25 {
        coordinator_steps = coordinator_steps[coordinator_steps.len() - 25..].to_vec();
    }
    let last_parent_step = parent.steps.last();
    let is_coordinator_active = is_session_running
        && last_parent_step
            .map(|s| s.agent_name == "Coordinator")
            .unwrap_or(true);

    lanes.push(SubagentLane {
        id: "Coordinator".to_string(),
        name: "Coordinator".to_string(),
        role: "Architecture Lead & Parallel Dispatcher (Antigravity Engine)".to_string(),
        target_repo: parent.project_name.clone(),
        status: if is_coordinator_active {
            "running".to_string()
        } else if is_session_running {
            "waiting".to_string()
        } else {
            "completed".to_string()
        },
        current_phase: parent.current_phase.clone(),
        current_step_index: last_parent_step.map(|s| s.step_index).unwrap_or(0),
        current_action_text: if is_coordinator_active {
            last_parent_step
                .map(|s| s.vietnamese_title.clone())
                .unwrap_or_else(|| "Đang điều phối luồng thực thi song song".to_string())
        } else if is_session_running {
            "Đang ủy quyền công việc cho các Subagent song song".to_string()
        } else if parent.status == "interrupted" || !is_session_actually_running {
            "Tiến trình đã dừng (Sẵn sàng nhận lệnh mới)".to_string()
        } else {
            "Đã hoàn thành điều phối toàn bộ quy trình".to_string()
        },
        current_tool_name: if is_coordinator_active {
            last_parent_step
                .and_then(|s| s.tool_calls.first().map(|t| t.name.clone()))
                .unwrap_or_else(|| "dispatch".to_string())
        } else {
            "standby".to_string()
        },
        prompt_brief: "Tiếp nhận yêu cầu từ người dùng, thiết kế Shared Contract, phân chia công việc cho erp-server-agent & erp-app-agent, và tổng hợp kết quả.".to_string(),
        steps: coordinator_steps,
        progress: if is_session_running { 0.6 } else { 1.0 },
        files_modified: Vec::new(),
        last_updated: Some(parent.updated_at.to_rfc3339()),
    parent_id: String::new(),
        spawned: true,
});
    added_names.insert("Coordinator".to_string());

    // 1. Spawned Subagents (via invoke_subagent / define_subagent), đệ quy xuống agent cháu
    push_spawned_lanes(
        &mut lanes,
        parent,
        "Coordinator",
        all_parsed,
        is_session_running,
        1,
    );
    for lane in &lanes {
        added_names.insert(lane.name.clone());
    }

    // 2. Dual-Repo Parallel Agents (Chỉ nạp nếu là dự án ERP)
    let is_erp_project = parent.project_name == "muop-erp-server"
        || parent.project_name == "muop-erp-app"
        || Path::new(&parent.project_path)
            .join(".agents/rules/parallel-erp-sync.md")
            .exists()
        || Path::new(&parent.project_path)
            .join(".agents/agents/erp-server-agent.md")
            .exists();

    if is_erp_project {
        let standard_agents = [
            (
                "erp-server-agent",
                "ERP Server Backend Specialist (Go / Fiber v3 / MongoDB)",
                "muop-erp-server",
                "Phụ trách Clean Architecture api/v1/internal/, Isolated Collections, RBAC, Socket.IO, docs/ và go build -v .",
            ),
            (
                "erp-app-agent",
                "ERP App Flutter Specialist (Riverpod / M3 / i18n)",
                "muop-erp-app",
                "Phụ trách đồng bộ Model, executeRequest, Riverpod Provider, Socket.IO, Material 3, vi/en.json và flutter analyze.",
            ),
            (
                "erp-contract-verifier",
                "Cross-Repo Contract & QA Verifier",
                "muop-erp-server ↔ muop-erp-app",
                "Đối soát chéo Canonical Endpoint, JSON DTO, RBAC Permission, Socket.IO event và nghiệm thu kép.",
            ),
        ];

        for (name, role, repo, desc) in standard_agents {
            if !added_names.contains(name) {
                let mut related_files = Vec::new();
                for f in &parent.files_touched {
                    if ((repo == "muop-erp-server" && f.repo == "muop-erp-server")
                        || (repo == "muop-erp-app" && f.repo == "muop-erp-app"))
                        && !related_files.contains(&f.path)
                    {
                        related_files.push(f.path.clone());
                    }
                }

                // Lọc các steps thuộc về agent này
                let mut agent_steps: Vec<AgentStep> = parent
                    .steps
                    .iter()
                    .filter(|s| {
                        if s.agent_name == name {
                            return true;
                        }
                        if name == "erp-server-agent" {
                            return s.tool_calls.iter().any(|tc| {
                                tc.target_path
                                    .as_deref()
                                    .map(|p| p.contains("muop-erp-server"))
                                    .unwrap_or(false)
                            });
                        }
                        if name == "erp-app-agent" {
                            return s.tool_calls.iter().any(|tc| {
                                tc.target_path
                                    .as_deref()
                                    .map(|p| p.contains("muop-erp-app"))
                                    .unwrap_or(false)
                            });
                        }
                        if name == "erp-contract-verifier" {
                            return s.phase == "crossVerification"
                                || s.tool_calls.iter().any(|tc| {
                                    tc.name == "run_command"
                                        && tc
                                            .args
                                            .get("CommandLine")
                                            .and_then(|v| v.as_str())
                                            .map(|c| {
                                                c.contains("go build")
                                                    || c.contains("flutter analyze")
                                            })
                                            .unwrap_or(false)
                                });
                        }
                        false
                    })
                    .cloned()
                    .collect();

                if agent_steps.len() > 25 {
                    agent_steps = agent_steps[agent_steps.len() - 25..].to_vec();
                }
                let last_step = agent_steps.last();
                let is_this_agent_active = is_session_running
                    && last_parent_step
                        .map(|s| s.agent_name == name)
                        .unwrap_or(false);

                let lane_status = if is_this_agent_active {
                    "running".to_string()
                } else if !agent_steps.is_empty() || !related_files.is_empty() {
                    "completed".to_string()
                } else {
                    "idle".to_string()
                };

                let current_action = if is_this_agent_active {
                    last_parent_step
                        .map(|s| s.vietnamese_title.clone())
                        .unwrap_or_else(|| format!("Đang thực thi tác vụ trên {}", repo))
                } else if !related_files.is_empty() {
                    format!("Đã cập nhật {} tệp trong {}", related_files.len(), repo)
                } else {
                    format!(
                        "Đã đăng ký trong .agents — Sẵn sàng nhận lệnh thực thi trên {}",
                        repo
                    )
                };

                let current_tool = if is_this_agent_active {
                    last_parent_step
                        .and_then(|s| s.tool_calls.first().map(|t| t.name.clone()))
                        .unwrap_or_else(|| "running".to_string())
                } else if !agent_steps.is_empty() {
                    "completed".to_string()
                } else {
                    "standby".to_string()
                };

                let progress = if lane_status == "running" {
                    0.7
                } else if lane_status == "completed" {
                    1.0
                } else {
                    0.0
                };

                lanes.push(SubagentLane {
                    id: name.to_string(),
                    name: name.to_string(),
                    role: role.to_string(),
                    target_repo: repo.to_string(),
                    status: lane_status,
                    current_phase: last_step
                        .map(|s| s.phase.clone())
                        .unwrap_or_else(|| parent.current_phase.clone()),
                    current_step_index: last_step
                        .map(|s| s.step_index)
                        .unwrap_or_else(|| last_parent_step.map(|s| s.step_index).unwrap_or(0)),
                    current_action_text: current_action,
                    current_tool_name: current_tool,
                    prompt_brief: desc.to_string(),
                    steps: agent_steps,
                    progress,
                    files_modified: related_files,
                    last_updated: Some(parent.updated_at.to_rfc3339()),
                    parent_id: "Coordinator".to_string(),
                    spawned: false,
                });
                added_names.insert(name.to_string());
            }
        }
    } else {
        // Dự án độc lập (như muop-agent): Quét xem có custom agent trong .agents/agents/*.md không
        let p_agents = Path::new(&parent.project_path).join(".agents/agents");
        if p_agents.is_dir() {
            if let Ok(entries) = fs::read_dir(p_agents) {
                for entry in entries.flatten() {
                    let path = entry.path();
                    if path.extension().and_then(|e| e.to_str()) == Some("md") {
                        if let Ok(raw) = fs::read_to_string(&path) {
                            let stem = path.file_stem().and_then(|s| s.to_str()).unwrap_or("agent");
                            let (name, desc, _) = parse_markdown_frontmatter(&raw, stem, "agent");
                            if !added_names.contains(&name) {
                                let mut agent_steps: Vec<AgentStep> = parent
                                    .steps
                                    .iter()
                                    .filter(|s| s.agent_name == name)
                                    .cloned()
                                    .collect();
                                let lane_status = if agent_steps.is_empty() {
                                    "idle".to_string()
                                } else {
                                    "completed".to_string()
                                };
                                if agent_steps.len() > 25 {
                                    agent_steps = agent_steps[agent_steps.len() - 25..].to_vec();
                                }
                                lanes.push(SubagentLane {
                                    id: name.clone(),
                                    name: name.clone(),
                                    role: desc.clone(),
                                    target_repo: parent.project_name.clone(),
                                    status: lane_status,
                                    current_phase: parent.current_phase.clone(),
                                    current_step_index: 0,
                                    current_action_text: format!(
                                        "Custom Agent trong .agents ({})",
                                        name
                                    ),
                                    current_tool_name: "standby".to_string(),
                                    prompt_brief: desc,
                                    steps: agent_steps,
                                    progress: 0.0,
                                    files_modified: Vec::new(),
                                    last_updated: Some(parent.updated_at.to_rfc3339()),
                                    parent_id: "Coordinator".to_string(),
                                    spawned: false,
                                });
                                added_names.insert(name);
                            }
                        }
                    }
                }
            }
        }
    }

    lanes
}

pub(super) fn infer_target_repo(name: &str, role: &str, prompt: &str) -> String {
    let combined = format!("{} {} {}", name, role, prompt).to_lowercase();
    if combined.contains("erp-app")
        || combined.contains("muop-erp-app")
        || combined.contains("flutter")
    {
        if combined.contains("verifier") || combined.contains("contract") {
            return "muop-erp-server ↔ muop-erp-app".to_string();
        }
        return "muop-erp-app".to_string();
    }
    if combined.contains("erp-server")
        || combined.contains("muop-erp-server")
        || combined.contains("golang")
        || combined.contains("kitchen")
    {
        return "muop-erp-server".to_string();
    }
    "muop-ecosystem".to_string()
}

/// Nạp transcript của mọi sub-agent (kể cả agent cháu) bắt đầu từ `roots` (id conversation con).
/// Trả về map id -> transcript đã parse; bỏ qua id đã nạp để không lặp vô hạn khi dữ liệu có vòng.
pub(super) fn load_subagent_transcripts(
    brain_dir: &std::path::Path,
    roots: Vec<String>,
    db_meta_map: &HashMap<String, DbConversationMeta>,
) -> HashMap<String, ParsedTranscript> {
    const MAX_LOADED: usize = 300;
    let mut loaded: HashMap<String, ParsedTranscript> = HashMap::new();
    let mut pending = roots;
    while let Some(sub_id) = pending.pop() {
        if sub_id.is_empty() || loaded.contains_key(&sub_id) || loaded.len() >= MAX_LOADED {
            continue;
        }
        let sub_path = brain_dir
            .join(&sub_id)
            .join(".system_generated/logs/transcript.jsonl");
        let Ok(meta) = fs::metadata(&sub_path) else {
            continue;
        };
        let modified: DateTime<Utc> = meta.modified().unwrap_or(SystemTime::UNIX_EPOCH).into();
        if let Some(parsed) = parse_transcript_file(&sub_id, modified, db_meta_map.get(&sub_id)) {
            for s in &parsed.spawned_subagents {
                if !s.id.is_empty() {
                    pending.push(s.id.clone());
                }
            }
            loaded.insert(sub_id, parsed);
        }
    }
    loaded
}
