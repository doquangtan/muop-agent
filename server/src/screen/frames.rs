//! Khung hình mới nhất của luồng màn hình, chia sẻ cho mọi client qua HTTP long-poll.
//!
//! - Một khung JPEG được mã hoá một lần, mọi client cùng đọc (chi phí không tăng theo số người xem).
//! - Mỗi khung có số thứ tự `seq` tăng dần. Client gửi `after=<seq>`: server trả khung mới hơn, hoặc
//!   đợi tới khi có khung như vậy. Không có khung mới thì không truyền gì (không gửi lặp khung cũ).
//! - Khung giống hệt khung trước (màn hình không đổi) bị bỏ, nên màn hình tĩnh không tốn băng thông.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;

use tokio::sync::watch;

#[derive(Debug)]
pub struct Frame {
    pub seq: u64,
    pub jpeg: Vec<u8>,
}

pub struct FrameHub {
    /// Khung hiện tại; `None` khi luồng đang tắt
    tx: watch::Sender<Option<Arc<Frame>>>,
    /// Bộ đếm số thứ tự, không đặt lại khi luồng bật lại (client cũ vẫn so sánh đúng)
    next_seq: AtomicU64,
}

impl FrameHub {
    pub fn new() -> Arc<Self> {
        let (tx, _rx) = watch::channel(None);
        Arc::new(Self {
            tx,
            next_seq: AtomicU64::new(0),
        })
    }

    /// Đăng khung mới. Trả false nếu khung giống hệt khung trước (bỏ qua, không tăng `seq`).
    pub fn publish(&self, jpeg: Vec<u8>) -> bool {
        if let Some(prev) = self.tx.borrow().as_ref() {
            if prev.jpeg == jpeg {
                return false;
            }
        }
        let seq = self.next_seq.fetch_add(1, Ordering::Relaxed) + 1;
        self.tx.send_replace(Some(Arc::new(Frame { seq, jpeg })));
        true
    }

    /// Luồng tắt: xóa khung để client không nhận hình cũ
    pub fn clear(&self) {
        self.tx.send_replace(None);
    }

    /// Khung hiện tại (nếu có)
    #[cfg(test)]
    pub fn latest(&self) -> Option<Arc<Frame>> {
        self.tx.borrow().clone()
    }

    /// Đợi khung có `seq > after`, tối đa `wait`. Trả `None` khi hết thời gian.
    pub async fn wait_newer(&self, after: u64, wait: Duration) -> Option<Arc<Frame>> {
        let mut rx = self.tx.subscribe();
        let found = tokio::time::timeout(
            wait,
            rx.wait_for(|f| f.as_ref().is_some_and(|f| f.seq > after)),
        )
        .await;
        match found {
            Ok(Ok(frame)) => frame.clone(),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn publish_assigns_increasing_seq_and_skips_duplicates() {
        let hub = FrameHub::new();
        assert!(hub.publish(vec![1, 2, 3]));
        assert!(!hub.publish(vec![1, 2, 3]), "khung giống hệt bị bỏ");
        assert!(hub.publish(vec![4]));
        assert_eq!(hub.latest().unwrap().seq, 2);
    }

    #[test]
    fn seq_keeps_growing_after_clear() {
        let hub = FrameHub::new();
        hub.publish(vec![1]);
        hub.clear();
        assert!(hub.latest().is_none());
        hub.publish(vec![1]);
        assert_eq!(hub.latest().unwrap().seq, 2);
    }

    #[tokio::test]
    async fn wait_newer_returns_immediately_when_frame_is_ahead() {
        let hub = FrameHub::new();
        hub.publish(vec![9]);
        let f = hub.wait_newer(0, Duration::from_millis(50)).await.unwrap();
        assert_eq!(f.seq, 1);
        // Đã nhận seq 1: không có khung mới thì hết giờ
        assert!(hub.wait_newer(1, Duration::from_millis(50)).await.is_none());
    }

    #[tokio::test]
    async fn wait_newer_wakes_when_frame_arrives() {
        let hub = FrameHub::new();
        let waiter = {
            let hub = hub.clone();
            tokio::spawn(async move { hub.wait_newer(0, Duration::from_secs(2)).await })
        };
        tokio::time::sleep(Duration::from_millis(30)).await;
        hub.publish(vec![7, 7]);
        let got = waiter.await.unwrap().expect("khung tới khi đang đợi");
        assert_eq!(got.jpeg, vec![7, 7]);
    }
}
