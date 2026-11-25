//! Quản lý Docker trên máy SSH đã lưu.
//!
//! - Mỗi máy có tối đa một **phiên Docker**: một kết nối SSH giữ sẵn (ControlMaster), tách biệt với phiên terminal.
//! - **Máy này** (loopback, đúng user server, xem `ssh::hosts::is_local`): không dùng ssh, chạy docker trực tiếp
//!   bằng shell của server (`$SHELL -i -c`). Không có ControlMaster, không cần sshd hay mật khẩu.
//! - Phiên tồn tại khi màn hình đóng. Chỉ kết thúc khi người dùng bấm "Kết thúc phiên", khi không được dùng
//!   quá `IDLE_TIMEOUT`, hoặc khi server khởi động lại.
//! - Mỗi lần dùng, nếu kết nối đã rớt thì tự kết nối lại bằng thông tin đã lưu.
//! - Lệnh docker chạy qua shell tương tác của user (như chạy lệnh SSH) để PATH đầy đủ.
//! - Mật khẩu/private key chỉ đi qua `SSH_ASKPASS` hoặc file key 0600 trong thư mục 0700 và bị xóa sau khi đăng nhập.

use crate::infra::store::SshHostRow;
use crate::models::{DockerContainerDto, DockerSessionDto};
use serde_json::Value;
use std::collections::HashMap;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::process::Stdio;
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};
use std::time::{Duration, Instant};
use tokio::process::Command;
use tokio::sync::Mutex as AsyncMutex;

/// Số phiên Docker cùng lúc (mỗi phiên là một kết nối SSH)
const MAX_SESSIONS: usize = 8;
/// Phiên không được dùng quá lâu thì tự đóng
const IDLE_TIMEOUT: Duration = Duration::from_secs(6 * 3600);
const CONNECT_TIMEOUT: Duration = Duration::from_secs(40);
const SCAN_TIMEOUT: Duration = Duration::from_secs(30);
const ACTION_TIMEOUT: Duration = Duration::from_secs(300);
const MAX_ACTION_CONTAINERS: usize = 200;
const DIR_PREFIX: &str = "muop-docker-";
/// Chỉ liệt kê container đang chạy; dòng JSON cho mỗi container
const PS_COMMAND: &str = "docker ps --no-trunc --format '{{json .}}'";

struct Inner {
    last_active: Instant,
    connected: bool,
    scanned_at: String,
    error: String,
    containers: Vec<DockerContainerDto>,
}

pub struct DockerSession {
    id: String,
    host: SshHostRow,
    started_at: String,
    /// Thư mục 0700 chứa socket ControlMaster (và key/askpass khi đang đăng nhập)
    dir: PathBuf,
    ctl: PathBuf,
    /// Giữ khi thiết lập/kết nối lại để hai lần không cùng tạo một socket
    connect_lock: AsyncMutex<()>,
    inner: Mutex<Inner>,
}

static SESSIONS: OnceLock<Mutex<HashMap<String, Arc<DockerSession>>>> = OnceLock::new();
static OPEN_LOCK: OnceLock<AsyncMutex<()>> = OnceLock::new();

fn registry() -> &'static Mutex<HashMap<String, Arc<DockerSession>>> {
    SESSIONS.get_or_init(|| Mutex::new(HashMap::new()))
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

fn get(id: &str) -> Option<Arc<DockerSession>> {
    lock(registry()).get(id).cloned()
}

fn find_by_host(host_id: i64) -> Option<Arc<DockerSession>> {
    lock(registry())
        .values()
        .find(|s| s.host.id == host_id)
        .cloned()
}

fn new_id() -> String {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    format!("dock-{}-{}", std::process::id(), nanos)
}

fn target(row: &SshHostRow) -> String {
    format!("{}@{}", row.username, row.host)
}

/// Máy này: chạy trực tiếp trên server, không qua ssh
fn is_local_session(s: &DockerSession) -> bool {
    crate::ssh::hosts::is_local(&s.host)
}

/// Lệnh shell trên máy server (`$SHELL -l -i -c`), cùng PATH với terminal của máy này
fn local_command(command: &str) -> Command {
    let mut cmd = Command::new(crate::ssh::hosts::local_shell());
    cmd.args(["-l", "-i", "-c", command]);
    if let Some(home) = std::env::var_os("HOME")
        .map(PathBuf::from)
        .filter(|p| p.is_dir())
    {
        cmd.current_dir(home);
    }
    cmd
}

fn snapshot(s: &DockerSession) -> DockerSessionDto {
    let inner = lock(&s.inner);
    DockerSessionDto {
        session_id: s.id.clone(),
        host_id: s.host.id,
        host_name: s.host.name.clone(),
        started_at: s.started_at.clone(),
        connected: inner.connected,
        scanned_at: inner.scanned_at.clone(),
        error: inner.error.clone(),
        containers: inner.containers.clone(),
    }
}

fn touch(s: &DockerSession) {
    lock(&s.inner).last_active = Instant::now();
}

/// Danh sách phiên Docker đang chạy (kèm kết quả quét gần nhất)
pub fn list() -> Vec<DockerSessionDto> {
    let sessions: Vec<Arc<DockerSession>> = lock(registry()).values().cloned().collect();
    let mut items: Vec<DockerSessionDto> = sessions.iter().map(|s| snapshot(s)).collect();
    items.sort_by(|a, b| a.started_at.cmp(&b.started_at));
    items
}

/// Mở phiên Docker cho máy đã lưu. Nếu máy đã có phiên thì gắn vào phiên đó và quét lại.
pub async fn open(row: SshHostRow) -> Result<DockerSessionDto, String> {
    if row.host.is_empty() || row.username.is_empty() {
        return Err("Thiếu host hoặc username".into());
    }
    if !crate::ssh::hosts::is_local(&row)
        && row.password.is_empty()
        && row.private_key.trim().is_empty()
    {
        return Err("Máy này chưa có mật khẩu hoặc private key".into());
    }
    let open_lock = OPEN_LOCK.get_or_init(|| AsyncMutex::new(()));
    let _guard = open_lock.lock().await;

    if let Some(existing) = find_by_host(row.id) {
        return Ok(scan(&existing).await);
    }
    if lock(registry()).len() >= MAX_SESSIONS {
        return Err("Đã đạt số phiên Docker tối đa".into());
    }

    let id = new_id();
    let dir = std::env::temp_dir().join(format!("{DIR_PREFIX}{id}"));
    if fs::create_dir(&dir).is_err()
        || fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).is_err()
    {
        return Err("Không tạo được thư mục tạm".into());
    }
    let session = Arc::new(DockerSession {
        id: id.clone(),
        host: row,
        started_at: chrono::Utc::now().to_rfc3339(),
        ctl: dir.join("ctl"),
        dir,
        connect_lock: AsyncMutex::new(()),
        inner: Mutex::new(Inner {
            last_active: Instant::now(),
            connected: false,
            scanned_at: String::new(),
            error: String::new(),
            containers: Vec::new(),
        }),
    });
    if let Err(e) = connect(&session).await {
        let _ = fs::remove_dir_all(&session.dir);
        return Err(e);
    }
    lock(registry()).insert(id, session.clone());
    Ok(scan(&session).await)
}

/// Quét lại danh sách container đang chạy của phiên
pub async fn scan_session(id: &str) -> Option<DockerSessionDto> {
    let s = get(id)?;
    Some(scan(&s).await)
}

/// Lệnh `ssh` mở một kênh mới trên kết nối ControlMaster của phiên, chạy `command` (dùng cho luồng log).
/// Bảo đảm kết nối đang sống trước khi trả về.
pub async fn stream_command(session_id: &str, command: &str) -> Result<Command, String> {
    let Some(s) = get(session_id) else {
        return Err("Phiên Docker đã kết thúc".into());
    };
    touch(&s);
    ensure_connected(&s).await?;
    if is_local_session(&s) {
        let mut cmd = local_command(command);
        cmd.stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .kill_on_drop(true);
        return Ok(cmd);
    }
    let mut cmd = Command::new("ssh");
    cmd.arg("-S")
        .arg(&s.ctl)
        .args(["-o", "ControlMaster=no"])
        .args(["-o", "ConnectTimeout=10"])
        .arg(target(&s.host))
        .arg(crate::ssh::hosts::remote_interactive_command(command))
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true);
    Ok(cmd)
}

/// Dừng hoặc khởi động lại các container (một container, hoặc cả compose project).
/// Sau thao tác luôn quét lại; lỗi của thao tác được trả trong `error`.
pub async fn run_action(
    id: &str,
    action: &str,
    container_ids: &[String],
) -> Result<DockerSessionDto, String> {
    let Some(s) = get(id) else {
        return Err("Phiên Docker đã kết thúc".into());
    };
    if action != "stop" && action != "restart" {
        return Err("Thao tác phải là stop hoặc restart".into());
    }
    if container_ids.is_empty() {
        return Err("Chưa chọn container nào".into());
    }
    if container_ids.len() > MAX_ACTION_CONTAINERS {
        return Err("Quá nhiều container trong một thao tác".into());
    }
    if container_ids
        .iter()
        .any(|c| c.len() < 12 || c.len() > 64 || !c.chars().all(|ch| ch.is_ascii_hexdigit()))
    {
        return Err("Mã container không hợp lệ".into());
    }
    let ids: Vec<String> = container_ids
        .iter()
        .map(|c| crate::ssh::hosts::shell_quote(c))
        .collect();
    let cmd = format!("docker {action} {}", ids.join(" "));
    let action_error = match run_remote(&s, &cmd, ACTION_TIMEOUT).await {
        Ok(out) if out.ok => String::new(),
        Ok(out) => docker_error(&out.stderr),
        Err(e) => e,
    };
    let mut dto = scan(&s).await;
    if !action_error.is_empty() {
        dto.error = action_error;
    }
    Ok(dto)
}

/// Kết thúc phiên: thoát kết nối SSH giữ sẵn và xóa thư mục tạm. Trả về false nếu phiên không tồn tại.
pub async fn close(id: &str) -> bool {
    let removed = lock(registry()).remove(id);
    match removed {
        Some(s) => {
            shutdown(&s).await;
            true
        }
        None => false,
    }
}

/// Đóng các phiên không được dùng quá `IDLE_TIMEOUT`. Trả về số phiên đã đóng.
pub async fn reap_idle() -> usize {
    let idle: Vec<String> = lock(registry())
        .values()
        .filter(|s| lock(&s.inner).last_active.elapsed() > IDLE_TIMEOUT)
        .map(|s| s.id.clone())
        .collect();
    for id in &idle {
        close(id).await;
    }
    idle.len()
}

/// Khi server khởi động: đóng kết nối ControlMaster còn sót lại từ lần chạy trước và xóa thư mục tạm
pub fn cleanup_stale() {
    let Ok(entries) = fs::read_dir(std::env::temp_dir()) else {
        return;
    };
    for entry in entries.flatten() {
        if !entry.file_name().to_string_lossy().starts_with(DIR_PREFIX) {
            continue;
        }
        let dir = entry.path();
        let _ = std::process::Command::new("ssh")
            .arg("-S")
            .arg(dir.join("ctl"))
            .args(["-O", "exit", "muop-docker-stale"])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
        let _ = fs::remove_dir_all(&dir);
    }
}

async fn shutdown(s: &DockerSession) {
    if is_local_session(s) {
        let _ = fs::remove_dir_all(&s.dir);
        return;
    }
    let _ = tokio::time::timeout(
        Duration::from_secs(5),
        Command::new("ssh")
            .arg("-S")
            .arg(&s.ctl)
            .args(["-O", "exit"])
            .arg(target(&s.host))
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status(),
    )
    .await;
    let _ = fs::remove_dir_all(&s.dir);
}

/// Thiết lập kết nối ControlMaster (`ssh -MNf`): sau khi xác thực, ssh tự chạy nền và giữ socket.
async fn connect(s: &DockerSession) -> Result<(), String> {
    if is_local_session(s) {
        lock(&s.inner).connected = true;
        return Ok(());
    }
    let _ = fs::remove_file(&s.ctl);
    let mut cmd = Command::new("ssh");
    cmd.arg("-M")
        .arg("-N")
        .arg("-f")
        .arg("-S")
        .arg(&s.ctl)
        .arg("-p")
        .arg(s.host.port.to_string())
        .args(["-o", "StrictHostKeyChecking=accept-new"])
        .args(["-o", "ConnectTimeout=10"])
        .args(["-o", "NumberOfPasswordPrompts=1"])
        // Phát hiện kết nối chết để lần sau tự kết nối lại
        .args(["-o", "ServerAliveInterval=30"])
        .args(["-o", "ServerAliveCountMax=3"])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    crate::ssh::hosts::apply_auth(&mut cmd, &s.host, &s.dir)?;
    cmd.arg(target(&s.host));

    let child = cmd
        .spawn()
        .map_err(|e| format!("Không chạy được ssh: {e}"))?;
    let res = tokio::time::timeout(CONNECT_TIMEOUT, child.wait_with_output()).await;
    crate::ssh::hosts::remove_auth_files(&s.dir);
    match res {
        Ok(Ok(out)) if out.status.success() => {
            lock(&s.inner).connected = true;
            Ok(())
        }
        Ok(Ok(out)) => {
            lock(&s.inner).connected = false;
            Err(connect_error(&String::from_utf8_lossy(&out.stderr)))
        }
        Ok(Err(e)) => Err(format!("Lỗi khi chạy ssh: {e}")),
        Err(_) => Err("Hết thời gian kết nối SSH".into()),
    }
}

async fn master_alive(s: &DockerSession) -> bool {
    if is_local_session(s) {
        return true;
    }
    Command::new("ssh")
        .arg("-S")
        .arg(&s.ctl)
        .args(["-O", "check"])
        .arg(target(&s.host))
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .await
        .map(|st| st.success())
        .unwrap_or(false)
}

/// Bảo đảm có kết nối ControlMaster đang sống; nếu không thì kết nối lại.
async fn ensure_connected(s: &DockerSession) -> Result<(), String> {
    let _guard = s.connect_lock.lock().await;
    if master_alive(s).await {
        return Ok(());
    }
    connect(s).await
}

struct RemoteOutput {
    ok: bool,
    stdout: String,
    stderr: String,
}

async fn run_once(
    s: &DockerSession,
    command: &str,
    timeout: Duration,
) -> Result<RemoteOutput, String> {
    let mut cmd = if is_local_session(s) {
        local_command(command)
    } else {
        let mut c = Command::new("ssh");
        c.arg("-S")
            .arg(&s.ctl)
            .args(["-o", "ControlMaster=no"])
            .args(["-o", "ConnectTimeout=10"])
            .arg(target(&s.host))
            // Shell tương tác của user để PATH đầy đủ (giống chạy lệnh SSH)
            .arg(crate::ssh::hosts::remote_interactive_command(command));
        c
    };
    cmd.stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    let child = cmd
        .spawn()
        .map_err(|e| format!("Không chạy được lệnh: {e}"))?;
    let out = tokio::time::timeout(timeout, child.wait_with_output())
        .await
        .map_err(|_| "Hết thời gian chờ lệnh Docker".to_string())?
        .map_err(|e| format!("Lỗi khi chạy ssh: {e}"))?;
    Ok(RemoteOutput {
        ok: out.status.success(),
        stdout: String::from_utf8_lossy(&out.stdout).into_owned(),
        stderr: crate::ssh::hosts::strip_shell_noise(&String::from_utf8_lossy(&out.stderr)),
    })
}

/// Chạy lệnh trên máy qua kết nối của phiên. Nếu kết nối rớt giữa chừng thì kết nối lại và chạy lại một lần.
async fn run_remote(
    s: &DockerSession,
    command: &str,
    timeout: Duration,
) -> Result<RemoteOutput, String> {
    ensure_connected(s).await?;
    let first = run_once(s, command, timeout).await?;
    if first.ok || master_alive(s).await {
        return Ok(first);
    }
    ensure_connected(s).await?;
    run_once(s, command, timeout).await
}

/// Quét container đang chạy và cập nhật trạng thái phiên
async fn scan(s: &DockerSession) -> DockerSessionDto {
    touch(s);
    let result = run_remote(s, PS_COMMAND, SCAN_TIMEOUT).await;
    {
        let mut inner = lock(&s.inner);
        match result {
            Ok(out) if out.ok => {
                inner.connected = true;
                inner.error.clear();
                inner.containers = parse_containers(&out.stdout);
                inner.scanned_at = chrono::Utc::now().to_rfc3339();
            }
            Ok(out) => {
                // SSH vẫn sống, nhưng lệnh docker lỗi (thiếu docker, không có quyền...)
                inner.connected = true;
                inner.error = docker_error(&out.stderr);
                inner.containers.clear();
            }
            Err(e) => {
                inner.connected = false;
                inner.error = e;
                inner.containers.clear();
            }
        }
    }
    snapshot(s)
}

/// Đọc đầu ra `docker ps --format '{{json .}}'`, mỗi dòng một container. Bỏ qua dòng không phải JSON
/// (ví dụ thông báo của shell đăng nhập).
fn parse_containers(stdout: &str) -> Vec<DockerContainerDto> {
    let mut items: Vec<DockerContainerDto> = stdout
        .lines()
        .filter_map(|line| {
            let v: Value = serde_json::from_str(line.trim()).ok()?;
            let labels = text(&v, "Labels");
            Some(DockerContainerDto {
                id: text(&v, "ID"),
                name: text(&v, "Names"),
                image: text(&v, "Image"),
                state: text(&v, "State"),
                status: text(&v, "Status"),
                ports: text(&v, "Ports"),
                project: label(&labels, "com.docker.compose.project"),
                service: label(&labels, "com.docker.compose.service"),
                created: text(&v, "CreatedAt"),
            })
        })
        .collect();
    // Container thuộc compose project đứng trước, nhóm theo project rồi theo tên
    items.sort_by(|a, b| {
        (a.project.is_empty(), a.project.as_str(), a.name.as_str()).cmp(&(
            b.project.is_empty(),
            b.project.as_str(),
            b.name.as_str(),
        ))
    });
    items
}

fn text(v: &Value, key: &str) -> String {
    v[key].as_str().unwrap_or("").to_string()
}

/// Lấy giá trị một label từ chuỗi `k1=v1,k2=v2`
fn label(labels: &str, key: &str) -> String {
    labels
        .split(',')
        .find_map(|kv| kv.strip_prefix(key).and_then(|rest| rest.strip_prefix('=')))
        .unwrap_or("")
        .to_string()
}

/// Dòng lỗi cuối cùng trong stderr, hoặc thông báo tiếng Việt cho các lỗi thường gặp
fn docker_error(stderr: &str) -> String {
    let lower = stderr.to_lowercase();
    if lower.contains("permission denied") {
        return "Tài khoản SSH không có quyền dùng Docker (cần thuộc nhóm docker trên máy)".into();
    }
    if lower.contains("command not found") || lower.contains("docker: not found") {
        return "Không tìm thấy lệnh docker trên máy này".into();
    }
    if lower.contains("cannot connect to the docker daemon") {
        return "Docker daemon không chạy trên máy này".into();
    }
    if stderr.trim().is_empty() {
        return "Lệnh docker thất bại".into();
    }
    connect_error(stderr)
}

fn connect_error(stderr: &str) -> String {
    stderr
        .lines()
        .rev()
        .map(|l| l.trim())
        .find(|l| !l.is_empty())
        .map(|l| l.to_string())
        .unwrap_or_else(|| "Không kết nối được SSH".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_running_containers_grouped_by_project() {
        let out = concat!(
            "{\"ID\":\"aaaaaaaaaaaa1\",\"Names\":\"web\",\"Image\":\"nginx\",\"State\":\"running\",\"Status\":\"Up 1 hour\",\"Ports\":\"80/tcp\",\"Labels\":\"com.docker.compose.project=shop,com.docker.compose.service=web\",\"CreatedAt\":\"x\"}\n",
            "Welcome banner from shell\n",
            "{\"ID\":\"bbbbbbbbbbbb2\",\"Names\":\"redis\",\"Image\":\"redis\",\"State\":\"running\",\"Status\":\"Up\",\"Ports\":\"\",\"Labels\":\"maintainer=x\",\"CreatedAt\":\"y\"}\n",
            "{\"ID\":\"cccccccccccc3\",\"Names\":\"db\",\"Image\":\"pg\",\"State\":\"running\",\"Status\":\"Up\",\"Ports\":\"\",\"Labels\":\"com.docker.compose.project=shop,com.docker.compose.service=db\",\"CreatedAt\":\"z\"}\n",
        );
        let items = parse_containers(out);
        assert_eq!(items.len(), 3);
        assert_eq!(items[0].name, "db");
        assert_eq!(items[0].project, "shop");
        assert_eq!(items[0].service, "db");
        assert_eq!(items[1].name, "web");
        assert_eq!(items[2].name, "redis");
        assert_eq!(items[2].project, "");
    }

    #[test]
    fn label_lookup_is_exact() {
        let labels =
            "com.docker.compose.project.config_files=/a.yml,com.docker.compose.project=shop";
        assert_eq!(label(labels, "com.docker.compose.project"), "shop");
        assert_eq!(
            label(
                "com.docker.compose.project.working_dir=/x",
                "com.docker.compose.project"
            ),
            ""
        );
    }

    #[test]
    fn maps_common_docker_errors() {
        assert!(docker_error(
            "permission denied while trying to connect to the Docker daemon socket"
        )
        .contains("quyền"));
        assert!(docker_error("bash: docker: command not found").contains("Không tìm thấy"));
        assert_eq!(docker_error("boom\n"), "boom");
    }
}
