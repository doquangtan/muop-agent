use super::*;

/// Lượt agy do server chạy đã bị cắt (tiến trình kết thúc khi server đang tắt) mà transcript
/// chưa có phản hồi của agent. Nếu đã có `PLANNER_RESPONSE` cuối thì lượt đã hoàn tất.
pub(super) fn agy_turn_cut_short(
    parsed: &ParsedTranscript,
    cut: &std::collections::HashSet<String>,
) -> bool {
    cut.contains(&parsed.id)
        && parsed
            .steps
            .last()
            .is_some_and(|s| s.step_type != "PLANNER_RESPONSE")
}

/// Quét toàn bộ /proc để tìm danh sách các conversation_id của các tiến trình agy CLI đang thực sự chạy trên hệ thống
pub fn scan_running_agy_conversations() -> std::collections::HashSet<String> {
    let mut running_ids = std::collections::HashSet::new();
    let proc_dir = match fs::read_dir("/proc") {
        Ok(d) => d,
        Err(_) => return running_ids,
    };

    for entry in proc_dir.flatten() {
        let file_name = entry.file_name();
        let name_str = file_name.to_string_lossy();
        if !name_str.chars().all(|c| c.is_ascii_digit()) {
            continue;
        }

        let cmdline_path = entry.path().join("cmdline");
        if let Ok(bytes) = fs::read(&cmdline_path) {
            let cmdline = String::from_utf8_lossy(&bytes);
            if cmdline.contains("agy") && cmdline.contains("--conversation") {
                let parts: Vec<&str> = cmdline.split('\0').collect();
                for i in 0..parts.len() {
                    if parts[i] == "--conversation" && i + 1 < parts.len() {
                        let cid = parts[i + 1].trim();
                        if !cid.is_empty() {
                            running_ids.insert(cid.to_string());
                        }
                    } else if let Some(rest) = parts[i].strip_prefix("--conversation=") {
                        let cid = rest.trim();
                        if !cid.is_empty() {
                            running_ids.insert(cid.to_string());
                        }
                    }
                }
            }
        }
    }
    running_ids
}
