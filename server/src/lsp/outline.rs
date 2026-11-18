use super::*;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FoldRange {
    /// Dòng bắt đầu, đếm từ 0
    pub start_line: u32,
    pub end_line: u32,
    pub kind: String,
}

/// Khi LSP vừa khởi động, yêu cầu đầu có thể trả về rỗng trước khi phân tích xong tệp. Thử lại vài lần.
pub(super) async fn request_until_ready(
    client: &LspClient,
    method: &str,
    params: Value,
) -> Result<Value, String> {
    let mut res = Value::Null;
    for attempt in 0..RETRY_EMPTY_TIMES {
        res = client
            .request(method, params.clone(), REQUEST_TIMEOUT)
            .await?;
        if res.as_array().is_some_and(|a| !a.is_empty()) || attempt + 1 == RETRY_EMPTY_TIMES {
            break;
        }
        tokio::time::sleep(Duration::from_secs(1)).await;
    }
    Ok(res)
}

pub async fn folding_ranges(path: &Path) -> Result<(String, Vec<FoldRange>), String> {
    let (client, uri) = prepare(path).await?;
    let res = request_until_ready(
        &client,
        "textDocument/foldingRange",
        json!({"textDocument": {"uri": uri}}),
    )
    .await?;
    let ranges = res
        .as_array()
        .map(|items| {
            items
                .iter()
                .filter_map(|r| {
                    let start = r["startLine"].as_u64()? as u32;
                    let end = r["endLine"].as_u64()? as u32;
                    if end <= start {
                        return None;
                    }
                    Some(FoldRange {
                        start_line: start,
                        end_line: end,
                        kind: r["kind"].as_str().unwrap_or("").to_string(),
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    Ok((client.lang.key().to_string(), ranges))
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SymbolItem {
    pub name: String,
    pub kind: u32,
    pub kind_label: String,
    /// Dòng khai báo, đếm từ 0
    pub line: u32,
    pub end_line: u32,
    pub depth: u32,
}

pub(super) fn symbol_kind_label(kind: u64) -> &'static str {
    match kind {
        2 => "module",
        5 => "class",
        6 => "method",
        7 => "property",
        8 => "field",
        9 => "constructor",
        10 => "enum",
        11 => "interface",
        12 => "function",
        13 => "variable",
        14 => "constant",
        23 => "struct",
        26 => "type",
        _ => "symbol",
    }
}

/// Làm phẳng cây ký hiệu (DocumentSymbol lồng nhau hoặc SymbolInformation)
pub(super) fn flatten_symbols(items: &[Value], depth: u32, out: &mut Vec<SymbolItem>) {
    for s in items {
        let name = s["name"].as_str().unwrap_or("").to_string();
        let kind = s["kind"].as_u64().unwrap_or(0);
        // DocumentSymbol có `range`; SymbolInformation có `location.range`
        let range = if s.get("range").is_some() {
            &s["range"]
        } else {
            &s["location"]["range"]
        };
        let line = range["start"]["line"].as_u64().unwrap_or(0) as u32;
        let end_line = range["end"]["line"].as_u64().unwrap_or(line as u64) as u32;
        if !name.is_empty() {
            out.push(SymbolItem {
                name,
                kind: kind as u32,
                kind_label: symbol_kind_label(kind).to_string(),
                line,
                end_line,
                depth,
            });
        }
        if let Some(children) = s["children"].as_array() {
            flatten_symbols(children, depth + 1, out);
        }
    }
}

pub async fn document_symbols(path: &Path) -> Result<Vec<SymbolItem>, String> {
    let (client, uri) = prepare(path).await?;
    let res = request_until_ready(
        &client,
        "textDocument/documentSymbol",
        json!({"textDocument": {"uri": uri}}),
    )
    .await?;
    let mut out = Vec::new();
    if let Some(items) = res.as_array() {
        flatten_symbols(items, 0, &mut out);
    }
    out.sort_by_key(|s| (s.line, s.depth));
    Ok(out)
}
