//! Duyệt thư mục trên máy server để chọn thư mục project trong màn Khởi tạo (cây thư mục, chỉ hiện thư mục).
//!
//! Chỉ liệt kê tên và đường dẫn thư mục con, không đọc nội dung file. Thư mục ẩn (tên bắt đầu bằng `.`)
//! không hiện để cây gọn. Bắt đầu từ thư mục home của user chạy server khi không truyền đường dẫn.

use crate::infra::paths::home_dir;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BrowseRequest {
    /// Thư mục cần xem; rỗng nghĩa là thư mục home
    #[serde(default)]
    pub path: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DirEntry {
    pub name: String,
    pub path: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DirListing {
    pub ok: bool,
    pub error: String,
    /// Thư mục đang xem (đường dẫn tuyệt đối, đã chuẩn hóa)
    pub path: String,
    /// Thư mục cha; rỗng khi đang ở thư mục gốc
    pub parent: String,
    /// Thư mục home của user chạy server (điểm bắt đầu mặc định)
    pub home: String,
    /// Các thư mục con, sắp xếp theo tên không phân biệt hoa thường
    pub dirs: Vec<DirEntry>,
}

fn failure(error: impl Into<String>, path: &str, home: &str) -> DirListing {
    DirListing {
        ok: false,
        error: error.into(),
        path: path.to_string(),
        parent: String::new(),
        home: home.to_string(),
        dirs: Vec::new(),
    }
}

/// Liệt kê thư mục con của [raw] (hoặc home nếu rỗng)
pub fn list_dirs(raw: &str) -> DirListing {
    let home = home_dir().to_string_lossy().into_owned();
    let trimmed = raw.trim();
    let target = if trimmed.is_empty() {
        PathBuf::from(&home)
    } else {
        PathBuf::from(trimmed)
    };
    if !target.is_absolute() {
        return failure("Đường dẫn phải là đường dẫn tuyệt đối", trimmed, &home);
    }
    let canonical = match target.canonicalize() {
        Ok(p) => p,
        Err(e) => return failure(format!("Không mở được thư mục: {e}"), trimmed, &home),
    };
    if !canonical.is_dir() {
        return failure("Đường dẫn không phải là thư mục", trimmed, &home);
    }
    let read = match std::fs::read_dir(&canonical) {
        Ok(r) => r,
        Err(e) => {
            return failure(
                format!("Không đọc được thư mục: {e}"),
                &canonical.to_string_lossy(),
                &home,
            )
        }
    };
    let mut dirs: Vec<DirEntry> = read
        .filter_map(|entry| entry.ok())
        .filter(|entry| entry.path().is_dir())
        .filter_map(|entry| {
            let name = entry.file_name().to_string_lossy().into_owned();
            if name.starts_with('.') {
                return None;
            }
            Some(DirEntry {
                name,
                path: entry.path().to_string_lossy().into_owned(),
            })
        })
        .collect();
    dirs.sort_by_key(|d| d.name.to_lowercase());
    DirListing {
        ok: true,
        error: String::new(),
        path: canonical.to_string_lossy().into_owned(),
        parent: canonical
            .parent()
            .map(|p| p.to_string_lossy().into_owned())
            .unwrap_or_default(),
        home,
        dirs,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Thư mục tạm riêng cho mỗi test (không cần thêm crate tempfile)
    fn temp_root(tag: &str) -> PathBuf {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        let dir =
            std::env::temp_dir().join(format!("muop-browse-{tag}-{}-{nanos}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn lists_only_visible_directories_sorted() {
        let root = temp_root("sort");
        std::fs::create_dir(root.join("beta")).unwrap();
        std::fs::create_dir(root.join("Alpha")).unwrap();
        std::fs::create_dir(root.join(".hidden")).unwrap();
        std::fs::write(root.join("file.txt"), b"x").unwrap();

        let listing = list_dirs(&root.to_string_lossy());
        assert!(listing.ok, "{}", listing.error);
        let names: Vec<&str> = listing.dirs.iter().map(|d| d.name.as_str()).collect();
        assert_eq!(names, vec!["Alpha", "beta"]);
        assert_eq!(listing.path, root.canonicalize().unwrap().to_string_lossy());
        assert!(!listing.parent.is_empty());
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn rejects_relative_missing_and_file_paths() {
        assert!(!list_dirs("relative/dir").ok);
        assert!(!list_dirs("/definitely/not/here/muop-browse").ok);
        let root = temp_root("file");
        let file = root.join("f.txt");
        std::fs::write(&file, b"x").unwrap();
        let listing = list_dirs(&file.to_string_lossy());
        assert!(!listing.ok);
        assert!(listing.dirs.is_empty());
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn empty_path_starts_at_home() {
        let listing = list_dirs("");
        assert!(listing.ok, "{}", listing.error);
        assert_eq!(
            listing.path,
            PathBuf::from(&listing.home)
                .canonicalize()
                .unwrap()
                .to_string_lossy()
        );
    }
}
