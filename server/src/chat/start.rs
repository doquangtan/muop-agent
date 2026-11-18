use super::*;

/// Chạy script đồng bộ session của Antigravity IDE (chỉ dùng cho provider agy)
pub(super) fn spawn_agy_sync(cid: String, delay_ms: u64) {
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(delay_ms)).await;
        let _ = Command::new("python3")
            .arg("/home/john/Documents/muop-ecosystem/muop-agent/server/scripts/sync_antigravity_ide.py")
            .arg(&cid)
            .output()
            .await;
    });
}

/// Gửi một lượt chat tới backend tương ứng với model đã chọn:
/// - `claude-cli:<alias>` → Claude Code CLI, tiếp tục session bằng `--resume`
/// - `agy:<model>` → Antigravity CLI (`agy`)
pub async fn start_chat_turn(state: AppState, req: ChatSendRequest) -> ChatSendResponse {
    start_chat_turn_attempt(state, req, 0).await
}

/// Gửi một lượt chat. `attempt` = 0 khi người dùng gửi; > 0 khi hệ thống tự gửi lại sau rate limit.
pub async fn start_chat_turn_attempt(
    state: AppState,
    req: ChatSendRequest,
    attempt: u32,
) -> ChatSendResponse {
    let request_snapshot = req.clone();
    let trimmed_prompt = req.prompt.trim().to_string();
    if trimmed_prompt.is_empty() {
        return ChatSendResponse {
            ok: false,
            conversation_id: req.conversation_id,
            project_path: req.project_path,
            error: "Nội dung tin nhắn trống".to_string(),
            source: String::new(),
        };
    }

    let (provider, model) = resolve_model(&req.model);

    let mut effective_cwd = req.project_path.trim().to_string();
    if effective_cwd.is_empty() || !Path::new(&effective_cwd).exists() {
        effective_cwd = "/home/john/Documents/muop-ecosystem/muop-erp-server".to_string();
    }

    let clean_conv_id = req.conversation_id.trim().to_string();
    // Người dùng gửi tay thì lịch tự gửi lại đang chờ của conversation này không còn cần nữa
    if attempt == 0 && !clean_conv_id.is_empty() {
        crate::chat::retry::cancel(&state, &clean_conv_id);
    }
    let is_resume =
        !clean_conv_id.is_empty() && clean_conv_id != "new" && !clean_conv_id.starts_with("sim-");
    let resume_id = if is_resume {
        Some(clean_conv_id.as_str())
    } else {
        None
    };

    let (bin, args) = match provider {
        Provider::ClaudeCli => {
            let (plan_mode, body) = strip_plan_command(&trimmed_prompt);
            if body.is_empty() {
                return ChatSendResponse {
                    ok: false,
                    conversation_id: req.conversation_id,
                    project_path: req.project_path,
                    error: "Nhập nội dung kế hoạch sau /plan".to_string(),
                    source: String::new(),
                };
            }
            (
                crate::claude::code::claude_bin(),
                claude_args(body, &model, resume_id, &effective_cwd, plan_mode),
            )
        }
        Provider::Agy => (
            agy_bin().to_string(),
            agy_args(&trimmed_prompt, &model, resume_id, req.agent_name.trim()),
        ),
    };

    eprintln!(
        "[CHAT_SEND] provider={:?} bin={} conv='{}' model='{}' cwd='{}' prompt='{}'",
        provider, bin, clean_conv_id, model, effective_cwd, trimmed_prompt
    );

    let use_systemd_scope =
        Path::new("/usr/bin/systemd-run").exists() || Path::new("/bin/systemd-run").exists();
    let mut cmd = if use_systemd_scope {
        let mut c = Command::new("systemd-run");
        c.arg("--user")
            .arg("--scope")
            .arg("--quiet")
            .arg(&bin)
            .args(&args);
        c
    } else {
        let mut c = Command::new(&bin);
        c.args(&args);
        c
    };

    let mut child = match cmd
        .current_dir(&effective_cwd)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
    {
        Ok(c) => c,
        Err(e) => {
            let label = match provider {
                Provider::ClaudeCli => "Claude Code CLI",
                Provider::Agy => "agy CLI",
            };
            return ChatSendResponse {
                ok: false,
                conversation_id: clean_conv_id,
                project_path: effective_cwd,
                error: format!("Không thể khởi chạy {} ({}): {}", label, bin, e),
                source: provider_source(provider).to_string(),
            };
        }
    };

    let pid = child.id().unwrap_or(0);
    let ctx = TurnCtx {
        state: state.clone(),
        pid,
        cwd: effective_cwd.clone(),
        prompt: trimmed_prompt.clone(),
        started_at: Utc::now().to_rfc3339(),
        model: model.clone(),
        request: request_snapshot,
        attempt,
        provider,
    };

    if !clean_conv_id.is_empty() {
        ctx.register(&clean_conv_id);
        ctx.emit(&clean_conv_id, String::new(), "starting", String::new());
        if provider == Provider::Agy {
            spawn_agy_sync(clean_conv_id.clone(), 2200);
        }
    }

    let (tx, rx) = oneshot::channel::<String>();
    let stdout = child.stdout.take();
    let stderr = child.stderr.take();
    let initial_cid = clean_conv_id.clone();

    tokio::spawn(async move {
        let mut st = TurnState {
            tracked_id: initial_cid,
            committed: String::new(),
            live: String::new(),
            thinking_text: String::new(),
            current_block_type: String::new(),
            result_error: None,
            init_tx: Some(tx),
            text_step: None,
        };

        if let Some(out) = stdout {
            let mut reader = BufReader::new(out).lines();
            while let Ok(Some(line)) = reader.next_line().await {
                let trimmed = line.trim();
                if trimmed.is_empty() {
                    continue;
                }
                let Ok(map) = serde_json::from_str::<Value>(trimmed) else {
                    continue;
                };
                match provider {
                    Provider::Agy => handle_agy_event(&ctx, &mut st, &map),
                    Provider::ClaudeCli => handle_claude_event(&ctx, &mut st, &map),
                }
            }
        }

        // Giữ các dòng stderr cuối (thông báo lỗi của CLI có thể nhiều dòng)
        let mut stderr_lines: Vec<String> = Vec::new();
        if let Some(err_pipe) = stderr {
            let mut err_reader = BufReader::new(err_pipe).lines();
            while let Ok(Some(line)) = err_reader.next_line().await {
                if !line.trim().is_empty() {
                    stderr_lines.push(line.trim().to_string());
                }
            }
        }
        let stderr_start = stderr_lines.len().saturating_sub(20);
        let stderr_msg = stderr_lines[stderr_start..].join("\n");

        let status = child.wait().await;
        let is_ok = status.map(|s| s.success()).unwrap_or(false) && st.result_error.is_none();
        finish_turn(&ctx, st, is_ok, stderr_msg, provider);
    });

    let resolved_id = match timeout(Duration::from_secs(4), rx).await {
        Ok(Ok(cid)) => cid,
        _ => clean_conv_id,
    };

    ChatSendResponse {
        ok: true,
        conversation_id: resolved_id,
        project_path: effective_cwd,
        error: String::new(),
        source: provider_source(provider).to_string(),
    }
}
