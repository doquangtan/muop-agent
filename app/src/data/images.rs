//! Kiểm tra và mã hóa ảnh đính kèm trước khi gửi lên server. Hàm thuần, không phụ thuộc giao diện.
//!
//! Giới hạn lấy theo `docs/API.md` mục 3: tối đa 6 ảnh, mỗi ảnh tối đa 20MB.

use base64::{engine::general_purpose::STANDARD, Engine as _};

pub const MAX_IMAGES: usize = 6;
pub const MAX_IMAGE_BYTES: usize = 20 * 1024 * 1024;

/// MIME theo đuôi file; `None` nếu không phải định dạng server nhận (PNG, JPEG, WebP).
pub fn mime_for_name(name: &str) -> Option<&'static str> {
    let ext = name.rsplit_once('.').map(|(_, e)| e.to_ascii_lowercase())?;
    match ext.as_str() {
        "png" => Some("image/png"),
        "jpg" | "jpeg" => Some("image/jpeg"),
        "webp" => Some("image/webp"),
        _ => None,
    }
}

/// Kết quả kiểm tra một danh sách file chọn thêm.
#[derive(Debug, Clone, PartialEq)]
pub struct Checked {
    /// Chỉ số các file được nhận, theo thứ tự đầu vào
    pub accepted: Vec<usize>,
    /// Thông báo lỗi cho các file bị bỏ (bỏ qua file không hợp lệ, không dừng cả lô)
    pub errors: Vec<String>,
}

/// Kiểm tra `incoming` (tên, số byte) khi đã có `existing` ảnh chờ gửi.
pub fn check_new(existing: usize, incoming: &[(String, usize)]) -> Checked {
    let mut accepted = Vec::new();
    let mut errors = Vec::new();
    for (index, (name, size)) in incoming.iter().enumerate() {
        if mime_for_name(name).is_none() {
            errors.push(format!("{name}: chỉ nhận PNG, JPEG hoặc WebP"));
            continue;
        }
        if *size > MAX_IMAGE_BYTES {
            errors.push(format!("{name}: vượt 20MB"));
            continue;
        }
        if existing + accepted.len() >= MAX_IMAGES {
            errors.push(format!("Tối đa {MAX_IMAGES} ảnh cho một lượt"));
            break;
        }
        accepted.push(index);
    }
    Checked { accepted, errors }
}

/// Mã hóa base64 chuẩn (không xuống dòng), dùng cho `dataBase64`.
pub fn encode_base64(bytes: &[u8]) -> String {
    STANDARD.encode(bytes)
}

/// Data URL để hiển thị xem trước trong `<img>`.
pub fn data_url(mime: &str, data_base64: &str) -> String {
    format!("data:{mime};base64,{data_base64}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mime_follows_extension_case_insensitively() {
        assert_eq!(mime_for_name("Anh.PNG"), Some("image/png"));
        assert_eq!(mime_for_name("a.jpeg"), Some("image/jpeg"));
        assert_eq!(mime_for_name("a.webp"), Some("image/webp"));
        assert_eq!(mime_for_name("a.gif"), None);
        assert_eq!(mime_for_name("khongduoi"), None);
    }

    #[test]
    fn rejects_bad_type_and_oversize_but_keeps_others() {
        let checked = check_new(
            0,
            &[
                ("a.png".into(), 10),
                ("b.txt".into(), 10),
                ("c.jpg".into(), MAX_IMAGE_BYTES + 1),
                ("d.webp".into(), 10),
            ],
        );
        assert_eq!(checked.accepted, vec![0, 3]);
        assert_eq!(checked.errors.len(), 2);
    }

    #[test]
    fn caps_total_images_per_turn() {
        let incoming: Vec<(String, usize)> = (0..4).map(|i| (format!("{i}.png"), 1)).collect();
        let checked = check_new(4, &incoming);
        assert_eq!(checked.accepted, vec![0, 1]);
        assert_eq!(checked.errors.len(), 1);
    }

    #[test]
    fn base64_matches_known_value() {
        assert_eq!(encode_base64(b"Man"), "TWFu");
        assert_eq!(data_url("image/png", "AAA="), "data:image/png;base64,AAA=");
    }
}
