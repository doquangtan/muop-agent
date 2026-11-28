//! Mount project của máy khác về máy này qua FUSE, để agent chạy trên máy này đọc/ghi thẳng vào
//! thư mục project của máy gửi (qua `/api/fs/*`).
//!
//! Máy gửi tự đính kèm `remoteProject` (danh sách địa chỉ của nó + đường dẫn project) trong lệnh chat.
//! Máy nhận không cần cấu hình gì thêm: chọn địa chỉ kết nối được, mount vào
//! `$HOME/.local/share/muop-agent/mounts/<mã>`, rồi chạy agent trên điểm mount.

// FUSE: Linux dùng `fuser` (kernel /dev/fuse); macOS dùng API libfuse của FUSE-T (`fuse_mac`), vì `fuser`
// không nói chuyện được với FUSE-T. Nơi khác: mọi hàm mount báo lỗi rõ ràng.
#[cfg(target_os = "linux")]
mod fuse;
#[cfg(all(target_os = "macos", feature = "mac-fuse"))]
mod fuse_mac;
#[cfg(target_os = "linux")]
mod inodes;
#[cfg(any(target_os = "linux", feature = "mac-fuse"))]
mod remote;

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

#[cfg(target_os = "linux")]
use fuser::{BackgroundSession, Config, MountOption, SessionACL};

use crate::models::RemoteProject;
use crate::scanner;
#[cfg(target_os = "linux")]
use fuse::RemoteFs;
#[cfg(target_os = "linux")]
use remote::Remote;

/// Thời gian chờ khi thăm dò một địa chỉ của máy gửi
const PROBE_TIMEOUT: Duration = Duration::from_secs(3);
/// Thư mục cha của các điểm mount, dưới `$HOME`
const MOUNTS_SUBDIR: &str = ".local/share/muop-agent/mounts";
/// Máy này có FUSE không: Linux, hoặc macOS khi build với `--features mac-fuse` (cần FUSE-T hoặc macFUSE)
pub const FUSE_SUPPORTED: bool = cfg!(any(target_os = "linux", feature = "mac-fuse"));
/// Thông báo khi máy này không hỗ trợ FUSE
const FUSE_UNSUPPORTED: &str = "mount project của máy khác (FUSE) cần Linux, hoặc macOS build với feature mac-fuse (cài FUSE-T trước)";
/// Biến đánh dấu tiến trình vừa được khởi động lại để nạp FUSE-T (tránh vòng lặp khởi động lại)
#[cfg(all(target_os = "macos", feature = "mac-fuse"))]
const FUSE_RELOAD_ENV: &str = "MUOP_FUSE_RELOADED";

/// macOS: FUSE-T có được nạp vào tiến trình này không. Binary build với `mac-fuse` link yếu tới
/// `libfuse-t` (xem Makefile), nên server vẫn khởi động khi chưa cài FUSE-T. Dò bằng symbol `fuse_mount`.
#[cfg(all(target_os = "macos", feature = "mac-fuse"))]
pub fn fuse_loaded() -> bool {
    let name = b"fuse_mount\0";
    // SAFETY: tra cứu tên symbol trên RTLD_DEFAULT, không gọi hàm nào
    unsafe { !libc::dlsym(libc::RTLD_DEFAULT, name.as_ptr() as *const libc::c_char).is_null() }
}

#[cfg(not(all(target_os = "macos", feature = "mac-fuse")))]
pub fn fuse_loaded() -> bool {
    false
}

/// FUSE-T đã có trên máy nhưng tiến trình này chưa nạp (cài sau khi server đã chạy): cần khởi động lại
#[cfg(all(target_os = "macos", feature = "mac-fuse"))]
pub fn restart_needed() -> bool {
    crate::setup::install::fuse_t_installed() && !fuse_loaded()
}

/// macOS: thư viện link lúc khởi động nên FUSE-T cài sau đó chưa dùng được. Khi thấy FUSE-T đã có mà
/// chưa nạp, chờ lúc rảnh (`is_idle`) rồi khởi động lại server: cùng PID, cùng cổng, client tự kết nối lại.
pub fn spawn_fuse_reload_watch(is_idle: impl Fn() -> bool + Send + 'static) {
    #[cfg(all(target_os = "macos", feature = "mac-fuse"))]
    {
        if std::env::var_os(FUSE_RELOAD_ENV).is_some() {
            return;
        }
        tokio::spawn(async move {
            // Chờ 5 giây trước lần kiểm tra đầu: không khởi động lại ngay lúc server vừa lên
            let start = tokio::time::Instant::now() + Duration::from_secs(5);
            let mut ticker = tokio::time::interval_at(start, Duration::from_secs(5));
            loop {
                ticker.tick().await;
                if restart_needed() && is_idle() {
                    tracing::info!("FUSE-T vừa được cài: khởi động lại server để nạp thư viện");
                    restart_self();
                }
            }
        });
    }
    #[cfg(not(all(target_os = "macos", feature = "mac-fuse")))]
    {
        let _ = is_idle;
    }
}

/// Thay tiến trình hiện tại bằng bản server mới (cùng binary, cùng tham số). Chỉ trả về khi lỗi.
#[cfg(all(target_os = "macos", feature = "mac-fuse"))]
fn restart_self() {
    use std::os::unix::process::CommandExt;
    let exe = match std::env::current_exe() {
        Ok(p) => p,
        Err(e) => {
            tracing::error!("không lấy được đường dẫn server để khởi động lại: {e}");
            return;
        }
    };
    let err = std::process::Command::new(exe)
        .args(std::env::args_os().skip(1))
        .env(FUSE_RELOAD_ENV, "1")
        .exec();
    tracing::error!("không khởi động lại được server: {err}");
}

/// Phiên mount đang giữ: Linux giữ `BackgroundSession` của fuser; macOS giữ `MacMount` (FUSE-T).
/// Nơi không có FUSE không bao giờ tạo được phiên nên dùng `()`.
#[cfg(target_os = "linux")]
type MountSession = BackgroundSession;
#[cfg(all(target_os = "macos", feature = "mac-fuse"))]
type MountSession = fuse_mac::MacMount;
#[cfg(not(any(target_os = "linux", all(target_os = "macos", feature = "mac-fuse"))))]
type MountSession = ();

/// Kết quả mount: điểm mount trên máy này và địa chỉ máy gửi đang dùng
#[derive(Debug, Clone)]
pub struct Mounted {
    pub mount_point: PathBuf,
    pub origin: String,
}

struct Active {
    origin: String,
    /// Giữ phiên FUSE; khi bỏ đi thì hệ file được gỡ mount
    _session: MountSession,
}

static ACTIVE: OnceLock<Mutex<HashMap<PathBuf, Active>>> = OnceLock::new();

/// Máy chính đã đăng ký với máy này (khi máy chính thêm máy này vào cầu nối): host → địa chỉ đang dùng
static REGISTERED: OnceLock<Mutex<HashMap<String, String>>> = OnceLock::new();

fn registered() -> &'static Mutex<HashMap<String, String>> {
    REGISTERED.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Đăng ký máy chính khi được thêm vào cầu nối. Chỉ kiểm tra: FUSE sẵn sàng và kết nối được tới máy chính
/// (stat thư mục gốc của máy chính). Không mount gì; project chỉ được mount khi có lượt chat chạy trên nó.
/// Trả về địa chỉ máy chính đang dùng.
pub fn register_origin(req: &RemoteProject) -> Result<String, String> {
    check_fuse_available()?;
    let root = normalize_project(&req.project_path)?;
    let candidates = order_candidates(&req.urls, &scanner::detect_lan_ips());
    if candidates.is_empty() {
        return Err("máy chính không cung cấp địa chỉ kết nối".into());
    }
    let origin = probe(&candidates, &root)?;
    let host = host_of(&origin).to_string();
    registered()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .insert(host, origin.clone());
    tracing::info!("fsmount: đã đăng ký máy chính {origin}");
    Ok(origin)
}

fn active() -> &'static Mutex<HashMap<PathBuf, Active>> {
    ACTIVE.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Chuẩn bị thư mục project của máy gửi để chạy agent: trả về đường dẫn điểm mount trên máy này.
/// Chạy hàm đồng bộ (có HTTP và mount); từ async thì dùng [`resolve_chat_project`].
pub fn ensure(req: &RemoteProject) -> Result<Mounted, String> {
    check_fuse_available()?;
    let project = normalize_project(&req.project_path)?;
    let candidates = order_candidates(&req.urls, &scanner::detect_lan_ips());
    if candidates.is_empty() {
        return Err("máy gửi không cung cấp địa chỉ kết nối".into());
    }
    let origin = probe(&candidates, &project)?;
    let mount_point = mount_point_for(&req.origin_host, &project)?;

    let mut registry = lock_registry();
    if let Some(entry) = registry.get(&mount_point) {
        if entry.origin == origin && is_alive(&mount_point) {
            return Ok(Mounted {
                mount_point,
                origin,
            });
        }
    }
    // Mount cũ (máy gửi đổi địa chỉ, hoặc phiên đã chết): gỡ rồi mount lại
    registry.remove(&mount_point);
    fusermount_quiet(&mount_point);
    std::fs::create_dir_all(&mount_point).map_err(|e| {
        format!(
            "không tạo được thư mục mount {}: {e}",
            mount_point.display()
        )
    })?;

    let session = mount_remote(&origin, &project, &mount_point)?;
    registry.insert(
        mount_point.clone(),
        Active {
            origin: origin.clone(),
            _session: session,
        },
    );
    tracing::info!(
        "fsmount: đã mount {project} từ {origin} tại {}",
        mount_point.display()
    );
    Ok(Mounted {
        mount_point,
        origin,
    })
}

/// Bản bất đồng bộ của [`ensure`] để gọi từ handler axum
pub async fn resolve_chat_project(remote: &RemoteProject) -> Result<Mounted, String> {
    let remote = remote.clone();
    tokio::task::spawn_blocking(move || ensure(&remote))
        .await
        .map_err(|e| format!("lỗi nội bộ khi mount project: {e}"))?
}

fn lock_registry() -> std::sync::MutexGuard<'static, HashMap<PathBuf, Active>> {
    active().lock().unwrap_or_else(|e| e.into_inner())
}

#[cfg(not(any(target_os = "linux", all(target_os = "macos", feature = "mac-fuse"))))]
fn mount_remote(
    _origin: &str,
    _project: &str,
    _mount_point: &Path,
) -> Result<MountSession, String> {
    Err(FUSE_UNSUPPORTED.into())
}

#[cfg(all(target_os = "macos", feature = "mac-fuse"))]
fn mount_remote(origin: &str, project: &str, mount_point: &Path) -> Result<MountSession, String> {
    fuse_mac::mount(origin, project, mount_point)
}

#[cfg(target_os = "linux")]
fn mount_remote(origin: &str, project: &str, mount_point: &Path) -> Result<MountSession, String> {
    let remote = Remote::with_default_timeout(origin, project)?;
    // SAFETY: getuid/getgid không có điều kiện đầu vào và không thể lỗi
    let (uid, gid) = unsafe { (libc::getuid(), libc::getgid()) };
    let fs = RemoteFs::new(remote, uid, gid);
    // ACL Owner (mặc định): chỉ user chạy server truy cập, không cần allow_other/fuse.conf.
    // Không dùng AutoUnmount: fuser yêu cầu allow_other/allow_root để bật nó. Mount sót do server
    // thoát đột ngột được gỡ bởi `fusermount_quiet` ở lần mount kế tiếp.
    let mut config = Config::default();
    config.acl = SessionACL::Owner;
    config.mount_options = vec![
        MountOption::FSName("muop-remote".to_string()),
        MountOption::Subtype("muopfs".to_string()),
        MountOption::DefaultPermissions,
    ];
    fuser::spawn_mount(fs, mount_point, &config).map_err(|e| {
        format!(
            "không mount được {} (kiểm tra fuse3 và quyền /dev/fuse): {e}",
            mount_point.display()
        )
    })
}

/// Điểm mount còn là mount FUSE đang hoạt động. Thư mục mount vẫn tồn tại sau khi FUSE bị gỡ,
/// nên chỉ kiểm tra tồn tại là không đủ: một filesystem được gắn lên điểm mount có `st_dev`
/// khác thư mục cha. Không đọc được (ENOTCONN, treo) hoặc cùng thiết bị với cha thì coi là chết.
#[cfg(unix)]
pub fn is_alive(mount_point: &Path) -> bool {
    use std::os::unix::fs::MetadataExt;
    let Ok(meta) = std::fs::metadata(mount_point) else {
        return false;
    };
    let Some(parent) = mount_point.parent() else {
        return false;
    };
    match std::fs::metadata(parent) {
        Ok(parent_meta) => meta.dev() != parent_meta.dev(),
        Err(_) => false,
    }
}

#[cfg(not(unix))]
pub fn is_alive(mount_point: &Path) -> bool {
    std::fs::metadata(mount_point).is_ok()
}

/// Gỡ mount còn sót lại (ví dụ từ lần chạy trước của server); lỗi bỏ qua vì thường là không có gì để gỡ
fn fusermount_quiet(mount_point: &Path) {
    if crate::infra::platform::IS_MACOS {
        // macOS (FUSE-T/macFUSE) không có fusermount: gỡ bằng umount
        let _ = std::process::Command::new("umount")
            .arg("-f")
            .arg(mount_point)
            .output();
        return;
    }
    let Some(bin) = fusermount_bin() else {
        return;
    };
    let _ = std::process::Command::new(bin)
        .args(["-uz"])
        .arg(mount_point)
        .output();
}

/// Helper setuid để user thường gỡ/mount FUSE: `fusermount3` (hoặc `fusermount`), dò bằng `which`
fn fusermount_bin() -> Option<PathBuf> {
    crate::infra::tools::resolve("fusermount3")
        .or_else(|| crate::infra::tools::resolve("fusermount"))
}

/// Máy có FUSE không: cần `/dev/fuse` và helper `fusermount3` (setuid) để user thường mount được
pub fn check_fuse_available() -> Result<(), String> {
    if !FUSE_SUPPORTED {
        return Err(FUSE_UNSUPPORTED.into());
    }
    if crate::infra::platform::IS_MACOS {
        // macOS không có /dev/fuse hay fusermount: FUSE-T tự đăng ký; kiểm tra thư viện đã được nạp chưa
        if fuse_loaded() {
            return Ok(());
        }
        if crate::setup::install::fuse_t_installed() {
            return Err(
                "FUSE-T vừa được cài, server đang chờ khởi động lại để nạp thư viện; thử lại sau vài giây".into(),
            );
        }
        return Err(
            "máy này chưa cài FUSE-T: cài ở Khởi tạo (mục Gói Homebrew) rồi thử lại".into(),
        );
    }
    if !Path::new("/dev/fuse").exists() {
        return Err("máy này chưa có /dev/fuse (cần bật FUSE trong kernel)".into());
    }
    if fusermount_bin().is_none() {
        return Err("máy này chưa cài fuse3 (thiếu fusermount3): sudo apt install fuse3".into());
    }
    Ok(())
}

/// Đường dẫn project hợp lệ để gửi lên máy gửi: tuyệt đối, không chứa `..`, bỏ `/` cuối
pub fn normalize_project(raw: &str) -> Result<String, String> {
    let trimmed = raw.trim().trim_end_matches('/');
    if !trimmed.starts_with('/') || trimmed.is_empty() {
        return Err("đường dẫn project từ máy gửi phải là đường dẫn tuyệt đối".into());
    }
    if trimmed.split('/').any(|part| part == "..") {
        return Err("đường dẫn project từ máy gửi không được chứa '..'".into());
    }
    Ok(trimmed.to_string())
}

/// Thăm dò lần lượt các địa chỉ của máy gửi, trả về địa chỉ đầu tiên đáp ứng được project.
/// Nếu máy gửi đáp nhưng từ chối (project không tồn tại, nằm ngoài vùng cho phép) thì báo lỗi ngay.
/// Chuỗi lỗi đầy đủ (lỗi gốc của reqwest nằm ở `source()`, không có trong thông báo ngoài)
fn chain_of(e: &dyn std::error::Error) -> String {
    let mut out = e.to_string();
    let mut cur = e.source();
    while let Some(inner) = cur {
        out.push_str(" <- ");
        out.push_str(&inner.to_string());
        cur = inner.source();
    }
    out
}

fn probe(candidates: &[String], project: &str) -> Result<String, String> {
    let client = reqwest::blocking::Client::builder()
        .timeout(PROBE_TIMEOUT)
        .build()
        .map_err(|e| format!("không tạo được client HTTP: {e}"))?;
    let mut last_error = String::from("không địa chỉ nào trả lời");
    for url in candidates {
        let resp = match client
            .get(format!("{url}/api/fs/stat"))
            .query(&[("path", project)])
            .send()
        {
            Ok(resp) => resp,
            Err(e) => {
                last_error = format!("{url}: {}", chain_of(&e));
                continue;
            }
        };
        if resp.status().is_success() {
            return Ok(url.clone());
        }
        let body: serde_json::Value = resp.json().unwrap_or_default();
        return Err(match body["error"].as_str() {
            Some(msg) => format!("máy gửi ({url}) từ chối project: {msg}"),
            None => format!("máy gửi ({url}) chưa hỗ trợ /api/fs (cần cập nhật server)"),
        });
    }
    Err(format!(
        "không kết nối được tới máy gửi (đã thử {} địa chỉ; {last_error})",
        candidates.len()
    ))
}

/// Sắp xếp địa chỉ máy gửi: địa chỉ cùng dải mạng /24 với máy này đứng trước, giữ nguyên thứ tự còn lại.
/// Chỉ nhận `http://`, bỏ trùng.
pub fn order_candidates(urls: &[String], local_ips: &[String]) -> Vec<String> {
    let mut seen = std::collections::HashSet::new();
    let mut same_net = Vec::new();
    let mut others = Vec::new();
    for raw in urls {
        let url = raw.trim().trim_end_matches('/');
        if !url.starts_with("http://") || !seen.insert(url.to_string()) {
            continue;
        }
        let host = host_of(url);
        if local_ips.iter().any(|ip| same_subnet24(ip, host)) {
            same_net.push(url.to_string());
        } else {
            others.push(url.to_string());
        }
    }
    same_net.extend(others);
    same_net
}

/// Phần host (không cổng) của địa chỉ `http://host:port`
pub fn host_of(url: &str) -> &str {
    url.strip_prefix("http://")
        .unwrap_or(url)
        .split(|c: char| c == '/' || c == ':')
        .next()
        .unwrap_or("")
}

fn same_subnet24(a: &str, b: &str) -> bool {
    let pa: Vec<&str> = a.split('.').collect();
    let pb: Vec<&str> = b.split('.').collect();
    pa.len() == 4 && pb.len() == 4 && pa[..3] == pb[..3]
}

/// Tên thư mục mount: băm ổn định (FNV-1a 64) của máy gửi + đường dẫn project
pub fn mount_name(origin_host: &str, project: &str) -> String {
    let host = if origin_host.trim().is_empty() {
        "remote"
    } else {
        origin_host.trim()
    };
    let key = format!("{host}\n{project}");
    format!("{:016x}", fnv1a64(key.as_bytes()))
}

fn fnv1a64(bytes: &[u8]) -> u64 {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for b in bytes {
        hash ^= u64::from(*b);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    hash
}

/// Thư mục chứa các điểm mount, dưới `$HOME`
fn mounts_root() -> Result<PathBuf, String> {
    let home = std::env::var("HOME").map_err(|_| "không xác định được $HOME".to_string())?;
    Ok(PathBuf::from(home).join(MOUNTS_SUBDIR))
}

fn mount_point_for(origin_host: &str, project: &str) -> Result<PathBuf, String> {
    Ok(mounts_root()?.join(mount_name(origin_host, project)))
}

/// Đường dẫn nằm trong một điểm mount project của máy khác (cwd của lượt chat trên mount)
pub fn is_mount_path(path: &str) -> bool {
    mounts_root().is_ok_and(|root| path_under(path, &root))
}

/// `path` nằm dưới `root` theo từng thành phần đường dẫn (không khớp tiền tố chữ như `mounts2`)
fn path_under(path: &str, root: &Path) -> bool {
    Path::new(path).starts_with(root)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prefers_candidates_on_the_same_subnet() {
        let urls = vec![
            "http://10.9.9.9:8787".to_string(),
            "http://192.168.31.96:8787".to_string(),
            "http://127.0.0.1:8787".to_string(),
        ];
        let local = vec!["192.168.31.216".to_string()];
        assert_eq!(
            order_candidates(&urls, &local),
            vec![
                "http://192.168.31.96:8787".to_string(),
                "http://10.9.9.9:8787".to_string(),
                "http://127.0.0.1:8787".to_string(),
            ]
        );
    }

    #[test]
    fn drops_duplicates_and_non_http_urls() {
        let urls = vec![
            "http://192.168.31.96:8787/".to_string(),
            "http://192.168.31.96:8787".to_string(),
            "https://example.com".to_string(),
            "".to_string(),
        ];
        assert_eq!(
            order_candidates(&urls, &[]),
            vec!["http://192.168.31.96:8787".to_string()]
        );
    }

    #[test]
    fn mount_name_is_stable_and_depends_on_host_and_project() {
        let a = mount_name("asrock", "/home/john/Documents/muop-ecosystem/muop-agent");
        assert_eq!(
            a,
            mount_name("asrock", "/home/john/Documents/muop-ecosystem/muop-agent")
        );
        assert_eq!(a.len(), 16);
        assert_ne!(
            a,
            mount_name("laptop", "/home/john/Documents/muop-ecosystem/muop-agent")
        );
        assert_ne!(
            a,
            mount_name("asrock", "/home/john/Documents/muop-ecosystem/other")
        );
        assert_eq!(mount_name("", "/x"), mount_name("  ", "/x"));
    }

    #[test]
    fn recognises_paths_inside_a_mount_point_by_component() {
        let root = Path::new("/home/john/.local/share/muop-agent/mounts");
        assert!(path_under(
            "/home/john/.local/share/muop-agent/mounts/3b0cf23755d3e304",
            root
        ));
        assert!(path_under(
            "/home/john/.local/share/muop-agent/mounts/3b0cf23755d3e304/lib",
            root
        ));
        assert!(!path_under(
            "/home/john/.local/share/muop-agent/mounts2/x",
            root
        ));
        assert!(!path_under(
            "/home/john/Documents/muop-ecosystem/muop-agent",
            root
        ));
    }

    #[test]
    fn normalizes_and_rejects_bad_project_paths() {
        assert_eq!(
            normalize_project(" /home/john/p/ ").unwrap(),
            "/home/john/p"
        );
        assert!(normalize_project("relative/path").is_err());
        assert!(normalize_project("").is_err());
        assert!(normalize_project("/home/john/../root").is_err());
    }
}
