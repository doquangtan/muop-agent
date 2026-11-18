use super::*;

pub(super) struct Shared {
    pub(super) stdin: AsyncMutex<ChildStdin>,
    pub(super) pending: Mutex<HashMap<i64, oneshot::Sender<Value>>>,
    pub(super) alive: AtomicBool,
}

pub struct LspClient {
    pub(super) lang: Lang,
    pub(super) root: PathBuf,
    pub(super) shared: Arc<Shared>,
    pub(super) next_id: AtomicI64,
    /// Tệp đã mở trong LSP: đường dẫn → (phiên bản, hash nội dung)
    pub(super) docs: AsyncMutex<HashMap<PathBuf, (i32, u64)>>,
    pub(super) last_used: Mutex<Instant>,
    /// Tên loại token (legend của semanticTokens) do server khai báo khi khởi động
    pub(super) token_types: Mutex<Vec<String>>,
    /// Thời điểm khởi động tiến trình (để biết còn trong giai đoạn lập chỉ mục)
    pub(super) started: Instant,
    pub(super) _child: Child,
}

pub(super) fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

pub(super) async fn write_message(stdin: &mut ChildStdin, msg: &Value) -> std::io::Result<()> {
    let body = msg.to_string();
    stdin
        .write_all(format!("Content-Length: {}\r\n\r\n", body.len()).as_bytes())
        .await?;
    stdin.write_all(body.as_bytes()).await?;
    stdin.flush().await
}

/// Đọc một thông điệp (header Content-Length + thân JSON). None khi tiến trình đã đóng đầu ra.
pub(super) async fn read_message<R: AsyncBufRead + Unpin>(r: &mut R) -> Option<Value> {
    let mut len: Option<usize> = None;
    loop {
        let mut line = String::new();
        if r.read_line(&mut line).await.ok()? == 0 {
            return None;
        }
        let t = line.trim_end();
        if t.is_empty() {
            break;
        }
        if let Some(v) = t.strip_prefix("Content-Length:") {
            len = v.trim().parse().ok();
        }
    }
    let mut buf = vec![0u8; len?];
    r.read_exact(&mut buf).await.ok()?;
    serde_json::from_slice(&buf).ok()
}

pub(super) async fn read_loop(
    mut reader: BufReader<tokio::process::ChildStdout>,
    shared: Arc<Shared>,
) {
    while let Some(msg) = read_message(&mut reader).await {
        let id = msg.get("id").cloned();
        let method = msg
            .get("method")
            .and_then(Value::as_str)
            .map(str::to_string);
        match (id, method) {
            // Yêu cầu từ server: trả lời để server không chờ mãi
            (Some(id), Some(method)) => {
                let result = if method == "workspace/configuration" {
                    let n = msg["params"]["items"].as_array().map(Vec::len).unwrap_or(0);
                    Value::Array(vec![Value::Null; n])
                } else {
                    Value::Null
                };
                let reply = json!({"jsonrpc": "2.0", "id": id, "result": result});
                let mut stdin = shared.stdin.lock().await;
                let _ = write_message(&mut stdin, &reply).await;
            }
            // Phản hồi cho yêu cầu của client
            (Some(id), None) => {
                if let Some(id) = id.as_i64() {
                    let tx = lock(&shared.pending).remove(&id);
                    if let Some(tx) = tx {
                        let _ = tx.send(msg);
                    }
                }
            }
            // Thông báo: bỏ qua (log, tiến độ...)
            _ => {}
        }
    }
    shared.alive.store(false, Ordering::SeqCst);
    // Hủy mọi yêu cầu đang chờ
    lock(&shared.pending).clear();
}

impl LspClient {
    pub(super) fn is_alive(&self) -> bool {
        self.shared.alive.load(Ordering::SeqCst)
    }

    pub(super) fn touch(&self) {
        *lock(&self.last_used) = Instant::now();
    }

    pub(super) async fn request(
        &self,
        method: &str,
        params: Value,
        timeout: Duration,
    ) -> Result<Value, String> {
        if !self.is_alive() {
            return Err("Tiến trình LSP đã dừng".into());
        }
        let id = self.next_id.fetch_add(1, Ordering::SeqCst);
        let (tx, rx) = oneshot::channel();
        lock(&self.shared.pending).insert(id, tx);
        let msg = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
        {
            let mut stdin = self.shared.stdin.lock().await;
            if write_message(&mut stdin, &msg).await.is_err() {
                lock(&self.shared.pending).remove(&id);
                return Err("Không gửi được yêu cầu tới LSP".into());
            }
        }
        match tokio::time::timeout(timeout, rx).await {
            Ok(Ok(resp)) => {
                if let Some(err) = resp.get("error") {
                    Err(err["message"].as_str().unwrap_or("LSP trả lỗi").to_string())
                } else {
                    Ok(resp.get("result").cloned().unwrap_or(Value::Null))
                }
            }
            Ok(Err(_)) => Err("Tiến trình LSP đã dừng".into()),
            Err(_) => {
                lock(&self.shared.pending).remove(&id);
                Err("LSP không phản hồi kịp thời (có thể đang lập chỉ mục, thử lại sau)".into())
            }
        }
    }

    pub(super) async fn notify(&self, method: &str, params: Value) -> Result<(), String> {
        let msg = json!({"jsonrpc": "2.0", "method": method, "params": params});
        let mut stdin = self.shared.stdin.lock().await;
        write_message(&mut stdin, &msg)
            .await
            .map_err(|_| "Không gửi được thông báo tới LSP".to_string())
    }

    /// Bảo đảm LSP đã có nội dung hiện tại của tệp (didOpen lần đầu, didChange khi nội dung đổi)
    pub(super) async fn sync_doc(&self, path: &Path, text: &str) -> Result<(), String> {
        let uri = file_uri(path);
        let hash = hash_text(text);
        let mut docs = self.docs.lock().await;
        match docs.get(path).copied() {
            None => {
                self.notify(
                    "textDocument/didOpen",
                    json!({"textDocument": {"uri": uri, "languageId": self.lang.language_id(), "version": 1, "text": text}}),
                )
                .await?;
                docs.insert(path.to_path_buf(), (1, hash));
            }
            Some((version, old_hash)) if old_hash != hash => {
                let next = version + 1;
                self.notify(
                    "textDocument/didChange",
                    json!({"textDocument": {"uri": uri, "version": next}, "contentChanges": [{"text": text}]}),
                )
                .await?;
                docs.insert(path.to_path_buf(), (next, hash));
            }
            _ => {}
        }
        Ok(())
    }
}
