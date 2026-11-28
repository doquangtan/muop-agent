//! Markdown tối thiểu cho phản hồi của agent: tiêu đề, đoạn văn, danh sách, khối code,
//! `code` và **đậm**. Parser là hàm thuần (có test); render nằm ở `MarkdownView`.

use dioxus::prelude::*;

#[derive(Debug, Clone, PartialEq)]
pub enum Span {
    Text(String),
    Code(String),
    Bold(String),
}

#[derive(Debug, Clone, PartialEq)]
pub enum Block {
    Heading {
        level: u8,
        spans: Vec<Span>,
    },
    Paragraph(Vec<Span>),
    Code {
        text: String,
    },
    List {
        ordered: bool,
        items: Vec<Vec<Span>>,
    },
}

/// Tách văn bản thành các khối.
pub fn parse(src: &str) -> Vec<Block> {
    let lines: Vec<&str> = src.lines().collect();
    let mut blocks = Vec::new();
    let mut i = 0;
    while i < lines.len() {
        let line = lines[i];
        let trimmed = line.trim_start();

        if trimmed.starts_with("```") {
            let mut code = Vec::new();
            i += 1;
            while i < lines.len() && !lines[i].trim_start().starts_with("```") {
                code.push(lines[i]);
                i += 1;
            }
            i += 1; // bỏ dòng đóng (nếu có)
            blocks.push(Block::Code {
                text: code.join("\n"),
            });
            continue;
        }

        if trimmed.is_empty() {
            i += 1;
            continue;
        }

        if let Some((level, rest)) = heading(trimmed) {
            blocks.push(Block::Heading {
                level,
                spans: inline(rest),
            });
            i += 1;
            continue;
        }

        if let Some((ordered, _)) = list_marker(trimmed) {
            let mut items = Vec::new();
            while i < lines.len() {
                match list_marker(lines[i].trim_start()) {
                    Some((o, rest)) if o == ordered => {
                        items.push(inline(rest));
                        i += 1;
                    }
                    _ => break,
                }
            }
            blocks.push(Block::List { ordered, items });
            continue;
        }

        // Đoạn văn: gom các dòng liên tiếp cho tới dòng trống hoặc khối khác
        let mut para = Vec::new();
        while i < lines.len() {
            let t = lines[i].trim_start();
            if t.is_empty()
                || t.starts_with("```")
                || heading(t).is_some()
                || list_marker(t).is_some()
            {
                break;
            }
            para.push(lines[i]);
            i += 1;
        }
        blocks.push(Block::Paragraph(inline(&para.join("\n"))));
    }
    blocks
}

/// `## Tiêu đề` → (2, "Tiêu đề"). Tối đa 6 cấp.
fn heading(line: &str) -> Option<(u8, &str)> {
    let level = line.chars().take_while(|c| *c == '#').count();
    if (1..=6).contains(&level) && line[level..].starts_with(' ') {
        Some((level as u8, line[level..].trim()))
    } else {
        None
    }
}

/// `- x`, `* x` → (false, "x"); `1. x` → (true, "x").
fn list_marker(line: &str) -> Option<(bool, &str)> {
    if let Some(rest) = line.strip_prefix("- ").or_else(|| line.strip_prefix("* ")) {
        return Some((false, rest));
    }
    let digits = line.chars().take_while(|c| c.is_ascii_digit()).count();
    if digits > 0 {
        if let Some(rest) = line[digits..].strip_prefix(". ") {
            return Some((true, rest));
        }
    }
    None
}

/// Tách `code` và **đậm** trong một đoạn. Dấu chưa đóng giữ nguyên là chữ thường.
pub fn inline(text: &str) -> Vec<Span> {
    let mut spans = Vec::new();
    let mut rest = text;
    while !rest.is_empty() {
        let code_at = rest.find('`');
        let bold_at = rest.find("**");
        let next = match (code_at, bold_at) {
            (None, None) => None,
            (Some(c), None) => Some((c, '`')),
            (None, Some(b)) => Some((b, '*')),
            (Some(c), Some(b)) => Some(if c <= b { (c, '`') } else { (b, '*') }),
        };
        let Some((at, marker)) = next else {
            spans.push(Span::Text(rest.to_string()));
            break;
        };
        if at > 0 {
            spans.push(Span::Text(rest[..at].to_string()));
        }
        let after = &rest[at..];
        if marker == '`' {
            let body = &after[1..];
            match body.find('`') {
                Some(end) => {
                    spans.push(Span::Code(body[..end].to_string()));
                    rest = &body[end + 1..];
                }
                None => {
                    spans.push(Span::Text("`".into()));
                    rest = body;
                }
            }
        } else {
            let body = &after[2..];
            match body.find("**") {
                Some(end) if end > 0 => {
                    spans.push(Span::Bold(body[..end].to_string()));
                    rest = &body[end + 2..];
                }
                _ => {
                    spans.push(Span::Text("**".into()));
                    rest = body;
                }
            }
        }
    }
    spans
}

#[derive(Props, Clone, PartialEq)]
pub struct MarkdownProps {
    pub text: String,
}

/// Hiển thị Markdown của một phản hồi agent.
#[component]
pub fn MarkdownView(props: MarkdownProps) -> Element {
    let blocks = parse(&props.text);
    rsx! {
        div { class: "md",
            for (index, block) in blocks.into_iter().enumerate() {
                BlockView { key: "{index}", block: block }
            }
        }
    }
}

#[derive(Props, Clone, PartialEq)]
struct BlockProps {
    block: Block,
}

#[component]
fn BlockView(props: BlockProps) -> Element {
    match props.block {
        Block::Heading { level, spans } => {
            let class = format!("md-h md-h{level}");
            rsx! { div { class: "{class}", SpanList { spans: spans } } }
        }
        Block::Paragraph(spans) => rsx! { p { class: "md-p", SpanList { spans: spans } } },
        Block::Code { text } => rsx! { pre { class: "md-code", code { "{text}" } } },
        Block::List { ordered, items } => {
            if ordered {
                rsx! {
                    ol { class: "md-list",
                        for (i, item) in items.into_iter().enumerate() {
                            li { key: "{i}", SpanList { spans: item } }
                        }
                    }
                }
            } else {
                rsx! {
                    ul { class: "md-list",
                        for (i, item) in items.into_iter().enumerate() {
                            li { key: "{i}", SpanList { spans: item } }
                        }
                    }
                }
            }
        }
    }
}

#[derive(Props, Clone, PartialEq)]
struct SpanListProps {
    spans: Vec<Span>,
}

#[component]
fn SpanList(props: SpanListProps) -> Element {
    rsx! {
        for (i, span) in props.spans.into_iter().enumerate() {
            match span {
                Span::Text(t) => rsx! { span { key: "{i}", "{t}" } },
                Span::Code(t) => rsx! { code { key: "{i}", class: "md-inline", "{t}" } },
                Span::Bold(t) => rsx! { strong { key: "{i}", "{t}" } },
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_headings_paragraphs_and_code() {
        let blocks = parse("# Tiêu đề\n\nDòng một\ndòng hai\n\n```rust\nlet x = 1;\n```");
        assert_eq!(
            blocks[0],
            Block::Heading {
                level: 1,
                spans: vec![Span::Text("Tiêu đề".into())]
            }
        );
        assert_eq!(
            blocks[1],
            Block::Paragraph(vec![Span::Text("Dòng một\ndòng hai".into())])
        );
        assert_eq!(
            blocks[2],
            Block::Code {
                text: "let x = 1;".into()
            }
        );
    }

    #[test]
    fn parses_lists_and_groups_items() {
        let blocks = parse("- a\n- b\n1. x");
        assert_eq!(
            blocks[0],
            Block::List {
                ordered: false,
                items: vec![vec![Span::Text("a".into())], vec![Span::Text("b".into())]]
            }
        );
        assert!(matches!(blocks[1], Block::List { ordered: true, .. }));
    }

    #[test]
    fn inline_code_and_bold() {
        assert_eq!(
            inline("Dùng **đậm** và `mã` xong"),
            vec![
                Span::Text("Dùng ".into()),
                Span::Bold("đậm".into()),
                Span::Text(" và ".into()),
                Span::Code("mã".into()),
                Span::Text(" xong".into()),
            ]
        );
    }

    #[test]
    fn unclosed_markers_stay_as_text() {
        assert_eq!(
            inline("a ** b"),
            vec![
                Span::Text("a ".into()),
                Span::Text("**".into()),
                Span::Text(" b".into())
            ]
        );
        assert_eq!(
            inline("x`y"),
            vec![
                Span::Text("x".into()),
                Span::Text("`".into()),
                Span::Text("y".into())
            ]
        );
    }

    #[test]
    fn unclosed_code_fence_runs_to_end() {
        let blocks = parse("```\nabc");
        assert_eq!(blocks, vec![Block::Code { text: "abc".into() }]);
    }
}
