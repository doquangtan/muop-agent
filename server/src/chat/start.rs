use super::*;
use crate::models::ChatImage;
use attachments::PreparedImage;
use tokio::io::AsyncWriteExt;

/// Câu mặc định khi người dùng chỉ gửi ảnh mà không gõ chữ (để lượt chat luôn có nội dung trong lịch sử)
const DEFAULT_IMAGE_PROMPT: &str = "Hãy mô tả các ảnh đính kèm.";

/// Lỗi khi thiếu công cụ (agy, claude): trả về ngay, client hiển thị và hướng dẫn chọn đường dẫn
fn tool_missing_response(req: &ChatSendRequest, error: String) -> ChatSendResponse {
    ChatSendResponse {
        ok: false,
        conversation_id: req.conversation_id.clone(),
        project_path: req.project_path.clone(),
        error,
        source: String::new(),
    }
}

/// Kiểm tra và lưu ảnh đính kèm ngoài luồng async (giải mã/thu nhỏ ảnh tốn CPU)
async fn prepare_images_blocking(images: Vec<ChatImage>) -> Result<Vec<PreparedImage>, String> {
    if images.is_empty() {
        return Ok(Vec::new());
    }
    match tokio::task::spawn_blocking(move || attachments::prepare_images(&images)).await {
        Ok(result) => result,
        Err(e) => Err(format!("Lỗi xử lý ảnh đính kèm: {e}")),
    }
}

/// Script đồng bộ session của Antigravity IDE, nhúng vào binary: không phụ thuộc vị trí repo khi cài .deb
const SYNC_IDE_SCRIPT: &str = include_str!("../../scripts/sync_antigravity_ide.py");

/// Chạy script đồng bộ session của Antigravity IDE (chỉ dùng cho provider agy).
/// Script đưa vào `python3 -` qua stdin. Không có python3 thì bỏ qua (tùy chọn).
pub(super) fn spawn_agy_sync(cid: String, delay_ms: u64) {
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(delay_ms)).await;
        let Some(python) = crate::infra::tools::resolve("python3") else {
            return;
        };
        let Ok(mut child) = Command::new(python)
            .arg("-")
            .arg(&cid)
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .kill_on_drop(true)
            .spawn()
        else {
            return;
        };
        if let Some(mut stdin) = child.stdin.take() {
            let _ = stdin.write_all(SYNC_IDE_SCRIPT.as_bytes()).await;
        }
        let _ = child.wait().await;
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
    mut req: ChatSendRequest,
    attempt: u32,
) -> ChatSendResponse {
    // Project ở máy khác: mount về đây và chạy agent trên điểm mount. Làm trước khi chụp snapshot
    // để lượt tự gửi lại (retry) dùng luôn điểm mount, không mount lại theo đường dẫn của máy gửi.
    if let Some(remote) = req.remote_project.take() {
        match crate::fsmount::resolve_chat_project(&remote).await {
            Ok(mounted) => {
                req.project_path = mounted.mount_point.to_string_lossy().into_owned();
            }
            Err(error) => {
                return ChatSendResponse {
                    ok: false,
                    conversation_id: req.conversation_id,
                    project_path: remote.project_path,
                    error,
                    source: String::new(),
                };
            }
        }
    }
    let request_snapshot = req.clone();
    let trimmed_prompt = req.prompt.trim().to_string();
    let images_in = std::mem::take(&mut req.images);
    if trimmed_prompt.is_empty() && images_in.is_empty() {
        return ChatSendResponse {
            ok: false,
            conversation_id: req.conversation_id,
            project_path: req.project_path,
            error: "Nội dung tin nhắn trống".to_string(),
            source: String::new(),
        };
    }
    // Chuẩn bị ảnh trước khi hủy lịch tự gửi lại: gửi lỗi thì lịch đang chờ vẫn giữ nguyên
    let images = match prepare_images_blocking(images_in).await {
        Ok(v) => v,
        Err(error) => {
            return ChatSendResponse {
                ok: false,
                conversation_id: req.conversation_id,
                project_path: req.project_path,
                error,
                source: String::new(),
            };
        }
    };
    let user_text = if trimmed_prompt.is_empty() {
        DEFAULT_IMAGE_PROMPT.to_string()
    } else {
        trimmed_prompt
    };

    let (provider, model) = resolve_model(&req.model);

    let effective_cwd = req.project_path.trim().to_string();
    if effective_cwd.is_empty() || !Path::new(&effective_cwd).exists() {
        return ChatSendResponse {
            ok: false,
            conversation_id: req.conversation_id,
            project_path: req.project_path,
            error: "Chưa chọn project hợp lệ cho lượt chat".to_string(),
            source: String::new(),
        };
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

    // `stdin_payload`: nội dung gửi qua stdin (Claude stream-json khi có ảnh); None = không dùng stdin
    let (bin, args, stdin_payload) = match provider {
        Provider::ClaudeCli => {
            let (plan_mode, body) = strip_plan_command(&user_text);
            if body.is_empty() {
                return ChatSendResponse {
                    ok: false,
                    conversation_id: req.conversation_id,
                    project_path: req.project_path,
                    error: "Nhập nội dung kế hoạch sau /plan".to_string(),
                    source: String::new(),
                };
            }
            let stream_input = !images.is_empty();
            let payload =
                stream_input.then(|| attachments::claude_stream_input_line(body, &images));
            let bin = match crate::claude::code::claude_bin() {
                Ok(bin) => bin,
                Err(e) => return tool_missing_response(&req, e),
            };
            (
                bin,
                claude_args(
                    body,
                    &model,
                    resume_id,
                    &effective_cwd,
                    plan_mode,
                    stream_input,
                ),
                payload,
            )
        }
        Provider::Agy => {
            // Project trên mount: nhắc agent dùng thư mục mount, vì conversation cũ có thể nhớ đường dẫn khác
            let agy_text = if crate::fsmount::is_mount_path(&effective_cwd) {
                format!(
                    "{user_text}{}",
                    attachments::agy_workdir_note(&effective_cwd)
                )
            } else {
                user_text.clone()
            };
            let bin = match agy_bin() {
                Ok(bin) => bin,
                Err(e) => return tool_missing_response(&req, e),
            };
            (
                bin,
                agy_args(
                    &attachments::agy_prompt(&agy_text, &images),
                    &model,
                    resume_id,
                    req.agent_name.trim(),
                ),
                None,
            )
        }
    };

    eprintln!(
        "[CHAT_SEND] provider={:?} bin={} conv='{}' model='{}' cwd='{}' images={} prompt='{}'",
        provider,
        bin,
        clean_conv_id,
        model,
        effective_cwd,
        images.len(),
        user_text
    );

    // systemd-run (nếu dò được bằng which): chạy agent trong scope riêng, tách khỏi tiến trình server
    let mut cmd = match crate::infra::tools::resolve("systemd-run") {
        Some(systemd_run) => {
            let mut c = Command::new(systemd_run);
            c.arg("--user")
                .arg("--scope")
                .arg("--quiet")
                .arg(&bin)
                .args(&args);
            c
        }
        None => {
            let mut c = Command::new(&bin);
            c.args(&args);
            c
        }
    };

    let mut child = match cmd
        .current_dir(&effective_cwd)
        .stdin(if stdin_payload.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
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
        prompt: user_text.clone(),
        started_at: Utc::now().to_rfc3339(),
        model: model.clone(),
        request: request_snapshot,
        attempt,
        provider,
    };

    // Quota agy lấy khi bắt đầu lượt (không chờ): watcher lấy từ API/hub rồi đẩy `quotas:update`
    if provider == Provider::Agy {
        crate::agy_account::request_refresh();
    }
    if !clean_conv_id.is_empty() {
        ctx.register(&clean_conv_id);
        ctx.emit(&clean_conv_id, String::new(), "starting", String::new());
        if provider == Provider::Agy {
            spawn_agy_sync(clean_conv_id.clone(), 2200);
        }
    }

    let (tx, rx) = oneshot::channel::<String>();
    let stdin_pipe = child.stdin.take();
    let stdout = child.stdout.take();
    let stderr = child.stderr.take();
    let initial_cid = clean_conv_id.clone();

    tokio::spawn(async move {
        // Ghi stdin trước khi đọc stdout: ảnh có thể lớn, và CLI chỉ bắt đầu trả lời sau khi nhận đủ input
        if let (Some(payload), Some(mut pipe)) = (stdin_payload, stdin_pipe) {
            let _ = pipe.write_all(payload.as_bytes()).await;
            let _ = pipe.shutdown().await;
        }

        let mut st = TurnState {
            tracked_id: initial_cid,
            committed: String::new(),
            live: String::new(),
            thinking_text: String::new(),
            current_block_type: String::new(),
            result_error: None,
            init_tx: Some(tx),
            text_step: None,
            thoughts: Vec::new(),
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
