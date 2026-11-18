use super::*;

pub(super) fn record_side_effects(
    name: &str,
    args: &HashMap<String, Value>,
    step_index: usize,
    timestamp: &str,
    files: &mut Vec<FileTouchRecord>,
    commands: &mut Vec<CommandExecutionRecord>,
) {
    let str_arg = |k: &str| args.get(k).and_then(|v| v.as_str()).unwrap_or("");
    match name {
        "Edit" | "MultiEdit" | "Write" | "NotebookEdit" => {
            let path = {
                let p = str_arg("file_path");
                if p.is_empty() {
                    str_arg("notebook_path")
                } else {
                    p
                }
            };
            if path.is_empty() {
                return;
            }
            let (added, removed, action) = match name {
                "Write" => (line_count(str_arg("content")), 0, "created"),
                "Edit" => (
                    line_count(str_arg("new_string")),
                    line_count(str_arg("old_string")),
                    "modified",
                ),
                _ => (line_count(str_arg("new_source")), 0, "modified"),
            };
            files.push(FileTouchRecord {
                path: path.to_string(),
                action: action.to_string(),
                repo: String::new(),
                agent_name: "Coordinator".to_string(),
                step_index,
                timestamp: timestamp.to_string(),
                added_lines: added,
                removed_lines: removed,
                diff_preview: String::new(),
                source: String::new(),
            });
        }
        "Bash" => {
            let cmd = str_arg("command");
            if cmd.is_empty() {
                return;
            }
            commands.push(CommandExecutionRecord {
                command_line: cmd.to_string(),
                summary: str_arg("description").to_string(),
                agent_name: "Coordinator".to_string(),
                step_index,
                timestamp: timestamp.to_string(),
                output_preview: String::new(),
                is_success: true,
            });
        }
        _ => {}
    }
}
