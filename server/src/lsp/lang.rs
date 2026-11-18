use super::*;

#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub enum Lang {
    Go,
    Dart,
    Rust,
}

impl Lang {
    pub const ALL: [Lang; 3] = [Lang::Go, Lang::Dart, Lang::Rust];

    /// Khóa lưu trong bảng `lsp_settings` và trong API
    pub fn key(self) -> &'static str {
        match self {
            Lang::Go => "go",
            Lang::Dart => "dart",
            Lang::Rust => "rust",
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Lang::Go => "Go (gopls)",
            Lang::Dart => "Dart (dart language-server)",
            Lang::Rust => "Rust (rust-analyzer)",
        }
    }

    pub fn from_key(s: &str) -> Option<Lang> {
        Lang::ALL.into_iter().find(|l| l.key() == s)
    }

    /// Ngôn ngữ theo đuôi tệp
    pub fn from_path(path: &Path) -> Option<Lang> {
        match path.extension()?.to_str()? {
            "go" => Some(Lang::Go),
            "dart" => Some(Lang::Dart),
            "rs" => Some(Lang::Rust),
            _ => None,
        }
    }

    /// Tên tệp đánh dấu thư mục gốc project
    pub(super) fn root_marker(self) -> &'static str {
        match self {
            Lang::Go => "go.mod",
            Lang::Dart => "pubspec.yaml",
            Lang::Rust => "Cargo.toml",
        }
    }

    /// Đối số sau tiến trình (gopls cần `serve`, dart cần `language-server`)
    pub(super) fn args(self) -> &'static [&'static str] {
        match self {
            Lang::Go => &["serve"],
            Lang::Dart => &["language-server", "--protocol=lsp"],
            Lang::Rust => &[],
        }
    }

    /// Tên tệp thực thi để tìm trong PATH
    pub(super) fn binary_name(self) -> &'static str {
        match self {
            Lang::Go => "gopls",
            Lang::Dart => "dart",
            Lang::Rust => "rust-analyzer",
        }
    }

    pub(super) fn language_id(self) -> &'static str {
        self.key()
    }
}
