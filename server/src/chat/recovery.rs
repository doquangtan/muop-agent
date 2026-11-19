//! Nhận lại các lượt chat còn đang chạy sau khi máy chủ khởi động lại.
//!
//! Trạng thái lượt (`active_streams`, `running_pids`) chỉ nằm trong bộ nhớ. Khi server restart,
//! trạng thái này mất hết, nhưng tiến trình `agy` / `claude` do server sinh ra có thể vẫn chạy.
//!
//! Mỗi lượt được ghi vào bảng `running_turns` ngay khi có init (kèm pid và thời điểm bắt đầu của
//! tiến trình). Khi khởi động, server nhận lại các tiến trình còn sống đúng pid + thời điểm bắt đầu,
//! đưa vào `active_streams` để client thấy lượt đang stream (và nút dừng hoạt động), rồi đóng lại
//! khi tiến trình kết thúc. Cách này không cần `--conversation` / `--resume` trong argv, nên
//! cả lượt đầu tiên của conversation mới cũng được nhận lại. Quét argv vẫn giữ làm phương án dự phòng.
//!
//! Đầu ra stdout của lượt cũ đã mất nên phần văn bản đang stream không khôi phục được;
//! nội dung đầy đủ vẫn hiện qua transcript khi session được quét lại.

use super::AppState;
use crate::infra::store::{self, RunningTurnRow};
use crate::models::ChatTurnStreamState;
use chrono::Utc;
use std::fs;

/// Một tiến trình lượt chat đang chạy, tìm thấy trong `/proc` hoặc trong bảng `running_turns`
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LiveTurn {
    pub conversation_id: String,
    pub pid: u32,
    pub start_ticks: u64,
    pub cwd: String,
}

/// Thời điểm bắt đầu của tiến trình (jiffies kể từ lúc boot, trường `starttime` của `/proc/<pid>/stat`).
/// Cùng pid nhưng khác thời điểm bắt đầu nghĩa là pid đã được tái sử dụng. Tiến trình zombie trả về None.
pub fn process_start_ticks(pid: u32) -> Option<u64> {
    let stat = fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    // Tên tiến trình nằm trong ngoặc đơn và có thể chứa khoảng trắng: tách sau dấu ')' cuối cùng
    let after = stat.rsplit_once(')')?.1;
    let fields: Vec<&str> = after.split_whitespace().collect();
    // fields[0] là trạng thái (trường 3), starttime là trường 22 → chỉ số 19
    if matches!(fields.first(), Some(&"Z") | Some(&"X") | None) {
        return None;
    }
    fields.get(19)?.parse().ok()
}

/// Lấy tên file từ đường dẫn (phần sau dấu `/` cuối cùng)
fn basename(path: &str) -> &str {
    path.rsplit('/').next().unwrap_or(path)
}

/// Giá trị của một cờ, dạng `--flag value` hoặc `--flag=value`
fn flag_value(argv: &[&str], flag: &str) -> Option<String> {
    let prefix = format!("{flag}=");
    for (i, arg) in argv.iter().enumerate() {
        if *arg == flag {
            return argv
                .get(i + 1)
                .map(|v| v.trim().to_string())
                .filter(|v| !v.is_empty());
        }
        if let Some(rest) = arg.strip_prefix(&prefix) {
            let v = rest.trim();
            return (!v.is_empty()).then(|| v.to_string());
        }
    }
    None
}

/// Nhận diện một dòng lệnh (argv) là lượt chat do server sinh ra, trả về conversation id.
///
/// - `agy`: `... --conversation <cid> -p <prompt>` (chỉ có khi resume)
/// - `claude`: `-p <prompt> --output-format stream-json ... --resume <cid>` (chỉ có khi resume).
///   Loại phiên của extension VSCode (dùng `--input-format stream-json`, không có `-p`).
/// - Tiến trình `systemd-run` bọc ngoài bị bỏ qua để chỉ lấy đúng tiến trình CLI.
pub fn conversation_from_argv(argv: &[&str]) -> Option<String> {
    let first = argv.first()?;
    if basename(first) == "systemd-run" {
        return None;
    }
    if argv.iter().any(|a| basename(a) == "agy") {
        return flag_value(argv, "--conversation");
    }
    if argv.iter().any(|a| basename(a) == "claude")
        && argv.contains(&"-p")
        && flag_value(argv, "--output-format").as_deref() == Some("stream-json")
        && !argv.contains(&"--input-format")
    {
        return flag_value(argv, "--resume");
    }
    None
}

/// Đọc dòng lệnh của tiến trình từ `/proc/<pid>/cmdline`. Tiến trình zombie không có dòng lệnh.
fn read_argv(pid: u32) -> Option<Vec<String>> {
    let bytes = fs::read(format!("/proc/{pid}/cmdline")).ok()?;
    let argv: Vec<String> = bytes
        .split(|b| *b == 0)
        .filter(|s| !s.is_empty())
        .map(|s| String::from_utf8_lossy(s).into_owned())
        .collect();
    (!argv.is_empty()).then_some(argv)
}

/// Tiến trình `pid` vẫn là đúng tiến trình đã nhận lại (cùng thời điểm bắt đầu)
fn still_running(pid: u32, start_ticks: u64) -> bool {
    process_start_ticks(pid) == Some(start_ticks)
}

/// Quét toàn bộ `/proc` tìm các lượt chat đang chạy theo argv (phương án dự phòng)
pub fn scan_live_turns() -> Vec<LiveTurn> {
    let Ok(dir) = fs::read_dir("/proc") else {
        return Vec::new();
    };
    let mut turns = Vec::new();
    for entry in dir.flatten() {
        let Some(pid) = entry
            .file_name()
            .to_str()
            .and_then(|s| s.parse::<u32>().ok())
        else {
            continue;
        };
        let Some(argv) = read_argv(pid) else {
            continue;
        };
        let refs: Vec<&str> = argv.iter().map(String::as_str).collect();
        let Some(cid) = conversation_from_argv(&refs) else {
            continue;
        };
        let Some(start_ticks) = process_start_ticks(pid) else {
            continue;
        };
        let cwd = fs::read_link(format!("/proc/{pid}/cwd"))
            .map(|p| p.to_string_lossy().into_owned())
            .unwrap_or_default();
        turns.push(LiveTurn {
            conversation_id: cid,
            pid,
            start_ticks,
            cwd,
        });
    }
    turns
}

/// Nhận lại các lượt đang chạy khi server vừa khởi động: đọc bảng `running_turns`, rồi quét argv
/// để bắt các tiến trình còn lại. Trả về số lượt nhận lại.
pub fn adopt_live_turns(state: &AppState) -> usize {
    let mut found: Vec<LiveTurn> = Vec::new();
    for row in store::list_running_turns() {
        match process_start_ticks(row.pid) {
            Some(ticks) if ticks == row.start_ticks => found.push(LiveTurn {
                conversation_id: row.conversation_id,
                pid: row.pid,
                start_ticks: ticks,
                cwd: row.cwd,
            }),
            // Tiến trình đã kết thúc (khi server đang tắt) hoặc pid bị tái sử dụng.
            // Với agy, nếu transcript chưa có phản hồi thì scanner sẽ hiện lượt là gián đoạn.
            _ => {
                store::delete_running_turn(&row.conversation_id);
                if row.provider == "agy" {
                    store::mark_cut_short_turn(&row.conversation_id);
                }
            }
        }
    }
    found.extend(scan_live_turns());
    adopt_found(state, found)
}

/// Đưa các lượt tìm thấy vào trạng thái stream. Lượt đã có trạng thái trong bộ nhớ thì bỏ qua.
fn adopt_found(state: &AppState, found: Vec<LiveTurn>) -> usize {
    let mut adopted = 0;
    for turn in found {
        let cid = turn.conversation_id.clone();
        let busy_pid = state
            .running_pids
            .lock()
            .map(|m| m.contains_key(&cid))
            .unwrap_or(true);
        let busy_stream = state
            .active_streams
            .lock()
            .map(|m| m.get(&cid).is_some_and(|s| s.is_running))
            .unwrap_or(true);
        if busy_pid || busy_stream {
            continue;
        }
        if let Ok(mut pids) = state.running_pids.lock() {
            pids.insert(cid.clone(), turn.pid);
        }
        if let Ok(mut adopted_map) = state.adopted_turns.lock() {
            adopted_map.insert(cid.clone(), (turn.pid, turn.start_ticks));
        }
        if let Ok(mut streams) = state.active_streams.lock() {
            streams.insert(
                cid.clone(),
                ChatTurnStreamState {
                    conversation_id: cid.clone(),
                    project_path: turn.cwd.clone(),
                    user_prompt: String::new(),
                    streaming_text: String::new(),
                    is_running: true,
                    active_step_type: "recovered".to_string(),
                    started_at: Utc::now().to_rfc3339(),
                    error: String::new(),
                    thinking_text: String::new(),
                    thinking_tokens: 0,
                },
            );
        }
        tracing::info!(
            "Nhận lại lượt chat đang chạy: conversation={} pid={}",
            cid,
            turn.pid
        );
        adopted += 1;
    }
    adopted
}

/// Đóng các lượt đã nhận lại khi tiến trình của chúng kết thúc.
/// Trả về các conversation id vừa được đóng để caller phát session update.
pub fn reconcile_adopted_turns(state: &AppState) -> Vec<String> {
    let adopted: Vec<(String, (u32, u64))> = match state.adopted_turns.lock() {
        Ok(m) => m.iter().map(|(k, v)| (k.clone(), *v)).collect(),
        Err(_) => return Vec::new(),
    };
    let mut closed = Vec::new();
    for (cid, (pid, start_ticks)) in adopted {
        if still_running(pid, start_ticks) {
            continue;
        }
        let owned = match state.adopted_turns.lock() {
            Ok(mut m) if m.get(&cid) == Some(&(pid, start_ticks)) => {
                m.remove(&cid);
                true
            }
            _ => false,
        };
        if !owned {
            // Lượt đã được thay thế bằng lượt khác của server, không đụng tới
            continue;
        }
        store::delete_running_turn(&cid);
        if let Ok(mut pids) = state.running_pids.lock() {
            if pids.get(&cid) == Some(&pid) {
                pids.remove(&cid);
            }
        }
        if let Ok(mut streams) = state.active_streams.lock() {
            if streams.get(&cid).is_some_and(|s| s.is_running) {
                streams.remove(&cid);
            }
        }
        tracing::info!("Lượt chat đã nhận lại đã kết thúc: conversation={}", cid);
        closed.push(cid);
    }
    closed
}

/// Bản ghi lượt đang chạy cho tiến trình hiện tại của server (ghi khi có init)
pub fn running_turn_row(
    conversation_id: &str,
    provider: &str,
    pid: u32,
    cwd: &str,
    started_at: &str,
) -> Option<RunningTurnRow> {
    let start_ticks = process_start_ticks(pid)?;
    Some(RunningTurnRow {
        conversation_id: conversation_id.to_string(),
        provider: provider.to_string(),
        pid,
        start_ticks,
        cwd: cwd.to_string(),
        started_at: started_at.to_string(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn agy_conversation_is_recognized() {
        let argv = [
            "/home/john/.local/bin/agy",
            "--app_data_dir=antigravity",
            "--output-format=stream-json",
            "--conversation",
            "abc-123",
            "-p",
            "hello",
        ];
        assert_eq!(conversation_from_argv(&argv).as_deref(), Some("abc-123"));
    }

    #[test]
    fn agy_equals_form_is_recognized() {
        let argv = ["agy", "--conversation=xyz", "-p", "hi"];
        assert_eq!(conversation_from_argv(&argv).as_deref(), Some("xyz"));
    }

    #[test]
    fn systemd_run_wrapper_is_ignored() {
        let argv = [
            "systemd-run",
            "--user",
            "--scope",
            "--quiet",
            "/home/john/.local/bin/agy",
            "--conversation",
            "abc",
            "-p",
            "hi",
        ];
        assert_eq!(conversation_from_argv(&argv), None);
    }

    #[test]
    fn agy_without_conversation_is_ignored() {
        let argv = ["/home/john/.local/bin/agy", "-p", "hi"];
        assert_eq!(conversation_from_argv(&argv), None);
    }

    #[test]
    fn claude_resume_is_recognized() {
        let argv = [
            "/home/john/.local/bin/claude",
            "-p",
            "hi",
            "--output-format",
            "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--model",
            "sonnet",
            "--resume",
            "sess-1",
            "--add-dir",
            "/home/john/project",
        ];
        assert_eq!(conversation_from_argv(&argv).as_deref(), Some("sess-1"));
    }

    #[test]
    fn claude_new_session_without_resume_is_ignored() {
        let argv = [
            "claude",
            "-p",
            "hi",
            "--output-format",
            "stream-json",
            "--add-dir",
            "/p",
        ];
        assert_eq!(conversation_from_argv(&argv), None);
    }

    #[test]
    fn vscode_claude_extension_is_ignored() {
        let argv = [
            "/home/john/.vscode/extensions/anthropic.claude-code/resources/native-binary/claude",
            "--output-format",
            "stream-json",
            "--verbose",
            "--input-format",
            "stream-json",
            "--resume",
            "sess-2",
        ];
        assert_eq!(conversation_from_argv(&argv), None);
    }

    #[test]
    fn own_process_has_start_ticks() {
        let ticks = process_start_ticks(std::process::id());
        assert!(ticks.is_some_and(|t| t > 0));
        assert_eq!(process_start_ticks(u32::MAX), None);
    }

    /// Tiến trình thật có argv giống lượt agy (có `--conversation`): được nhận lại khi đang chạy,
    /// đóng lại khi kết thúc. Dùng hàm quét argv để không phụ thuộc bảng SQLite.
    #[test]
    fn adopts_live_process_and_releases_it_after_exit() {
        use std::os::unix::process::CommandExt;
        use std::time::Duration;

        let (_layer, io) = socketioxide::SocketIo::builder().build_layer();
        let state = AppState::new(io);
        let cid = format!("recovery-test-{}", std::process::id());

        let mut child = std::process::Command::new("sh")
            .arg0("/nonexistent/agy")
            .args(["-c", "sleep 20; true", "--conversation", &cid, "-p", "hi"])
            .spawn()
            .expect("không khởi chạy được tiến trình giả lập");
        std::thread::sleep(Duration::from_millis(200));

        let found: Vec<LiveTurn> = scan_live_turns()
            .into_iter()
            .filter(|t| t.conversation_id == cid)
            .collect();
        assert_eq!(found.len(), 1);
        adopt_found(&state, found);

        assert_eq!(
            state
                .adopted_turns
                .lock()
                .unwrap()
                .get(&cid)
                .map(|(p, _)| *p),
            Some(child.id())
        );
        assert!(state
            .active_streams
            .lock()
            .unwrap()
            .get(&cid)
            .is_some_and(|s| s.is_running));
        assert!(reconcile_adopted_turns(&state).is_empty());

        child.kill().unwrap();
        child.wait().unwrap();

        assert_eq!(reconcile_adopted_turns(&state), vec![cid.clone()]);
        assert!(!state.adopted_turns.lock().unwrap().contains_key(&cid));
        assert!(!state.running_pids.lock().unwrap().contains_key(&cid));
        assert!(!state.active_streams.lock().unwrap().contains_key(&cid));
    }
}
