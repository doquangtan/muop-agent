//! Mở phiên chia sẻ màn hình qua `xdg-desktop-portal` (interface ScreenCast).
//!
//! Trên Wayland không có cách nào khác để đọc khung hình màn hình mà không hỏi người dùng.
//! Lần đầu, GNOME hiện hộp thoại "Chia sẻ màn hình"; portal trả về `restore_token` để các lần sau
//! (persist_mode = 2) không hỏi lại.

use futures_util::StreamExt;
use std::collections::HashMap;
use std::os::fd::OwnedFd;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;
use zbus::proxy::SignalStream;
use zbus::zvariant::{ObjectPath, OwnedObjectPath, OwnedValue, Value};
use zbus::{Connection, Proxy};

const PORTAL_DEST: &str = "org.freedesktop.portal.Desktop";
const PORTAL_PATH: &str = "/org/freedesktop/portal/desktop";
const SCREENCAST_IFACE: &str = "org.freedesktop.portal.ScreenCast";
const REQUEST_IFACE: &str = "org.freedesktop.portal.Request";
const SESSION_IFACE: &str = "org.freedesktop.portal.Session";

/// Thời gian tối đa chờ người dùng xác nhận trong hộp thoại của portal
const USER_TIMEOUT: Duration = Duration::from_secs(180);

/// Nguồn: 1 = màn hình (monitor). Cursor: 2 = vẽ con trỏ vào khung hình.
const SOURCE_MONITOR: u32 = 1;
const CURSOR_EMBEDDED: u32 = 2;
/// persist_mode 2: nhớ quyền cho đến khi người dùng thu hồi
const PERSIST_UNTIL_REVOKED: u32 = 2;

type Results = HashMap<String, OwnedValue>;

/// Phiên portal đang mở. Đóng bằng [`PortalSession::close`].
pub struct PortalSession {
    conn: Connection,
    session: OwnedObjectPath,
}

/// Kết quả mở phiên: phiên portal, fd của PipeWire remote và id của node màn hình
pub struct OpenedStream {
    pub session: PortalSession,
    pub fd: OwnedFd,
    pub node_id: u32,
    /// Kích thước màn hình nguồn (pixel), nếu portal báo
    pub source_size: Option<(u32, u32)>,
    /// Token mới do portal trả về (nếu có), dùng cho lần mở sau
    pub restore_token: Option<String>,
}

static TOKEN_COUNTER: AtomicU64 = AtomicU64::new(0);

/// Handle token hợp lệ cho portal (chỉ gồm chữ và số)
fn new_token(prefix: &str) -> String {
    let n = TOKEN_COUNTER.fetch_add(1, Ordering::Relaxed);
    format!("{prefix}{}x{n}", std::process::id())
}

/// Tên người gửi (":1.42") đổi thành "1_42" theo quy tắc đường dẫn request của portal
fn sanitize_sender(unique: &str) -> String {
    unique.trim_start_matches(':').replace('.', "_")
}

fn err<E: std::fmt::Display>(ctx: &'static str) -> impl FnOnce(E) -> String {
    move |e| format!("{ctx}: {e}")
}

/// Đọc `Response` của một request portal: (code, results). Code 0 = thành công.
async fn read_response(stream: &mut SignalStream<'_>) -> Result<Results, String> {
    let msg = tokio::time::timeout(USER_TIMEOUT, stream.next())
        .await
        .map_err(|_| "Hết thời gian chờ xác nhận chia sẻ màn hình".to_string())?
        .ok_or_else(|| "Portal đóng kênh phản hồi".to_string())?;
    let (code, results): (u32, Results) = msg
        .body()
        .deserialize()
        .map_err(err("Không đọc được phản hồi của portal"))?;
    match code {
        0 => Ok(results),
        1 => Err("Đã hủy chia sẻ màn hình".to_string()),
        _ => Err("Portal từ chối yêu cầu chia sẻ màn hình".to_string()),
    }
}

/// Proxy của request portal, tạo trước khi gọi để không bỏ lỡ `Response`
async fn request_proxy<'c>(
    conn: &'c Connection,
    sender: &str,
    handle_token: &str,
) -> Result<Proxy<'c>, String> {
    let path = format!(
        "{PORTAL_PATH}/request/{}/{handle_token}",
        sanitize_sender(sender)
    );
    Proxy::new(conn, PORTAL_DEST, path, REQUEST_IFACE)
        .await
        .map_err(err("Không tạo được request portal"))
}

fn str_value(v: &OwnedValue) -> Option<String> {
    String::try_from(v.try_clone().ok()?).ok()
}

/// `session_handle` là kiểu `s` (chuỗi) trong spec portal, không phải `o` (object path)
fn session_path(v: &OwnedValue) -> Result<OwnedObjectPath, String> {
    let text = String::try_from(v.try_clone().map_err(err("session_handle"))?)
        .map_err(err("session_handle"))?;
    OwnedObjectPath::try_from(text).map_err(err("session_handle"))
}

/// Mục đầu của `streams` (kiểu `a(ua{sv})`): (node id, thuộc tính)
fn first_stream(v: &OwnedValue) -> Result<(u32, Results), String> {
    let streams: Vec<(u32, Results)> = v
        .try_clone()
        .map_err(err("streams"))?
        .try_into()
        .map_err(err("streams"))?;
    streams
        .into_iter()
        .next()
        .ok_or_else(|| "Không có màn hình nào được chọn".to_string())
}

/// Kích thước màn hình trong thuộc tính `size` (kiểu `(ii)`)
fn stream_size(props: &Results) -> Option<(u32, u32)> {
    let (w, h): (i32, i32) = props.get("size")?.try_clone().ok()?.try_into().ok()?;
    (w > 0 && h > 0).then_some((w as u32, h as u32))
}

/// Mở phiên ScreenCast: chọn màn hình, bắt đầu, rồi lấy PipeWire remote
pub async fn open(restore_token: Option<String>) -> Result<OpenedStream, String> {
    if !crate::infra::platform::IS_LINUX {
        return Err("Quay màn hình chỉ hỗ trợ Linux (xdg-desktop-portal và PipeWire)".into());
    }
    let conn = Connection::session()
        .await
        .map_err(err("Không kết nối được session D-Bus"))?;
    let sender = conn
        .unique_name()
        .map(|n| n.to_string())
        .ok_or("Session D-Bus chưa có tên")?;
    let portal = Proxy::new(&conn, PORTAL_DEST, PORTAL_PATH, SCREENCAST_IFACE)
        .await
        .map_err(err("Không tìm thấy xdg-desktop-portal ScreenCast"))?;

    // 1. CreateSession
    let create_token = new_token("create");
    let create = request_proxy(&conn, &sender, &create_token).await?;
    let mut create_stream = create
        .receive_signal("Response")
        .await
        .map_err(err("Không lắng nghe được portal"))?;
    let mut opts: HashMap<&str, Value> = HashMap::new();
    let session_token = new_token("session");
    opts.insert("handle_token", Value::from(create_token.as_str()));
    opts.insert("session_handle_token", Value::from(session_token.as_str()));
    portal
        .call_method("CreateSession", &(opts))
        .await
        .map_err(err("CreateSession thất bại"))?;
    let created = read_response(&mut create_stream).await?;
    drop(create_stream);
    let session = session_path(
        created
            .get("session_handle")
            .ok_or("Portal không trả về session_handle")?,
    )?;
    let session_ref: ObjectPath<'_> = session.as_ref();

    // 2. SelectSources
    let select_token = new_token("select");
    let select = request_proxy(&conn, &sender, &select_token).await?;
    let mut select_stream = select
        .receive_signal("Response")
        .await
        .map_err(err("Không lắng nghe được portal"))?;
    let mut sel: HashMap<&str, Value> = HashMap::new();
    sel.insert("handle_token", Value::from(select_token.as_str()));
    sel.insert("types", Value::from(SOURCE_MONITOR));
    sel.insert("multiple", Value::from(false));
    sel.insert("cursor_mode", Value::from(CURSOR_EMBEDDED));
    sel.insert("persist_mode", Value::from(PERSIST_UNTIL_REVOKED));
    if let Some(tok) = restore_token.as_deref().filter(|t| !t.is_empty()) {
        sel.insert("restore_token", Value::from(tok));
    }
    portal
        .call_method("SelectSources", &(session_ref.clone(), sel))
        .await
        .map_err(err("SelectSources thất bại"))?;
    read_response(&mut select_stream).await?;
    drop(select_stream);

    // 3. Start: người dùng xác nhận ở đây (lần đầu)
    let start_token = new_token("start");
    let start = request_proxy(&conn, &sender, &start_token).await?;
    let mut start_stream = start
        .receive_signal("Response")
        .await
        .map_err(err("Không lắng nghe được portal"))?;
    let mut start_opts: HashMap<&str, Value> = HashMap::new();
    start_opts.insert("handle_token", Value::from(start_token.as_str()));
    portal
        .call_method("Start", &(session_ref.clone(), "", start_opts))
        .await
        .map_err(err("Start thất bại"))?;
    let started = read_response(&mut start_stream).await?;
    drop(start_stream);

    let (node_id, props) = first_stream(
        started
            .get("streams")
            .ok_or("Portal không trả về danh sách màn hình")?,
    )?;
    let source_size = stream_size(&props);
    let new_restore = started.get("restore_token").and_then(str_value);

    // 4. OpenPipeWireRemote: fd để GStreamer đọc khung hình
    let reply = portal
        .call_method(
            "OpenPipeWireRemote",
            &(session_ref.clone(), HashMap::<&str, Value>::new()),
        )
        .await
        .map_err(err("OpenPipeWireRemote thất bại"))?;
    let fd: zbus::zvariant::OwnedFd = reply
        .body()
        .deserialize()
        .map_err(err("Không nhận được fd PipeWire"))?;
    let fd: OwnedFd = fd.into();

    Ok(OpenedStream {
        session: PortalSession { conn, session },
        fd,
        node_id,
        source_size,
        restore_token: new_restore,
    })
}

impl PortalSession {
    /// Đóng phiên ScreenCast để portal dừng chia sẻ và ẩn chỉ báo
    pub async fn close(self) {
        if let Ok(proxy) = Proxy::new(
            &self.conn,
            PORTAL_DEST,
            self.session.as_str(),
            SESSION_IFACE,
        )
        .await
        {
            let _ = proxy.call_method("Close", &()).await;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use zbus::zvariant::{Array, Structure};

    #[test]
    fn session_handle_is_a_string() {
        let v = OwnedValue::try_from(Value::from(
            "/org/freedesktop/portal/desktop/session/1_2/abc",
        ))
        .unwrap();
        let path = session_path(&v).unwrap();
        assert_eq!(
            path.as_str(),
            "/org/freedesktop/portal/desktop/session/1_2/abc"
        );
    }

    #[test]
    fn first_stream_reads_node_and_size() {
        let mut props: HashMap<String, Value> = HashMap::new();
        props.insert("size".into(), Value::from((1920i32, 1080i32)));
        let entry = Value::Structure(Structure::from((77u32, props)));
        let array = Value::Array(Array::from(vec![entry]));
        let v = OwnedValue::try_from(array).unwrap();
        let (node, props) = first_stream(&v).unwrap();
        assert_eq!(node, 77);
        assert_eq!(stream_size(&props), Some((1920, 1080)));
    }
}
