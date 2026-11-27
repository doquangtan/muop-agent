//! Timer dùng chung, chạy đúng trên native (tokio) và web (gloo-timers).

use std::time::Duration;

pub async fn sleep(duration: Duration) {
    #[cfg(not(target_arch = "wasm32"))]
    tokio::time::sleep(duration).await;

    #[cfg(target_arch = "wasm32")]
    gloo_timers::future::sleep(duration).await;
}
