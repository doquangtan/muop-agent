//! Phục vụ bản Flutter web (`make build-web`) ở cổng riêng, mặc định 8788.
//! API và Socket.IO vẫn ở cổng 8787; bản web gọi chúng cùng IP của máy đang mở trang.
//! Thư mục web lấy từ `MUOP_WEB_DIR`, mặc định `~/.local/share/muop-agent/web`. Đọc theo từng request,
//! nên cập nhật bản web không cần khởi động lại máy chủ.

use std::net::SocketAddr;
use std::path::PathBuf;

use axum::Router;
use tower_http::services::{ServeDir, ServeFile};

/// Cổng mặc định của bản web (đổi bằng biến môi trường `MUOP_WEB_PORT`)
pub const DEFAULT_WEB_PORT: u16 = 8788;

/// Cổng phục vụ bản web
pub fn web_port() -> u16 {
    std::env::var("MUOP_WEB_PORT")
        .ok()
        .and_then(|s| s.trim().parse::<u16>().ok())
        .unwrap_or(DEFAULT_WEB_PORT)
}

/// Thư mục chứa bản web đã build (có `index.html`)
pub fn web_root() -> PathBuf {
    match std::env::var_os("MUOP_WEB_DIR").filter(|v| !v.is_empty()) {
        Some(dir) => PathBuf::from(dir),
        None => crate::infra::paths::app_data_dir().join("web"),
    }
}

/// Router tĩnh: file có trong thư mục thì trả file; đường dẫn khác trả `index.html` để app tự điều hướng.
pub fn router(root: PathBuf) -> Router {
    let index = root.join("index.html");
    let serve = ServeDir::new(&root).fallback(ServeFile::new(index));
    Router::new().fallback_service(serve)
}

/// Lắng nghe bản web trên cổng riêng. Lỗi (cổng bận...) chỉ ghi log, không làm dừng máy chủ chính.
pub async fn serve(port: u16, root: PathBuf) {
    if !root.join("index.html").is_file() {
        tracing::warn!(
            "Chưa có bản web tại {} (chạy make build-web để tạo); cổng {port} sẽ trả 404 cho tới khi có",
            root.display()
        );
    }
    let addr = SocketAddr::from(([0, 0, 0, 0], port));
    match tokio::net::TcpListener::bind(addr).await {
        Ok(listener) => {
            tracing::info!("Bản web đang phục vụ tại cổng {port} ({})", root.display());
            if let Err(e) = axum::serve(listener, router(root)).await {
                tracing::error!("Máy chủ web dừng lỗi: {e}");
            }
        }
        Err(e) => tracing::error!("Không mở được cổng web {port}: {e}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    /// Thư mục tạm riêng cho mỗi test (không đụng bản web thật)
    fn temp_root(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("muop-web-test-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("assets")).unwrap();
        std::fs::write(dir.join("index.html"), "<html>app</html>").unwrap();
        std::fs::write(dir.join("assets/app.js"), "console.log(1)").unwrap();
        dir
    }

    /// Chạy router trên cổng ngẫu nhiên và trả về (dòng trạng thái, thân) của một GET
    async fn get(root: PathBuf, path: &str) -> (String, String) {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            let _ = axum::serve(listener, router(root)).await;
        });
        let mut stream = tokio::net::TcpStream::connect(addr).await.unwrap();
        let req = format!("GET {path} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
        stream.write_all(req.as_bytes()).await.unwrap();
        let mut raw = Vec::new();
        stream.read_to_end(&mut raw).await.unwrap();
        let text = String::from_utf8_lossy(&raw).into_owned();
        let (head, body) = text.split_once("\r\n\r\n").unwrap_or((&text, ""));
        (
            head.lines().next().unwrap_or("").to_string(),
            body.to_string(),
        )
    }

    #[tokio::test]
    async fn serves_index_files_and_spa_fallback() {
        let root = temp_root("fallback");
        let (status, body) = get(root.clone(), "/").await;
        assert!(status.contains(" 200 "), "{status}");
        assert_eq!(body, "<html>app</html>");

        let (status, body) = get(root.clone(), "/assets/app.js").await;
        assert!(status.contains(" 200 "), "{status}");
        assert_eq!(body, "console.log(1)");

        // Đường dẫn không có file: trả index.html với 200 để app tự điều hướng
        let (status, body) = get(root.clone(), "/some/route").await;
        assert!(status.contains(" 200 "), "{status}");
        assert_eq!(body, "<html>app</html>");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn web_port_defaults_to_8788() {
        assert_eq!(DEFAULT_WEB_PORT, 8788);
    }
}
