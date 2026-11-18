use super::*;

/// Token ngữ nghĩa của tệp: `kinds` là danh sách tên loại; `data` gồm bộ 4 số [dòng, cột, độ dài, chỉ số loại]
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SemanticTokens {
    pub kinds: Vec<String>,
    pub data: Vec<u32>,
}

/// Giải mã semanticTokens/full (dạng tương đối của LSP) thành vị trí tuyệt đối
pub(super) fn decode_semantic(data: &[u64]) -> Vec<u32> {
    let mut out = Vec::with_capacity(data.len() / 5 * 4);
    let (mut line, mut start) = (0u64, 0u64);
    for chunk in data.chunks_exact(5) {
        let (dl, ds, len, kind) = (chunk[0], chunk[1], chunk[2], chunk[3]);
        if dl > 0 {
            line += dl;
            start = ds;
        } else {
            start += ds;
        }
        out.extend([line as u32, start as u32, len as u32, kind as u32]);
    }
    out
}

pub async fn semantic_tokens(path: &Path) -> Result<SemanticTokens, String> {
    let (client, uri) = prepare(path).await?;
    let kinds = lock(&client.token_types).clone();
    let mut data: Vec<u64> = Vec::new();
    for attempt in 0..RETRY_EMPTY_TIMES {
        let res = client
            .request(
                "textDocument/semanticTokens/full",
                json!({"textDocument": {"uri": uri}}),
                REQUEST_TIMEOUT,
            )
            .await?;
        data = res["data"]
            .as_array()
            .map(|a| a.iter().filter_map(Value::as_u64).collect())
            .unwrap_or_default();
        if !data.is_empty() || attempt + 1 == RETRY_EMPTY_TIMES {
            break;
        }
        tokio::time::sleep(Duration::from_secs(1)).await;
    }
    Ok(SemanticTokens {
        kinds,
        data: decode_semantic(&data),
    })
}
