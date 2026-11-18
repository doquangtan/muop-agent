// Gom steps của một session thành các "lượt" (turn): mỗi lượt = một tin user + các phản hồi AI
// + thao tác (tool) + tệp thay đổi. Tương đương cách chat_canvas_view.dart hiển thị một thẻ AI.

use crate::api::{FileTouch, Session};

#[derive(Default, Debug)]
pub struct Turn {
    pub user: Option<String>,
    pub ai_texts: Vec<String>,
    pub tools: Vec<String>,
    pub files: Vec<String>,
    /// Chỉ số step đầu tiên của lượt (dùng để gán tệp thay đổi)
    pub first_step: usize,
}

fn is_user_step(source: &str, step_type: &str) -> bool {
    source == "USER_EXPLICIT" || step_type == "USER_INPUT"
}

fn format_file(f: &FileTouch) -> String {
    let mut line = format!("{} · {}", f.action, f.path);
    if f.added_lines > 0 || f.removed_lines > 0 {
        line.push_str(&format!("  (+{} / -{})", f.added_lines, f.removed_lines));
    }
    line
}

pub fn build_turns(session: &Session) -> Vec<Turn> {
    let mut turns: Vec<Turn> = Vec::new();
    for step in &session.steps {
        if is_user_step(&step.source, &step.step_type) {
            let text = step.content.trim();
            turns.push(Turn {
                user: (!text.is_empty()).then(|| text.to_string()),
                first_step: step.step_index,
                ..Default::default()
            });
            continue;
        }
        if step.source != "MODEL" {
            continue;
        }
        if turns.is_empty() {
            turns.push(Turn {
                first_step: step.step_index,
                ..Default::default()
            });
        }
        let turn = turns.last_mut().expect("vừa push");
        let text = step.content.trim();
        if !text.is_empty() {
            turn.ai_texts.push(text.to_string());
        }
        for tc in &step.tool_calls {
            turn.tools.push(if tc.summary_label.is_empty() {
                tc.name.clone()
            } else {
                tc.summary_label.clone()
            });
        }
    }

    // Tệp thay đổi thuộc lượt có first_step lớn nhất nhưng ≤ step_index của tệp
    for f in &session.files_touched {
        if let Some(turn) = turns
            .iter_mut()
            .filter(|t| t.first_step <= f.step_index)
            .last()
        {
            turn.files.push(format_file(f));
        }
    }
    turns
}
