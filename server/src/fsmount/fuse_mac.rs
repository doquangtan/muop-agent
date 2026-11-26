//! FUSE cho macOS, dùng API libfuse (FUSE-T cung cấp) thay cho `fuser`: `fuser` nói protocol `/dev/fuse`
//! kiểu macFUSE nên FUSE-T ngắt kết nối ngay sau khi mount.
//!
//! Logic giống `fuse.rs` (đọc theo đoạn, ghi qua bộ đệm RAM, đẩy cả file khi flush/release) nhưng theo
//! đường dẫn thay vì inode, vì API high-level của libfuse là path-based. Mỗi mount chạy `fuse_loop` trên
//! một luồng riêng; luồng này không dùng `fuse_main` vì nó tự đặt signal handler và chặn SIGTERM của server.

use std::collections::HashMap;
use std::ffi::{c_char, c_int, c_void, CStr, CString};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::MetadataExt;
use std::panic::AssertUnwindSafe;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, MutexGuard};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use fuser::Errno;
use serde_json::Value;

use super::remote::{Remote, MAX_FILE_BYTES};

/// Thời gian tối đa chờ mount xong (FUSE-T cần vài giây cho lần đầu)
const READY_TIMEOUT: Duration = Duration::from_secs(15);
/// Tên chương trình trong argv của libfuse (chỉ để hiển thị)
const PROG: &str = "muop-remote";
/// Tùy chọn mount: tên hiển thị và để kernel tự kiểm tra quyền theo thuộc tính trả về
const MOUNT_OPTS: &str = "fsname=muop-remote,default_permissions";

/// Con trỏ hàm của `struct fuse_operations`; mọi con trỏ hàm C đều cùng kích thước nên dùng chung kiểu này
type Ptr = Option<unsafe extern "C" fn()>;
type FillDir =
    unsafe extern "C" fn(*mut c_void, *const c_char, *const libc::stat, libc::off_t) -> c_int;

/// `struct fuse_args`
#[repr(C)]
struct FuseArgs {
    argc: c_int,
    argv: *mut *mut c_char,
    allocated: c_int,
}

/// `struct fuse_file_info` (bản macOS): `fh` là khóa handle của mình
#[repr(C)]
struct FuseFileInfo {
    flags: c_int,
    fh_old: libc::c_ulong,
    writepage: c_int,
    /// direct_io, keep_cache, flush, nonseekable, flock_release, padding, purge_attr, purge_ubc
    _bits: u32,
    fh: u64,
    lock_owner: u64,
}

/// `struct fuse_context`: `private_data` là con trỏ tới `Ctx` của mount
#[repr(C)]
struct FuseContext {
    fuse: *mut c_void,
    uid: libc::uid_t,
    gid: libc::gid_t,
    pid: libc::pid_t,
    private_data: *mut c_void,
    umask: libc::mode_t,
}

/// `struct fuse_operations` theo đúng thứ tự của header FUSE-T (bản `__APPLE__`).
/// Không được đổi thứ tự: FUSE-T đọc theo offset và `fuse_new` nhận `sizeof` của struct này.
#[repr(C)]
#[derive(Default)]
struct FuseOps {
    getattr: Ptr,
    readlink: Ptr,
    getdir: Ptr,
    mknod: Ptr,
    mkdir: Ptr,
    unlink: Ptr,
    rmdir: Ptr,
    symlink: Ptr,
    rename: Ptr,
    link: Ptr,
    chmod: Ptr,
    chown: Ptr,
    truncate: Ptr,
    utime: Ptr,
    open: Ptr,
    read: Ptr,
    write: Ptr,
    statfs: Ptr,
    flush: Ptr,
    release: Ptr,
    fsync: Ptr,
    setxattr: Ptr,
    getxattr: Ptr,
    listxattr: Ptr,
    removexattr: Ptr,
    opendir: Ptr,
    readdir: Ptr,
    releasedir: Ptr,
    fsyncdir: Ptr,
    init: Ptr,
    destroy: Ptr,
    access: Ptr,
    create: Ptr,
    ftruncate: Ptr,
    fgetattr: Ptr,
    lock: Ptr,
    utimens: Ptr,
    bmap: Ptr,
    /// flag_nullpath_ok, flag_nopath, flag_utime_omit_ok, flag_reserved (một đơn vị 32 bit)
    _flag_bits: u32,
    ioctl: Ptr,
    poll: Ptr,
    write_buf: Ptr,
    read_buf: Ptr,
    flock: Ptr,
    fallocate: Ptr,
    reserved00: Ptr,
    reserved01: Ptr,
    renamex: Ptr,
    statfs_x: Ptr,
    setvolname: Ptr,
    exchange: Ptr,
    getxtimes: Ptr,
    setbkuptime: Ptr,
    setchgtime: Ptr,
    setcrtime: Ptr,
    chflags: Ptr,
    setattr_x: Ptr,
    fsetattr_x: Ptr,
}

#[link(name = "fuse-t")]
extern "C" {
    fn fuse_mount(mountpoint: *const c_char, args: *mut FuseArgs) -> *mut c_void;
    fn fuse_new(
        ch: *mut c_void,
        args: *mut FuseArgs,
        ops: *const FuseOps,
        op_size: usize,
        user_data: *mut c_void,
    ) -> *mut c_void;
    fn fuse_loop(f: *mut c_void) -> c_int;
    fn fuse_unmount(mountpoint: *const c_char, ch: *mut c_void);
    fn fuse_destroy(f: *mut c_void);
    fn fuse_get_context() -> *mut FuseContext;
}

struct Handle {
    /// Đường dẫn tương đối tại thời điểm mở (cập nhật khi đổi tên)
    rel: String,
    /// Nội dung đang sửa; `None` với handle chỉ đọc
    buf: Option<Vec<u8>>,
    /// Tăng mỗi lần ghi vào bộ đệm, để flush không xóa cờ bẩn của lần ghi mới hơn
    version: u64,
    dirty: bool,
}

/// Trạng thái của một mount, sống từ lúc mount đến lúc gỡ
struct Ctx {
    remote: Remote,
    handles: Mutex<HashMap<u64, Handle>>,
    next_fh: AtomicU64,
    uid: u32,
    gid: u32,
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

impl Ctx {
    fn insert_handle(&self, rel: String, buf: Option<Vec<u8>>, dirty: bool) -> u64 {
        let fh = self.next_fh.fetch_add(1, Ordering::Relaxed);
        lock(&self.handles).insert(
            fh,
            Handle {
                rel,
                buf,
                version: 0,
                dirty,
            },
        );
        fh
    }

    /// Kích thước bộ đệm đang mở để ghi của một đường dẫn (handle mới nhất), nếu có
    fn buffered_size(&self, rel: &str) -> Option<u64> {
        lock(&self.handles)
            .iter()
            .filter(|(_, h)| h.rel == rel)
            .filter_map(|(fh, h)| h.buf.as_ref().map(|b| (*fh, b.len() as u64)))
            .max_by_key(|(fh, _)| *fh)
            .map(|(_, len)| len)
    }

    /// Đẩy bộ đệm của handle lên máy gửi nếu có thay đổi
    fn flush_fh(&self, fh: u64) -> Result<(), Errno> {
        let (rel, data, version) = {
            let handles = lock(&self.handles);
            match handles.get(&fh) {
                Some(h) if h.dirty => match &h.buf {
                    Some(buf) => (h.rel.clone(), buf.clone(), h.version),
                    None => return Ok(()),
                },
                _ => return Ok(()),
            }
        };
        self.remote.write(&rel, data)?;
        if let Some(h) = lock(&self.handles).get_mut(&fh) {
            if h.version == version {
                h.dirty = false;
            }
        }
        Ok(())
    }

    /// Đổi kích thước file: với handle đang mở để ghi thì đổi trên bộ đệm, không thì ghi thẳng lên máy gửi
    fn truncate(&self, rel: &str, fh: Option<u64>, size: u64) -> Result<(), Errno> {
        let size = usize::try_from(size)
            .ok()
            .filter(|s| *s <= MAX_FILE_BYTES)
            .ok_or(Errno::EFBIG)?;
        if let Some(fh) = fh {
            let mut handles = lock(&self.handles);
            if let Some(h) = handles.get_mut(&fh) {
                if let Some(buf) = h.buf.as_mut() {
                    buf.resize(size, 0);
                    h.version += 1;
                    h.dirty = true;
                    return Ok(());
                }
            }
        }
        let mut data = if size == 0 {
            Vec::new()
        } else {
            self.remote.read_all(rel)?
        };
        data.resize(size, 0);
        self.remote.write(rel, data)
    }

    /// Sau khi đổi tên, các handle đang mở trỏ tới đường dẫn mới
    fn rename_handles(&self, from: &str, to: &str) {
        let prefix = format!("{from}/");
        for h in lock(&self.handles).values_mut() {
            if h.rel == from {
                h.rel = to.to_string();
            } else if let Some(rest) = h.rel.strip_prefix(&prefix) {
                h.rel = format!("{to}/{rest}");
            }
        }
    }
}

/// `Ctx` của luồng đang chạy callback (đặt làm `private_data` khi `fuse_new`)
unsafe fn ctx<'a>() -> &'a Ctx {
    let c = fuse_get_context();
    &*((*c).private_data as *const Ctx)
}

/// Đường dẫn tương đối từ đường dẫn tuyệt đối của libfuse (gốc là chuỗi rỗng)
unsafe fn rel_of(path: *const c_char) -> Result<String, c_int> {
    if path.is_null() {
        return Err(-libc::EINVAL);
    }
    let s = CStr::from_ptr(path).to_str().map_err(|_| -libc::EINVAL)?;
    let rel = s.trim_matches('/');
    if rel.split('/').any(|p| p == "..") {
        return Err(-libc::EACCES);
    }
    Ok(rel.to_string())
}

fn neg(e: Errno) -> c_int {
    -i32::from(e)
}

/// Chặn panic đi qua biên FFI (panic qua C là UB); panic thì trả EIO
fn guard<F>(f: AssertUnwindSafe<F>) -> c_int
where
    F: FnOnce() -> Result<c_int, c_int>,
{
    match std::panic::catch_unwind(f) {
        Ok(Ok(v)) => v,
        Ok(Err(e)) => e,
        Err(_) => {
            tracing::error!("fsmount (macOS): callback panic");
            -libc::EIO
        }
    }
}

/// Điền `struct stat` từ thuộc tính của máy gửi
unsafe fn fill_stat(st: *mut libc::stat, info: &Value, size_override: Option<u64>, c: &Ctx) {
    let is_dir = info["isDir"].as_bool().unwrap_or(false);
    let size = size_override.unwrap_or_else(|| info["size"].as_u64().unwrap_or(0));
    let mtime = info["mtime"].as_u64().unwrap_or(0) as libc::time_t;
    let default_mode = if is_dir { 0o755 } else { 0o644 };
    let perm = (info["mode"].as_u64().unwrap_or(default_mode) & 0o7777) as libc::mode_t;
    std::ptr::write_bytes(st, 0, 1);
    let kind = if is_dir { libc::S_IFDIR } else { libc::S_IFREG };
    (*st).st_mode = kind | perm;
    (*st).st_nlink = if is_dir { 2 } else { 1 };
    (*st).st_size = size as libc::off_t;
    (*st).st_blocks = size.div_ceil(512) as _;
    (*st).st_blksize = 4096;
    (*st).st_uid = c.uid as _;
    (*st).st_gid = c.gid as _;
    (*st).st_atime = mtime;
    (*st).st_mtime = mtime;
    (*st).st_ctime = mtime;
}

unsafe extern "C" fn cb_getattr(path: *const c_char, st: *mut libc::stat) -> c_int {
    guard(AssertUnwindSafe(|| -> Result<c_int, c_int> {
        let c = ctx();
        let rel = rel_of(path)?;
        let info = c.remote.stat(&rel).map_err(neg)?;
        fill_stat(st, &info, c.buffered_size(&rel), c);
        Ok(0)
    }))
}

unsafe extern "C" fn cb_fgetattr(
    path: *const c_char,
    st: *mut libc::stat,
    _fi: *mut FuseFileInfo,
) -> c_int {
    cb_getattr(path, st)
}

unsafe extern "C" fn cb_readdir(
    path: *const c_char,
    buf: *mut c_void,
    filler: FillDir,
    offset: libc::off_t,
    _fi: *mut FuseFileInfo,
) -> c_int {
    guard(AssertUnwindSafe(|| -> Result<c_int, c_int> {
        let c = ctx();
        let rel = rel_of(path)?;
        let entries = c.remote.list(&rel).map_err(neg)?;
        // "." và ".." trước, rồi các entry; offset của mỗi entry là vị trí kế tiếp (1-based)
        let mut all: Vec<(String, Value)> = vec![
            (".".to_string(), serde_json::json!({"isDir": true})),
            ("..".to_string(), serde_json::json!({"isDir": true})),
        ];
        for e in entries {
            if let Some(name) = e["name"].as_str() {
                all.push((name.to_string(), e.clone()));
            }
        }
        for (i, (name, info)) in all.iter().enumerate().skip(offset.max(0) as usize) {
            let Ok(cname) = CString::new(name.as_str()) else {
                continue;
            };
            let mut st: libc::stat = std::mem::zeroed();
            fill_stat(&mut st, info, None, c);
            if filler(buf, cname.as_ptr(), &st, (i + 1) as libc::off_t) != 0 {
                break;
            }
        }
        Ok(0)
    }))
}

unsafe extern "C" fn cb_open(path: *const c_char, fi: *mut FuseFileInfo) -> c_int {
    guard(AssertUnwindSafe(|| -> Result<c_int, c_int> {
        let c = ctx();
        let rel = rel_of(path)?;
        let info = c.remote.stat(&rel).map_err(neg)?;
        if info["isDir"].as_bool().unwrap_or(false) {
            return Err(-libc::EISDIR);
        }
        let flags = (*fi).flags;
        let writable = (flags & libc::O_ACCMODE) != libc::O_RDONLY;
        let truncate = (flags & libc::O_TRUNC) != 0;
        let (buf, dirty) = if writable {
            if truncate {
                (Some(Vec::new()), true)
            } else {
                (Some(c.remote.read_all(&rel).map_err(neg)?), false)
            }
        } else {
            (None, false)
        };
        (*fi).fh = c.insert_handle(rel, buf, dirty);
        Ok(0)
    }))
}

unsafe extern "C" fn cb_create(
    path: *const c_char,
    _mode: libc::mode_t,
    fi: *mut FuseFileInfo,
) -> c_int {
    guard(AssertUnwindSafe(|| -> Result<c_int, c_int> {
        let c = ctx();
        let rel = rel_of(path)?;
        c.remote.write(&rel, Vec::new()).map_err(neg)?;
        (*fi).fh = c.insert_handle(rel, Some(Vec::new()), false);
        Ok(0)
    }))
}

unsafe extern "C" fn cb_read(
    _path: *const c_char,
    buf: *mut c_char,
    size: libc::size_t,
    offset: libc::off_t,
    fi: *mut FuseFileInfo,
) -> c_int {
    guard(AssertUnwindSafe(|| -> Result<c_int, c_int> {
        let c = ctx();
        let fh = (*fi).fh;
        let (rel, cached) = {
            let handles = lock(&c.handles);
            let Some(h) = handles.get(&fh) else {
                return Err(-libc::EBADF);
            };
            let start = offset.max(0) as usize;
            let cached = h.buf.as_ref().map(|b| {
                let s = start.min(b.len());
                let e = s.saturating_add(size).min(b.len());
                b[s..e].to_vec()
            });
            (h.rel.clone(), cached)
        };
        let data = match cached {
            Some(data) => data,
            None => {
                c.remote
                    .read(&rel, offset.max(0) as u64, size as u64)
                    .map_err(neg)?
                    .0
            }
        };
        let n = data.len().min(size);
        std::ptr::copy_nonoverlapping(data.as_ptr(), buf as *mut u8, n);
        Ok(n as c_int)
    }))
}

unsafe extern "C" fn cb_write(
    _path: *const c_char,
    buf: *const c_char,
    size: libc::size_t,
    offset: libc::off_t,
    fi: *mut FuseFileInfo,
) -> c_int {
    guard(AssertUnwindSafe(|| -> Result<c_int, c_int> {
        let c = ctx();
        let data = std::slice::from_raw_parts(buf as *const u8, size);
        let start = usize::try_from(offset).map_err(|_| -libc::EFBIG)?;
        let end = start
            .checked_add(data.len())
            .filter(|e| *e <= MAX_FILE_BYTES)
            .ok_or(-libc::EFBIG)?;
        let mut handles = lock(&c.handles);
        let h = handles.get_mut(&(*fi).fh).ok_or(-libc::EBADF)?;
        let b = h.buf.as_mut().ok_or(-libc::EBADF)?;
        if b.len() < end {
            b.resize(end, 0);
        }
        b[start..end].copy_from_slice(data);
        h.version += 1;
        h.dirty = true;
        Ok(data.len() as c_int)
    }))
}

unsafe extern "C" fn cb_flush(_path: *const c_char, fi: *mut FuseFileInfo) -> c_int {
    guard(AssertUnwindSafe(|| -> Result<c_int, c_int> {
        ctx().flush_fh((*fi).fh).map(|_| 0).map_err(neg)
    }))
}

unsafe extern "C" fn cb_fsync(
    path: *const c_char,
    _datasync: c_int,
    fi: *mut FuseFileInfo,
) -> c_int {
    cb_flush(path, fi)
}

unsafe extern "C" fn cb_release(_path: *const c_char, fi: *mut FuseFileInfo) -> c_int {
    guard(AssertUnwindSafe(|| -> Result<c_int, c_int> {
        let c = ctx();
        let fh = (*fi).fh;
        // Luôn bỏ handle; lỗi đẩy lên máy gửi được báo qua close() của tiến trình
        let result = c.flush_fh(fh);
        lock(&c.handles).remove(&fh);
        result.map(|_| 0).map_err(neg)
    }))
}

unsafe extern "C" fn cb_truncate(path: *const c_char, size: libc::off_t) -> c_int {
    guard(AssertUnwindSafe(|| -> Result<c_int, c_int> {
        let rel = rel_of(path)?;
        ctx()
            .truncate(&rel, None, size.max(0) as u64)
            .map(|_| 0)
            .map_err(neg)
    }))
}

unsafe extern "C" fn cb_ftruncate(
    path: *const c_char,
    size: libc::off_t,
    fi: *mut FuseFileInfo,
) -> c_int {
    guard(AssertUnwindSafe(|| -> Result<c_int, c_int> {
        let rel = rel_of(path)?;
        ctx()
            .truncate(&rel, Some((*fi).fh), size.max(0) as u64)
            .map(|_| 0)
            .map_err(neg)
    }))
}

unsafe extern "C" fn cb_mkdir(path: *const c_char, _mode: libc::mode_t) -> c_int {
    guard(AssertUnwindSafe(|| -> Result<c_int, c_int> {
        let rel = rel_of(path)?;
        ctx().remote.mkdir(&rel).map(|_| 0).map_err(neg)
    }))
}

unsafe extern "C" fn cb_unlink(path: *const c_char) -> c_int {
    guard(AssertUnwindSafe(|| -> Result<c_int, c_int> {
        let c = ctx();
        let rel = rel_of(path)?;
        let info = c.remote.stat(&rel).map_err(neg)?;
        if info["isDir"].as_bool().unwrap_or(false) {
            return Err(-libc::EISDIR);
        }
        c.remote.delete(&rel, false).map(|_| 0).map_err(neg)
    }))
}

unsafe extern "C" fn cb_rmdir(path: *const c_char) -> c_int {
    guard(AssertUnwindSafe(|| -> Result<c_int, c_int> {
        let c = ctx();
        let rel = rel_of(path)?;
        let info = c.remote.stat(&rel).map_err(neg)?;
        if !info["isDir"].as_bool().unwrap_or(false) {
            return Err(-libc::ENOTDIR);
        }
        c.remote.delete(&rel, false).map(|_| 0).map_err(neg)
    }))
}

unsafe extern "C" fn cb_rename(from: *const c_char, to: *const c_char) -> c_int {
    guard(AssertUnwindSafe(|| -> Result<c_int, c_int> {
        let c = ctx();
        let from = rel_of(from)?;
        let to = rel_of(to)?;
        c.remote.rename(&from, &to, true).map_err(neg)?;
        c.rename_handles(&from, &to);
        Ok(0)
    }))
}

/// Quyền và chủ sở hữu không đồng bộ lên máy gửi (như `fuse.rs`): báo thành công
unsafe extern "C" fn cb_chmod(_path: *const c_char, _mode: libc::mode_t) -> c_int {
    0
}

unsafe extern "C" fn cb_chown(_path: *const c_char, _uid: libc::uid_t, _gid: libc::gid_t) -> c_int {
    0
}

unsafe extern "C" fn cb_utimens(_path: *const c_char, _tv: *const libc::timespec) -> c_int {
    0
}

unsafe extern "C" fn cb_access(path: *const c_char, _mask: c_int) -> c_int {
    guard(AssertUnwindSafe(|| -> Result<c_int, c_int> {
        let rel = rel_of(path)?;
        ctx().remote.stat(&rel).map(|_| 0).map_err(neg)
    }))
}

unsafe extern "C" fn cb_statfs(_path: *const c_char, st: *mut libc::statvfs) -> c_int {
    // Máy gửi không báo dung lượng; trả số lớn để công cụ (df, editor) không báo đầy
    std::ptr::write_bytes(st, 0, 1);
    (*st).f_bsize = 4096;
    (*st).f_frsize = 4096;
    (*st).f_blocks = 1 << 24;
    (*st).f_bfree = 1 << 24;
    (*st).f_bavail = 1 << 24;
    (*st).f_files = 1 << 20;
    (*st).f_ffree = 1 << 20;
    (*st).f_favail = 1 << 20;
    (*st).f_namemax = 255;
    0
}

/// Đổi con trỏ hàm C (đã ép về `*const ()`) thành `Ptr`; con trỏ null thành `None`
fn op(f: *const ()) -> Ptr {
    // SAFETY: f là địa chỉ của một hàm `extern "C"` hoặc null; Option<fn()> có cùng biểu diễn với con trỏ đó
    unsafe { std::mem::transmute::<*const (), Ptr>(f) }
}

fn ops_table() -> FuseOps {
    FuseOps {
        getattr: op(cb_getattr as *const ()),
        fgetattr: op(cb_fgetattr as *const ()),
        mkdir: op(cb_mkdir as *const ()),
        unlink: op(cb_unlink as *const ()),
        rmdir: op(cb_rmdir as *const ()),
        rename: op(cb_rename as *const ()),
        chmod: op(cb_chmod as *const ()),
        chown: op(cb_chown as *const ()),
        truncate: op(cb_truncate as *const ()),
        open: op(cb_open as *const ()),
        read: op(cb_read as *const ()),
        write: op(cb_write as *const ()),
        statfs: op(cb_statfs as *const ()),
        flush: op(cb_flush as *const ()),
        release: op(cb_release as *const ()),
        fsync: op(cb_fsync as *const ()),
        readdir: op(cb_readdir as *const ()),
        access: op(cb_access as *const ()),
        create: op(cb_create as *const ()),
        ftruncate: op(cb_ftruncate as *const ()),
        utimens: op(cb_utimens as *const ()),
        ..FuseOps::default()
    }
}

/// Mount đang chạy. Gỡ mount khi bỏ đi (`Drop`), rồi chờ luồng FUSE thoát trước khi giải phóng `Ctx`.
pub struct MacMount {
    mount_point: PathBuf,
    ctx: *mut Ctx,
    thread: Option<JoinHandle<c_int>>,
}

// SAFETY: `ctx` chỉ được dùng từ luồng FUSE của mount này và chỉ được giải phóng sau khi luồng đó thoát
unsafe impl Send for MacMount {}

impl Drop for MacMount {
    fn drop(&mut self) {
        // umount -f làm fuse_loop thoát; nếu không có gì để gỡ thì lỗi được bỏ qua
        let _ = std::process::Command::new("umount")
            .arg("-f")
            .arg(&self.mount_point)
            .output();
        if let Some(handle) = self.thread.take() {
            let _ = handle.join();
        }
        // SAFETY: luồng FUSE đã thoát nên không còn ai giữ con trỏ tới Ctx
        unsafe { drop(Box::from_raw(self.ctx)) };
    }
}

/// Chạy vòng lặp FUSE của một mount trên luồng hiện tại (gọi từ luồng riêng)
fn run_loop(mount_point: &CString, ctx: *mut c_void) -> c_int {
    let ops = ops_table();
    let ch = call_with_args(&[PROG, "-o", MOUNT_OPTS], |a| unsafe {
        fuse_mount(mount_point.as_ptr(), a)
    });
    if ch.is_null() {
        return -1;
    }
    let f = call_with_args(&[PROG], |a| unsafe {
        fuse_new(ch, a, &ops, std::mem::size_of::<FuseOps>(), ctx)
    });
    if f.is_null() {
        // SAFETY: ch vừa được fuse_mount trả về và chưa được giải phóng
        unsafe { fuse_unmount(mount_point.as_ptr(), ch) };
        return -2;
    }
    // SAFETY: f hợp lệ từ fuse_new; fuse_loop trả về khi mount bị gỡ
    let rc = unsafe { fuse_loop(f) };
    unsafe {
        fuse_unmount(mount_point.as_ptr(), ch);
        fuse_destroy(f);
    }
    rc
}

/// Dựng `struct fuse_args` từ danh sách tham số, giữ chuỗi sống trong suốt lời gọi
fn call_with_args<R>(items: &[&str], f: impl FnOnce(&mut FuseArgs) -> R) -> R {
    let owned: Vec<CString> = items
        .iter()
        .map(|s| CString::new(*s).expect("tham số không chứa NUL"))
        .collect();
    let mut argv: Vec<*mut c_char> = owned.iter().map(|s| s.as_ptr() as *mut c_char).collect();
    argv.push(std::ptr::null_mut());
    let mut args = FuseArgs {
        argc: owned.len() as c_int,
        argv: argv.as_mut_ptr(),
        allocated: 0,
    };
    f(&mut args)
}

/// Thư mục mount đã thành một điểm mount (khác thiết bị với thư mục cha)
fn is_mounted(mount_point: &Path) -> bool {
    let Some(parent) = mount_point.parent() else {
        return false;
    };
    match (std::fs::metadata(mount_point), std::fs::metadata(parent)) {
        (Ok(m), Ok(p)) => m.dev() != p.dev(),
        _ => false,
    }
}

/// Mount project của máy gửi tại `mount_point`. Chỉ trả về khi điểm mount đã có; lỗi thì không để lại mount.
pub fn mount(origin: &str, project: &str, mount_point: &Path) -> Result<MacMount, String> {
    let remote = Remote::with_default_timeout(origin, project)?;
    // SAFETY: getuid/getgid không có điều kiện đầu vào và không thể lỗi
    let (uid, gid) = unsafe { (libc::getuid(), libc::getgid()) };
    let ctx = Box::into_raw(Box::new(Ctx {
        remote,
        handles: Mutex::new(HashMap::new()),
        next_fh: AtomicU64::new(1),
        uid,
        gid,
    }));
    let mp = CString::new(mount_point.as_os_str().as_bytes())
        .map_err(|_| "đường dẫn mount có ký tự NUL".to_string())?;
    let ctx_addr = ctx as usize;
    let mp_thread = mp.clone();
    let thread = std::thread::Builder::new()
        .name("fuse-mac".into())
        .spawn(move || run_loop(&mp_thread, ctx_addr as *mut c_void))
        .map_err(|e| format!("không tạo được luồng FUSE: {e}"));
    let thread = match thread {
        Ok(t) => t,
        Err(e) => {
            // SAFETY: luồng chưa chạy nên Ctx không được dùng ở đâu khác
            unsafe { drop(Box::from_raw(ctx)) };
            return Err(e);
        }
    };
    let mount = MacMount {
        mount_point: mount_point.to_path_buf(),
        ctx,
        thread: Some(thread),
    };

    let started = Instant::now();
    loop {
        if is_mounted(mount_point) {
            return Ok(mount);
        }
        let finished = mount.thread.as_ref().map_or(true, |t| t.is_finished());
        if finished {
            // Luồng thoát trước khi mount xong: FUSE-T không mount được (Drop dọn lại)
            return Err(
                "FUSE-T không mount được (kiểm tra FUSE-T đã cài và cho phép trong System Settings)"
                    .into(),
            );
        }
        if started.elapsed() > READY_TIMEOUT {
            return Err("FUSE-T mount quá lâu, không thấy điểm mount".into());
        }
        std::thread::sleep(Duration::from_millis(100));
    }
}
