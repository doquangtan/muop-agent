//! Runtime I/O dùng chung. Mạng (REST, Socket.IO) chạy trên runtime tokio riêng,
//! UI chỉ `await` kết quả qua `run`, nên không phụ thuộc runtime của Dioxus.
//!
//! Trên web (wasm) sẽ thay phần này bằng `wasm_bindgen_futures::spawn_local`.

use std::future::Future;
use std::sync::OnceLock;

use tokio::runtime::{Builder, Runtime};
use tokio::sync::oneshot;

static RUNTIME: OnceLock<Runtime> = OnceLock::new();

pub fn runtime() -> &'static Runtime {
    RUNTIME.get_or_init(|| {
        Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("muop-io")
            .enable_all()
            .build()
            .expect("không tạo được runtime I/O")
    })
}

/// Chạy `fut` trên runtime I/O và chờ kết quả. `Err` chỉ khi tác vụ bị hủy/panic.
pub async fn run<F>(fut: F) -> Result<F::Output, String>
where
    F: Future + Send + 'static,
    F::Output: Send + 'static,
{
    let (tx, rx) = oneshot::channel();
    runtime().spawn(async move {
        let _ = tx.send(fut.await);
    });
    rx.await.map_err(|_| "tác vụ mạng bị hủy".to_string())
}

/// Chờ `duration` trên runtime I/O (dùng cho vòng lặp làm mới định kỳ trong giao diện).
pub async fn sleep(duration: std::time::Duration) {
    let _ = run(async move { tokio::time::sleep(duration).await }).await;
}
