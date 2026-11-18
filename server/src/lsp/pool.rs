use super::*;

pub(super) static CLIENTS: OnceLock<AsyncMutex<HashMap<(Lang, PathBuf), Arc<LspClient>>>> =
    OnceLock::new();

pub(super) fn clients() -> &'static AsyncMutex<HashMap<(Lang, PathBuf), Arc<LspClient>>> {
    CLIENTS.get_or_init(|| AsyncMutex::new(HashMap::new()))
}

/// Thư mục gốc của project: thư mục gần nhất chứa tệp đánh dấu (go.mod / pubspec.yaml / Cargo.toml)
pub fn find_root(lang: Lang, file: &Path) -> PathBuf {
    let start = file.parent().unwrap_or(file);
    let mut dir = Some(start);
    while let Some(d) = dir {
        if d.join(lang.root_marker()).is_file() {
            return d.to_path_buf();
        }
        dir = d.parent();
    }
    start.to_path_buf()
}

pub(super) async fn spawn_client(lang: Lang, root: PathBuf) -> Result<Arc<LspClient>, String> {
    let exe = effective_exe(lang).ok_or_else(|| {
        format!(
            "Chưa tìm thấy {}. Đặt đường dẫn trong màn hình Cài đặt LSP.",
            lang.label()
        )
    })?;
    let mut child = Command::new(&exe)
        .args(lang.args())
        .current_dir(&root)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .map_err(|e| format!("Không chạy được {}: {e}", exe.display()))?;
    let stdin = child.stdin.take().ok_or("Không mở được stdin của LSP")?;
    let stdout = child.stdout.take().ok_or("Không mở được stdout của LSP")?;
    let shared = Arc::new(Shared {
        stdin: AsyncMutex::new(stdin),
        pending: Mutex::new(HashMap::new()),
        alive: AtomicBool::new(true),
    });
    tokio::spawn(read_loop(BufReader::new(stdout), shared.clone()));
    let client = Arc::new(LspClient {
        lang,
        root: root.clone(),
        shared,
        next_id: AtomicI64::new(1),
        docs: AsyncMutex::new(HashMap::new()),
        last_used: Mutex::new(Instant::now()),
        token_types: Mutex::new(Vec::new()),
        started: Instant::now(),
        _child: child,
    });

    let root_uri = file_uri(&root);
    // gopls tắt semantic tokens mặc định; phải bật bằng initializationOptions
    let init_options = if lang == Lang::Go {
        json!({"semanticTokens": true})
    } else {
        Value::Null
    };
    let init = json!({
        "processId": std::process::id(),
        "initializationOptions": init_options,
        "rootUri": root_uri,
        "workspaceFolders": [{"uri": root_uri, "name": root.file_name().and_then(|n| n.to_str()).unwrap_or("project")}],
        "capabilities": {
            "workspace": {"configuration": true, "workspaceFolders": true},
            "textDocument": {
                "foldingRange": {"lineFoldingOnly": true},
                "documentSymbol": {"hierarchicalDocumentSymbolSupport": true},
                "definition": {"linkSupport": true},
                "references": {},
                "hover": {"contentFormat": ["markdown", "plaintext"]},
                "semanticTokens": {"requests": {"full": true}, "tokenTypes": STANDARD_TOKEN_TYPES, "tokenModifiers": [], "formats": ["relative"]}
            },
            "window": {"workDoneProgress": true}
        }
    });
    let init_res = client.request("initialize", init, INIT_TIMEOUT).await?;
    let legend: Vec<String> = init_res["capabilities"]["semanticTokensProvider"]["legend"]
        ["tokenTypes"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|v| v.as_str().map(str::to_string))
                .collect()
        })
        .unwrap_or_default();
    *lock(&client.token_types) = legend;
    client.notify("initialized", json!({})).await?;
    Ok(client)
}

/// Lấy (hoặc khởi động) tiến trình LSP cho ngôn ngữ và thư mục gốc
pub(super) async fn client_for(lang: Lang, root: PathBuf) -> Result<Arc<LspClient>, String> {
    let mut map = clients().lock().await;
    let key = (lang, root.clone());
    if let Some(c) = map.get(&key) {
        if c.is_alive() {
            c.touch();
            return Ok(c.clone());
        }
        map.remove(&key);
    }
    if map.len() >= MAX_CLIENTS {
        // Dừng tiến trình ít dùng nhất
        let oldest = map
            .iter()
            .min_by_key(|(_, c)| *lock(&c.last_used))
            .map(|(k, _)| k.clone());
        if let Some(k) = oldest {
            map.remove(&k);
        }
    }
    let client = spawn_client(lang, root).await?;
    map.insert(key, client.clone());
    Ok(client)
}

/// Dừng các tiến trình không dùng quá `IDLE_TIMEOUT`. Trả về số tiến trình đã dừng.
pub async fn reap_idle() -> usize {
    let mut map = clients().lock().await;
    let before = map.len();
    map.retain(|_, c| c.is_alive() && lock(&c.last_used).elapsed() <= IDLE_TIMEOUT);
    before - map.len()
}

/// Dừng toàn bộ tiến trình LSP (khi server tắt)
pub async fn shutdown_all() {
    clients().lock().await.clear();
}

// ---------------------------------------------------------------------------
// Các thao tác cho client
// ---------------------------------------------------------------------------

/// Chuẩn bị: xác định ngôn ngữ, thư mục gốc, LSP client, và đồng bộ nội dung tệp
pub(super) async fn prepare(path: &Path) -> Result<(Arc<LspClient>, String), String> {
    let lang = Lang::from_path(path).ok_or("Không hỗ trợ LSP cho loại tệp này")?;
    if !path.is_file() {
        return Err("Tệp không tồn tại trên server".into());
    }
    let text = tokio::fs::read_to_string(path)
        .await
        .map_err(|_| "Không đọc được tệp (có thể là tệp nhị phân)".to_string())?;
    let root = find_root(lang, path);
    let client = client_for(lang, root).await?;
    client.sync_doc(path, &text).await?;
    client.touch();
    Ok((client, file_uri(path)))
}
