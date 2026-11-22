//! Theo dõi các thư mục đang mở trong explorer và đẩy `explore:update` cho đúng nhóm đang xem.
//!
//! - Room `explore:<khóa>`. Khóa là đường dẫn tương đối tới thư mục project (`muop-agent`,
//!   `muop-agent/lib`; thư mục gốc là `.`), hoặc đường dẫn tuyệt đối nếu thư mục nằm ngoài project.
//!   Nhờ vậy hai UI xem hai thư mục khác nhau không nhận nhầm cập nhật của nhau.
//! - Một thư mục chỉ được theo dõi khi room có ít nhất một socket đang xem. Khi không còn socket nào
//!   (explorer đóng, bỏ mở thư mục, hoặc socket ngắt kết nối) thì watcher được dừng.
//! - Chỉ theo dõi nội dung trực tiếp của thư mục (không đệ quy), vì explorer chỉ hiển thị một cấp con.

use notify::{Config, Event, EventKind, RecommendedWatcher, RecursiveMode, Watcher};
use serde::{Deserialize, Serialize};
use socketioxide::{extract::SocketRef, SocketIo};
use std::collections::{HashMap, HashSet};
use std::path::{Component, Path, PathBuf};
use std::sync::{Mutex, MutexGuard, OnceLock};
use std::time::Duration;
use tokio::sync::mpsc;

/// Tiền tố room của explorer
pub const ROOM_PREFIX: &str = "explore:";
/// Sự kiện gửi tới room khi nội dung thư mục đổi
pub const UPDATE_EVENT: &str = "explore:update";
/// Gom các sự kiện trong khoảng này thành một lần thông báo (một lần lưu file có thể tạo nhiều sự kiện)
const DEBOUNCE: Duration = Duration::from_millis(300);

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WatchRequest {
    /// Đường dẫn tuyệt đối của thư mục đang mở
    pub path: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UnwatchRequest {
    /// Room trả về từ `explore:watch`
    pub room: String,
}

/// Ack của `explore:watch` và `explore:unwatch`
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ExploreAck {
    pub ok: bool,
    pub room: String,
    pub error: String,
}

/// Payload của `explore:update`
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ExploreUpdate {
    pub room: String,
    /// Đường dẫn tuyệt đối (đã giải symlink) của thư mục vừa đổi
    pub path: String,
}

/// Một thư mục đang được theo dõi: danh sách socket đang xem và watcher (bỏ khỏi bảng là dừng)
struct Watch {
    subscribers: HashSet<String>,
    _watcher: RecommendedWatcher,
}

#[derive(Default)]
struct Hub {
    /// room → thư mục đang theo dõi
    watches: HashMap<String, Watch>,
    /// id socket → các room socket đó đang xem
    joined: HashMap<String, HashSet<String>>,
}

static HUB: OnceLock<Mutex<Hub>> = OnceLock::new();
static IO: OnceLock<SocketIo> = OnceLock::new();

fn hub() -> MutexGuard<'static, Hub> {
    HUB.get_or_init(|| Mutex::new(Hub::default()))
        .lock()
        .unwrap_or_else(|e| e.into_inner())
}

pub fn init(io: SocketIo) {
    let _ = IO.set(io);
}

/// Khóa room của một thư mục đã giải symlink, theo thư mục gốc project (tham số để test được)
pub fn room_key_in(root: Option<&Path>, dir: &Path) -> String {
    let key = match root {
        Some(root) => match dir.strip_prefix(root) {
            Ok(rel) if rel.as_os_str().is_empty() => ".".to_string(),
            Ok(rel) => rel.to_string_lossy().into_owned(),
            Err(_) => dir.to_string_lossy().into_owned(),
        },
        None => dir.to_string_lossy().into_owned(),
    };
    format!("{ROOM_PREFIX}{key}")
}

/// Khóa room theo thư mục project đang cấu hình trên server
pub fn room_key(dir: &Path) -> String {
    let root = crate::setup::workspace_root().and_then(|r| r.canonicalize().ok());
    room_key_in(root.as_deref(), dir)
}

/// Đường dẫn phải tuyệt đối, không chứa `..`, tồn tại và là thư mục; trả về đường dẫn đã giải symlink
fn resolve_dir(raw: &str) -> Result<PathBuf, String> {
    let p = Path::new(raw.trim());
    if !p.is_absolute() {
        return Err("đường dẫn phải là tuyệt đối".into());
    }
    if p.components().any(|c| matches!(c, Component::ParentDir)) {
        return Err("đường dẫn không được chứa '..'".into());
    }
    let dir = p
        .canonicalize()
        .map_err(|e| format!("không mở được thư mục: {e}"))?;
    if !dir.is_dir() {
        return Err("đường dẫn không phải thư mục".into());
    }
    Ok(dir)
}

/// Sự kiện làm nội dung thư mục đổi (bỏ qua truy cập chỉ đọc)
fn relevant(kind: &EventKind) -> bool {
    !matches!(kind, EventKind::Access(_) | EventKind::Other)
}

/// Tạo watcher không đệ quy trên `dir`. Mỗi đợt sự kiện (đã gom) gọi `on_fire` một lần.
fn start_watch(
    dir: &Path,
    on_fire: impl Fn() + Send + 'static,
) -> Result<RecommendedWatcher, String> {
    let (tx, mut rx) = mpsc::unbounded_channel::<()>();
    let mut watcher = notify::recommended_watcher(move |res: notify::Result<Event>| {
        if let Ok(event) = res {
            if relevant(&event.kind) {
                let _ = tx.send(());
            }
        }
    })
    .map_err(|e| e.to_string())?;
    watcher
        .watch(dir, RecursiveMode::NonRecursive)
        .map_err(|e| e.to_string())?;
    // Khi watcher bị bỏ, sender đóng và task này tự kết thúc
    tokio::spawn(async move {
        while rx.recv().await.is_some() {
            tokio::time::sleep(DEBOUNCE).await;
            while rx.try_recv().is_ok() {}
            on_fire();
        }
    });
    Ok(watcher)
}

fn emit_update(room: &str, dir: &Path) {
    let Some(io) = IO.get() else {
        return;
    };
    let Some(ns) = io.of("/") else {
        return;
    };
    let payload = ExploreUpdate {
        room: room.to_string(),
        path: dir.to_string_lossy().into_owned(),
    };
    let _ = ns.to(room.to_string()).emit(UPDATE_EVENT, &payload);
}

/// Ghi nhận một socket xem `room` (thư mục `dir`). Tạo watcher nếu là người xem đầu tiên.
fn subscribe(h: &mut Hub, room: &str, dir: &Path, sid: &str) -> Result<(), String> {
    if !h.watches.contains_key(room) {
        let (room_c, dir_c) = (room.to_string(), dir.to_path_buf());
        let watcher = start_watch(dir, move || emit_update(&room_c, &dir_c))?;
        h.watches.insert(
            room.to_string(),
            Watch {
                subscribers: HashSet::new(),
                _watcher: watcher,
            },
        );
    }
    if let Some(w) = h.watches.get_mut(room) {
        w.subscribers.insert(sid.to_string());
    }
    h.joined
        .entry(sid.to_string())
        .or_default()
        .insert(room.to_string());
    Ok(())
}

/// Bỏ một socket khỏi `only` (nếu có) hoặc khỏi mọi room. Room không còn người xem thì dừng watcher.
fn release(h: &mut Hub, sid: &str, only: Option<&str>) {
    let rooms: Vec<String> = match only {
        Some(room) => {
            if let Some(set) = h.joined.get_mut(sid) {
                set.remove(room);
                if set.is_empty() {
                    h.joined.remove(sid);
                }
            }
            vec![room.to_string()]
        }
        None => h
            .joined
            .remove(sid)
            .map(|set| set.into_iter().collect())
            .unwrap_or_default(),
    };
    for room in rooms {
        let empty = match h.watches.get_mut(&room) {
            Some(w) => {
                w.subscribers.remove(sid);
                w.subscribers.is_empty()
            }
            None => false,
        };
        if empty {
            // Bỏ khỏi bảng = bỏ watcher = dừng theo dõi
            h.watches.remove(&room);
        }
    }
}

/// `explore:watch`: socket vào room của thư mục và bắt đầu theo dõi nếu chưa có ai xem
pub fn watch(socket: &SocketRef, raw: &str) -> Result<String, String> {
    let dir = resolve_dir(raw)?;
    let room = room_key(&dir);
    subscribe(&mut hub(), &room, &dir, &socket.id.to_string())?;
    socket.join(room.clone()).map_err(|e| e.to_string())?;
    Ok(room)
}

/// `explore:unwatch`: socket rời room; room trống thì dừng theo dõi
pub fn unwatch(socket: &SocketRef, room: &str) {
    let _ = socket.leave(room.to_string());
    release(&mut hub(), &socket.id.to_string(), Some(room));
}

/// Socket ngắt kết nối: gỡ khỏi mọi room, dừng các thư mục không còn ai xem
pub fn release_socket(sid: &str) {
    release(&mut hub(), sid, None);
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;

    fn temp_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "muop-explore-{tag}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0)
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn room_key_is_relative_inside_project_and_absolute_outside() {
        let root = Path::new("/work/muop-ecosystem");
        assert_eq!(
            room_key_in(Some(root), Path::new("/work/muop-ecosystem/muop-agent")),
            "explore:muop-agent"
        );
        assert_eq!(
            room_key_in(Some(root), Path::new("/work/muop-ecosystem/muop-agent/lib")),
            "explore:muop-agent/lib"
        );
        assert_eq!(room_key_in(Some(root), root), "explore:.");
        assert_eq!(
            room_key_in(Some(root), Path::new("/home/x")),
            "explore:/home/x"
        );
        assert_eq!(room_key_in(None, Path::new("/home/x")), "explore:/home/x");
    }

    #[test]
    fn resolve_dir_rejects_relative_parent_and_files() {
        assert!(resolve_dir("relative/dir").is_err());
        assert!(resolve_dir("/tmp/../etc").is_err());
        let dir = temp_dir("resolve");
        let file = dir.join("f.txt");
        std::fs::write(&file, "x").unwrap();
        assert!(resolve_dir(&file.to_string_lossy()).is_err());
        assert!(resolve_dir(&dir.to_string_lossy()).is_ok());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn subscribers_share_one_watcher_and_last_one_out_stops_it() {
        let dir = temp_dir("refcount");
        let room = room_key_in(None, &dir);
        let mut h = Hub::default();
        subscribe(&mut h, &room, &dir, "sock-a").unwrap();
        subscribe(&mut h, &room, &dir, "sock-b").unwrap();
        assert_eq!(h.watches.len(), 1, "hai người xem chỉ có một watcher");

        release(&mut h, "sock-a", Some(&room));
        assert_eq!(h.watches.len(), 1, "còn một người xem thì vẫn theo dõi");

        release(&mut h, "sock-b", None);
        assert!(h.watches.is_empty(), "hết người xem thì dừng theo dõi");
        assert!(h.joined.is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn disconnect_releases_every_room_of_that_socket_only() {
        let a = temp_dir("disc-a");
        let b = temp_dir("disc-b");
        let (ra, rb) = (room_key_in(None, &a), room_key_in(None, &b));
        let mut h = Hub::default();
        subscribe(&mut h, &ra, &a, "sock-1").unwrap();
        subscribe(&mut h, &rb, &b, "sock-1").unwrap();
        subscribe(&mut h, &rb, &b, "sock-2").unwrap();

        release(&mut h, "sock-1", None);
        assert!(!h.watches.contains_key(&ra), "room không còn ai thì dừng");
        assert!(h.watches.contains_key(&rb), "room còn sock-2 vẫn theo dõi");
        let _ = std::fs::remove_dir_all(&a);
        let _ = std::fs::remove_dir_all(&b);
    }

    #[tokio::test]
    async fn creating_a_file_fires_once_after_debounce() {
        let dir = temp_dir("fire");
        let fired = Arc::new(AtomicUsize::new(0));
        let counter = fired.clone();
        let _watcher = start_watch(&dir, move || {
            counter.fetch_add(1, Ordering::SeqCst);
        })
        .unwrap();

        // Vài lần ghi liên tiếp nằm trong một đợt gom
        for i in 0..3 {
            std::fs::write(dir.join(format!("f{i}.txt")), "x").unwrap();
        }
        for _ in 0..50 {
            if fired.load(Ordering::SeqCst) > 0 {
                break;
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
        tokio::time::sleep(DEBOUNCE + Duration::from_millis(300)).await;
        let count = fired.load(Ordering::SeqCst);
        assert!(count >= 1, "phải có ít nhất một thông báo");
        assert!(
            count <= 3,
            "các sự kiện trong một đợt được gom, không bắn từng cái: {count}"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }
}
