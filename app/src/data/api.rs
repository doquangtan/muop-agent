//! REST client tới `muop-agent-server`. Chỉ đọc; gửi chat sẽ thêm sau.

use std::fmt;

use reqwest::Url;
use serde::de::DeserializeOwned;

use super::models::{ConversationSession, PingInfo, SessionList, SessionSummary};

#[derive(Debug, Clone, PartialEq)]
pub enum ApiError {
    Address(String),
    Network(String),
    Status { code: u16, message: String },
    Decode(String),
}

impl fmt::Display for ApiError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ApiError::Address(m) => write!(f, "Địa chỉ không hợp lệ: {m}"),
            ApiError::Network(m) => write!(f, "Không kết nối được máy chủ: {m}"),
            ApiError::Status { code, message } if message.is_empty() => {
                write!(f, "Máy chủ trả lỗi HTTP {code}")
            }
            ApiError::Status { code, message } => write!(f, "Máy chủ trả lỗi {code}: {message}"),
            ApiError::Decode(m) => write!(f, "Dữ liệu máy chủ không đúng định dạng: {m}"),
        }
    }
}

pub type ApiResult<T> = Result<T, ApiError>;

fn endpoint(base: &str, path: &str, query: &[(&str, &str)]) -> ApiResult<Url> {
    let raw = format!("{}{}", base.trim_end_matches('/'), path);
    let mut url = Url::parse(&raw).map_err(|e| ApiError::Address(e.to_string()))?;
    if !query.is_empty() {
        let mut pairs = url.query_pairs_mut();
        for (key, value) in query {
            pairs.append_pair(key, value);
        }
    }
    Ok(url)
}

async fn get_json<T: DeserializeOwned>(url: Url) -> ApiResult<T> {
    let response = reqwest::get(url)
        .await
        .map_err(|e| ApiError::Network(e.to_string()))?;
    let status = response.status();
    if !status.is_success() {
        let body = response.text().await.unwrap_or_default();
        let message = body.chars().take(200).collect::<String>();
        return Err(ApiError::Status {
            code: status.as_u16(),
            message,
        });
    }
    response
        .json::<T>()
        .await
        .map_err(|e| ApiError::Decode(e.to_string()))
}

pub async fn ping(base: &str) -> ApiResult<PingInfo> {
    get_json(endpoint(base, "/api/ping", &[])?).await
}

pub async fn sessions(base: &str) -> ApiResult<Vec<SessionSummary>> {
    let list: SessionList = get_json(endpoint(base, "/api/sessions", &[])?).await?;
    Ok(list.sessions)
}

pub async fn session(base: &str, id: &str) -> ApiResult<ConversationSession> {
    get_json(endpoint(base, "/api/session", &[("id", id)])?).await
}

#[cfg(test)]
mod live_tests {
    //! Chạy thủ công khi máy chủ đang bật:
    //! `MUOP_SERVER=http://127.0.0.1:8787 cargo test live -- --ignored --nocapture`
    use super::*;

    fn base() -> String {
        std::env::var("MUOP_SERVER").unwrap_or_else(|_| "http://127.0.0.1:8787".into())
    }

    #[tokio::test]
    #[ignore = "cần muop-agent-server đang chạy"]
    async fn live_ping_sessions_and_detail_parse() {
        let base = base();
        let info = ping(&base).await.expect("ping");
        assert_eq!(info.status, "ok");
        assert!(!info.hostname.is_empty());

        let list = sessions(&base).await.expect("sessions");
        assert!(!list.is_empty(), "máy chủ không có session nào");
        let first = &list[0];
        assert!(!first.id.is_empty());

        let detail = session(&base, &first.id).await.expect("session detail");
        assert_eq!(detail.id, first.id);
        assert!(detail.steps.iter().all(|s| !s.kind.is_empty()));
        println!(
            "ping: host={} | sessions={} | first='{}' steps={}",
            info.hostname,
            list.len(),
            first.title,
            detail.steps.len()
        );
    }
}
