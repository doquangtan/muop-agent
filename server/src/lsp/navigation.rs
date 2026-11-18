use super::*;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DefinitionLocation {
    pub path: String,
    /// Đếm từ 0
    pub line: u32,
    /// Đếm từ 0, theo UTF-16 như LSP
    pub character: u32,
}

/// Chuyển kết quả definition / references (null | Location | Location[] | LocationLink[]) thành danh sách vị trí
pub(super) fn parse_locations(res: Value) -> Vec<DefinitionLocation> {
    let items: Vec<Value> = match res {
        Value::Null => Vec::new(),
        Value::Array(a) => a,
        other => vec![other],
    };
    let mut out = Vec::new();
    for loc in items {
        let (uri, range) = if let Some(target) = loc.get("targetUri") {
            (
                target.as_str().unwrap_or("").to_string(),
                loc.get("targetSelectionRange")
                    .or_else(|| loc.get("targetRange"))
                    .cloned()
                    .unwrap_or(Value::Null),
            )
        } else {
            (
                loc["uri"].as_str().unwrap_or("").to_string(),
                loc["range"].clone(),
            )
        };
        if uri.is_empty() {
            continue;
        }
        out.push(DefinitionLocation {
            path: uri_to_path(&uri),
            line: range["start"]["line"].as_u64().unwrap_or(0) as u32,
            character: range["start"]["character"].as_u64().unwrap_or(0) as u32,
        });
    }
    out
}

pub(super) fn position_params(uri: &str, line: u32, character: u32) -> Value {
    json!({
        "textDocument": {"uri": uri},
        "position": {"line": line, "character": character}
    })
}

/// Tìm định nghĩa của ký hiệu tại vị trí (dòng, cột đếm từ 0)
pub async fn definition(
    path: &Path,
    line: u32,
    character: u32,
) -> Result<Vec<DefinitionLocation>, String> {
    let (client, uri) = prepare(path).await?;
    let res = client
        .request(
            "textDocument/definition",
            position_params(&uri, line, character),
            REQUEST_TIMEOUT,
        )
        .await?;
    Ok(parse_locations(res))
}

/// Tìm mọi chỗ tham chiếu tới ký hiệu tại vị trí (kể cả khai báo)
pub async fn references(
    path: &Path,
    line: u32,
    character: u32,
) -> Result<Vec<DefinitionLocation>, String> {
    let (client, uri) = prepare(path).await?;
    let mut params = position_params(&uri, line, character);
    params["context"] = json!({"includeDeclaration": true});
    let mut locations = Vec::new();
    for attempt in 0..RETRY_EMPTY_TIMES {
        let res = client
            .request("textDocument/references", params.clone(), REQUEST_TIMEOUT)
            .await?;
        locations = parse_locations(res);
        if !locations.is_empty() || attempt + 1 == RETRY_EMPTY_TIMES || !still_warming(&client) {
            break;
        }
        tokio::time::sleep(Duration::from_secs(1)).await;
    }
    Ok(locations)
}

/// Trong giai đoạn lập chỉ mục đầu (60 giây đầu), kết quả rỗng có thể là do chưa phân tích xong.
pub(super) fn still_warming(client: &LspClient) -> bool {
    client.started.elapsed() < Duration::from_secs(60)
}

/// Nội dung hover (kiểu, tài liệu) của ký hiệu tại vị trí, dạng văn bản/markdown
pub async fn hover(path: &Path, line: u32, character: u32) -> Result<String, String> {
    let (client, uri) = prepare(path).await?;
    let params = position_params(&uri, line, character);
    let mut text = String::new();
    for attempt in 0..RETRY_EMPTY_TIMES {
        let res = client
            .request("textDocument/hover", params.clone(), REQUEST_TIMEOUT)
            .await?;
        text = hover_text(&res["contents"]);
        if !text.trim().is_empty() || attempt + 1 == RETRY_EMPTY_TIMES || !still_warming(&client) {
            break;
        }
        tokio::time::sleep(Duration::from_secs(1)).await;
    }
    Ok(text)
}

/// `contents` của hover có thể là MarkupContent, MarkedString, chuỗi, hoặc mảng các loại đó
pub(super) fn hover_text(contents: &Value) -> String {
    match contents {
        Value::String(s) => s.clone(),
        Value::Object(o) => {
            if let Some(v) = o.get("value").and_then(Value::as_str) {
                match o.get("language").and_then(Value::as_str) {
                    Some(lang) => format!("```{lang}\n{v}\n```"),
                    None => v.to_string(),
                }
            } else {
                String::new()
            }
        }
        Value::Array(items) => items
            .iter()
            .map(hover_text)
            .filter(|t| !t.trim().is_empty())
            .collect::<Vec<_>>()
            .join("\n\n"),
        _ => String::new(),
    }
}
