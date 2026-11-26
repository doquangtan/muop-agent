//! Phân tích đầu ra của `sftp` (lệnh `ls -la`, `pwd`) và đặt đường dẫn vào lệnh batch.
//!
//! Dùng `sftp` của OpenSSH để có cùng định dạng trên Linux và macOS. Tên có khoảng trắng, dấu nháy
//! và dấu gạch chéo ngược được escape; ký tự xuống dòng bị từ chối vì không đặt được vào một dòng batch.

use regex::Regex;
use std::sync::OnceLock;

/// Một mục trong thư mục trên máy đích
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteEntry {
    pub name: String,
    pub is_dir: bool,
    pub is_link: bool,
    pub size: u64,
    /// Thời điểm như `ls` in ra (ví dụ `Nov 25 10:00` hoặc `Nov 25  2025`)
    pub modified: String,
    /// Chuỗi quyền, ví dụ `-rw-r--r--`
    pub mode: String,
    /// Thời điểm sửa đổi (giây unix). Chỉ có với "Máy này"; ls không cho năm chính xác.
    pub modified_unix: Option<i64>,
}

fn long_line() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(
            // Số liên kết là `?` khi sftp không lấy được (ví dụ với một số máy chủ)
            r"^([\-dlbcps][rwxsStT\-]{9}[@+.]?)\s+(?:\d+|\?)\s+\S+\s+\S+\s+(\d+)\s+(\w{3}\s+\d{1,2}\s+(?:\d{1,2}:\d{2}|\d{4}))\s+(.+)$",
        )
        .expect("regex ls -l")
    })
}

/// Phân tích đầu ra `ls -l` của sftp. Bỏ qua `.`, `..` và các dòng không phải mục thư mục.
pub fn parse_ls(output: &str) -> Vec<RemoteEntry> {
    let re = long_line();
    let mut out = Vec::new();
    for line in output.lines() {
        let line = line.trim_end_matches('\r');
        let Some(c) = re.captures(line) else {
            continue;
        };
        let mode = c[1].to_string();
        let kind = mode.chars().next().unwrap_or('-');
        let size: u64 = c[2].parse().unwrap_or(0);
        let modified = c[3].to_string();
        let mut rest = c[4].to_string();
        // Liên kết: "tên -> đích". Chỉ lấy tên.
        let is_link = kind == 'l';
        if is_link {
            if let Some(idx) = rest.find(" -> ") {
                rest.truncate(idx);
            }
        }
        // Khi liệt kê một file cụ thể, sftp in cả đường dẫn: chỉ giữ tên cuối
        let name = match rest.rfind('/') {
            Some(idx) => rest[idx + 1..].to_string(),
            None => rest,
        };
        if name.is_empty() || name == "." || name == ".." {
            continue;
        }
        out.push(RemoteEntry {
            name,
            is_dir: kind == 'd',
            is_link,
            size,
            modified,
            mode,
            modified_unix: None,
        });
    }
    sort_entries(&mut out);
    out
}

/// Thư mục trước, rồi theo tên không phân biệt hoa thường (dùng chung cho SSH và máy này)
pub fn sort_entries(items: &mut [RemoteEntry]) {
    items.sort_by(|a, b| {
        b.is_dir
            .cmp(&a.is_dir)
            .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
    });
}

/// Thư mục làm việc từ đầu ra `pwd` của sftp (`Remote working directory: /home/john`)
pub fn parse_pwd(output: &str) -> Option<String> {
    output
        .lines()
        .find_map(|l| l.strip_prefix("Remote working directory:"))
        .map(|p| p.trim().to_string())
        .filter(|p| p.starts_with('/'))
}

/// Đường dẫn tuyệt đối trên máy đích, không chứa ký tự điều khiển.
pub fn check_remote_path(path: &str) -> Result<(), String> {
    if !path.starts_with('/') {
        return Err("Đường dẫn phải là đường dẫn tuyệt đối".into());
    }
    if path.chars().any(|c| c.is_control()) {
        return Err("Đường dẫn chứa ký tự không hợp lệ".into());
    }
    Ok(())
}

/// Đặt một đường dẫn vào lệnh batch của sftp: bọc trong nháy kép, escape `\` và `"`.
pub fn quote(path: &str) -> Result<String, String> {
    check_remote_path(path)?;
    let mut out = String::with_capacity(path.len() + 2);
    out.push('"');
    for c in path.chars() {
        if c == '\\' || c == '"' {
            out.push('\\');
        }
        out.push(c);
    }
    out.push('"');
    Ok(out)
}

/// Đường dẫn cục bộ (file tạm trên server) đặt vào batch: cùng quy tắc escape
pub fn quote_local(path: &std::path::Path) -> Result<String, String> {
    let s = path.to_string_lossy();
    if s.chars().any(|c| c.is_control()) {
        return Err("Đường dẫn tạm không hợp lệ".into());
    }
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        if c == '\\' || c == '"' {
            out.push('\\');
        }
        out.push(c);
    }
    out.push('"');
    Ok(out)
}

/// Nối thư mục cha và tên mục
pub fn join(dir: &str, name: &str) -> String {
    if dir.ends_with('/') {
        format!("{dir}{name}")
    } else {
        format!("{dir}/{name}")
    }
}

/// Lỗi của sftp dịch sang tiếng Việt, giữ lại dòng gốc nếu không nhận ra
pub fn sftp_error(stderr: &str) -> String {
    let lower = stderr.to_lowercase();
    if lower.contains("no such file") {
        "Không tìm thấy đường dẫn".into()
    } else if lower.contains("permission denied") {
        "Không đủ quyền trên máy đích".into()
    } else if lower.contains("file exists") || lower.contains("already exists") {
        "Đã tồn tại".into()
    } else if lower.contains("directory not empty") {
        "Thư mục không rỗng".into()
    } else {
        stderr
            .lines()
            .rev()
            .find(|l| !l.trim().is_empty())
            .map(|l| l.trim().to_string())
            .unwrap_or_else(|| "Thao tác SFTP thất bại".into())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const LS: &str = "drwxr-xr-x    2 john     john         4096 Nov 25 10:00 projects
-rw-r--r--    1 john     john          123 Nov 25  2025 notes.txt
-rw-r--r--    1 john     john          512 Nov 25 10:00 my file \"v2\".md
lrwxrwxrwx    1 john     john           11 Nov 24 09:00 link -> /etc/hosts
drwxr-xr-x    3 john     john         4096 Oct 01 08:00 .config
";

    #[test]
    fn parses_long_listing_with_spaces_links_and_years() {
        let items = parse_ls(LS);
        let names: Vec<&str> = items.iter().map(|e| e.name.as_str()).collect();
        // Thư mục trước, rồi theo tên không phân biệt hoa thường
        assert_eq!(
            names,
            vec![
                ".config",
                "projects",
                "link",
                "my file \"v2\".md",
                "notes.txt"
            ]
        );
        let notes = items.iter().find(|e| e.name == "notes.txt").unwrap();
        assert_eq!(notes.size, 123);
        assert_eq!(notes.modified, "Nov 25  2025");
        assert!(!notes.is_dir);
        let link = items.iter().find(|e| e.name == "link").unwrap();
        assert!(link.is_link && !link.is_dir);
        assert!(items.iter().find(|e| e.name == "projects").unwrap().is_dir);
    }

    #[test]
    fn parses_real_batch_output_with_echoed_commands() {
        // Đầu ra thật của `sftp -b -` (OpenSSH): dòng lệnh được in lại, số liên kết là `?`,
        // tên là đường dẫn đầy đủ, có cả `.` và `..`
        let out = "sftp> ls -la \"/tmp/x\"
drwxrwxr-x    ? john     john           80 Nov 25 16:47 /tmp/x/.
drwxrwxrwt    ? root     root         5200 Nov 25 16:47 /tmp/x/..
-rw-rw-r--    ? john     john            3 Nov 25 16:47 /tmp/x/a b.txt
drwxrwxr-x    ? john     john           40 Nov 25 16:47 /tmp/x/with space
sftp> pwd
Remote working directory: /home/john
";
        let items = parse_ls(out);
        let names: Vec<&str> = items.iter().map(|e| e.name.as_str()).collect();
        assert_eq!(names, vec!["with space", "a b.txt"]);
        assert_eq!(items[1].size, 3);
        assert_eq!(parse_pwd(out), Some("/home/john".into()));
    }

    #[test]
    fn skips_dot_entries_and_noise() {
        let out = "sftp> ls\n-rw-r--r--    1 john john 5 Nov 25 10:00 .\n-rw-r--r--    1 john john 5 Nov 25 10:00 ..\nCouldn't stat";
        assert!(parse_ls(out).is_empty());
    }

    #[test]
    fn single_file_listing_uses_basename() {
        let out = "-rw-r--r--    1 john john 5 Nov 25 10:00 /home/john/a.txt";
        let items = parse_ls(out);
        assert_eq!(items[0].name, "a.txt");
    }

    #[test]
    fn parses_pwd() {
        assert_eq!(
            parse_pwd("Remote working directory: /home/john\n"),
            Some("/home/john".into())
        );
        assert_eq!(parse_pwd("nothing"), None);
    }

    #[test]
    fn quotes_paths_for_batch() {
        assert_eq!(quote("/a b/c").unwrap(), "\"/a b/c\"");
        assert_eq!(quote("/x/\"q\"\\y").unwrap(), "\"/x/\\\"q\\\"\\\\y\"");
        assert!(quote("relative").is_err());
        assert!(quote("/a\nrm -rf").is_err());
    }

    #[test]
    fn maps_sftp_errors() {
        assert_eq!(
            sftp_error("Couldn't stat remote file: No such file or directory"),
            "Không tìm thấy đường dẫn"
        );
        assert_eq!(
            sftp_error("remote readdir(\"/root\"): Permission denied"),
            "Không đủ quyền trên máy đích"
        );
        assert_eq!(sftp_error("Something odd\n"), "Something odd");
    }

    #[test]
    fn joins_names() {
        assert_eq!(join("/home/john", "a"), "/home/john/a");
        assert_eq!(join("/", "a"), "/a");
    }
}
