use crate::chat::AppState;
use crate::models::*;
use crate::scanner;
use axum::{
    extract::{Query, State},
    http::StatusCode,
    response::IntoResponse,
    Json,
};
use serde_json::json;
use std::collections::HashMap;
use std::path::PathBuf;

pub async fn handle_project_agents(
    Query(params): Query<HashMap<String, String>>,
) -> impl IntoResponse {
    let project_path = if let Some(p) = params
        .get("path")
        .map(|s| s.trim())
        .filter(|s| !s.is_empty())
    {
        PathBuf::from(p)
    } else if let Some(n) = params
        .get("name")
        .map(|s| s.trim())
        .filter(|s| !s.is_empty())
    {
        match crate::setup::workspace_root() {
            Some(root) => root.join(n),
            None => {
                return (
                    StatusCode::CONFLICT,
                    Json(json!({
                        "ok": false,
                        "error": "Chưa khởi tạo thư mục project (Cài đặt → Thư mục project)"
                    })),
                )
                    .into_response();
            }
        }
    } else {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({ "ok": false, "error": "Thiếu tham số path hoặc name của project" })),
        )
            .into_response();
    };

    let (specs, available) = scanner::scan_project_agents_and_skills(&project_path);
    let project_name = project_path
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or("project")
        .to_string();

    let mut custom_agents = Vec::new();
    let mut skills = Vec::new();
    let mut rules = Vec::new();
    for s in specs {
        if s.kind == "agent" {
            custom_agents.push(s);
        } else if s.kind == "skill" {
            skills.push(s);
        } else if s.kind == "rule" {
            rules.push(s);
        }
    }

    (
        StatusCode::OK,
        Json(crate::models::ProjectAgentsResponse {
            ok: true,
            project_path: project_path.to_string_lossy().to_string(),
            project_name,
            available_agents: available,
            custom_agents,
            skills,
            rules,
            error: None,
        }),
    )
        .into_response()
}

pub async fn handle_claude_extensions(
    Query(params): Query<HashMap<String, String>>,
) -> impl IntoResponse {
    let project_path = params
        .get("path")
        .map(|s| s.trim().to_string())
        .unwrap_or_default();
    let items = crate::claude::code::scan_claude_extensions(&project_path);
    (
        StatusCode::OK,
        Json(ClaudeExtensionsResponse { ok: true, items }),
    )
}

pub async fn handle_project_create(
    State(state): State<AppState>,
    Json(req): Json<crate::models::CreateProjectRequest>,
) -> impl IntoResponse {
    match scanner::create_new_project(&req.name, &req.template, &req.description) {
        Ok(project) => {
            state.broadcast_projects_update();
            (
                StatusCode::OK,
                Json(crate::models::CreateProjectResponse {
                    ok: true,
                    message: format!("Đã tạo thành công dự án [{}]", project.name),
                    project: Some(project),
                    error: None,
                }),
            )
        }
        Err(err) => (
            StatusCode::BAD_REQUEST,
            Json(crate::models::CreateProjectResponse {
                ok: false,
                message: err.clone(),
                project: None,
                error: Some(err),
            }),
        ),
    }
}
