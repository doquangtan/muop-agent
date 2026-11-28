//! Đẩy trạng thái phiên Docker tới màn hình đang xem, thay cho việc app tự quét định kỳ.
//!
//! - Room `docker-session:<sessionId>`. Socket gọi `docker:session:watch` để vào room, và
//!   `docker:session:unwatch` (hoặc ngắt kết nối) để rời.
//! - Khi có người xem, server quét phiên mỗi `SCAN_EVERY` và phát `docker:session:update`. Payload gồm
//!   `sessionId`, `ok`, `error`, `session` (cùng dạng với REST scan) và `ended`.
//! - Hết người xem thì vòng quét dừng. Phiên đã kết thúc thì phát `ended: true` rồi dừng.
//! - Mỗi phiên có tối đa một vòng quét. `gen` phân biệt các vòng: vòng cũ đã dừng không quét thêm nếu phiên
//!   được xem lại trước khi vòng cũ kịp thoát.

use serde::Deserialize;
use serde_json::json;
use socketioxide::{extract::SocketRef, SocketIo};
use std::collections::{HashMap, HashSet};
use std::sync::{Mutex, MutexGuard, OnceLock};
use std::time::Duration;

/// Tiền tố room của một phiên Docker
pub const ROOM_PREFIX: &str = "docker-session:";
/// Sự kiện gửi tới room mỗi lần quét xong
pub const UPDATE_EVENT: &str = "docker:session:update";
/// Khoảng giữa hai lần quét khi có người xem (trùng chu kỳ app dùng trước đây)
const SCAN_EVERY: Duration = Duration::from_secs(10);
const ENDED_MESSAGE: &str = "Phiên Docker đã kết thúc";

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WatchRequest {
    pub session_id: String,
}

#[derive(Default)]
struct Watch {
    /// Số thứ tự của vòng quét đang phục vụ phiên này
    gen: u64,
    /// Id socket đang xem phiên
    subscribers: HashSet<String>,
}

#[derive(Default)]
struct Hub {
    next_gen: u64,
    /// id phiên → người xem và vòng quét
    watches: HashMap<String, Watch>,
    /// id socket → các phiên socket đó đang xem
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

pub fn room(session_id: &str) -> String {
    format!("{ROOM_PREFIX}{session_id}")
}

/// Ghi nhận socket xem phiên. Trả về số thứ tự vòng quét mới nếu đây là người xem đầu tiên
/// (khi đó phải khởi động vòng quét); `None` nếu vòng đang chạy.
fn subscribe(h: &mut Hub, session_id: &str, sid: &str) -> Option<u64> {
    h.joined
        .entry(sid.to_string())
        .or_default()
        .insert(session_id.to_string());
    if let Some(watch) = h.watches.get_mut(session_id) {
        watch.subscribers.insert(sid.to_string());
        return None;
    }
    h.next_gen += 1;
    let gen = h.next_gen;
    let subscribers = HashSet::from([sid.to_string()]);
    h.watches
        .insert(session_id.to_string(), Watch { gen, subscribers });
    Some(gen)
}

/// Bỏ một socket khỏi phiên. Phiên không còn người xem thì bỏ luôn vòng quét (vòng sẽ tự dừng).
fn release(h: &mut Hub, session_id: &str, sid: &str) {
    if let Some(set) = h.joined.get_mut(sid) {
        set.remove(session_id);
        if set.is_empty() {
            h.joined.remove(sid);
        }
    }
    let empty = match h.watches.get_mut(session_id) {
        Some(watch) => {
            watch.subscribers.remove(sid);
            watch.subscribers.is_empty()
        }
        None => false,
    };
    if empty {
        h.watches.remove(session_id);
    }
}

/// Vòng quét `gen` còn cần chạy: phiên còn người xem và chưa bị thay bằng vòng khác
fn still_watched(session_id: &str, gen: u64) -> bool {
    matches!(
        hub().watches.get(session_id),
        Some(w) if w.gen == gen && !w.subscribers.is_empty()
    )
}

/// Vòng quét đã kết thúc (phiên không còn): gỡ mục của phiên nếu vẫn là vòng này
fn finish(session_id: &str, gen: u64) {
    let mut h = hub();
    if h.watches.get(session_id).is_some_and(|w| w.gen == gen) {
        h.watches.remove(session_id);
    }
}

fn emit(session_id: &str, ended: bool, ok: bool, error: String, session: impl serde::Serialize) {
    let Some(io) = IO.get() else {
        return;
    };
    let Some(ns) = io.of("/") else {
        return;
    };
    let payload = json!({
        "sessionId": session_id,
        "ended": ended,
        "ok": ok,
        "error": error,
        "session": session,
    });
    let _ = ns.to(room(session_id)).emit(UPDATE_EVENT, &payload);
}

fn spawn_loop(session_id: String, gen: u64) {
    tokio::spawn(async move {
        loop {
            tokio::time::sleep(SCAN_EVERY).await;
            if !still_watched(&session_id, gen) {
                break;
            }
            match crate::docker::sessions::scan_session(&session_id).await {
                Some(session) => {
                    let ok = session.error.is_empty();
                    let error = session.error.clone();
                    emit(&session_id, false, ok, error, Some(session));
                }
                None => {
                    emit(
                        &session_id,
                        true,
                        false,
                        ENDED_MESSAGE.to_string(),
                        None::<()>,
                    );
                    finish(&session_id, gen);
                    break;
                }
            }
        }
    });
}

/// `docker:session:watch`: socket vào room của phiên và bắt đầu quét định kỳ nếu chưa có ai xem
pub fn watch(socket: &SocketRef, session_id: &str) {
    let _ = socket.join(room(session_id));
    let sid = socket.id.to_string();
    if let Some(gen) = subscribe(&mut hub(), session_id, &sid) {
        spawn_loop(session_id.to_string(), gen);
    }
}

/// `docker:session:unwatch`: socket rời phiên
pub fn unwatch(socket: &SocketRef, session_id: &str) {
    let _ = socket.leave(room(session_id));
    release(&mut hub(), session_id, &socket.id.to_string());
}

/// Socket ngắt kết nối: gỡ khỏi mọi phiên đang xem
pub fn release_socket(sid: &str) {
    let mut h = hub();
    let sessions: Vec<String> = h
        .joined
        .get(sid)
        .map(|set| set.iter().cloned().collect())
        .unwrap_or_default();
    for session_id in sessions {
        release(&mut h, &session_id, sid);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn first_viewer_starts_loop_and_last_one_out_drops_it() {
        let mut h = Hub::default();
        let gen =
            subscribe(&mut h, "ds-1", "sock-a").expect("người xem đầu tiên bắt đầu vòng quét");
        assert!(
            subscribe(&mut h, "ds-1", "sock-b").is_none(),
            "vòng đang chạy thì không bắt đầu thêm"
        );

        release(&mut h, "ds-1", "sock-a");
        assert!(
            h.watches.contains_key("ds-1"),
            "còn một người xem thì vẫn theo dõi"
        );

        release(&mut h, "ds-1", "sock-b");
        assert!(h.watches.is_empty(), "hết người xem thì bỏ vòng quét");
        assert!(h.joined.is_empty());
        assert!(!still_watched("ds-1", gen));
    }

    #[test]
    fn reopening_after_leaving_uses_a_new_generation() {
        let mut h = Hub::default();
        let first = subscribe(&mut h, "ds-1", "sock-a").unwrap();
        release(&mut h, "ds-1", "sock-a");
        let second = subscribe(&mut h, "ds-1", "sock-a").unwrap();
        assert_ne!(
            first, second,
            "vòng cũ không được quét tiếp khi phiên được xem lại"
        );
    }

    #[test]
    fn disconnect_releases_only_that_socket_sessions() {
        let mut h = Hub::default();
        subscribe(&mut h, "ds-1", "sock-1");
        subscribe(&mut h, "ds-2", "sock-1");
        subscribe(&mut h, "ds-2", "sock-2");
        let sessions: Vec<String> = h.joined["sock-1"].iter().cloned().collect();
        for s in sessions {
            release(&mut h, &s, "sock-1");
        }
        assert!(!h.watches.contains_key("ds-1"));
        assert!(h.watches.contains_key("ds-2"), "ds-2 còn sock-2 đang xem");
    }

    #[test]
    fn room_name_is_prefixed_by_session_id() {
        assert_eq!(room("abc"), "docker-session:abc");
    }
}
