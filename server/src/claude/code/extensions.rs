use super::*;

/// Quét extension của Claude Code theo hai phạm vi: `<project>/.claude` (ưu tiên)
/// rồi `~/.claude`. Gồm skills (`skills/<name>/SKILL.md`), agents (`agents/**/*.md`)
/// và commands (`commands/**/*.md`, thư mục con thành namespace `dir:name`).
pub fn scan_claude_extensions(project_path: &str) -> Vec<CustomAgentSpec> {
    let mut roots = Vec::new();
    if !project_path.trim().is_empty() {
        roots.push(Path::new(project_path.trim()).join(".claude"));
    }
    roots.push(home_dir().join(".claude"));

    let mut specs: Vec<CustomAgentSpec> = Vec::new();
    for root in &roots {
        scan_claude_skill_dir(&root.join("skills"), &mut specs);
        scan_claude_md_dir(&root.join("agents"), "", "agent", &mut specs);
        scan_claude_md_dir(&root.join("commands"), "", "command", &mut specs);
    }
    specs.sort_by(|a, b| a.kind.cmp(&b.kind).then_with(|| a.name.cmp(&b.name)));
    specs
}

pub(super) fn push_claude_spec(specs: &mut Vec<CustomAgentSpec>, spec: CustomAgentSpec) {
    if !specs
        .iter()
        .any(|s| s.kind == spec.kind && s.name == spec.name)
    {
        specs.push(spec);
    }
}

pub(super) fn scan_claude_skill_dir(dir: &Path, specs: &mut Vec<CustomAgentSpec>) {
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let skill_file = entry.path().join("SKILL.md");
        let Ok(raw) = fs::read_to_string(&skill_file) else {
            continue;
        };
        let folder = entry.file_name().to_string_lossy().to_string();
        let (name, description, _) = parse_markdown_frontmatter(&raw, &folder, "skill");
        push_claude_spec(
            specs,
            CustomAgentSpec {
                name,
                description,
                kind: "skill".to_string(),
                file_path: skill_file.to_string_lossy().to_string(),
                body_content: String::new(),
            },
        );
    }
}

pub(super) fn scan_claude_md_dir(
    dir: &Path,
    prefix: &str,
    kind: &str,
    specs: &mut Vec<CustomAgentSpec>,
) {
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let file_name = entry.file_name().to_string_lossy().to_string();
        if path.is_dir() {
            let nested = if prefix.is_empty() {
                file_name
            } else {
                format!("{prefix}:{file_name}")
            };
            scan_claude_md_dir(&path, &nested, kind, specs);
            continue;
        }
        if path.extension().and_then(|e| e.to_str()) != Some("md") {
            continue;
        }
        let Ok(raw) = fs::read_to_string(&path) else {
            continue;
        };
        let stem = path
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or_default()
            .to_string();
        let base = if prefix.is_empty() {
            stem
        } else {
            format!("{prefix}:{stem}")
        };
        let (frontmatter_name, description, _) = parse_markdown_frontmatter(&raw, &base, kind);
        let name = if kind == "agent" {
            frontmatter_name
        } else {
            base
        };
        push_claude_spec(
            specs,
            CustomAgentSpec {
                name,
                description,
                kind: kind.to_string(),
                file_path: path.to_string_lossy().to_string(),
                body_content: String::new(),
            },
        );
    }
}
