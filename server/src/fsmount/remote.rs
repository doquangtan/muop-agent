//! Client HTTP gọi `/api/fs/*` của máy có project. Dùng bản blocking vì callback FUSE chạy trên luồng
//! thường (không phải task async). Mọi lỗi được đổi thành errno để trả thẳng cho kernel.

use std::time::Duration;

use fuser::Errno;
use reqwest::blocking::{Client, Response};
use serde_json::{json, Value};

/// Thời gian chờ mỗi lần gọi tới máy gửi
const CALL_TIMEOUT: Duration = Duration::from_secs(30);
/// Cỡ mỗi lần đọc khi tải toàn bộ file (máy gửi tự giới hạn tối đa 16MB mỗi lần)
const READ_CHUNK: u64 = 8 * 1024 * 1024;
/// Giới hạn kích thước file đưa vào bộ nhớ khi ghi (cả file được ghi lại mỗi lần lưu)
pub const MAX_FILE_BYTES: usize = 512 * 1024 * 1024;

pub struct Remote {
    http: Client,
    base: String,
    root: String,
}

impl Remote {
    /// `base` là `http://IP:PORT`; `root` là đường dẫn tuyệt đối của project trên máy gửi
    pub fn new(base: &str, root: &str, timeout: Duration) -> Result<Self, String> {
        let http = Client::builder()
            .timeout(timeout)
            .build()
            .map_err(|e| format!("không tạo được client HTTP: {e}"))?;
        Ok(Self {
            http,
            base: base.trim_end_matches('/').to_string(),
            root: root.trim_end_matches('/').to_string(),
        })
    }

    pub fn with_default_timeout(base: &str, root: &str) -> Result<Self, String> {
        Self::new(base, root, CALL_TIMEOUT)
    }

    /// Đường dẫn tuyệt đối trên máy gửi của một đường dẫn tương đối
    pub fn abs(&self, rel: &str) -> String {
        if rel.is_empty() {
            self.root.clone()
        } else {
            format!("{}/{}", self.root, rel)
        }
    }

    fn url(&self, route: &str) -> String {
        format!("{}{}", self.base, route)
    }

    /// Thuộc tính của một đường dẫn (cùng dạng JSON với `GET /api/fs/stat`)
    pub fn stat(&self, rel: &str) -> Result<Value, Errno> {
        let resp = self
            .http
            .get(self.url("/api/fs/stat"))
            .query(&[("path", self.abs(rel))])
            .send()
            .map_err(transport_err)?;
        json_of(check(resp)?)
    }

    /// Danh sách entry của thư mục (`entries` trong `GET /api/fs/list`)
    pub fn list(&self, rel: &str) -> Result<Vec<Value>, Errno> {
        let resp = self
            .http
            .get(self.url("/api/fs/list"))
            .query(&[("path", self.abs(rel))])
            .send()
            .map_err(transport_err)?;
        let body = json_of(check(resp)?)?;
        Ok(body["entries"].as_array().cloned().unwrap_or_default())
    }

    /// Đọc một đoạn file. Trả về dữ liệu và cờ đã chạm cuối file (`X-Fs-Eof`).
    pub fn read(&self, rel: &str, offset: u64, length: u64) -> Result<(Vec<u8>, bool), Errno> {
        let resp = self
            .http
            .get(self.url("/api/fs/read"))
            .query(&[
                ("path", self.abs(rel)),
                ("offset", offset.to_string()),
                ("length", length.to_string()),
            ])
            .send()
            .map_err(transport_err)?;
        let resp = check(resp)?;
        let eof = resp
            .headers()
            .get("X-Fs-Eof")
            .and_then(|v| v.to_str().ok())
            .map(|v| v == "true")
            .unwrap_or(false);
        let data = resp.bytes().map_err(transport_err)?.to_vec();
        Ok((data, eof))
    }

    /// Đọc toàn bộ file
    pub fn read_all(&self, rel: &str) -> Result<Vec<u8>, Errno> {
        let mut out = Vec::new();
        loop {
            let (chunk, eof) = self.read(rel, out.len() as u64, READ_CHUNK)?;
            out.extend_from_slice(&chunk);
            if out.len() > MAX_FILE_BYTES {
                return Err(Errno::EFBIG);
            }
            if eof || chunk.is_empty() {
                return Ok(out);
            }
        }
    }

    /// Ghi (tạo hoặc thay thế) toàn bộ nội dung file
    pub fn write(&self, rel: &str, data: Vec<u8>) -> Result<(), Errno> {
        let resp = self
            .http
            .put(self.url("/api/fs/write"))
            .query(&[("path", self.abs(rel))])
            .body(data)
            .send()
            .map_err(transport_err)?;
        check(resp).map(drop)
    }

    /// Ghi từng đoạn vào file đang có, không gửi lại cả file. `truncate` đặt kích thước trước khi ghi.
    /// Mỗi đoạn là `(offset, dữ liệu)`; khung nhị phân khớp `parse_patch_frames` của máy gửi.
    pub fn patch(
        &self,
        rel: &str,
        truncate: Option<u64>,
        writes: &[(u64, &[u8])],
    ) -> Result<(), Errno> {
        let total: usize = writes.iter().map(|(_, d)| 12 + d.len()).sum();
        let mut body = Vec::with_capacity(total);
        for (off, data) in writes {
            body.extend_from_slice(&off.to_le_bytes());
            body.extend_from_slice(&(data.len() as u32).to_le_bytes());
            body.extend_from_slice(data);
        }
        let mut query = vec![("path", self.abs(rel))];
        if let Some(size) = truncate {
            query.push(("truncate", size.to_string()));
        }
        let resp = self
            .http
            .put(self.url("/api/fs/patch"))
            .query(&query)
            .body(body)
            .send()
            .map_err(transport_err)?;
        check(resp).map(drop)
    }

    pub fn mkdir(&self, rel: &str) -> Result<(), Errno> {
        self.post("/api/fs/mkdir", json!({ "path": self.abs(rel) }))
    }

    pub fn delete(&self, rel: &str, recursive: bool) -> Result<(), Errno> {
        self.post(
            "/api/fs/delete",
            json!({ "path": self.abs(rel), "recursive": recursive }),
        )
    }

    pub fn rename(&self, from: &str, to: &str, overwrite: bool) -> Result<(), Errno> {
        self.post(
            "/api/fs/rename",
            json!({ "from": self.abs(from), "to": self.abs(to), "overwrite": overwrite }),
        )
    }

    fn post(&self, route: &str, body: Value) -> Result<(), Errno> {
        let resp = self
            .http
            .post(self.url(route))
            .json(&body)
            .send()
            .map_err(transport_err)?;
        check(resp).map(drop)
    }
}

fn transport_err(e: reqwest::Error) -> Errno {
    tracing::warn!("fsmount: không gọi được máy gửi: {e}");
    Errno::EIO
}

fn json_of(resp: Response) -> Result<Value, Errno> {
    resp.json::<Value>().map_err(transport_err)
}

/// Thành công thì trả lại response; lỗi thì đổi mã `code` của máy gửi sang errno
fn check(resp: Response) -> Result<Response, Errno> {
    if resp.status().is_success() {
        return Ok(resp);
    }
    let status = resp.status().as_u16();
    let code = resp
        .json::<Value>()
        .ok()
        .and_then(|v| v["code"].as_str().map(str::to_owned));
    Err(match code {
        Some(code) => errno_for_code(&code),
        None => errno_for_status(status),
    })
}

/// Mã lỗi `code` của `/api/fs/*` (xem `fsops.rs`) → errno
pub fn errno_for_code(code: &str) -> Errno {
    match code {
        "invalid" => Errno::EINVAL,
        "outside_root" => Errno::EACCES,
        "not_found" => Errno::ENOENT,
        "exists" => Errno::EEXIST,
        "not_empty" => Errno::ENOTEMPTY,
        "is_dir" => Errno::EISDIR,
        "not_dir" => Errno::ENOTDIR,
        _ => Errno::EIO,
    }
}

fn errno_for_status(status: u16) -> Errno {
    match status {
        400 => Errno::EINVAL,
        403 => Errno::EACCES,
        404 => Errno::ENOENT,
        409 => Errno::EEXIST,
        _ => Errno::EIO,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_remote_codes_to_errno() {
        assert_eq!(errno_for_code("not_found"), Errno::ENOENT);
        assert_eq!(errno_for_code("not_empty"), Errno::ENOTEMPTY);
        assert_eq!(errno_for_code("is_dir"), Errno::EISDIR);
        assert_eq!(errno_for_code("outside_root"), Errno::EACCES);
        assert_eq!(errno_for_code("cái gì đó lạ"), Errno::EIO);
    }

    #[test]
    fn joins_relative_paths_under_the_remote_root() {
        let r = Remote::with_default_timeout("http://10.0.0.2:8787/", "/home/john/p/").unwrap();
        assert_eq!(r.abs(""), "/home/john/p");
        assert_eq!(r.abs("lib/main.dart"), "/home/john/p/lib/main.dart");
        assert_eq!(r.url("/api/fs/stat"), "http://10.0.0.2:8787/api/fs/stat");
    }
}
