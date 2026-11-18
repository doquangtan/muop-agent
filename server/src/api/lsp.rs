use crate::lsp;
use crate::models::*;
use axum::{extract::Query, http::StatusCode, response::IntoResponse, Json};
use serde_json::json;
use std::collections::HashMap;
use std::path::Path;

/// Trạng thái LSP của Go / Dart / Rust (đường dẫn cấu hình, đường dẫn tự dò)
pub async fn handle_lsp_settings_get() -> impl IntoResponse {
    Json(json!({"ok": true, "error": "", "languages": lsp::all_status()}))
}

/// Đặt hoặc xóa đường dẫn LSP của một ngôn ngữ (lưu trong SQLite)
pub async fn handle_lsp_settings_set(Json(req): Json<LspSettingRequest>) -> impl IntoResponse {
    let Some(lang) = lsp::Lang::from_key(req.language.trim()) else {
        return (
            StatusCode::BAD_REQUEST,
            Json(
                json!({"ok": false, "error": "Ngôn ngữ phải là go, dart hoặc rust", "languages": []}),
            ),
        );
    };
    let path = req.path.trim().to_string();
    if path.is_empty() {
        crate::infra::store::delete_lsp_path(lang.key());
    } else {
        if !lsp::is_executable(Path::new(&path)) || !lsp::runs(lang, Path::new(&path)) {
            return (
                StatusCode::BAD_REQUEST,
                Json(json!({
                    "ok": false,
                    "error": "Tệp không tồn tại, không có quyền chạy, hoặc chạy thử (--version / version) thất bại",
                    "languages": lsp::all_status()
                })),
            );
        }
        if !crate::infra::store::set_lsp_path(lang.key(), &path) {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(
                    json!({"ok": false, "error": "Không lưu được cấu hình", "languages": lsp::all_status()}),
                ),
            );
        }
    }
    (
        StatusCode::OK,
        Json(json!({"ok": true, "error": "", "languages": lsp::all_status()})),
    )
}

pub fn code_error(msg: String) -> Json<serde_json::Value> {
    Json(json!({"ok": false, "error": msg}))
}

/// Gấp code: các vùng gấp (folding ranges) của tệp, lấy từ LSP
pub async fn handle_code_fold(Query(params): Query<HashMap<String, String>>) -> impl IntoResponse {
    let path = params
        .get("path")
        .map(|s| s.trim().to_string())
        .unwrap_or_default();
    match lsp::folding_ranges(Path::new(&path)).await {
        Ok((language, ranges)) => {
            Json(json!({"ok": true, "error": "", "language": language, "ranges": ranges}))
        }
        Err(e) => code_error(e),
    }
}

/// Danh sách ký hiệu của tệp (hàm, class, method...), lấy từ LSP
pub async fn handle_code_symbols(
    Query(params): Query<HashMap<String, String>>,
) -> impl IntoResponse {
    let path = params
        .get("path")
        .map(|s| s.trim().to_string())
        .unwrap_or_default();
    match lsp::document_symbols(Path::new(&path)).await {
        Ok(symbols) => Json(json!({"ok": true, "error": "", "symbols": symbols})),
        Err(e) => code_error(e),
    }
}

/// Token ngữ nghĩa để tô màu cú pháp, lấy từ LSP
pub async fn handle_code_tokens(
    Query(params): Query<HashMap<String, String>>,
) -> impl IntoResponse {
    let path = params
        .get("path")
        .map(|s| s.trim().to_string())
        .unwrap_or_default();
    match lsp::semantic_tokens(Path::new(&path)).await {
        Ok(tokens) => {
            Json(json!({"ok": true, "error": "", "kinds": tokens.kinds, "data": tokens.data}))
        }
        Err(e) => code_error(e),
    }
}

/// Tham chiếu (references) tới ký hiệu tại con trỏ, lấy từ LSP
pub async fn handle_code_references(Json(req): Json<CodeDefinitionRequest>) -> impl IntoResponse {
    match lsp::references(Path::new(req.path.trim()), req.line, req.character).await {
        Ok(locations) => Json(json!({"ok": true, "error": "", "locations": locations})),
        Err(e) => code_error(e),
    }
}

/// Nội dung hover của ký hiệu tại con trỏ, lấy từ LSP
pub async fn handle_code_hover(Json(req): Json<CodeDefinitionRequest>) -> impl IntoResponse {
    match lsp::hover(Path::new(req.path.trim()), req.line, req.character).await {
        Ok(contents) => Json(json!({"ok": true, "error": "", "contents": contents})),
        Err(e) => code_error(e),
    }
}

/// Định nghĩa của ký hiệu tại con trỏ (Ctrl+click), lấy từ LSP
pub async fn handle_code_definition(Json(req): Json<CodeDefinitionRequest>) -> impl IntoResponse {
    match lsp::definition(Path::new(req.path.trim()), req.line, req.character).await {
        Ok(locations) => Json(json!({"ok": true, "error": "", "locations": locations})),
        Err(e) => code_error(e),
    }
}
