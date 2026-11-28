//! API đọc/ghi file cho máy phụ qua mạng (không cần SSH key). Máy nhận dùng API này để mount project
//! qua FUSE (`server/src/fsmount/`).
//!
//! Quy tắc phạm vi: mọi đường dẫn phải là tuyệt đối, không có `..`, và sau khi giải symlink
//! phải nằm trong `ECOSYSTEM_DIR_PATH`. Symlink trỏ ra ngoài bị từ chối. Khi xóa hoặc đổi tên,
//! chính symlink được xử lý, không theo vào đích.

use axum::{
    body::{Body, Bytes},
    extract::Query,
    http::{header, StatusCode},
    response::{IntoResponse, Response},
    Json,
};
use serde::Deserialize;
use serde_json::{json, Value};
use std::fs;
use std::io::{Read, Seek, SeekFrom, Write};
use std::os::unix::fs::PermissionsExt;
use std::path::{Component, Path, PathBuf};
use std::time::UNIX_EPOCH;

/// Giới hạn mỗi lần đọc qua API (byte)
const MAX_READ_CHUNK: u64 = 16 * 1024 * 1024;
/// Kích thước tối đa của file sau khi ghi theo đoạn (khớp giới hạn của máy nhận)
const MAX_PATCH_BYTES: u64 = 512 * 1024 * 1024;

#[derive(Debug)]
pub enum FsErr {
    Invalid(String),
    OutsideRoot,
    NotFound,
    Exists,
    NotEmpty,
    IsDir,
    NotDir,
    Io(String),
}

impl FsErr {
    fn code(&self) -> &'static str {
        match self {
            FsErr::Invalid(_) => "invalid",
            FsErr::OutsideRoot => "outside_root",
            FsErr::NotFound => "not_found",
            FsErr::Exists => "exists",
            FsErr::NotEmpty => "not_empty",
            FsErr::IsDir => "is_dir",
            FsErr::NotDir => "not_dir",
            FsErr::Io(_) => "io",
        }
    }

    fn status(&self) -> StatusCode {
        match self {
            FsErr::Invalid(_) | FsErr::IsDir | FsErr::NotDir => StatusCode::BAD_REQUEST,
            FsErr::OutsideRoot => StatusCode::FORBIDDEN,
            FsErr::NotFound => StatusCode::NOT_FOUND,
            FsErr::Exists | FsErr::NotEmpty => StatusCode::CONFLICT,
            FsErr::Io(_) => StatusCode::INTERNAL_SERVER_ERROR,
        }
    }

    fn message(&self) -> String {
        match self {
            FsErr::Invalid(m) | FsErr::Io(m) => m.clone(),
            FsErr::OutsideRoot => "đường dẫn nằm ngoài thư mục được phép".into(),
            FsErr::NotFound => "không tìm thấy".into(),
            FsErr::Exists => "đã tồn tại".into(),
            FsErr::NotEmpty => "thư mục chưa rỗng (dùng recursive=true để xóa cả nội dung)".into(),
            FsErr::IsDir => "đây là thư mục, không phải tệp".into(),
            FsErr::NotDir => "không phải thư mục".into(),
        }
    }

    fn response(&self) -> Response {
        (
            self.status(),
            Json(json!({ "ok": false, "code": self.code(), "error": self.message() })),
        )
            .into_response()
    }
}

fn io_err(e: std::io::Error) -> FsErr {
    match e.kind() {
        std::io::ErrorKind::NotFound => FsErr::NotFound,
        std::io::ErrorKind::AlreadyExists => FsErr::Exists,
        std::io::ErrorKind::DirectoryNotEmpty => FsErr::NotEmpty,
        _ => FsErr::Io(e.to_string()),
    }
}

/// Thư mục project đã cấu hình khi khởi tạo; chưa có thì mọi thao tác file bị từ chối
fn root() -> Result<PathBuf, FsErr> {
    crate::setup::workspace_root().ok_or_else(|| {
        FsErr::Invalid("Chưa khởi tạo thư mục project (mở Cài đặt → Thư mục project)".into())
    })
}

fn canonical_root(root: &Path) -> Result<PathBuf, FsErr> {
    root.canonicalize().map_err(io_err)
}

/// Đường dẫn phải tuyệt đối và không chứa `..`
fn absolute(raw: &str) -> Result<PathBuf, FsErr> {
    let p = Path::new(raw.trim());
    if !p.is_absolute() {
        return Err(FsErr::Invalid("đường dẫn phải là tuyệt đối".into()));
    }
    if p.components().any(|c| matches!(c, Component::ParentDir)) {
        return Err(FsErr::OutsideRoot);
    }
    Ok(p.to_path_buf())
}

/// Đường dẫn đã tồn tại, sau khi giải symlink phải nằm trong thư mục gốc
fn resolve_existing(root: &Path, raw: &str) -> Result<PathBuf, FsErr> {
    let p = absolute(raw)?.canonicalize().map_err(io_err)?;
    if !p.starts_with(canonical_root(root)?) {
        return Err(FsErr::OutsideRoot);
    }
    Ok(p)
}

/// Mục con có thể chưa tồn tại hoặc là symlink: giải thư mục cha (phải nằm trong gốc), giữ nguyên tên
fn resolve_child(root: &Path, raw: &str) -> Result<PathBuf, FsErr> {
    let p = absolute(raw)?;
    let name = p
        .file_name()
        .ok_or_else(|| FsErr::Invalid("thiếu tên mục".into()))?
        .to_owned();
    let parent = p
        .parent()
        .ok_or_else(|| FsErr::Invalid("đường dẫn không hợp lệ".into()))?;
    let parent_canon = resolve_existing(root, &parent.to_string_lossy())?;
    if !parent_canon.is_dir() {
        return Err(FsErr::NotDir);
    }
    Ok(parent_canon.join(name))
}

fn meta_json(name: &str, m: &fs::Metadata) -> Value {
    let mtime = m
        .modified()
        .ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_secs())
        .unwrap_or(0);
    json!({
        "name": name,
        "isDir": m.is_dir(),
        "size": m.len(),
        "mtime": mtime,
        "mode": m.permissions().mode() & 0o7777,
    })
}

pub fn op_stat(root: &Path, raw: &str) -> Result<Value, FsErr> {
    let p = resolve_existing(root, raw)?;
    let m = fs::metadata(&p).map_err(io_err)?;
    let name = p
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_default();
    let mut v = meta_json(&name, &m);
    v["ok"] = json!(true);
    v["path"] = json!(p.to_string_lossy());
    Ok(v)
}

pub fn op_list(root: &Path, raw: &str) -> Result<Value, FsErr> {
    let dir = resolve_existing(root, raw)?;
    if !dir.is_dir() {
        return Err(FsErr::NotDir);
    }
    let mut entries = Vec::new();
    for entry in fs::read_dir(&dir).map_err(io_err)? {
        let entry = entry.map_err(io_err)?;
        // Symlink hỏng hoặc không đọc được metadata: bỏ qua, không làm hỏng cả thư mục
        let Ok(m) = fs::metadata(entry.path()) else {
            continue;
        };
        entries.push(meta_json(&entry.file_name().to_string_lossy(), &m));
    }
    entries.sort_by(|a, b| a["name"].as_str().cmp(&b["name"].as_str()));
    Ok(json!({
        "ok": true,
        "path": dir.to_string_lossy(),
        "entries": entries,
    }))
}

/// Đọc một đoạn tệp. Trả về (nội dung, kích thước tệp, đã tới cuối tệp chưa).
pub fn op_read(
    root: &Path,
    raw: &str,
    offset: u64,
    length: u64,
) -> Result<(Vec<u8>, u64, bool), FsErr> {
    let p = resolve_existing(root, raw)?;
    let mut f = fs::File::open(&p).map_err(io_err)?;
    let meta = f.metadata().map_err(io_err)?;
    if meta.is_dir() {
        return Err(FsErr::IsDir);
    }
    let size = meta.len();
    let want = length.min(MAX_READ_CHUNK).min(size.saturating_sub(offset));
    let mut buf = vec![0u8; want as usize];
    if want > 0 {
        f.seek(SeekFrom::Start(offset)).map_err(io_err)?;
        f.read_exact(&mut buf).map_err(io_err)?;
    }
    let eof = offset.saturating_add(want) >= size;
    Ok((buf, size, eof))
}

/// Ghi toàn bộ nội dung tệp (tạo mới hoặc ghi đè). Ghi vào tệp tạm rồi đổi tên, giữ quyền truy cập cũ.
pub fn op_write(root: &Path, raw: &str, data: &[u8]) -> Result<Value, FsErr> {
    let target = match resolve_existing(root, raw) {
        Ok(p) => {
            if p.is_dir() {
                return Err(FsErr::IsDir);
            }
            p
        }
        Err(FsErr::NotFound) => resolve_child(root, raw)?,
        Err(e) => return Err(e),
    };
    let parent = target
        .parent()
        .ok_or_else(|| FsErr::Invalid("đường dẫn không hợp lệ".into()))?;
    let name = target
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_default();
    let existing_mode = fs::metadata(&target)
        .ok()
        .map(|m| m.permissions().mode() & 0o7777);
    let tmp = parent.join(format!(".{}.muopfs-tmp-{}", name, std::process::id()));
    let result = (|| -> Result<(), FsErr> {
        fs::write(&tmp, data).map_err(io_err)?;
        let mode = existing_mode.unwrap_or(0o644);
        fs::set_permissions(&tmp, fs::Permissions::from_mode(mode)).map_err(io_err)?;
        fs::rename(&tmp, &target).map_err(io_err)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&tmp);
    }
    result?;
    Ok(json!({ "ok": true, "path": target.to_string_lossy(), "size": data.len() }))
}

pub fn op_mkdir(root: &Path, raw: &str) -> Result<Value, FsErr> {
    let p = resolve_child(root, raw)?;
    if fs::symlink_metadata(&p).is_ok() {
        return Err(FsErr::Exists);
    }
    fs::create_dir(&p).map_err(io_err)?;
    Ok(json!({ "ok": true, "path": p.to_string_lossy() }))
}

/// Xóa một mục. Symlink bị xóa chính nó, không xóa đích của nó.
pub fn op_delete(root: &Path, raw: &str, recursive: bool) -> Result<Value, FsErr> {
    let p = resolve_child(root, raw)?;
    let meta = fs::symlink_metadata(&p).map_err(io_err)?;
    if meta.is_dir() {
        if recursive {
            fs::remove_dir_all(&p).map_err(io_err)?;
        } else {
            fs::remove_dir(&p).map_err(io_err)?;
        }
    } else {
        fs::remove_file(&p).map_err(io_err)?;
    }
    Ok(json!({ "ok": true, "path": p.to_string_lossy() }))
}

/// Đổi tên/di chuyển. `overwrite`: thay thế đích nếu đích là tệp hoặc symlink (đúng ngữ nghĩa POSIX
/// `rename`, dùng khi sed -i hay editor ghi tệp tạm rồi đổi tên đè). Đích là thư mục thì luôn từ chối.
pub fn op_rename(root: &Path, from: &str, to: &str, overwrite: bool) -> Result<Value, FsErr> {
    let src = resolve_child(root, from)?;
    fs::symlink_metadata(&src).map_err(io_err)?;
    let dst = resolve_child(root, to)?;
    if let Ok(existing) = fs::symlink_metadata(&dst) {
        if !overwrite || existing.is_dir() {
            return Err(FsErr::Exists);
        }
    }
    fs::rename(&src, &dst).map_err(io_err)?;
    Ok(json!({ "ok": true, "from": src.to_string_lossy(), "to": dst.to_string_lossy() }))
}

// ───── HTTP ─────

#[derive(Deserialize)]
pub struct PathQuery {
    pub path: Option<String>,
}

#[derive(Deserialize)]
pub struct ReadQuery {
    pub path: Option<String>,
    pub offset: Option<u64>,
    pub length: Option<u64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MkdirRequest {
    pub path: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeleteRequest {
    pub path: String,
    #[serde(default)]
    pub recursive: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RenameRequest {
    pub from: String,
    pub to: String,
    #[serde(default)]
    pub overwrite: bool,
}

fn required(path: Option<String>) -> Result<String, FsErr> {
    path.map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .ok_or_else(|| FsErr::Invalid("thiếu tham số path".into()))
}

async fn run_json<F>(f: F) -> Response
where
    F: FnOnce() -> Result<Value, FsErr> + Send + 'static,
{
    match tokio::task::spawn_blocking(f).await {
        Ok(Ok(v)) => (StatusCode::OK, Json(v)).into_response(),
        Ok(Err(e)) => e.response(),
        Err(_) => FsErr::Io("tác vụ đọc/ghi file thất bại".into()).response(),
    }
}

/// GET /api/fs/stat?path=
pub async fn handle_stat(Query(q): Query<PathQuery>) -> Response {
    let raw = match required(q.path) {
        Ok(r) => r,
        Err(e) => return e.response(),
    };
    run_json(move || op_stat(&root()?, &raw)).await
}

/// GET /api/fs/list?path=
pub async fn handle_list(Query(q): Query<PathQuery>) -> Response {
    let raw = match required(q.path) {
        Ok(r) => r,
        Err(e) => return e.response(),
    };
    run_json(move || op_list(&root()?, &raw)).await
}

/// GET /api/fs/read?path=&offset=&length=  → nội dung nhị phân, kèm X-Fs-Size và X-Fs-Eof
pub async fn handle_read(Query(q): Query<ReadQuery>) -> Response {
    let raw = match required(q.path) {
        Ok(r) => r,
        Err(e) => return e.response(),
    };
    let offset = q.offset.unwrap_or(0);
    let length = q.length.unwrap_or(MAX_READ_CHUNK);
    match tokio::task::spawn_blocking(move || op_read(&root()?, &raw, offset, length)).await {
        Ok(Ok((buf, size, eof))) => Response::builder()
            .header(header::CONTENT_TYPE, "application/octet-stream")
            .header("X-Fs-Size", size.to_string())
            .header("X-Fs-Eof", if eof { "true" } else { "false" })
            .body(Body::from(buf))
            .unwrap_or_else(|_| StatusCode::INTERNAL_SERVER_ERROR.into_response()),
        Ok(Err(e)) => e.response(),
        Err(_) => FsErr::Io("tác vụ đọc file thất bại".into()).response(),
    }
}

/// PUT /api/fs/write?path=  body = nội dung tệp (nhị phân)
pub async fn handle_write(Query(q): Query<PathQuery>, body: Bytes) -> Response {
    let raw = match required(q.path) {
        Ok(r) => r,
        Err(e) => return e.response(),
    };
    run_json(move || op_write(&root()?, &raw, &body[..])).await
}

#[derive(Deserialize)]
pub struct PatchQuery {
    pub path: Option<String>,
    pub truncate: Option<u64>,
}

/// PUT /api/fs/patch?path=&truncate=  body = các khung ghi (xem `parse_patch_frames`)
pub async fn handle_patch(Query(q): Query<PatchQuery>, body: Bytes) -> Response {
    let raw = match required(q.path) {
        Ok(r) => r,
        Err(e) => return e.response(),
    };
    let writes = match parse_patch_frames(&body) {
        Ok(w) => w,
        Err(e) => return e.response(),
    };
    let truncate = q.truncate;
    run_json(move || op_patch(&root()?, &raw, truncate, &writes)).await
}

/// POST /api/fs/mkdir {path}
pub async fn handle_mkdir(Json(req): Json<MkdirRequest>) -> Response {
    run_json(move || op_mkdir(&root()?, &req.path)).await
}

/// POST /api/fs/delete {path, recursive}
pub async fn handle_delete(Json(req): Json<DeleteRequest>) -> Response {
    run_json(move || op_delete(&root()?, &req.path, req.recursive)).await
}

/// POST /api/fs/rename {from, to}
pub async fn handle_rename(Json(req): Json<RenameRequest>) -> Response {
    run_json(move || op_rename(&root()?, &req.from, &req.to, req.overwrite)).await
}

/// Đọc các đoạn ghi từ body: mỗi đoạn là `offset` (u64 LE), `length` (u32 LE), rồi dữ liệu.
pub fn parse_patch_frames(body: &[u8]) -> Result<Vec<(u64, Vec<u8>)>, FsErr> {
    let mut out = Vec::new();
    let mut i = 0usize;
    while i < body.len() {
        if body.len() - i < 12 {
            return Err(FsErr::Invalid("khung ghi bị cắt cụt".into()));
        }
        let mut off = [0u8; 8];
        off.copy_from_slice(&body[i..i + 8]);
        let mut len = [0u8; 4];
        len.copy_from_slice(&body[i + 8..i + 12]);
        let len = u32::from_le_bytes(len) as usize;
        i += 12;
        if body.len() - i < len {
            return Err(FsErr::Invalid("khung ghi bị cắt cụt".into()));
        }
        out.push((u64::from_le_bytes(off), body[i..i + len].to_vec()));
        i += len;
    }
    Ok(out)
}

/// Ghi từng đoạn vào file ngay tại chỗ (không ghi lại cả file). `truncate` đặt kích thước trước khi ghi.
/// File chưa có thì được tạo. Khác `op_write`: giữ nguyên inode và quyền của file đang có.
pub fn op_patch(
    root: &Path,
    raw: &str,
    truncate: Option<u64>,
    writes: &[(u64, Vec<u8>)],
) -> Result<Value, FsErr> {
    let target = match resolve_existing(root, raw) {
        Ok(p) => {
            if p.is_dir() {
                return Err(FsErr::IsDir);
            }
            p
        }
        Err(FsErr::NotFound) => resolve_child(root, raw)?,
        Err(e) => return Err(e),
    };
    if truncate.is_some_and(|t| t > MAX_PATCH_BYTES) {
        return Err(FsErr::Invalid("kích thước vượt giới hạn 512MB".into()));
    }
    for (off, data) in writes {
        let end = off.checked_add(data.len() as u64).unwrap_or(u64::MAX);
        if end > MAX_PATCH_BYTES {
            return Err(FsErr::Invalid("kích thước vượt giới hạn 512MB".into()));
        }
    }
    let mut f = fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(&target)
        .map_err(io_err)?;
    if let Some(t) = truncate {
        f.set_len(t).map_err(io_err)?;
    }
    for (off, data) in writes {
        f.seek(SeekFrom::Start(*off)).map_err(io_err)?;
        f.write_all(data).map_err(io_err)?;
    }
    let size = f.metadata().map(|m| m.len()).unwrap_or(0);
    Ok(json!({ "ok": true, "size": size }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;

    /// Thư mục tạm riêng cho mỗi test (root giả lập)
    fn temp_root(tag: &str) -> PathBuf {
        let nanos = std::time::SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = std::env::temp_dir().join(format!("muopfs-{tag}-{}-{nanos}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn patch_writes_in_place_and_keeps_size_rules() {
        let root = temp_root("patch");
        let file = root.join("a.bin");
        fs::write(&file, b"0123456789").unwrap();
        let path = file.to_string_lossy().to_string();
        // Ghi đè giữa file, rồi ghi nối đuôi (mở rộng file)
        op_patch(
            &root,
            &path,
            None,
            &[(2, b"AB".to_vec()), (10, b"XYZ".to_vec())],
        )
        .unwrap();
        assert_eq!(fs::read(&file).unwrap(), b"01AB456789XYZ");
        // Cắt bớt trước khi ghi
        op_patch(&root, &path, Some(4), &[(0, b"zz".to_vec())]).unwrap();
        assert_eq!(fs::read(&file).unwrap(), b"zzAB");
        // File chưa có được tạo
        let fresh = root.join("new.txt");
        op_patch(
            &root,
            &fresh.to_string_lossy(),
            Some(0),
            &[(0, b"hi".to_vec())],
        )
        .unwrap();
        assert_eq!(fs::read(&fresh).unwrap(), b"hi");
        // Vượt giới hạn bị từ chối
        assert!(op_patch(&root, &path, None, &[(MAX_PATCH_BYTES, vec![0])]).is_err());
        fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn patch_frames_round_trip_and_reject_truncated_body() {
        let mut body = Vec::new();
        for (off, data) in [(5u64, b"abc".to_vec()), (0u64, b"Z".to_vec())] {
            body.extend_from_slice(&off.to_le_bytes());
            body.extend_from_slice(&(data.len() as u32).to_le_bytes());
            body.extend_from_slice(&data);
        }
        let frames = parse_patch_frames(&body).unwrap();
        assert_eq!(frames, vec![(5, b"abc".to_vec()), (0, b"Z".to_vec())]);
        assert!(parse_patch_frames(&body[..body.len() - 1]).is_err());
        assert!(parse_patch_frames(&body[..5]).is_err());
    }

    #[test]
    fn rejects_relative_paths_and_parent_segments() {
        let root = temp_root("abs");
        assert!(matches!(
            op_stat(&root, "relative.txt"),
            Err(FsErr::Invalid(_))
        ));
        let escape = format!("{}/../etc", root.display());
        assert!(matches!(op_stat(&root, &escape), Err(FsErr::OutsideRoot)));
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn write_then_read_round_trip_and_range_read() {
        let root = temp_root("rw");
        let file = format!("{}/a.txt", root.display());
        op_write(&root, &file, b"hello world").unwrap();
        let (buf, size, eof) = op_read(&root, &file, 0, 1024).unwrap();
        assert_eq!(buf, b"hello world");
        assert_eq!(size, 11);
        assert!(eof);
        let (part, _, eof2) = op_read(&root, &file, 6, 3).unwrap();
        assert_eq!(part, b"wor");
        assert!(!eof2);
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn overwrite_keeps_existing_permissions() {
        let root = temp_root("mode");
        let file = format!("{}/run.sh", root.display());
        op_write(&root, &file, b"v1").unwrap();
        fs::set_permissions(&file, fs::Permissions::from_mode(0o600)).unwrap();
        op_write(&root, &file, b"v2 edited").unwrap();
        let mode = fs::metadata(&file).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
        assert_eq!(fs::read(&file).unwrap(), b"v2 edited");
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn write_refuses_missing_parent_directory() {
        let root = temp_root("noparent");
        let file = format!("{}/missing/a.txt", root.display());
        assert!(matches!(op_write(&root, &file, b"x"), Err(FsErr::NotFound)));
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn symlink_pointing_outside_root_is_refused() {
        let root = temp_root("link-out");
        let outside = temp_root("outside");
        fs::write(outside.join("secret.txt"), b"secret").unwrap();
        symlink(&outside, root.join("ext")).unwrap();
        let through = format!("{}/ext/secret.txt", root.display());
        assert!(matches!(
            op_read(&root, &through, 0, 10),
            Err(FsErr::OutsideRoot)
        ));
        assert!(matches!(
            op_write(&root, &through, b"x"),
            Err(FsErr::OutsideRoot)
        ));
        let _ = fs::remove_dir_all(&root);
        let _ = fs::remove_dir_all(&outside);
    }

    #[test]
    fn delete_removes_the_symlink_not_its_target() {
        let root = temp_root("del-link");
        let target = temp_root("del-target");
        fs::write(target.join("keep.txt"), b"keep").unwrap();
        let link = root.join("link");
        symlink(target.join("keep.txt"), &link).unwrap();
        op_delete(&root, &format!("{}/link", root.display()), false).unwrap();
        assert!(fs::symlink_metadata(&link).is_err());
        assert_eq!(fs::read(target.join("keep.txt")).unwrap(), b"keep");
        let _ = fs::remove_dir_all(&root);
        let _ = fs::remove_dir_all(&target);
    }

    #[test]
    fn non_empty_directory_needs_recursive_flag() {
        let root = temp_root("nonempty");
        let dir = root.join("d");
        fs::create_dir(&dir).unwrap();
        fs::write(dir.join("f.txt"), b"x").unwrap();
        let path = format!("{}/d", root.display());
        assert!(matches!(
            op_delete(&root, &path, false),
            Err(FsErr::NotEmpty)
        ));
        op_delete(&root, &path, true).unwrap();
        assert!(!dir.exists());
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn rename_refuses_to_overwrite_and_moves_inside_root() {
        let root = temp_root("rename");
        fs::write(root.join("a.txt"), b"a").unwrap();
        fs::write(root.join("b.txt"), b"b").unwrap();
        let a = format!("{}/a.txt", root.display());
        let b = format!("{}/b.txt", root.display());
        let c = format!("{}/c.txt", root.display());
        assert!(matches!(
            op_rename(&root, &a, &b, false),
            Err(FsErr::Exists)
        ));
        op_rename(&root, &a, &c, false).unwrap();
        assert!(!root.join("a.txt").exists());
        assert_eq!(fs::read(root.join("c.txt")).unwrap(), b"a");
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn rename_overwrite_replaces_file_but_never_a_directory() {
        let root = temp_root("rename-ow");
        fs::write(root.join("tmp.txt"), b"new").unwrap();
        fs::write(root.join("target.txt"), b"old").unwrap();
        fs::create_dir(root.join("adir")).unwrap();
        let tmp = format!("{}/tmp.txt", root.display());
        let target = format!("{}/target.txt", root.display());
        let adir = format!("{}/adir", root.display());
        op_rename(&root, &tmp, &target, true).unwrap();
        assert_eq!(fs::read(root.join("target.txt")).unwrap(), b"new");
        assert!(!root.join("tmp.txt").exists());
        fs::write(root.join("again.txt"), b"x").unwrap();
        let again = format!("{}/again.txt", root.display());
        assert!(matches!(
            op_rename(&root, &again, &adir, true),
            Err(FsErr::Exists)
        ));
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn mkdir_and_list_show_entries_sorted() {
        let root = temp_root("list");
        op_mkdir(&root, &format!("{}/zeta", root.display())).unwrap();
        fs::write(root.join("alpha.txt"), b"1").unwrap();
        let v = op_list(&root, &root.to_string_lossy()).unwrap();
        let names: Vec<&str> = v["entries"]
            .as_array()
            .unwrap()
            .iter()
            .map(|e| e["name"].as_str().unwrap())
            .collect();
        assert_eq!(names, vec!["alpha.txt", "zeta"]);
        assert_eq!(v["entries"][1]["isDir"], json!(true));
        let _ = fs::remove_dir_all(&root);
    }
}
