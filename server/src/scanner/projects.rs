use super::*;

pub fn discover_projects(sessions: &[ConversationSession]) -> Vec<ProjectWorkspace> {
    let mut project_map: HashMap<String, (String, usize, usize, Option<String>)> = HashMap::new();

    // Chưa khởi tạo (hoặc chưa chọn thư mục project) thì không quét project nào
    if let Some(root) = crate::setup::workspace_root() {
        for entry in fs::read_dir(root).into_iter().flatten().flatten() {
            let path = entry.path();
            if path.is_dir() {
                if let Some(name) = path.file_name().and_then(|n| n.to_str()) {
                    if !name.starts_with('.') {
                        project_map.insert(
                            name.to_string(),
                            (path.to_string_lossy().to_string(), 0, 0, None),
                        );
                    }
                }
            }
        }
    }

    for s in sessions {
        let entry = project_map
            .entry(s.project_name.clone())
            .or_insert_with(|| (s.project_path.clone(), 0, 0, None));
        entry.1 += 1;
        if s.status == "running" {
            entry.2 += 1;
        }
        let update_str = s.updated_at.clone();
        match &entry.3 {
            Some(prev) => {
                if update_str > *prev {
                    entry.3 = Some(update_str);
                }
            }
            None => entry.3 = Some(update_str),
        }
    }

    let mut list: Vec<ProjectWorkspace> = project_map
        .into_iter()
        .map(|(name, (path, count, running, last_active))| {
            let git_sync_status = check_git_sync_status(&path);
            let (custom_agents, available_agents) =
                scan_project_agents_and_skills(Path::new(&path));
            let is_mount = crate::fsmount::is_mount_path(&path);
            let mount_live = is_mount && crate::fsmount::is_alive(Path::new(&path));
            ProjectWorkspace {
                id: name.clone(),
                name,
                path,
                session_count: count,
                running_count: running,
                last_active_at: last_active,
                git_sync_status,
                custom_agents,
                available_agents,
                is_mount,
                mount_live,
            }
        })
        .collect();

    list.sort_by(|a, b| {
        b.running_count
            .cmp(&a.running_count)
            .then_with(|| b.session_count.cmp(&a.session_count))
            .then_with(|| a.name.cmp(&b.name))
    });

    list
}

pub fn create_new_project(
    name: &str,
    template: &str,
    description: &str,
) -> Result<ProjectWorkspace, String> {
    let trimmed_name = name.trim();
    if trimmed_name.is_empty() {
        return Err("Tên dự án không được để trống".to_string());
    }

    if !trimmed_name
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
    {
        return Err(
            "Tên dự án chỉ được chứa chữ cái, số, gạch nối (-) và gạch dưới (_)".to_string(),
        );
    }

    let root = crate::setup::workspace_root()
        .ok_or("Chưa khởi tạo thư mục project (Cài đặt → Thư mục project)")?;
    let target_path = root.join(trimmed_name);
    if target_path.exists() {
        return Err(format!(
            "Dự án [{}] đã tồn tại trong thư mục project",
            trimmed_name
        ));
    }

    fs::create_dir_all(&target_path).map_err(|e| format!("Không thể tạo thư mục dự án: {}", e))?;

    let desc_text = if description.trim().is_empty() {
        format!("Dự án {}", trimmed_name)
    } else {
        description.trim().to_string()
    };

    match template {
        "go" => {
            let mod_name = trimmed_name.replace('-', "_");
            let go_mod = format!("module muop/{}\n\ngo 1.22\n", mod_name);
            let _ = fs::write(target_path.join("go.mod"), go_mod);
            let main_go = format!(
                "package main\n\nimport \"fmt\"\n\nfunc main() {{\n    fmt.Println(\"🚀 Khởi chạy dự án {}!\")\n}}\n",
                trimmed_name
            );
            let _ = fs::write(target_path.join("main.go"), main_go);
            let gitignore =
                "*.exe\n*.exe~\n*.dll\n*.so\n*.dylib\n*.test\n*.out\nvendor/\n.idea/\n.vscode/\n";
            let _ = fs::write(target_path.join(".gitignore"), gitignore);
            let readme = format!(
                "# {}\n\n{}\n\n- Ngôn ngữ: Go\n- Kiến trúc: Hexagonal Clean Architecture\n- Khởi tạo qua: Mướp Agent Monitor\n",
                trimmed_name, desc_text
            );
            let _ = fs::write(target_path.join("README.md"), readme);
        }
        "flutter" => {
            let clean_name = trimmed_name.replace('-', "_").to_lowercase();
            let pubspec = format!(
                "name: {}\ndescription: \"{}\"\nversion: 1.0.0+1\nenvironment:\n  sdk: '>=3.0.0 <4.0.0'\ndependencies:\n  flutter:\n    sdk: flutter\n  flutter_riverpod: ^2.5.1\ndev_dependencies:\n  flutter_test:\n    sdk: flutter\n  flutter_lints: ^3.0.0\nflutter:\n  uses-material-design: true\n",
                clean_name, desc_text
            );
            let _ = fs::write(target_path.join("pubspec.yaml"), pubspec);
            let lib_dir = target_path.join("lib");
            let _ = fs::create_dir_all(&lib_dir);
            let main_dart = format!(
                "import 'package:flutter/material.dart';\n\nvoid main() {{\n  runApp(const MyApp());\n}}\n\nclass MyApp extends StatelessWidget {{\n  const MyApp({{super.key}});\n\n  @override\n  Widget build(BuildContext context) {{\n    return MaterialApp(\n      title: '{}',\n      theme: ThemeData(useMaterial3: true),\n      home: const Scaffold(\n        body: Center(\n          child: Text('{} - Mướp Ecosystem'),\n        ),\n      ),\n    );\n  }}\n}}\n",
                trimmed_name, trimmed_name
            );
            let _ = fs::write(lib_dir.join("main.dart"), main_dart);
            let gitignore = ".dart_tool/\n.flutter-plugins\n.flutter-plugins-dependencies\n.packages\nbuild/\n.idea/\n.vscode/\n";
            let _ = fs::write(target_path.join(".gitignore"), gitignore);
            let readme = format!(
                "# {}\n\n{}\n\n- Nền tảng: Flutter Client\n- Material 3 & Riverpod\n- Khởi tạo qua: Mướp Agent Monitor\n",
                trimmed_name, desc_text
            );
            let _ = fs::write(target_path.join("README.md"), readme);
        }
        _ => {
            let gitignore = ".idea/\n.vscode/\n*.log\n.DS_Store\nnode_modules/\n";
            let _ = fs::write(target_path.join(".gitignore"), gitignore);
            let readme = format!(
                "# {}\n\n{}\n\nKhởi tạo tự động qua Mướp Agent Monitor.\n",
                trimmed_name, desc_text
            );
            let _ = fs::write(target_path.join("README.md"), readme);
        }
    }

    let (custom_agents, available_agents) = scan_project_agents_and_skills(&target_path);
    Ok(ProjectWorkspace {
        id: trimmed_name.to_string(),
        name: trimmed_name.to_string(),
        path: target_path.to_string_lossy().to_string(),
        session_count: 0,
        running_count: 0,
        last_active_at: Some(Utc::now().to_rfc3339()),
        git_sync_status: None,
        custom_agents,
        available_agents,
        is_mount: false,
        mount_live: false,
    })
}

/// Quét toàn bộ agents, skills, rules từ thư mục `.agents/` của project (hoặc tệp `.agents`)
pub fn scan_project_agents_and_skills(project_path: &Path) -> (Vec<CustomAgentSpec>, Vec<String>) {
    let mut specs = Vec::new();
    let mut available_agents = vec!["Coordinator".to_string()];

    // 1. Quét từ thư mục .agents hoặc file .agents trong project
    let agents_dir = project_path.join(".agents");
    if agents_dir.exists() {
        if agents_dir.is_dir() {
            scan_agent_subdir(&agents_dir.join("agents"), "agent", &mut specs);
            scan_agent_subdir(&agents_dir.join("skills"), "skill", &mut specs);
            scan_agent_subdir(&agents_dir.join("rules"), "rule", &mut specs);
        } else if agents_dir.is_file() {
            if let Ok(raw) = fs::read_to_string(&agents_dir) {
                let stem = agents_dir
                    .file_stem()
                    .and_then(|s| s.to_str())
                    .unwrap_or("agent");
                let (name, desc, _) = parse_markdown_frontmatter(&raw, stem, "agent");
                specs.push(CustomAgentSpec {
                    name,
                    description: desc,
                    kind: "agent".to_string(),
                    file_path: agents_dir.to_string_lossy().to_string(),
                    body_content: String::new(),
                });
            }
        }
    }

    // 2. Thêm built-in skills từ ~/.gemini/antigravity/builtin/skills nếu chưa có
    let builtin_skills_dir = crate::infra::paths::antigravity_dir().join("builtin/skills");
    if builtin_skills_dir.exists() {
        scan_agent_subdir(&builtin_skills_dir, "skill", &mut specs);
    }

    // Lọc danh sách available_agents: Coordinator + các agent có kind == "agent"
    for s in &specs {
        if s.kind == "agent" && !available_agents.contains(&s.name) {
            available_agents.push(s.name.clone());
        }
    }

    (specs, available_agents)
}

/// Agent và skill tùy chỉnh của project đã cấu hình (`<thư mục project>/muop-erp-server`, nếu có)
pub fn load_custom_agent_specs() -> Vec<CustomAgentSpec> {
    let Some(root) = crate::setup::workspace_root() else {
        return Vec::new();
    };
    let (specs, _) = scan_project_agents_and_skills(&root.join("muop-erp-server"));
    specs
}

pub(super) fn scan_agent_subdir(dir: &Path, kind: &str, specs: &mut Vec<CustomAgentSpec>) {
    if !dir.exists() {
        return;
    }
    if let Ok(entries) = fs::read_dir(dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                scan_agent_subdir(&path, kind, specs);
            } else if path.extension().and_then(|e| e.to_str()) == Some("md") {
                if let Ok(raw) = fs::read_to_string(&path) {
                    let file_stem = path
                        .file_stem()
                        .and_then(|s| s.to_str())
                        .unwrap_or("custom")
                        .to_string();
                    let default_name = if file_stem == "SKILL" || file_stem == "skill" {
                        path.parent()
                            .and_then(|p| p.file_name())
                            .and_then(|n| n.to_str())
                            .unwrap_or(&file_stem)
                    } else {
                        &file_stem
                    };
                    let (name, desc, _) = parse_markdown_frontmatter(&raw, default_name, kind);
                    if !specs.iter().any(|s| s.name == name && s.kind == kind) {
                        specs.push(CustomAgentSpec {
                            name,
                            description: desc,
                            kind: kind.to_string(),
                            file_path: path.to_string_lossy().to_string(),
                            body_content: String::new(),
                        });
                    }
                }
            }
        }
    }
}

pub(crate) fn parse_markdown_frontmatter(
    raw: &str,
    default_name: &str,
    kind: &str,
) -> (String, String, String) {
    let mut name = default_name.to_string();
    let mut desc = format!("Cấu hình {}", kind);
    let mut body = raw.to_string();

    if raw.starts_with("---") {
        if let Some(end_idx) = raw[3..].find("\n---") {
            let header = raw[3..3 + end_idx].trim();
            body = raw[3 + end_idx + 4..].trim().to_string();

            let mut current_key = "";
            let mut desc_buf = String::new();
            for line in header.lines() {
                let trimmed = line.trim();
                if let Some(rest) = trimmed.strip_prefix("name:") {
                    current_key = "name";
                    let n = rest.trim();
                    if !n.is_empty() {
                        name = n.to_string();
                    }
                } else if let Some(rest) = trimmed.strip_prefix("description:") {
                    current_key = "description";
                    let after = rest.trim();
                    if after != ">-" && after != ">" && after != "|" && !after.is_empty() {
                        desc_buf.push_str(after);
                    }
                } else if current_key == "description" && line.starts_with("  ") {
                    if !desc_buf.is_empty() {
                        desc_buf.push(' ');
                    }
                    desc_buf.push_str(trimmed);
                } else if trimmed.contains(':') {
                    current_key = "";
                }
            }
            if !desc_buf.is_empty() {
                desc = desc_buf;
            }
        }
    }

    (name, desc, body)
}
