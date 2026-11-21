//! Hàng đợi job nền dùng chung cho các việc blocking (đọc CLI, quét quota, ghi phát socket...).
//!
//! - Số worker cố định (`WORKERS`), không tạo luồng mới cho mỗi job. Trước đây mỗi lần cần việc nền là một
//!   `std::thread::spawn` hoặc `spawn_blocking` mới, nên khi việc chậm (ví dụ quota qua TUI 30 giây) các
//!   luồng cứ chồng lên nhau.
//! - Khử trùng theo khóa: job cùng khóa đang chờ hoặc đang chạy thì bỏ qua lần xếp thêm.
//! - Hẹn giờ (`submit_after`) dùng task tokio `sleep`, không giữ luồng OS trong lúc chờ.

use std::collections::{HashSet, VecDeque};
use std::sync::{Condvar, Mutex, OnceLock};
use std::time::Duration;

/// Số worker chạy job blocking song song
const WORKERS: usize = 2;

type Job = Box<dyn FnOnce() + Send + 'static>;

struct Queue {
    /// (khóa, việc) đang chờ worker
    items: Mutex<VecDeque<(String, Job)>>,
    /// Khóa đang chờ hoặc đang chạy (để khử trùng)
    active: Mutex<HashSet<String>>,
    ready: Condvar,
}

static QUEUE: OnceLock<Queue> = OnceLock::new();

fn queue() -> &'static Queue {
    QUEUE.get_or_init(|| {
        for i in 0..WORKERS {
            std::thread::Builder::new()
                .name(format!("muop-job-{i}"))
                .spawn(worker)
                .expect("không khởi tạo được worker job");
        }
        Queue {
            items: Mutex::new(VecDeque::new()),
            active: Mutex::new(HashSet::new()),
            ready: Condvar::new(),
        }
    })
}

fn worker() {
    let q = queue();
    loop {
        let (key, job) = {
            let mut items = q.items.lock().unwrap_or_else(|e| e.into_inner());
            loop {
                if let Some(next) = items.pop_front() {
                    break next;
                }
                items = q.ready.wait(items).unwrap_or_else(|e| e.into_inner());
            }
        };
        // Một job lỗi panic không được làm chết worker
        let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(job));
        if let Ok(mut active) = q.active.lock() {
            active.remove(&key);
        }
    }
}

/// Xếp `job` vào hàng đợi. Trả về `false` nếu đã có job cùng `key` đang chờ hoặc đang chạy.
pub fn submit(key: &str, job: impl FnOnce() + Send + 'static) -> bool {
    let q = queue();
    {
        let mut active = q.active.lock().unwrap_or_else(|e| e.into_inner());
        if !active.insert(key.to_string()) {
            return false;
        }
    }
    q.items
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .push_back((key.to_string(), Box::new(job)));
    q.ready.notify_one();
    true
}

/// Xếp `job` sau `delay`. Chờ bằng task tokio nên không giữ luồng OS.
pub fn submit_after(key: String, delay: Duration, job: impl FnOnce() + Send + 'static) {
    match tokio::runtime::Handle::try_current() {
        Ok(handle) => {
            handle.spawn(async move {
                tokio::time::sleep(delay).await;
                submit(&key, job);
            });
        }
        // Gọi từ luồng không có runtime tokio: chỉ dùng luồng tạm khi thật sự cần
        Err(_) => {
            std::thread::spawn(move || {
                std::thread::sleep(delay);
                submit(&key, job);
            });
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc;

    #[test]
    fn same_key_is_deduplicated_until_done() {
        let (release_tx, release_rx) = mpsc::channel::<()>();
        let (done_tx, done_rx) = mpsc::channel::<()>();
        assert!(submit("jobs-test-dedupe", move || {
            let _ = release_rx.recv();
            let _ = done_tx.send(());
        }));
        // Đang chờ/chạy: lần xếp thứ hai cùng khóa bị bỏ qua
        assert!(!submit("jobs-test-dedupe", || {}));
        release_tx.send(()).unwrap();
        done_rx
            .recv_timeout(Duration::from_secs(5))
            .expect("job phải chạy xong");
        // Chạy xong thì khóa được giải phóng (chờ worker cập nhật active)
        let mut ok = false;
        for _ in 0..100 {
            if submit("jobs-test-dedupe", || {}) {
                ok = true;
                break;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        assert!(ok, "khóa phải được giải phóng sau khi job xong");
    }

    #[test]
    fn panicking_job_does_not_kill_worker() {
        assert!(submit("jobs-test-panic", || panic!(
            "lỗi có chủ ý trong test"
        )));
        let (tx, rx) = mpsc::channel::<()>();
        assert!(submit("jobs-test-after-panic", move || {
            let _ = tx.send(());
        }));
        rx.recv_timeout(Duration::from_secs(5))
            .expect("worker phải sống sau job panic");
    }
}
