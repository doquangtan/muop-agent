//! Xem log container: mỗi lần xem mở một kênh SSH chạy `docker logs -f` trên kết nối của phiên Docker.
//!
//! - Dòng log được gom theo lô rồi phát qua Socket.IO (`docker:logs:data`) tới room `docker-logs:<streamId>`.
//! - Client gửi `docker:logs:ping` định kỳ. Nếu quá `PING_TIMEOUT` không có ping (app đã thoát, mất mạng)
//!   thì server dừng luồng và đóng kênh SSH, không để tiến trình ssh mồ côi.
//! - `docker:logs:close` dừng luồng ngay khi người dùng thoát màn hình log.

use crate::chat::AppState;
use serde_json::json;
use std::collections::HashMap;
use std::sync::{Mutex, MutexGuard, OnceLock};
use std::time::{Duration, Instant};
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::Child;
use tokio::sync::oneshot;

/// Số luồng log đồng thời tối đa
const MAX_STREAMS: usize = 16;
/// Không có ping quá khoảng này thì dừng luồng
const PING_TIMEOUT: Duration = Duration::from_secs(30);
const MAX_TAIL: u32 = 5000;
/// Gom dòng theo lô: tối đa số dòng này hoặc sau khoảng thời gian `FLUSH_EVERY`
const FLUSH_LINES: usize = 80;
const FLUSH_EVERY: Duration = Duration::from_millis(150);

struct Stream {
    last_ping: Instant,
    stop: Option<oneshot::Sender<()>>,
}

static STREAMS: OnceLock<Mutex<HashMap<String, Stream>>> = OnceLock::new();

fn streams() -> &'static Mutex<HashMap<String, Stream>> {
    STREAMS.get_or_init(|| Mutex::new(HashMap::new()))
}

fn lock(m: &Mutex<HashMap<String, Stream>>) -> MutexGuard<'_, HashMap<String, Stream>> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

pub fn new_stream_id() -> String {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    format!("logs-{}-{}", std::process::id(), nanos)
}

pub fn room_for(stream_id: &str) -> String {
    format!("docker-logs:{stream_id}")
}

/// Ghi nhận client còn đang xem. Trả về false nếu luồng không còn.
pub fn ping(stream_id: &str) -> bool {
    match lock(streams()).get_mut(stream_id) {
        Some(s) => {
            s.last_ping = Instant::now();
            true
        }
        None => false,
    }
}

/// Dừng luồng theo yêu cầu của client
pub fn stop(stream_id: &str) -> bool {
    let removed = lock(streams()).remove(stream_id);
    match removed {
        Some(mut s) => {
            if let Some(tx) = s.stop.take() {
                let _ = tx.send(());
            }
            true
        }
        None => false,
    }
}

/// Bắt đầu luồng log của một container trong phiên Docker. Dòng log được phát tới room của `stream_id`.
/// Caller phải join socket vào room trước khi gọi, để không mất dòng đầu tiên.
pub async fn start(
    state: AppState,
    stream_id: String,
    session_id: &str,
    container_id: &str,
    tail: u32,
) -> Result<(), String> {
    if container_id.len() < 12
        || container_id.len() > 64
        || !container_id.chars().all(|c| c.is_ascii_hexdigit())
    {
        return Err("Mã container không hợp lệ".into());
    }
    if lock(streams()).len() >= MAX_STREAMS {
        return Err("Đã đạt số luồng log tối đa".into());
    }
    let tail = tail.clamp(1, MAX_TAIL);
    let command = format!("docker logs -f --timestamps --tail {tail} {container_id} 2>&1");
    let mut cmd = crate::docker::sessions::stream_command(session_id, &command).await?;
    let mut child = cmd
        .spawn()
        .map_err(|e| format!("Không mở được kênh SSH: {e}"))?;
    let Some(stdout) = child.stdout.take() else {
        return Err("Không đọc được đầu ra của kênh SSH".into());
    };

    let (tx, rx) = oneshot::channel();
    lock(streams()).insert(
        stream_id.clone(),
        Stream {
            last_ping: Instant::now(),
            stop: Some(tx),
        },
    );
    tokio::spawn(pump(state, stream_id, child, stdout, rx));
    Ok(())
}

/// Đọc đầu ra của kênh SSH, phát từng lô dòng, và dừng khi có yêu cầu, khi kênh đóng, hoặc khi client mất kết nối.
async fn pump(
    state: AppState,
    stream_id: String,
    mut child: Child,
    stdout: tokio::process::ChildStdout,
    mut stop_rx: oneshot::Receiver<()>,
) {
    let room = room_for(&stream_id);
    let mut reader = BufReader::new(stdout);
    // `line` giữ phần đã đọc dở để không mất byte khi nhánh select khác thắng
    let mut line: Vec<u8> = Vec::new();
    let mut batch: Vec<String> = Vec::new();
    let mut flush_tick = tokio::time::interval(FLUSH_EVERY);
    flush_tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    let mut watchdog = tokio::time::interval(Duration::from_secs(5));
    let mut eof = false;

    loop {
        tokio::select! {
            res = reader.read_until(b'\n', &mut line), if !eof => match res {
                Ok(0) | Err(_) => eof = true,
                Ok(_) => {
                    let text = String::from_utf8_lossy(&line)
                        .trim_end_matches(['\r', '\n'])
                        .to_string();
                    line.clear();
                    if !is_shell_noise(&text) {
                        batch.push(text);
                    }
                    if batch.len() >= FLUSH_LINES {
                        flush(&state, &room, &stream_id, &mut batch);
                    }
                }
            },
            _ = flush_tick.tick() => flush(&state, &room, &stream_id, &mut batch),
            _ = watchdog.tick() => {
                let stale = lock(streams())
                    .get(&stream_id)
                    .map(|s| s.last_ping.elapsed() > PING_TIMEOUT)
                    .unwrap_or(true);
                if stale {
                    tracing::info!("Dừng luồng log {stream_id}: client không còn ping");
                    break;
                }
            }
            _ = &mut stop_rx => break,
        }
        if eof {
            break;
        }
    }

    flush(&state, &room, &stream_id, &mut batch);
    let _ = child.start_kill();
    let code = child.wait().await.ok().and_then(|s| s.code());
    lock(streams()).remove(&stream_id);
    if let Some(ns) = state.io.of("/") {
        let _ = ns.to(room).emit(
            "docker:logs:end",
            &json!({"streamId": stream_id, "exitCode": code}),
        );
    }
}

fn flush(state: &AppState, room: &str, stream_id: &str, batch: &mut Vec<String>) {
    if batch.is_empty() {
        return;
    }
    if let Some(ns) = state.io.of("/") {
        let _ = ns.to(room.to_string()).emit(
            "docker:logs:data",
            &json!({"streamId": stream_id, "lines": batch.clone()}),
        );
    }
    batch.clear();
}

/// Thông báo của shell tương tác khi không có TTY (không phải log của container)
fn is_shell_noise(line: &str) -> bool {
    line.starts_with("bash: cannot set terminal process group")
        || line.starts_with("bash: no job control in this shell")
}
