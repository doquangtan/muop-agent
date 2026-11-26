//! SFTP trên chính máy này ("Máy này"): thao tác trực tiếp trên hệ thống file, với quyền của user chạy server.
//! Không qua ssh nên không cần sshd; các thao tác trả về cùng kiểu dữ liệu với đường SSH.

use super::listing::{sort_entries, RemoteEntry};
use super::MAX_READ_BYTES;
use chrono::{DateTime, Local};
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::os::unix::fs::{FileTypeExt, MetadataExt};
use std::time::SystemTime;

/// Thông báo lỗi I/O bằng tiếng Việt
pub fn io_message(e: &std::io::Error) -> String {
    match e.kind() {
        std::io::ErrorKind::NotFound => "Không tìm thấy đường dẫn".into(),
        std::io::ErrorKind::PermissionDenied => "Không đủ quyền trên máy đích".into(),
        std::io::ErrorKind::AlreadyExists => "Đã tồn tại".into(),
        _ => e.to_string(),
    }
}

/// Thời điểm kiểu `ls -l`: giờ trong nửa năm gần đây, năm với mục cũ hơn
fn format_time(t: Option<SystemTime>) -> String {
    let Some(t) = t else {
        return String::new();
    };
    let dt: DateTime<Local> = t.into();
    let age_days = (Local::now() - dt).num_days().abs();
    if age_days < 182 {
        dt.format("%b %e %H:%M").to_string()
    } else {
        dt.format("%b %e  %Y").to_string()
    }
}

/// Chuỗi quyền kiểu `ls`: ký tự loại + rwx ba nhóm
fn mode_string(kind: char, mode: u32) -> String {
    let mut s = String::with_capacity(10);
    s.push(kind);
    for shift in [6u32, 3, 0] {
        let bits = (mode >> shift) & 0o7;
        s.push(if bits & 4 != 0 { 'r' } else { '-' });
        s.push(if bits & 2 != 0 { 'w' } else { '-' });
        s.push(if bits & 1 != 0 { 'x' } else { '-' });
    }
    s
}

/// Liệt kê thư mục. Liên kết hỏng vẫn hiện (lấy thông tin của chính liên kết).
pub fn list(path: &str) -> Result<Vec<RemoteEntry>, String> {
    let rd = fs::read_dir(path).map_err(|e| io_message(&e))?;
    let mut out = Vec::new();
    for ent in rd.flatten() {
        let name = ent.file_name().to_string_lossy().into_owned();
        let p = ent.path();
        let Ok(lmeta) = fs::symlink_metadata(&p) else {
            continue;
        };
        let is_link = lmeta.file_type().is_symlink();
        let meta = if is_link {
            fs::metadata(&p).unwrap_or_else(|_| lmeta.clone())
        } else {
            lmeta.clone()
        };
        let is_dir = !is_link && meta.is_dir();
        let kind = if is_link {
            'l'
        } else if meta.is_dir() {
            'd'
        } else if meta.file_type().is_fifo()
            || meta.file_type().is_socket()
            || meta.file_type().is_char_device()
            || meta.file_type().is_block_device()
        {
            's'
        } else {
            '-'
        };
        out.push(RemoteEntry {
            name,
            is_dir,
            is_link,
            size: meta.len(),
            modified: format_time(meta.modified().ok()),
            mode: mode_string(kind, lmeta.mode()),
            modified_unix: meta
                .modified()
                .ok()
                .and_then(|t| t.duration_since(SystemTime::UNIX_EPOCH).ok())
                .map(|d| d.as_secs() as i64),
        });
    }
    sort_entries(&mut out);
    Ok(out)
}

pub fn mkdir(path: &str) -> Result<(), String> {
    fs::create_dir(path).map_err(|e| io_message(&e))
}

pub fn rename(from: &str, to: &str) -> Result<(), String> {
    fs::rename(from, to).map_err(|e| io_message(&e))
}

/// Xóa file, hoặc thư mục và toàn bộ nội dung. Không đi theo liên kết mềm.
pub fn delete(path: &str, is_dir: bool) -> Result<(), String> {
    let res = if is_dir {
        fs::remove_dir_all(path)
    } else {
        fs::remove_file(path)
    };
    res.map_err(|e| io_message(&e))
}

/// Ghi file. Không ghi đè khi `overwrite` = false và đã có file.
pub fn write(path: &str, data: &[u8], overwrite: bool) -> Result<(), String> {
    let mut file = OpenOptions::new()
        .write(true)
        .create(overwrite)
        .create_new(!overwrite)
        .truncate(true)
        .open(path)
        .map_err(|e| io_message(&e))?;
    file.write_all(data).map_err(|e| io_message(&e))
}

/// Đọc file để sửa trong app (giới hạn [`MAX_READ_BYTES`]). Trả về (nội dung, nhị phân?).
pub fn read(path: &str) -> Result<(Vec<u8>, bool), String> {
    let meta = fs::metadata(path).map_err(|e| io_message(&e))?;
    if meta.is_dir() {
        return Err("Đây là thư mục, không mở để sửa được".into());
    }
    if meta.len() > MAX_READ_BYTES {
        return Err("File quá lớn để sửa (tối đa 1MB)".into());
    }
    let bytes = fs::read(path).map_err(|e| io_message(&e))?;
    let binary = bytes.contains(&0) || std::str::from_utf8(&bytes).is_err();
    Ok((bytes, binary))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn list_reports_modified_time_and_hides_nothing_here() {
        let dir = std::env::temp_dir().join(format!("muop-local-test-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("a.txt"), b"hi").unwrap();
        fs::write(dir.join(".env"), b"x").unwrap();
        let items = list(dir.to_str().unwrap()).unwrap();
        let a = items.iter().find(|e| e.name == "a.txt").unwrap();
        assert!(a.modified_unix.unwrap() > 1_600_000_000);
        assert_eq!(a.size, 2);
        // Lọc file ẩn là việc của app, server trả đủ mục
        assert!(items.iter().any(|e| e.name == ".env"));
        fs::remove_dir_all(&dir).ok();
    }
}
