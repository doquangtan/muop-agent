//! Bảng inode của mount: FUSE làm việc bằng số inode, còn máy gửi làm việc bằng đường dẫn.
//! Bảng này gán số inode ổn định cho từng đường dẫn tương đối (không có `/` đầu, gốc là chuỗi rỗng).

use std::collections::HashMap;

/// Inode của thư mục gốc theo quy ước FUSE
pub const ROOT_INO: u64 = 1;

#[derive(Debug)]
pub struct Inodes {
    by_ino: HashMap<u64, String>,
    by_path: HashMap<String, u64>,
    next: u64,
}

impl Default for Inodes {
    fn default() -> Self {
        Self::new()
    }
}

impl Inodes {
    pub fn new() -> Self {
        let mut table = Self {
            by_ino: HashMap::new(),
            by_path: HashMap::new(),
            next: ROOT_INO + 1,
        };
        table.by_ino.insert(ROOT_INO, String::new());
        table.by_path.insert(String::new(), ROOT_INO);
        table
    }

    /// Inode của một đường dẫn; tạo mới nếu chưa có. Cùng đường dẫn luôn trả cùng inode.
    pub fn ino_for(&mut self, rel: &str) -> u64 {
        if let Some(&ino) = self.by_path.get(rel) {
            return ino;
        }
        let ino = self.next;
        self.next += 1;
        self.by_ino.insert(ino, rel.to_string());
        self.by_path.insert(rel.to_string(), ino);
        ino
    }

    pub fn path_of(&self, ino: u64) -> Option<&str> {
        self.by_ino.get(&ino).map(String::as_str)
    }

    /// Cập nhật sau khi đổi tên `from` → `to` trên máy gửi. Cây con đi theo thư mục, giữ nguyên inode
    /// của file đã di chuyển. Inode của đích bị ghi đè (và con của nó) bị bỏ vì không còn trỏ đúng nữa.
    pub fn rename(&mut self, from: &str, to: &str) {
        self.forget_subtree(to);
        let moved: Vec<(u64, String)> = self
            .by_ino
            .iter()
            .filter(|(_, path)| in_subtree(path, from))
            .map(|(ino, path)| (*ino, path.clone()))
            .collect();
        for (ino, old) in moved {
            self.by_path.remove(&old);
            let new = rebase(&old, from, to);
            self.by_path.insert(new.clone(), ino);
            self.by_ino.insert(ino, new);
        }
    }

    fn forget_subtree(&mut self, base: &str) {
        let gone: Vec<(u64, String)> = self
            .by_ino
            .iter()
            .filter(|(_, path)| in_subtree(path, base))
            .map(|(ino, path)| (*ino, path.clone()))
            .collect();
        for (ino, path) in gone {
            self.by_ino.remove(&ino);
            self.by_path.remove(&path);
        }
    }
}

/// `path` là `base` hoặc nằm dưới `base`
fn in_subtree(path: &str, base: &str) -> bool {
    if base.is_empty() {
        return false;
    }
    path == base || path.starts_with(&format!("{base}/"))
}

/// Đổi tiền tố `from` thành `to` của `path` (đã biết `path` nằm trong cây `from`)
fn rebase(path: &str, from: &str, to: &str) -> String {
    if path == from {
        to.to_string()
    } else {
        format!("{to}{}", &path[from.len()..])
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn root_is_one_and_paths_are_stable() {
        let mut t = Inodes::new();
        assert_eq!(t.path_of(ROOT_INO), Some(""));
        let a = t.ino_for("src/main.rs");
        assert_ne!(a, ROOT_INO);
        assert_eq!(t.ino_for("src/main.rs"), a);
        assert_eq!(t.path_of(a), Some("src/main.rs"));
    }

    #[test]
    fn rename_moves_subtree_and_keeps_inodes() {
        let mut t = Inodes::new();
        let dir = t.ino_for("app");
        let file = t.ino_for("app/lib/a.dart");
        let other = t.ino_for("apple.txt");
        t.rename("app", "service");
        assert_eq!(t.path_of(dir), Some("service"));
        assert_eq!(t.path_of(file), Some("service/lib/a.dart"));
        // "apple.txt" chỉ có chung tiền tố chữ, không thuộc cây "app"
        assert_eq!(t.path_of(other), Some("apple.txt"));
        assert_eq!(t.ino_for("service/lib/a.dart"), file);
    }

    #[test]
    fn rename_over_existing_target_drops_stale_inodes() {
        let mut t = Inodes::new();
        let old_target = t.ino_for("notes.md");
        let old_child = t.ino_for("dir/child.md");
        let moved = t.ino_for("tmp.md");
        t.rename("tmp.md", "notes.md");
        assert_eq!(t.path_of(moved), Some("notes.md"));
        assert_eq!(t.path_of(old_target), None);
        assert_eq!(t.path_of(old_child), Some("dir/child.md"));

        // Đổi thư mục "dir" đè lên "notes.md": file đích cũ bị bỏ, con của "dir" đi theo thư mục
        let dir = t.ino_for("dir");
        t.rename("dir", "notes.md");
        assert_eq!(t.path_of(dir), Some("notes.md"));
        assert_eq!(t.path_of(old_child), Some("notes.md/child.md"));
        assert_eq!(t.path_of(moved), None);
    }
}
