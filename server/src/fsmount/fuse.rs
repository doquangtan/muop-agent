//! Hệ file FUSE: ánh xạ thao tác của kernel sang `/api/fs/*` của máy gửi.
//!
//! - Đọc: gọi thẳng máy gửi theo từng đoạn (offset/size).
//! - Ghi: file mở để ghi được tải vào bộ đệm trong bộ nhớ; sửa trên bộ đệm và đẩy cả file lên máy gửi
//!   khi `flush`/`fsync`/`release` (phù hợp với `sed -i`, editor và `cp`).

use std::collections::HashMap;
use std::ffi::OsStr;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, MutexGuard};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use fuser::{
    Errno, FileAttr, FileHandle, FileType, Filesystem, FopenFlags, Generation, INodeNo, LockOwner,
    OpenAccMode, OpenFlags, RenameFlags, ReplyAttr, ReplyCreate, ReplyData, ReplyDirectory,
    ReplyEmpty, ReplyEntry, ReplyOpen, ReplyWrite, Request,
};
use serde_json::Value;

/// Bit RENAME_NOREPLACE của kernel (chỉ Linux có; nơi khác là 0 nên không bao giờ coi là có cờ này)
#[cfg(target_os = "linux")]
const NOREPLACE_BITS: u32 = libc::RENAME_NOREPLACE as u32;
#[cfg(not(target_os = "linux"))]
const NOREPLACE_BITS: u32 = 0;

use super::inodes::Inodes;
use super::remote::{Remote, MAX_FILE_BYTES};

/// Thời gian kernel giữ thuộc tính/entry trong cache
const TTL: Duration = Duration::from_secs(1);

struct Handle {
    rel: String,
    /// Nội dung đang sửa; `None` với handle chỉ đọc
    buf: Option<Vec<u8>>,
    /// Tăng mỗi lần ghi vào bộ đệm, để flush không xoá cờ bẩn của lần ghi mới hơn
    version: u64,
    /// Bộ đệm có khác máy gửi và cần đẩy lên
    dirty: bool,
}

pub struct RemoteFs {
    remote: Remote,
    inodes: Mutex<Inodes>,
    handles: Mutex<HashMap<u64, Handle>>,
    next_fh: AtomicU64,
    uid: u32,
    gid: u32,
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

impl RemoteFs {
    pub fn new(remote: Remote, uid: u32, gid: u32) -> Self {
        Self {
            remote,
            inodes: Mutex::new(Inodes::new()),
            handles: Mutex::new(HashMap::new()),
            next_fh: AtomicU64::new(1),
            uid,
            gid,
        }
    }

    fn rel_of(&self, ino: INodeNo) -> Result<String, Errno> {
        lock(&self.inodes)
            .path_of(ino.0)
            .map(str::to_string)
            .ok_or(Errno::ENOENT)
    }

    /// Đường dẫn tương đối của `name` trong thư mục `parent`
    fn child_rel(&self, parent: INodeNo, name: &OsStr) -> Result<String, Errno> {
        let parent = self.rel_of(parent)?;
        let name = name.to_str().ok_or(Errno::EINVAL)?;
        if name.is_empty() || name == "." || name == ".." || name.contains('/') {
            return Err(Errno::EINVAL);
        }
        Ok(join(&parent, name))
    }

    fn to_attr(&self, ino: u64, st: &Value) -> FileAttr {
        let is_dir = st["isDir"].as_bool().unwrap_or(false);
        let size = st["size"].as_u64().unwrap_or(0);
        let mtime = UNIX_EPOCH + Duration::from_secs(st["mtime"].as_u64().unwrap_or(0));
        FileAttr {
            ino: INodeNo(ino),
            size,
            blocks: size.div_ceil(512),
            atime: mtime,
            mtime,
            ctime: mtime,
            crtime: mtime,
            kind: if is_dir {
                FileType::Directory
            } else {
                FileType::RegularFile
            },
            perm: (st["mode"].as_u64().unwrap_or(0o644) & 0o7777) as u16,
            nlink: if is_dir { 2 } else { 1 },
            uid: self.uid,
            gid: self.gid,
            rdev: 0,
            blksize: 4096,
            flags: 0,
        }
    }

    /// Thuộc tính của một đường dẫn đã biết inode
    fn attr_by_ino(&self, ino: INodeNo, rel: &str) -> Result<FileAttr, Errno> {
        let st = self.remote.stat(rel)?;
        Ok(self.to_attr(ino.0, &st))
    }

    /// Thuộc tính của một đường dẫn chưa biết inode (lookup/create/mkdir); gán inode nếu cần
    fn attr_by_rel(&self, rel: &str) -> Result<FileAttr, Errno> {
        let st = self.remote.stat(rel)?;
        let ino = lock(&self.inodes).ino_for(rel);
        Ok(self.to_attr(ino, &st))
    }

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

    /// Đẩy bộ đệm của handle lên máy gửi nếu có thay đổi
    fn flush_handle(&self, fh: u64) -> Result<(), Errno> {
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

    /// Đổi kích thước file. Với handle đang mở để ghi thì đổi trên bộ đệm, không thì ghi thẳng lên máy gửi.
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
}

/// Ghép thư mục cha và tên con (cha rỗng nghĩa là gốc)
fn join(parent: &str, name: &str) -> String {
    if parent.is_empty() {
        name.to_string()
    } else {
        format!("{parent}/{name}")
    }
}

/// Thư mục cha của một đường dẫn tương đối (gốc là chuỗi rỗng)
fn parent_of(rel: &str) -> String {
    rel.rsplit_once('/')
        .map(|(p, _)| p.to_string())
        .unwrap_or_default()
}

/// Đoạn `[offset, offset+size)` của bộ đệm, cắt theo độ dài thực
fn slice_of(buf: &[u8], offset: u64, size: u32) -> Vec<u8> {
    let start = usize::try_from(offset).unwrap_or(usize::MAX).min(buf.len());
    let end = start.saturating_add(size as usize).min(buf.len());
    buf[start..end].to_vec()
}

impl Filesystem for RemoteFs {
    fn lookup(&self, _req: &Request, parent: INodeNo, name: &OsStr, reply: ReplyEntry) {
        let rel = match self.child_rel(parent, name) {
            Ok(rel) => rel,
            Err(e) => return reply.error(e),
        };
        match self.attr_by_rel(&rel) {
            Ok(attr) => reply.entry(&TTL, &attr, Generation(0)),
            Err(e) => reply.error(e),
        }
    }

    fn getattr(&self, _req: &Request, ino: INodeNo, fh: Option<FileHandle>, reply: ReplyAttr) {
        let rel = match self.rel_of(ino) {
            Ok(rel) => rel,
            Err(e) => return reply.error(e),
        };
        let mut attr = match self.attr_by_ino(ino, &rel) {
            Ok(attr) => attr,
            Err(e) => return reply.error(e),
        };
        // Handle đang sửa: kích thước là của bộ đệm (chưa đẩy lên máy gửi)
        if let Some(fh) = fh {
            if let Some(buf) = lock(&self.handles).get(&fh.0).and_then(|h| h.buf.as_ref()) {
                attr.size = buf.len() as u64;
            }
        }
        reply.attr(&TTL, &attr);
    }

    fn setattr(
        &self,
        _req: &Request,
        ino: INodeNo,
        _mode: Option<u32>,
        _uid: Option<u32>,
        _gid: Option<u32>,
        size: Option<u64>,
        _atime: Option<fuser::TimeOrNow>,
        _mtime: Option<fuser::TimeOrNow>,
        _ctime: Option<SystemTime>,
        fh: Option<FileHandle>,
        _crtime: Option<SystemTime>,
        _chgtime: Option<SystemTime>,
        _bkuptime: Option<SystemTime>,
        _flags: Option<fuser::BsdFileFlags>,
        _kill_suid_gid: bool,
        reply: ReplyAttr,
    ) {
        // Quyền và thời gian không đồng bộ lên máy gửi; chỉ kích thước được áp dụng
        let rel = match self.rel_of(ino) {
            Ok(rel) => rel,
            Err(e) => return reply.error(e),
        };
        if let Some(size) = size {
            if let Err(e) = self.truncate(&rel, fh.map(|f| f.0), size) {
                return reply.error(e);
            }
        }
        match self.attr_by_ino(ino, &rel) {
            Ok(attr) => reply.attr(&TTL, &attr),
            Err(e) => reply.error(e),
        }
    }

    fn mkdir(
        &self,
        _req: &Request,
        parent: INodeNo,
        name: &OsStr,
        _mode: u32,
        _umask: u32,
        _owner: fuser::Owner,
        reply: ReplyEntry,
    ) {
        let rel = match self.child_rel(parent, name) {
            Ok(rel) => rel,
            Err(e) => return reply.error(e),
        };
        if let Err(e) = self.remote.mkdir(&rel) {
            return reply.error(e);
        }
        match self.attr_by_rel(&rel) {
            Ok(attr) => reply.entry(&TTL, &attr, Generation(0)),
            Err(e) => reply.error(e),
        }
    }

    fn unlink(&self, _req: &Request, parent: INodeNo, name: &OsStr, reply: ReplyEmpty) {
        let rel = match self.child_rel(parent, name) {
            Ok(rel) => rel,
            Err(e) => return reply.error(e),
        };
        match self.remote.stat(&rel) {
            Ok(st) if st["isDir"].as_bool().unwrap_or(false) => reply.error(Errno::EISDIR),
            Ok(_) => match self.remote.delete(&rel, false) {
                Ok(()) => reply.ok(),
                Err(e) => reply.error(e),
            },
            Err(e) => reply.error(e),
        }
    }

    fn rmdir(&self, _req: &Request, parent: INodeNo, name: &OsStr, reply: ReplyEmpty) {
        let rel = match self.child_rel(parent, name) {
            Ok(rel) => rel,
            Err(e) => return reply.error(e),
        };
        match self.remote.stat(&rel) {
            Ok(st) if !st["isDir"].as_bool().unwrap_or(false) => reply.error(Errno::ENOTDIR),
            Ok(_) => match self.remote.delete(&rel, false) {
                Ok(()) => reply.ok(),
                Err(e) => reply.error(e),
            },
            Err(e) => reply.error(e),
        }
    }

    fn rename(
        &self,
        _req: &Request,
        parent: INodeNo,
        name: &OsStr,
        newparent: INodeNo,
        newname: &OsStr,
        flags: RenameFlags,
        _owner: Option<fuser::Owner>,
        reply: ReplyEmpty,
    ) {
        let from = match self.child_rel(parent, name) {
            Ok(rel) => rel,
            Err(e) => return reply.error(e),
        };
        let to = match self.child_rel(newparent, newname) {
            Ok(rel) => rel,
            Err(e) => return reply.error(e),
        };
        // Chỉ hỗ trợ RENAME_NOREPLACE (chỉ có trên Linux; macOS không gửi cờ này); cờ khác (như RENAME_EXCHANGE) chưa có
        if flags.bits() & !NOREPLACE_BITS != 0 {
            return reply.error(Errno::EINVAL);
        }
        let noreplace = NOREPLACE_BITS != 0 && flags.bits() & NOREPLACE_BITS != 0;
        if noreplace && self.remote.stat(&to).is_ok() {
            return reply.error(Errno::EEXIST);
        }
        if let Err(e) = self.remote.rename(&from, &to, true) {
            return reply.error(e);
        }
        lock(&self.inodes).rename(&from, &to);
        reply.ok();
    }

    fn open(&self, _req: &Request, ino: INodeNo, flags: OpenFlags, _kill: bool, reply: ReplyOpen) {
        let rel = match self.rel_of(ino) {
            Ok(rel) => rel,
            Err(e) => return reply.error(e),
        };
        match self.remote.stat(&rel) {
            Ok(st) if st["isDir"].as_bool().unwrap_or(false) => return reply.error(Errno::EISDIR),
            Ok(_) => {}
            Err(e) => return reply.error(e),
        }
        let writable = !matches!(flags.acc_mode(), OpenAccMode::O_RDONLY);
        let truncate = flags.0 & libc::O_TRUNC != 0;
        let (buf, dirty) = if writable {
            if truncate {
                (Some(Vec::new()), true)
            } else {
                match self.remote.read_all(&rel) {
                    Ok(data) => (Some(data), false),
                    Err(e) => return reply.error(e),
                }
            }
        } else {
            (None, false)
        };
        let fh = self.insert_handle(rel, buf, dirty);
        reply.opened(FileHandle(fh), FopenFlags::empty());
    }

    fn read(
        &self,
        _req: &Request,
        _ino: INodeNo,
        fh: FileHandle,
        offset: u64,
        size: u32,
        _flags: OpenFlags,
        _lock_owner: Option<LockOwner>,
        reply: ReplyData,
    ) {
        let (rel, cached) = {
            let handles = lock(&self.handles);
            let Some(h) = handles.get(&fh.0) else {
                return reply.error(Errno::EBADF);
            };
            (
                h.rel.clone(),
                h.buf.as_ref().map(|b| slice_of(b, offset, size)),
            )
        };
        if let Some(data) = cached {
            return reply.data(&data);
        }
        match self.remote.read(&rel, offset, u64::from(size)) {
            Ok((data, _)) => reply.data(&data),
            Err(e) => reply.error(e),
        }
    }

    fn write(
        &self,
        _req: &Request,
        _ino: INodeNo,
        fh: FileHandle,
        offset: u64,
        data: &[u8],
        _write_flags: fuser::WriteFlags,
        _flags: OpenFlags,
        _lock_owner: Option<LockOwner>,
        reply: ReplyWrite,
    ) {
        let mut handles = lock(&self.handles);
        let Some(h) = handles.get_mut(&fh.0) else {
            return reply.error(Errno::EBADF);
        };
        let Some(buf) = h.buf.as_mut() else {
            return reply.error(Errno::EBADF);
        };
        let start = match usize::try_from(offset) {
            Ok(v) => v,
            Err(_) => return reply.error(Errno::EFBIG),
        };
        let end = match start.checked_add(data.len()) {
            Some(end) if end <= MAX_FILE_BYTES => end,
            _ => return reply.error(Errno::EFBIG),
        };
        if buf.len() < end {
            buf.resize(end, 0);
        }
        buf[start..end].copy_from_slice(data);
        h.version += 1;
        h.dirty = true;
        reply.written(data.len() as u32);
    }

    fn flush(
        &self,
        _req: &Request,
        _ino: INodeNo,
        fh: FileHandle,
        _owner: LockOwner,
        reply: ReplyEmpty,
    ) {
        match self.flush_handle(fh.0) {
            Ok(()) => reply.ok(),
            Err(e) => reply.error(e),
        }
    }

    fn fsync(
        &self,
        _req: &Request,
        _ino: INodeNo,
        fh: FileHandle,
        _datasync: bool,
        reply: ReplyEmpty,
    ) {
        match self.flush_handle(fh.0) {
            Ok(()) => reply.ok(),
            Err(e) => reply.error(e),
        }
    }

    fn release(
        &self,
        _req: &Request,
        _ino: INodeNo,
        fh: FileHandle,
        _flags: OpenFlags,
        _lock_owner: Option<LockOwner>,
        _flush: bool,
        reply: ReplyEmpty,
    ) {
        // Luôn bỏ handle; lỗi đẩy lên máy gửi được báo qua close() của tiến trình
        let result = self.flush_handle(fh.0);
        lock(&self.handles).remove(&fh.0);
        match result {
            Ok(()) => reply.ok(),
            Err(e) => reply.error(e),
        }
    }

    fn readdir(
        &self,
        _req: &Request,
        ino: INodeNo,
        _fh: FileHandle,
        offset: u64,
        mut reply: ReplyDirectory,
    ) {
        let rel = match self.rel_of(ino) {
            Ok(rel) => rel,
            Err(e) => return reply.error(e),
        };
        let entries = match self.remote.list(&rel) {
            Ok(entries) => entries,
            Err(e) => return reply.error(e),
        };
        let mut all: Vec<(u64, FileType, String)> = Vec::with_capacity(entries.len() + 2);
        {
            let mut inodes = lock(&self.inodes);
            all.push((ino.0, FileType::Directory, ".".to_string()));
            let parent_ino = inodes.ino_for(&parent_of(&rel));
            all.push((parent_ino, FileType::Directory, "..".to_string()));
            for e in &entries {
                let Some(name) = e["name"].as_str() else {
                    continue;
                };
                let kind = if e["isDir"].as_bool().unwrap_or(false) {
                    FileType::Directory
                } else {
                    FileType::RegularFile
                };
                let child = inodes.ino_for(&join(&rel, name));
                all.push((child, kind, name.to_string()));
            }
        }
        for (i, (child, kind, name)) in all.iter().enumerate().skip(offset as usize) {
            // Offset kế tiếp là vị trí sau entry này
            if reply.add(INodeNo(*child), (i + 1) as u64, *kind, name) {
                break;
            }
        }
        reply.ok();
    }

    fn create(
        &self,
        _req: &Request,
        parent: INodeNo,
        name: &OsStr,
        _mode: u32,
        _umask: u32,
        _flags: i32,
        _kill: bool,
        _owner: fuser::Owner,
        reply: ReplyCreate,
    ) {
        let rel = match self.child_rel(parent, name) {
            Ok(rel) => rel,
            Err(e) => return reply.error(e),
        };
        if let Err(e) = self.remote.write(&rel, Vec::new()) {
            return reply.error(e);
        }
        let attr = match self.attr_by_rel(&rel) {
            Ok(attr) => attr,
            Err(e) => return reply.error(e),
        };
        let fh = self.insert_handle(rel, Some(Vec::new()), false);
        reply.created(
            &TTL,
            &attr,
            Generation(0),
            FileHandle(fh),
            FopenFlags::empty(),
        );
    }

    fn access(&self, _req: &Request, _ino: INodeNo, _mask: fuser::AccessFlags, reply: ReplyEmpty) {
        reply.ok();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn joins_and_takes_parents() {
        assert_eq!(join("", "a.txt"), "a.txt");
        assert_eq!(join("lib", "a.dart"), "lib/a.dart");
        assert_eq!(parent_of("lib/src/a.dart"), "lib/src");
        assert_eq!(parent_of("a.txt"), "");
    }

    #[test]
    fn slices_buffer_within_bounds() {
        let buf = b"hello";
        assert_eq!(slice_of(buf, 1, 3), b"ell".to_vec());
        assert_eq!(slice_of(buf, 3, 100), b"lo".to_vec());
        assert!(slice_of(buf, 9, 4).is_empty());
    }
}
