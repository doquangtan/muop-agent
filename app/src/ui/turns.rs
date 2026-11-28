//! Gán tệp đã đổi và tool call cho từng lượt của agent. Hàm thuần, có test.

use crate::data::models::{AgentStep, FileTouched};

/// Tệp thuộc lượt của bước `index` (một `PLANNER_RESPONSE`).
///
/// Một lượt gồm mọi bước từ tin `USER_INPUT` trước đó đến tin `USER_INPUT` kế tiếp (không gồm).
/// Tệp của cả lượt được gắn vào bước `PLANNER_RESPONSE` cuối cùng của lượt; các bước
/// `PLANNER_RESPONSE` trước đó chỉ nhận tệp đã đổi đến bước của chính chúng.
/// Khi chưa có tin người dùng trong cửa sổ hiển thị, giới hạn dưới là bước đầu của cửa sổ.
/// Trùng đường dẫn thì giữ bản ghi sau cùng.
pub fn files_for_turn(
    steps: &[AgentStep],
    files: &[FileTouched],
    index: usize,
) -> Vec<FileTouched> {
    let Some(step) = steps.get(index) else {
        return Vec::new();
    };
    let own = step.step_index as i64;
    let lower = steps[..index]
        .iter()
        .rev()
        .find(|s| s.kind == "USER_INPUT")
        .map(|s| s.step_index as i64)
        .unwrap_or_else(|| steps.first().map(|s| s.step_index as i64).unwrap_or(0) - 1);
    let after = &steps[index + 1..];
    let next_user = after
        .iter()
        .find(|s| s.kind == "USER_INPUT")
        .map(|s| s.step_index as i64);
    let is_last_reply = !after
        .iter()
        .take_while(|s| s.kind != "USER_INPUT")
        .any(|s| s.kind == "PLANNER_RESPONSE");

    let mut out: Vec<FileTouched> = Vec::new();
    for file in files {
        let at = file.step_index as i64;
        let in_turn = at > lower
            && if is_last_reply {
                next_user.is_none_or(|n| at < n)
            } else {
                at <= own
            };
        if !in_turn {
            continue;
        }
        match out.iter_mut().find(|existing| existing.path == file.path) {
            Some(existing) => *existing = file.clone(),
            None => out.push(file.clone()),
        }
    }
    out
}

/// Tổng dòng thêm/bớt của một danh sách tệp, dùng cho nhãn chip.
pub fn line_totals(files: &[FileTouched]) -> (u64, u64) {
    files
        .iter()
        .fold((0, 0), |(a, r), f| (a + f.added_lines, r + f.removed_lines))
}

/// Chuỗi JSON của tham số tool, cắt bớt để hộp thoại không quá dài.
pub fn preview_args(args: &serde_json::Value) -> String {
    if args.is_null() {
        return String::new();
    }
    let text = serde_json::to_string_pretty(args).unwrap_or_default();
    const LIMIT: usize = 1200;
    if text.chars().count() <= LIMIT {
        text
    } else {
        let cut: String = text.chars().take(LIMIT).collect();
        format!("{cut}\n…")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn step(i: u64, kind: &str) -> AgentStep {
        AgentStep {
            step_index: i,
            kind: kind.into(),
            ..Default::default()
        }
    }

    fn file(path: &str, at: u64, added: u64) -> FileTouched {
        FileTouched {
            path: path.into(),
            step_index: at,
            added_lines: added,
            ..Default::default()
        }
    }

    #[test]
    fn files_belong_to_the_turn_between_user_steps() {
        let steps = vec![
            step(1, "USER_INPUT"),
            step(2, "PLANNER_RESPONSE"),
            step(4, "TOOL"),
            step(5, "USER_INPUT"),
            step(6, "PLANNER_RESPONSE"),
        ];
        let files = vec![
            file("a", 2, 1),
            file("b", 4, 2),
            file("c", 6, 3),
            file("d", 7, 9),
        ];
        // Lượt 1 có bước trả lời ở 2 và tool ở 4: tệp của cả lượt gắn vào bước trả lời cuối (chỉ có một)
        let first: Vec<_> = files_for_turn(&steps, &files, 1)
            .into_iter()
            .map(|f| f.path)
            .collect();
        assert_eq!(first, vec!["a", "b"]);
        // Lượt 2 là lượt cuối: nhận mọi tệp sau tin người dùng thứ hai
        let second: Vec<_> = files_for_turn(&steps, &files, 4)
            .into_iter()
            .map(|f| f.path)
            .collect();
        assert_eq!(second, vec!["c", "d"]);
    }

    #[test]
    fn earlier_reply_in_same_turn_gets_only_its_own_files() {
        let steps = vec![
            step(1, "USER_INPUT"),
            step(2, "PLANNER_RESPONSE"),
            step(4, "PLANNER_RESPONSE"),
        ];
        let files = vec![file("a", 2, 1), file("b", 4, 2)];
        let first: Vec<_> = files_for_turn(&steps, &files, 1)
            .into_iter()
            .map(|f| f.path)
            .collect();
        let last: Vec<_> = files_for_turn(&steps, &files, 2)
            .into_iter()
            .map(|f| f.path)
            .collect();
        assert_eq!(first, vec!["a"]);
        // Bước trả lời cuối của lượt nhận toàn bộ tệp của lượt
        assert_eq!(last, vec!["a", "b"]);
    }

    #[test]
    fn same_path_keeps_last_record_and_totals_add_up() {
        let steps = vec![step(1, "USER_INPUT"), step(3, "PLANNER_RESPONSE")];
        let files = vec![file("a", 2, 1), file("a", 3, 5), file("b", 3, 2)];
        let got = files_for_turn(&steps, &files, 1);
        assert_eq!(got.len(), 2);
        assert_eq!(got[0].added_lines, 5);
        assert_eq!(line_totals(&got), (7, 0));
    }

    #[test]
    fn first_turn_in_window_ignores_files_older_than_window() {
        let steps = vec![step(10, "PLANNER_RESPONSE")];
        let files = vec![file("old", 3, 1), file("new", 10, 1)];
        let got: Vec<_> = files_for_turn(&steps, &files, 0)
            .into_iter()
            .map(|f| f.path)
            .collect();
        assert_eq!(got, vec!["new"]);
    }

    #[test]
    fn preview_args_is_empty_for_null_and_truncates_long_values() {
        assert_eq!(preview_args(&serde_json::Value::Null), "");
        let long = serde_json::json!({"text": "x".repeat(5000)});
        let shown = preview_args(&long);
        assert!(shown.ends_with('…'));
        assert!(shown.chars().count() <= 1210);
    }
}
