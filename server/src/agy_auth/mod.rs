//! Đăng nhập / đăng xuất tài khoản Antigravity (agy).
//!
//! - Đăng nhập: server mở terminal SSH tới máy này chạy `agy` ([`open_login_terminal`]). Người dùng tự
//!   đăng nhập trong terminal đó (chọn Google OAuth, mở link, dán mã). Server theo dõi: hub báo đã có
//!   token thì thành công; agy thoát mà chưa có token thì thất bại ([`watch_login`]).
//! - Đăng xuất: gọi RPC `AuthLogout` của hub do server mở (`agy_account::logout_via_hub`), chờ `agy models` báo chưa đăng nhập.
//! - Trạng thái giữ trong [`CURRENT`] và đẩy cho client qua Socket.IO `agy:auth:update` mỗi khi đổi
//!   (xem [`socket`]). Client không cần hỏi lại theo chu kỳ.
//!
//! Các hàm trong module này chặn luồng (curl, SSH, chờ): API phải gọi qua `spawn_blocking`.

mod flow;
pub(crate) mod host;
pub mod socket;
pub(crate) mod tui;

use crate::models::{AccountsStatus, AgyAuthEvent};
use base64::Engine;
use socketioxide::SocketIo;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, MutexGuard, OnceLock};
use std::thread;
use std::time::{Duration, Instant};

/// Độ dài tối đa của mã xác thực (hoặc URL callback) người dùng dán vào
const MAX_CODE_LEN: usize = 4096;
/// Thời gian tối đa cho một lần đăng nhập trong terminal
const LOGIN_TTL: Duration = Duration::from_secs(20 * 60);
/// Khoảng cách kiểm tra trạng thái khi terminal đăng nhập đang chạy
const LOGIN_POLL: Duration = Duration::from_secs(1);
/// Số lần tối đa tự chọn Google OAuth ở menu đăng nhập, và khoảng cách giữa các lần
const PICK_MAX: u32 = 3;
const PICK_GAP: Duration = Duration::from_secs(3);
/// Khoảng cách kiểm tra đăng nhập nền (không cần client hỏi): báo khi đăng nhập đổi.
/// Mỗi lần chạy `agy models` (một tiến trình, có gọi mạng) nên để thưa hơn kiểm tra qua hub.
const STATUS_WATCH_EVERY: Duration = Duration::from_secs(30);

const EXITED_MSG: &str =
    "agy đã thoát trước khi đăng nhập. Chưa đăng nhập: bấm Đăng nhập bằng Google để thử lại.";
const AGY_EXITED_AFTER_TOKEN_MSG: &str = "agy đã thoát sau khi nhận mã mà chưa đăng nhập được.";
const EXPIRED_MSG: &str = "Phiên đăng nhập đã hết hạn. Bấm Đăng nhập bằng Google để thử lại.";

/// Socket.IO để phát `agy:auth:update`. Gắn một lần khi khởi tạo socket.
static IO: OnceLock<SocketIo> = OnceLock::new();
/// App vừa đăng xuất agy. Vòng kiểm tra nền không tự đăng nhập lại từ hub (hub có thể còn trạng thái cũ)
/// cho tới khi đăng nhập lại qua terminal.
static SIGNED_OUT_BY_APP: AtomicBool = AtomicBool::new(false);
/// Trạng thái gần nhất, client kết nối sau vẫn nhận được ngay
static CURRENT: Mutex<Option<AgyAuthEvent>> = Mutex::new(None);
/// Nội dung (JSON) của event `agy:auth:update` đã phát gần nhất. Tách khỏi `CURRENT` vì `query` cũng ghi
/// `CURRENT` mà không phát, nên so với `CURRENT` sẽ bỏ sót thay đổi.
static LAST_EMITTED: Mutex<Option<String>> = Mutex::new(None);
/// Terminal SSH đang chạy `agy` để đăng nhập (hoặc đồng ý điều khoản): (id phiên, id máy đã lưu)
static LOGIN_TERMINAL: Mutex<Option<(String, i64)>> = Mutex::new(None);
/// URL Google OAuth lấy từ đầu ra của terminal đăng nhập (để client hiện và sao chép đủ link)
static LOGIN_URL: Mutex<String> = Mutex::new(String::new());
/// Bước hiện tại của luồng đăng nhập (xem `flow.rs`): waiting_link, awaiting_token, verifying, awaiting_terms
static LOGIN_STAGE: Mutex<String> = Mutex::new(String::new());
/// Độ dài chữ terminal lúc gửi mã (None nếu chưa gửi). Chỉ xét chữ mới sau mốc này.
static SUBMITTED_AT: Mutex<Option<usize>> = Mutex::new(None);

/// Kết luận của một lần đăng nhập trong terminal
enum Outcome {
    LoggedIn,
    Exited,
    Expired,
    /// agy in lỗi xác thực (nội dung lỗi)
    Failed(String),
}

/// Gắn Socket.IO để phát event. Gọi một lần khi khởi tạo socket.
pub fn init(io: SocketIo) {
    let _ = IO.set(io);
    crate::agy_account::start();
    // TUI của lần chạy trước (server đã thoát) còn sót thì tắt đi
    host::cleanup_stale();
    // Kiểm tra đăng nhập nền: client không cần hỏi mới biết agy đã đăng nhập (màn Tài khoản, wizard)
    thread::spawn(|| loop {
        thread::sleep(STATUS_WATCH_EVERY);
        watch_status();
    });
}

/// Trạng thái gần nhất đã biết (idle nếu chưa có gì xảy ra)
pub fn current() -> AgyAuthEvent {
    let stored = CURRENT.lock().ok().and_then(|g| g.clone());
    stored.unwrap_or_else(|| make("idle", false, ""))
}

/// Dựng trạng thái. Khi đang có terminal đăng nhập, kèm id phiên và id máy để client mở đúng khung.
fn make(phase: &str, logged_in: bool, error: &str) -> AgyAuthEvent {
    let (ssh_session_id, ssh_host_id) = terminal_session().unwrap_or_default();
    let login_url = login_url_slot().clone();
    let login_stage = login_stage_slot().clone();
    AgyAuthEvent {
        ok: !matches!(phase, "failed" | "expired"),
        phase: phase.to_string(),
        logged_in,
        login_url,
        login_stage,
        error: error.to_string(),
        ssh_session_id,
        ssh_host_id,
    }
}

fn login_url_slot() -> MutexGuard<'static, String> {
    LOGIN_URL.lock().unwrap_or_else(|e| e.into_inner())
}

fn login_stage_slot() -> MutexGuard<'static, String> {
    LOGIN_STAGE.lock().unwrap_or_else(|e| e.into_inner())
}

fn submitted_slot() -> MutexGuard<'static, Option<usize>> {
    SUBMITTED_AT.lock().unwrap_or_else(|e| e.into_inner())
}

/// Đặt lại mọi trạng thái của một lần đăng nhập
fn reset_login_state() {
    login_url_slot().clear();
    login_stage_slot().clear();
    *submitted_slot() = None;
}

/// Đầu ra thô của terminal đăng nhập (kể cả phần đã in từ trước), None nếu phiên đã đóng
fn terminal_output(sid: &str) -> Option<Vec<u8>> {
    crate::ssh::terminal::attach(sid)
        .ok()
        .map(|(_, bytes)| bytes)
}

fn terminal_slot() -> MutexGuard<'static, Option<(String, i64)>> {
    LOGIN_TERMINAL.lock().unwrap_or_else(|e| e.into_inner())
}

/// Phiên terminal đăng nhập đang được server giữ (có thể đã thoát, xem [`login_active`])
fn terminal_session() -> Option<(String, i64)> {
    terminal_slot().clone()
}

/// Terminal SSH còn sống (agy chưa thoát)
fn terminal_alive(sid: &str) -> bool {
    crate::ssh::terminal::list()
        .iter()
        .any(|s| s.session_id == sid)
}

/// Đang có terminal đăng nhập còn sống. Trong lúc đó host không được mở thêm agy:
/// hub do `discover_hub` chọn là một hub bất kỳ, nên hai agy cùng chạy sẽ cho trạng thái sai.
pub(super) fn login_active() -> bool {
    terminal_session().is_some_and(|(sid, _)| terminal_alive(&sid))
}

/// Mở terminal SSH tới máy này chạy `agy` để người dùng tự đăng nhập (hoặc đồng ý điều khoản),
/// rồi theo dõi tới khi đăng nhập xong hoặc agy thoát. Đã có terminal còn sống thì dùng lại.
pub(crate) fn open_login_terminal() -> Result<(String, i64), String> {
    if let Some((sid, host_id)) = terminal_session() {
        if terminal_alive(&sid) {
            return Ok((sid, host_id));
        }
    }
    let (sid, host_id) = crate::setup::ssh::open_agy_terminal()?;
    *terminal_slot() = Some((sid.clone(), host_id));
    reset_login_state();
    *login_stage_slot() = "waiting_link".to_string();
    publish("login_terminal", false, "");
    let started = Instant::now();
    let watch_sid = sid.clone();
    thread::spawn(move || watch_login(&watch_sid, started));
    Ok((sid, host_id))
}

/// Theo dõi terminal đăng nhập: hub báo đã có token thì thành công; agy thoát thì kiểm tra token rồi kết luận.
fn watch_login(sid: &str, started: Instant) {
    let mut picks: u32 = 0;
    let mut last_pick: Option<Instant> = None;
    loop {
        thread::sleep(LOGIN_POLL);
        if !is_login_session(sid) {
            // Đã hủy, hoặc đã được thay bằng phiên khác
            return;
        }
        // Đọc đầu ra trước khi kiểm tra phiên: khi agy thoát, phiên bị gỡ và đầu ra không còn đọc được
        let Some(raw) = terminal_output(sid) else {
            // Phiên đã đóng (agy đã thoát). agy có thể thoát ngay sau khi đã xác thực, trước khi vẽ màn chat
            // (đã gặp: crash trong initAuth sau "Auth succeeded"). Token đã có trong nguồn lưu, nên hỏi
            // `agy models` (cùng nguồn mà terminal dùng) trước khi kết luận thất bại.
            if matches!(signed_in_by_models(), Ok(true)) {
                return end_login(sid, Outcome::LoggedIn);
            }
            let outcome = if submitted_slot().is_some() {
                Outcome::Failed(AGY_EXITED_AFTER_TOKEN_MSG.to_string())
            } else {
                Outcome::Exited
            };
            return end_login(sid, outcome);
        };
        let text = tui::strip_ansi(&raw);
        // Link chỉ có khi đang hiện trên màn hình: màn khác thay link thì xóa (client ẩn nút mở link và ô mã)
        let screen_url = tui::link_on_screen(&raw).unwrap_or_default();
        if set_login_url(&screen_url) && is_login_session(sid) {
            publish("login_terminal", false, "");
        }
        let submitted = *submitted_slot();
        // Đang ở menu đăng nhập, chưa có link: chọn Google OAuth (Enter, mục đang trỏ là mục đầu) thay người dùng.
        // Tối đa PICK_MAX lần, mỗi lần cách PICK_GAP, để không nhấn lặp khi menu vẫn còn sau một lần nhấn.
        if screen_url.is_empty()
            && submitted.is_none()
            && tui::google_menu_on_screen(&text)
            && picks < PICK_MAX
            && last_pick.is_none_or(|t| t.elapsed() >= PICK_GAP)
        {
            pick_google_oauth(sid);
            picks += 1;
            last_pick = Some(Instant::now());
        }
        // Tính trước: guard của `login_url_slot()` trong scrutinee của `match` sống tới hết `match`,
        // mà nhánh `Failed`/`Done` gọi `end_login` → `reset_login_state` lock lại cùng mutex → treo vĩnh viễn.
        let has_url = !login_url_slot().is_empty();
        match flow::assess(&text, has_url, submitted) {
            flow::Stage::Failed(message) => return end_login(sid, Outcome::Failed(message)),
            flow::Stage::Done => {
                // Cho agy ghi token vào keyring trước khi đóng terminal
                thread::sleep(Duration::from_secs(1));
                return end_login(sid, Outcome::LoggedIn);
            }
            stage => set_stage(stage.name()),
        }
        if started.elapsed() >= LOGIN_TTL {
            return end_login(sid, Outcome::Expired);
        }
    }
}

/// Nhấn Enter để chọn Google OAuth ở menu đăng nhập. Lỗi ghi thì để vòng sau thử lại.
fn pick_google_oauth(sid: &str) {
    let data = base64::engine::general_purpose::STANDARD.encode("\r");
    let _ = crate::ssh::terminal::write_input(sid, &data);
}

/// Đặt link đang hiện trên màn hình. Trả về true nếu đổi.
fn set_login_url(url: &str) -> bool {
    let mut slot = login_url_slot();
    if slot.as_str() == url {
        false
    } else {
        *slot = url.to_string();
        true
    }
}

/// Đổi bước đăng nhập và phát `login_terminal` (chỉ khi có thay đổi)
fn set_stage(stage: &str) {
    let changed = {
        let mut slot = login_stage_slot();
        if slot.as_str() == stage {
            false
        } else {
            *slot = stage.to_string();
            true
        }
    };
    if changed && terminal_session().is_some() {
        publish("login_terminal", false, "");
    }
}

fn is_login_session(sid: &str) -> bool {
    terminal_slot().as_ref().is_some_and(|(cur, _)| cur == sid)
}

/// Bỏ phiên đăng nhập nếu vẫn là phiên `sid`. Trả về false nếu phiên đã bị thay hoặc hủy.
fn take_login(sid: &str) -> bool {
    let mut slot = terminal_slot();
    if slot.as_ref().is_some_and(|(cur, _)| cur == sid) {
        *slot = None;
        reset_login_state();
        true
    } else {
        false
    }
}

/// Kết thúc một lần đăng nhập: đóng terminal (nếu còn) và phát kết quả
fn end_login(sid: &str, outcome: Outcome) {
    if !take_login(sid) {
        return;
    }
    crate::ssh::terminal::close(sid);
    match outcome {
        Outcome::LoggedIn => {
            SIGNED_OUT_BY_APP.store(false, Ordering::SeqCst);
            publish("logged_in", true, "");
            sync_quotas();
        }
        Outcome::Exited => publish("failed", false, EXITED_MSG),
        Outcome::Expired => publish("expired", false, EXPIRED_MSG),
        Outcome::Failed(message) => publish(
            "failed",
            false,
            &format!("Xác thực thất bại: {message}. Bấm Đăng nhập bằng Google để thử lại."),
        ),
    }
}

/// Gửi mã xác thực (hoặc URL callback) người dùng dán vào app vào terminal đăng nhập đang chạy agy.
/// Trả về trạng thái hiện tại. Lỗi nhập (mã trống, có khoảng trắng, không có terminal...) nằm trong
/// `error` với `ok = false` và không đổi phase: terminal vẫn sống để nhập lại. Kết quả xác thực đến qua watcher.
pub fn submit_code(raw: &str) -> AgyAuthEvent {
    match submit_inner(raw) {
        Ok(()) => current(),
        Err(e) => {
            let mut ev = current();
            ev.ok = false;
            ev.error = e;
            ev
        }
    }
}

fn submit_inner(raw: &str) -> Result<(), String> {
    let code = raw.trim();
    if code.is_empty() {
        return Err("Thiếu mã xác thực.".into());
    }
    if code.len() > MAX_CODE_LEN {
        return Err("Mã xác thực quá dài.".into());
    }
    if code.chars().any(|c| c.is_control() || c.is_whitespace()) {
        return Err("Mã xác thực không được chứa khoảng trắng hoặc ký tự điều khiển.".into());
    }
    let (sid, _) = terminal_session()
        .filter(|(sid, _)| terminal_alive(sid))
        .ok_or("Chưa có terminal đăng nhập đang mở. Bấm Đăng nhập bằng Google trước.")?;
    if login_stage_slot().as_str() != "awaiting_token" {
        return Err("Chưa đến bước nhập mã: hãy đợi agy hiển thị link đăng nhập.".into());
    }
    // Mốc: chữ đã có trước khi gửi, để sau này chỉ xét chữ agy in ra sau mã
    let mark = terminal_output(&sid)
        .map(|raw| tui::strip_ansi(&raw).len())
        .unwrap_or(0);
    // agy đọc dòng từ PTY: mã kèm "\r" là một lần Enter
    let data = base64::engine::general_purpose::STANDARD.encode(format!("{code}\r"));
    crate::ssh::terminal::write_input(&sid, &data)?;
    *submitted_slot() = Some(mark);
    set_stage("verifying");
    Ok(())
}

/// Hủy đăng nhập đang chờ: đóng terminal (agy thoát). Không có thì không làm gì.
pub fn cancel_login() {
    let taken = terminal_slot().take();
    reset_login_state();
    if let Some((sid, _)) = taken {
        crate::ssh::terminal::close(&sid);
        publish("cancelled", false, "");
    }
}

/// Ghi trạng thái gần nhất mà không phát event
fn store(ev: &AgyAuthEvent) {
    if let Ok(mut cur) = CURRENT.lock() {
        *cur = Some(ev.clone());
    }
}

/// Đổi trạng thái và phát `agy:auth:update` cho mọi client đang kết nối (luôn phát).
/// Các thay đổi trong luồng đăng nhập (link hiện/ẩn, bước, kết quả) dùng hàm này.
pub(crate) fn publish(phase: &str, logged_in: bool, error: &str) {
    emit(&make(phase, logged_in, error));
}

/// Như [`publish`] nhưng chỉ phát khi nội dung khác event đã phát gần nhất. Trả về true nếu đã phát.
/// Dùng cho kiểm tra định kỳ (`agy:auth:check`, vòng nền) để không gửi lặp cùng một trạng thái.
fn publish_if_changed(phase: &str, logged_in: bool, error: &str) -> bool {
    let ev = make(phase, logged_in, error);
    let json = serde_json::to_string(&ev).unwrap_or_default();
    let changed = LAST_EMITTED
        .lock()
        .map(|last| last.as_deref() != Some(json.as_str()))
        .unwrap_or(true);
    if changed {
        emit(&ev);
    } else {
        store(&ev);
    }
    changed
}

/// Ghi trạng thái, nhớ nội dung đã phát và gửi cho mọi client
fn emit(ev: &AgyAuthEvent) {
    emit_quiet(ev);
    if ev.phase == "logged_in" || ev.phase == "logged_out" {
        // Tài khoản đổi: watcher của agy_account xóa hoặc lấy lại thông tin, rồi đẩy model và quota mới
        crate::agy_account::on_login_changed(ev.logged_in);
        push_models_after_account_change();
    }
}

/// Phát `agy:auth:update` không kéo theo việc đổi tài khoản (dùng khi chỉ thông tin tài khoản đổi)
fn emit_quiet(ev: &AgyAuthEvent) {
    store(ev);
    if let Ok(mut last) = LAST_EMITTED.lock() {
        *last = serde_json::to_string(ev).ok();
    }
    if let Some(io) = IO.get() {
        if let Some(ns) = io.of("/") {
            let _ = ns.emit("agy:auth:update", ev);
        }
    }
}

/// Phát lại trạng thái đã đăng nhập để client tải lại thông tin tài khoản (email, gói)
pub(crate) fn republish_logged_in() {
    let ev = current();
    if ev.logged_in {
        emit_quiet(&ev);
    }
}

/// Đẩy quota agy hiện tại cho mọi client (`quotas:update`), không mở host
pub(crate) fn push_quotas() {
    let Some(io) = IO.get() else { return };
    let snapshot = crate::scanner::quota_snapshot(false);
    if let (Ok(val), Some(ns)) = (serde_json::to_value(&snapshot), io.of("/")) {
        let _ = ns.emit("quotas:update", &val);
    }
}

/// Sau khi đăng nhập hoặc đăng xuất agy, tài khoản (và danh sách model) có thể đã đổi. Lấy lại `agy models`
/// rồi phát `meta:update` cho mọi client. Nếu không, app chỉ nhận meta lúc kết nối và phải thoát mở lại mới thấy model mới.
fn push_models_after_account_change() {
    thread::spawn(|| {
        crate::scanner::reload_agy_models();
        let sessions =
            crate::scanner::scan_all_sessions(&std::collections::HashMap::new(), None, 500);
        let meta = crate::scanner::build_meta(&sessions);
        let Ok(val) = serde_json::to_value(&meta) else {
            return;
        };
        if let Some(io) = IO.get() {
            if let Some(ns) = io.of("/") {
                let _ = ns.emit("meta:update", &val);
            }
        }
    });
}

/// Kiểm tra đăng nhập nền (vòng lặp trong [`init`]): phát `agy:auth:update` khi `agy models` cho thấy đã
/// đăng nhập mà server còn ghi là chưa (đăng nhập ở agy khác). Chỉ nâng lên `logged_in`, không hạ xuống:
/// watcher của terminal đăng nhập quản lý việc đăng xuất. Bỏ qua khi có terminal đăng nhập, khi đã đăng nhập,
/// hoặc khi app vừa đăng xuất (tránh tự đăng nhập lại).
fn watch_status() {
    if login_active() || current().logged_in || SIGNED_OUT_BY_APP.load(Ordering::SeqCst) {
        return;
    }
    if !matches!(signed_in_by_models(), Ok(true)) {
        return;
    }
    if publish_if_changed("logged_in", true, "") {
        // Vừa đăng nhập: tải lại quota của tài khoản mới
        sync_quotas();
    }
}

/// Đã đăng nhập agy hay chưa, theo `agy models` (cùng nguồn token mà terminal đăng nhập dùng).
/// Không hỏi hub: hub có thể giữ trạng thái cũ (đã gặp: `authResult: {}` khi tài khoản vẫn đăng nhập).
pub fn status() -> Result<bool, String> {
    signed_in_by_models()
}

/// Thời gian tối đa chờ `agy models` khi xác nhận đăng nhập
const MODELS_TIMEOUT: Duration = Duration::from_secs(20);

/// Dấu trong log agy khi token hợp lệ và xác thực thành công (kèm email tài khoản).
/// Không dùng danh sách model của `agy models`: agy vẫn in model khi chưa đăng nhập (đã gặp).
/// Không dùng "Auth succeeded" hay "You are not logged into": cả hai xuất hiện trong cả hai trường hợp.
const AUTH_OK_MARK: &str = "authenticated successfully as";

/// Đã đăng nhập agy hay chưa. Chạy `agy models` (có timeout) rồi đọc log của agy vừa chạy:
/// có dòng xác thực thành công thì đã đăng nhập. Đây là tín hiệu duy nhất đã kiểm chứng đúng cả hai chiều.
fn signed_in_by_models() -> Result<bool, String> {
    let since = std::time::SystemTime::now();
    // Output của `agy models` ghi vào file tạm (không dùng pipe: tiến trình con có thể giữ pipe và làm treo)
    let stamp = since
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or_default();
    let out_path = std::env::temp_dir().join(format!(
        "muop-agy-models-{}-{stamp}.txt",
        std::process::id()
    ));
    let out_file = std::fs::File::create(&out_path)
        .map_err(|e| format!("Không tạo được file tạm cho agy models: {e}"))?;
    let waited = wait_agy_models(out_file);
    let output = std::fs::read_to_string(&out_path).unwrap_or_default();
    let _ = std::fs::remove_file(&out_path);
    waited?;
    // Mỗi lần kiểm tra đăng nhập đều có danh sách model mới nhất (kể cả khi chưa đăng nhập agy vẫn in model)
    crate::scanner::refresh_agy_models(&output);
    Ok(logged_in_from_logs(&agy_logs_since(since)))
}

/// Chạy `agy models` (stdout vào `out`, stderr bỏ) và chờ tối đa [`MODELS_TIMEOUT`]
fn wait_agy_models(out: std::fs::File) -> Result<(), String> {
    let agy = crate::chat::agy_bin()?;
    let mut child = std::process::Command::new(agy)
        .arg("models")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::from(out))
        .stderr(std::process::Stdio::null())
        .spawn()
        .map_err(|e| format!("Không chạy được agy: {e}"))?;
    let started = Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(_)) => return Ok(()),
            Ok(None) if started.elapsed() < MODELS_TIMEOUT => {
                thread::sleep(Duration::from_millis(100))
            }
            Ok(None) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err("agy models không trả lời kịp".into());
            }
            Err(e) => return Err(format!("Lỗi chờ agy models: {e}")),
        }
    }
}

/// Có log nào trong danh sách ghi xác thực thành công hay không
fn logged_in_from_logs(logs: &[String]) -> bool {
    logs.iter().any(|log| log.contains(AUTH_OK_MARK))
}

/// Nội dung các file log agy được tạo hoặc cập nhật từ `since` trở đi (`~/.gemini/antigravity-cli/log`)
fn agy_logs_since(since: std::time::SystemTime) -> Vec<String> {
    let Some(home) = std::env::var_os("HOME") else {
        return Vec::new();
    };
    let dir = std::path::Path::new(&home).join(".gemini/antigravity-cli/log");
    let Ok(entries) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    entries
        .flatten()
        .filter(|e| {
            e.metadata()
                .and_then(|m| m.modified())
                .is_ok_and(|t| t >= since)
        })
        .filter_map(|e| std::fs::read_to_string(e.path()).ok())
        .collect()
}

/// Trạng thái đăng nhập: terminal đăng nhập đang chạy thì lấy từ terminal; không thì hỏi `agy models`.
/// Không phát event: dùng cho client hỏi bằng `agy:auth:status`.
pub fn query() -> AgyAuthEvent {
    // Đang đăng nhập trong terminal: trạng thái lấy từ terminal (watcher). Không hỏi hub:
    // hub của agy đang đăng nhập có thể đang bận (OAuth) và làm lời gọi treo.
    if login_active() {
        let ev = make("login_terminal", false, "");
        store(&ev);
        return ev;
    }
    let ev = match signed_in_by_models() {
        Ok(true) => make("logged_in", true, ""),
        Ok(false) => make("logged_out", false, ""),
        Err(e) => make("failed", false, &e),
    };
    store(&ev);
    ev
}

/// Kiểm tra trạng thái đăng nhập agy (socket `agy:auth:check`, REST `POST /api/agy/auth/check`).
/// Khi terminal đăng nhập đang chạy và đã vào màn chat thì kết thúc luồng đăng nhập (như watcher).
/// Không thì trả trạng thái như `agy:auth:status` (`query`). Phát `agy:auth:update` khi trạng thái đổi.
pub fn check() -> AgyAuthEvent {
    if let Some((sid, _)) = terminal_session().filter(|(sid, _)| terminal_alive(sid)) {
        let in_chat =
            terminal_output(&sid).is_some_and(|raw| tui::chat_ready(&tui::strip_ansi(&raw)));
        if in_chat {
            // Cho agy ghi token vào keyring trước khi đóng terminal (như watcher)
            thread::sleep(Duration::from_secs(1));
            end_login(&sid, Outcome::LoggedIn);
            return current();
        }
    }
    let ev = query();
    // Client hỏi mỗi vài giây khi khung đăng nhập hiện: chỉ phát khi trạng thái đổi
    publish_if_changed(&ev.phase, ev.logged_in, &ev.error);
    current()
}

/// Đăng xuất agy bằng đúng thao tác của người dùng: gọi RPC `AuthLogout` của hub.
/// Hủy terminal đăng nhập đang mở (nếu có). Chặn luồng: gọi qua `spawn_blocking`.
pub fn logout() -> Result<(), String> {
    cancel_login();
    let res = logout_inner();
    match &res {
        Ok(()) => {
            SIGNED_OUT_BY_APP.store(true, Ordering::SeqCst);
            publish("logged_out", false, "");
            sync_quotas();
        }
        Err(e) => publish("failed", matches!(signed_in_by_models(), Ok(true)), e),
    }
    res
}

/// Thời gian tối đa chờ agy xóa token sau `AuthLogout`, và khoảng cách giữa hai lần kiểm tra
const LOGOUT_WAIT: Duration = Duration::from_secs(60);
const LOGOUT_CHECK_EVERY: Duration = Duration::from_secs(2);

/// Gọi `AuthLogout` của hub rồi chờ `agy models` báo chưa đăng nhập
fn logout_inner() -> Result<(), String> {
    if matches!(signed_in_by_models(), Ok(false)) {
        return Ok(());
    }
    crate::agy_account::logout_via_hub()?;
    let deadline = Instant::now() + LOGOUT_WAIT;
    loop {
        if matches!(signed_in_by_models(), Ok(false)) {
            return Ok(());
        }
        if Instant::now() >= deadline {
            return Err("agy vẫn báo đã đăng nhập sau khi đăng xuất".into());
        }
        thread::sleep(LOGOUT_CHECK_EVERY);
    }
}

/// Bắt đầu đăng nhập: mở terminal SSH chạy `agy` để người dùng tự đăng nhập trong đó.
/// Kết quả đến qua `agy:auth:update` (xem [`watch_login`]).
pub fn begin_login() -> Result<(), String> {
    let res = begin_login_inner();
    if let Err(e) = &res {
        publish("failed", matches!(signed_in_by_models(), Ok(true)), e);
    }
    res
}

fn begin_login_inner() -> Result<(), String> {
    if matches!(signed_in_by_models(), Ok(true)) {
        return Err("Agy đang đăng nhập. Hãy đăng xuất trước khi đăng nhập lại.".to_string());
    }
    open_login_terminal().map(|_| ())
}

/// Xóa quota cũ của Antigravity rồi đẩy quota hiện tại (`quotas:update`) cho mọi client.
/// Gọi sau khi đăng xuất (quota về rỗng) và sau khi đăng nhập xong (quota của tài khoản mới).
pub(crate) fn sync_quotas() {
    crate::scanner::clear_antigravity_quota_cache();
    push_quotas();
}

/// Trạng thái hai tài khoản (agy và Claude Code CLI) cho màn hình Tài khoản.
/// Gọi trong blocking thread (có curl tới hub).
pub fn accounts_status() -> AccountsStatus {
    let agy_logged_in = matches!(status(), Ok(true));
    // Email và gói lấy từ DB (watcher của agy_account lấy từ hub), không hỏi hub trong lúc trả lời client
    let (agy_email, agy_plan) = match (agy_logged_in, crate::agy_account::snapshot()) {
        (true, Some(snap)) => (snap.email, snap.plan),
        _ => (String::new(), String::new()),
    };
    let (claude_logged_in, claude_plan) = crate::claude::code::claude_account();
    AccountsStatus {
        agy_logged_in,
        agy_email,
        agy_plan,
        claude_logged_in,
        claude_plan,
    }
}

#[cfg(test)]
mod publish_tests {
    use super::*;

    // Một test duy nhất: `LAST_EMITTED` là biến toàn cục, test song song sẽ giẫm lên nhau
    #[test]
    fn publish_if_changed_skips_repeated_state_only() {
        assert!(publish_if_changed("logged_out", false, ""));
        assert!(!publish_if_changed("logged_out", false, ""));
        // `query` ghi CURRENT mà không phát: lần kiểm tra sau vẫn phải phát vì khác event đã phát (logged_out)
        store(&make("logged_in", true, ""));
        assert!(publish_if_changed("logged_in", true, ""));
        assert!(!publish_if_changed("logged_in", true, ""));
    }
}

#[cfg(test)]
mod login_log_tests {
    use super::*;

    #[test]
    fn auth_line_with_account_means_signed_in() {
        let log = "OAuth: authenticated successfully as a@b.c".to_string();
        assert!(logged_in_from_logs(&[log]));
    }

    #[test]
    fn logged_out_logs_are_not_signed_in() {
        // Log thật khi chưa đăng nhập: có "Auth succeeded" nhưng không có dòng xác thực theo tài khoản
        let log =
            "Auth succeeded, refreshing features\nYou are not logged into Antigravity".to_string();
        assert!(!logged_in_from_logs(&[log]));
        assert!(!logged_in_from_logs(&[]));
    }
}
