//! Client tối thiểu cho `agy acp` (Agent Client Protocol, JSON-RPC qua stdio). Đây là giao diện native của agy
//! để hỏi trạng thái tài khoản, thay cho việc đọc log hay gọi hub:
//! - đăng nhập: `session/list` trả `-32000 Authentication required` khi chưa đăng nhập, và danh sách khi đã đăng nhập
//!   (chỉ đọc, không tạo phiên, không mở luồng OAuth);
//! - gói: `authenticate` trả `_meta.antigravity.tier.name` (ví dụ "Google AI Pro"). Chỉ gọi khi đã đăng nhập, vì khi
//!   chưa đăng nhập `authenticate` có thể mở luồng OAuth.
//! Mỗi lần hỏi chạy một tiến trình `agy acp` rồi tắt nó đi.

use crate::chat::AGY_APP_DATA_ARG;
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Write};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError};
use std::sync::Mutex;
use std::thread;
use std::time::{Duration, Instant};

/// Thời gian chờ mỗi request
const REQUEST_TIMEOUT: Duration = Duration::from_secs(20);
/// Thời gian giữ kết quả hỏi tài khoản (mỗi lần hỏi chạy một tiến trình `agy acp`, ~2 giây)
const ACCOUNT_CACHE_TTL: Duration = Duration::from_secs(20);
/// Kết quả gần nhất của `account_state` và thời điểm lấy
static ACCOUNT_CACHE: Mutex<Option<(Instant, AccountState)>> = Mutex::new(None);
/// Mã JSON-RPC của "Authentication required" (chưa đăng nhập)
const AUTH_REQUIRED: i64 = -32000;

/// Trạng thái tài khoản đọc từ ACP
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AccountState {
    pub logged_in: bool,
    /// Tên gói (ví dụ "Google AI Pro"); rỗng nếu chưa đăng nhập hoặc agy không trả gói
    pub tier: String,
}

#[derive(Debug)]
enum AcpError {
    /// Server trả `error` JSON-RPC
    Rpc { code: i64, message: String },
    /// Lỗi tiến trình, ghi stdin, hết giờ, hoặc phản hồi không hợp lệ
    Transport(String),
}

impl std::fmt::Display for AcpError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            AcpError::Rpc { code, message } => write!(f, "{code} {message}"),
            AcpError::Transport(e) => write!(f, "{e}"),
        }
    }
}

struct AcpProcess {
    child: Child,
    stdin: ChildStdin,
    lines: Receiver<Value>,
    next_id: u64,
}

impl AcpProcess {
    fn start() -> Result<Self, String> {
        let agy = crate::chat::agy_bin()?;
        let mut child = Command::new(agy)
            .args(["acp", AGY_APP_DATA_ARG])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|e| format!("Không chạy được agy acp: {e}"))?;
        let stdin = child.stdin.take().ok_or("agy acp không có stdin")?;
        let stdout = child.stdout.take().ok_or("agy acp không có stdout")?;
        // Luồng đọc riêng để việc chờ có thể hết giờ (đọc stdout trực tiếp sẽ treo)
        let (tx, rx) = mpsc::channel();
        thread::spawn(move || {
            for line in BufReader::new(stdout).lines().map_while(Result::ok) {
                if let Ok(value) = serde_json::from_str::<Value>(&line) {
                    if tx.send(value).is_err() {
                        break;
                    }
                }
            }
        });
        Ok(Self {
            child,
            stdin,
            lines: rx,
            next_id: 1,
        })
    }

    /// Gửi một request và đợi phản hồi có cùng id. Bỏ qua notification (`session/update`...).
    fn request(&mut self, method: &str, params: Value) -> Result<Value, AcpError> {
        let id = self.next_id;
        self.next_id += 1;
        let msg = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
        writeln!(self.stdin, "{msg}")
            .and_then(|_| self.stdin.flush())
            .map_err(|e| AcpError::Transport(format!("Không gửi được {method}: {e}")))?;
        let deadline = Instant::now() + REQUEST_TIMEOUT;
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            match self.lines.recv_timeout(left) {
                Ok(value) => {
                    if value.get("id").and_then(Value::as_u64) != Some(id) {
                        continue;
                    }
                    if let Some(err) = value.get("error") {
                        return Err(AcpError::Rpc {
                            code: err.get("code").and_then(Value::as_i64).unwrap_or(0),
                            message: err
                                .get("message")
                                .and_then(Value::as_str)
                                .unwrap_or("")
                                .to_string(),
                        });
                    }
                    return Ok(value.get("result").cloned().unwrap_or(Value::Null));
                }
                Err(RecvTimeoutError::Timeout) => {
                    return Err(AcpError::Transport(format!("{method} hết giờ")));
                }
                Err(RecvTimeoutError::Disconnected) => {
                    return Err(AcpError::Transport(format!(
                        "agy acp đã thoát trước khi trả lời {method}"
                    )));
                }
            }
        }
    }
}

impl Drop for AcpProcess {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// Đăng nhập và gói của tài khoản agy đang dùng (hỏi qua ACP, không đọc log).
/// Lỗi tiến trình hoặc hết giờ trả `Err`, để người gọi không nhầm là chưa đăng nhập.
pub fn account_state() -> Result<AccountState, String> {
    if let Ok(guard) = ACCOUNT_CACHE.lock() {
        if let Some((at, state)) = guard.as_ref() {
            if at.elapsed() < ACCOUNT_CACHE_TTL {
                return Ok(state.clone());
            }
        }
    }
    let state = query_account_state()?;
    if let Ok(mut guard) = ACCOUNT_CACHE.lock() {
        *guard = Some((Instant::now(), state.clone()));
    }
    Ok(state)
}

/// Bỏ cache trạng thái tài khoản (gọi khi đăng nhập hoặc đăng xuất đổi trạng thái)
pub fn invalidate_account_cache() {
    if let Ok(mut guard) = ACCOUNT_CACHE.lock() {
        *guard = None;
    }
}

fn query_account_state() -> Result<AccountState, String> {
    let mut acp = AcpProcess::start()?;
    acp.request(
        "initialize",
        json!({"protocolVersion": 1, "clientCapabilities": {}}),
    )
    .map_err(|e| e.to_string())?;
    match acp.request("session/list", json!({})) {
        Ok(_) => {}
        Err(AcpError::Rpc { code, .. }) if code == AUTH_REQUIRED => {
            return Ok(AccountState {
                logged_in: false,
                tier: String::new(),
            });
        }
        Err(e) => return Err(e.to_string()),
    }
    // Đã đăng nhập: `authenticate` chỉ trả gói (không đổi trạng thái đăng nhập)
    let tier = acp
        .request("authenticate", json!({"methodId": "oauth-personal"}))
        .ok()
        .as_ref()
        .and_then(tier_name)
        .unwrap_or_default();
    Ok(AccountState {
        logged_in: true,
        tier,
    })
}

/// Tên gói trong phản hồi `authenticate` hoặc `session/new`: `_meta.antigravity.tier.name`
pub(crate) fn tier_name(result: &Value) -> Option<String> {
    result
        .pointer("/_meta/antigravity/tier/name")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
}

/// Danh sách model của tài khoản (id, tên hiển thị) từ `session/new`. Phiên tạm được đóng ngay và không gửi
/// prompt nên không tốn quota. Chưa đăng nhập thì ACP trả lỗi và hàm này trả `Err` (người gọi giữ danh sách cũ).
pub fn list_models() -> Result<Vec<(String, String)>, String> {
    let mut acp = AcpProcess::start()?;
    acp.request(
        "initialize",
        json!({"protocolVersion": 1, "clientCapabilities": {}}),
    )
    .map_err(|e| e.to_string())?;
    let cwd = crate::infra::paths::home_dir()
        .to_string_lossy()
        .into_owned();
    let result = acp
        .request("session/new", json!({"cwd": cwd, "mcpServers": []}))
        .map_err(|e| e.to_string())?;
    if let Some(session_id) = result.get("sessionId").and_then(Value::as_str) {
        let _ = acp.request("session/close", json!({"sessionId": session_id}));
    }
    let models: Vec<(String, String)> = result
        .pointer("/models/availableModels")
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(|m| {
                    let id = m.get("modelId")?.as_str()?.trim();
                    let name = m.get("name")?.as_str()?.trim();
                    (!id.is_empty()).then(|| (id.to_string(), name.to_string()))
                })
                .collect()
        })
        .unwrap_or_default();
    if models.is_empty() {
        return Err("agy acp không trả danh sách model".into());
    }
    Ok(models)
}

/// Hỏi agy qua ACP để CLI dùng token hiện tại (làm mới khi sắp hết hạn). Không dùng cache. Kết quả không quan trọng:
/// việc token có được làm mới hay không được kiểm tra bằng hạn trong file token.
pub fn touch_auth() -> Result<(), String> {
    let mut acp = AcpProcess::start()?;
    acp.request(
        "initialize",
        json!({"protocolVersion": 1, "clientCapabilities": {}}),
    )
    .map_err(|e| e.to_string())?;
    acp.request("session/list", json!({}))
        .map(|_| ())
        .map_err(|e| e.to_string())
}

/// Đăng xuất qua ACP (`auth.logout` trong `agentCapabilities` của agy). Chỉ gửi lệnh: việc token đã bị xóa
/// được kiểm tra bằng [`account_state`] ở nơi gọi. Xóa cache trạng thái để lần hỏi sau không dùng kết quả cũ.
pub fn logout() -> Result<(), String> {
    let mut acp = AcpProcess::start()?;
    acp.request(
        "initialize",
        json!({"protocolVersion": 1, "clientCapabilities": {}}),
    )
    .map_err(|e| e.to_string())?;
    let result = acp.request("logout", json!({})).map_err(|e| e.to_string());
    invalidate_account_cache();
    result.map(|_| ())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tier_name_reads_antigravity_meta() {
        let v = json!({"_meta": {"antigravity": {"tier": {"name": "Google AI Pro", "id": "g1-pro-tier"}}}});
        assert_eq!(tier_name(&v).as_deref(), Some("Google AI Pro"));
    }

    #[test]
    fn tier_name_missing_is_none() {
        assert_eq!(tier_name(&json!({})), None);
        assert_eq!(
            tier_name(&json!({"_meta": {"antigravity": {"tier": {"name": ""}}}})),
            None
        );
    }
}
