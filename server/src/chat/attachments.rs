//! Ảnh đính kèm của tin nhắn chat.
//!
//! Client gửi ảnh dạng base64 trong `ChatSendRequest.images` (qua REST `/api/chat/send`).
//! Server:
//! 1. Giải base64 và nhận diện định dạng từ nội dung thật (không tin MIME khai báo).
//! 2. Thu nhỏ ảnh quá lớn (cạnh dài > [`MAX_LONG_SIDE`]) và chuyển WebP/ảnh có alpha về PNG/JPEG.
//! 3. Lưu vào `~/.local/share/muop-agent/uploads/` để agy đọc được bằng đường dẫn.
//!
//! Cách đưa ảnh vào CLI:
//! - Claude CLI: stream-json trên stdin, mỗi ảnh là một block `image` base64 ([`claude_stream_input_line`]).
//! - agy: không có cờ ảnh, nên đường dẫn file được ghi vào prompt ([`agy_prompt`]) và agent đọc bằng tool.

use crate::models::ChatImage;
use base64::{engine::general_purpose::STANDARD, Engine as _};
use image::codecs::jpeg::JpegEncoder;
use image::imageops::FilterType;
use image::{GenericImageView, ImageFormat};
use serde_json::{json, Value};
use std::io::Cursor;
use std::path::PathBuf;

/// Số ảnh tối đa trong một tin nhắn
pub const MAX_IMAGES: usize = 6;
/// Dung lượng tối đa của một ảnh gửi lên (trước khi thu nhỏ)
pub const MAX_IMAGE_BYTES: usize = 20 * 1024 * 1024;
/// Cạnh dài tối đa; ảnh lớn hơn được thu nhỏ (giới hạn khuyến nghị của model vision)
pub const MAX_LONG_SIDE: u32 = 1568;
/// Dòng mở đầu khối ảnh trong prompt gửi agy. Scanner dùng chuỗi này để tách khối khỏi nội dung hiển thị.
pub const AGY_BLOCK_HEADER: &str = "[Ảnh đính kèm]";

/// Ảnh đã kiểm tra, đã chuẩn hoá và đã lưu xuống đĩa
#[derive(Debug, Clone)]
pub struct PreparedImage {
    pub mime: &'static str,
    pub bytes: Vec<u8>,
    pub path: PathBuf,
}

fn uploads_dir() -> PathBuf {
    crate::infra::paths::app_data_dir().join("uploads")
}

/// Kiểm tra, chuẩn hoá và lưu toàn bộ ảnh của một tin nhắn.
/// Gọi trong `spawn_blocking` vì giải mã/thu nhỏ ảnh tốn CPU.
pub fn prepare_images(images: &[ChatImage]) -> Result<Vec<PreparedImage>, String> {
    if images.len() > MAX_IMAGES {
        return Err(format!("Tối đa {MAX_IMAGES} ảnh cho mỗi tin nhắn"));
    }
    if images.is_empty() {
        return Ok(Vec::new());
    }
    let dir = uploads_dir();
    std::fs::create_dir_all(&dir)
        .map_err(|e| format!("Không tạo được thư mục ảnh đính kèm: {e}"))?;

    let mut out = Vec::with_capacity(images.len());
    for (i, img) in images.iter().enumerate() {
        let name = img.name.trim().to_string();
        let label = if name.is_empty() {
            format!("ảnh {}", i + 1)
        } else {
            name.clone()
        };
        let raw = decode_payload(&img.data_base64).map_err(|e| format!("{label}: {e}"))?;
        if raw.len() > MAX_IMAGE_BYTES {
            return Err(format!(
                "{label}: vượt quá {} MB",
                MAX_IMAGE_BYTES / (1024 * 1024)
            ));
        }
        let (bytes, mime, ext) = normalize(&raw).map_err(|e| format!("{label}: {e}"))?;
        let stamp = chrono::Utc::now().timestamp_nanos_opt().unwrap_or_default();
        let path = dir.join(format!("{stamp}-{i}.{ext}"));
        std::fs::write(&path, &bytes).map_err(|e| format!("{label}: không ghi được file: {e}"))?;
        out.push(PreparedImage { mime, bytes, path });
    }
    Ok(out)
}

/// Giải base64, chấp nhận cả dạng `data:<mime>;base64,<dữ liệu>`
fn decode_payload(data: &str) -> Result<Vec<u8>, String> {
    let s = data.trim();
    let body = match s
        .strip_prefix("data:")
        .and_then(|rest| rest.find(";base64,"))
    {
        Some(p) => &s["data:".len() + p + ";base64,".len()..],
        None => s,
    };
    let raw = STANDARD
        .decode(body.trim())
        .map_err(|_| "dữ liệu base64 không hợp lệ".to_string())?;
    if raw.is_empty() {
        return Err("file rỗng".to_string());
    }
    Ok(raw)
}

/// Trả về (bytes, MIME, đuôi file). Giữ nguyên file gốc khi đã là PNG/JPEG và không cần thu nhỏ.
fn normalize(raw: &[u8]) -> Result<(Vec<u8>, &'static str, &'static str), String> {
    let format = image::guess_format(raw).map_err(|_| "không phải file ảnh hợp lệ".to_string())?;
    let (mime, ext) = match format {
        ImageFormat::Png => ("image/png", "png"),
        ImageFormat::Jpeg => ("image/jpeg", "jpg"),
        ImageFormat::WebP => ("image/webp", "webp"),
        _ => return Err("chỉ hỗ trợ PNG, JPEG, WebP".to_string()),
    };
    let img = image::load_from_memory_with_format(raw, format)
        .map_err(|e| format!("không đọc được ảnh ({e})"))?;
    let (w, h) = img.dimensions();
    let needs_resize = w.max(h) > MAX_LONG_SIDE;
    if !needs_resize && matches!(format, ImageFormat::Png | ImageFormat::Jpeg) {
        return Ok((raw.to_vec(), mime, ext));
    }

    let img = if needs_resize {
        img.resize(MAX_LONG_SIDE, MAX_LONG_SIDE, FilterType::Lanczos3)
    } else {
        img
    };
    if img.color().has_alpha() {
        let mut cursor = Cursor::new(Vec::new());
        img.write_to(&mut cursor, ImageFormat::Png)
            .map_err(|e| format!("không ghi được PNG ({e})"))?;
        Ok((cursor.into_inner(), "image/png", "png"))
    } else {
        let rgb = img.to_rgb8();
        let mut buf = Vec::new();
        JpegEncoder::new_with_quality(&mut buf, 85)
            .encode_image(&rgb)
            .map_err(|e| format!("không ghi được JPEG ({e})"))?;
        Ok((buf, "image/jpeg", "jpg"))
    }
}

/// Một dòng JSON (kèm `\n`) gửi cho `claude --input-format stream-json`: một lượt người dùng gồm ảnh và chữ.
pub fn claude_stream_input_line(prompt: &str, images: &[PreparedImage]) -> String {
    let mut content: Vec<Value> = images
        .iter()
        .map(|img| {
            json!({
                "type": "image",
                "source": {
                    "type": "base64",
                    "media_type": img.mime,
                    "data": STANDARD.encode(&img.bytes),
                }
            })
        })
        .collect();
    if !prompt.trim().is_empty() {
        content.push(json!({"type": "text", "text": prompt}));
    }
    let msg = json!({
        "type": "user",
        "message": {"role": "user", "content": content},
    });
    format!("{msg}\n")
}

/// Đầu dòng chỉ dẫn thư mục làm việc, gắn vào prompt agy khi project nằm trên mount (xem `fsmount`)
pub const AGY_WORKDIR_HEADER: &str = "[Thư mục làm việc]";

/// Chỉ dẫn thư mục làm việc cho agy. Agy không nhận đường dẫn project qua tham số, và một conversation
/// tiếp tục có thể còn nhớ đường dẫn cũ trong lịch sử (đã gặp: ghi vào repo local thay vì mount).
pub fn agy_workdir_note(cwd: &str) -> String {
    format!(
        "\n\n{AGY_WORKDIR_HEADER} {cwd}. Mọi thao tác đọc/ghi file và lệnh shell phải dùng thư mục này, không dùng đường dẫn cũ trong lịch sử hội thoại."
    )
}

/// Bỏ chỉ dẫn thư mục làm việc khỏi nội dung hiển thị (phần chữ đứng sau dòng chỉ dẫn bị cắt)
pub fn strip_agy_workdir_note(text: &str) -> String {
    match text.find(&format!("\n\n{AGY_WORKDIR_HEADER} ")) {
        Some(pos) => text[..pos].trim_end().to_string(),
        None => text.to_string(),
    }
}

/// Prompt gửi agy: nội dung người dùng, kèm khối liệt kê đường dẫn ảnh để agent mở bằng tool đọc file.
pub fn agy_prompt(text: &str, images: &[PreparedImage]) -> String {
    if images.is_empty() {
        return text.to_string();
    }
    let mut s = String::new();
    s.push_str(text);
    s.push_str("\n\n");
    s.push_str(AGY_BLOCK_HEADER);
    s.push('\n');
    for img in images {
        s.push_str("- ");
        s.push_str(&img.path.display().to_string());
        s.push('\n');
    }
    s.push_str("Hãy đọc các ảnh trên bằng công cụ đọc file trước khi trả lời.");
    s
}

/// Tách khối ảnh do [`agy_prompt`] tạo khỏi nội dung người dùng.
/// Trả về (nội dung sạch, đường dẫn các ảnh đính kèm).
pub fn split_agy_attachments(text: &str) -> (String, Vec<String>) {
    let marker = format!("\n\n{AGY_BLOCK_HEADER}\n");
    let Some(pos) = text.find(&marker) else {
        return (text.to_string(), Vec::new());
    };
    let paths = text[pos..]
        .lines()
        .filter_map(|line| line.strip_prefix("- "))
        .map(|p| p.trim().to_string())
        .collect();
    (text[..pos].trim().to_string(), paths)
}

/// Đường dẫn của endpoint lấy ảnh đính kèm (xem `api::chat::handle_chat_attachment`)
pub const ATTACHMENT_URL_PREFIX: &str = "/api/chat/attachment";

/// URL lấy ảnh đã lưu trong thư mục uploads (dùng cho agy, vì đường dẫn nằm trong prompt)
pub fn agy_attachment_url(path: &str) -> String {
    format!("{ATTACHMENT_URL_PREFIX}?path={}", pct_encode(path))
}

/// URL lấy ảnh thứ `index` trong dòng transcript Claude có `uuid` của session `session_id`
pub fn transcript_attachment_url(session_id: &str, uuid: &str, index: usize) -> String {
    format!(
        "{ATTACHMENT_URL_PREFIX}?cid={}&uuid={}&i={index}",
        pct_encode(session_id),
        pct_encode(uuid)
    )
}

/// Mã hoá phần trăm cho giá trị query string
pub fn pct_encode(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for b in value.bytes() {
        if b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.' | b'~' | b'/') {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

/// MIME của ảnh đã lưu, theo đuôi file do `prepare_images` đặt
fn mime_for_path(path: &std::path::Path) -> &'static str {
    match path.extension().and_then(|e| e.to_str()) {
        Some("png") => "image/png",
        Some("webp") => "image/webp",
        _ => "image/jpeg",
    }
}

/// Đọc ảnh đã lưu trong thư mục uploads. Từ chối mọi đường dẫn nằm ngoài thư mục này.
pub fn read_uploaded_image(path: &str) -> Result<(Vec<u8>, &'static str), String> {
    let dir = uploads_dir()
        .canonicalize()
        .map_err(|_| "chưa có ảnh đính kèm nào".to_string())?;
    let file = PathBuf::from(path)
        .canonicalize()
        .map_err(|_| "không tìm thấy ảnh".to_string())?;
    if !file.starts_with(&dir) {
        return Err("đường dẫn ảnh không hợp lệ".to_string());
    }
    let bytes = std::fs::read(&file).map_err(|e| format!("không đọc được ảnh: {e}"))?;
    Ok((bytes, mime_for_path(&file)))
}

/// Lấy ảnh thứ `index` trong block `image` của dòng user có `uuid` ở transcript Claude.
/// Ảnh được Claude lưu dạng base64 nên đọc lại từ transcript, không cần file riêng.
pub fn read_transcript_image(
    jsonl: &std::path::Path,
    uuid: &str,
    index: usize,
) -> Result<(Vec<u8>, String), String> {
    use std::io::{BufRead, BufReader};
    let file = std::fs::File::open(jsonl).map_err(|_| "không mở được transcript".to_string())?;
    for line in BufReader::new(file).lines() {
        let Ok(line) = line else { continue };
        if !line.contains(uuid) {
            continue;
        }
        let Ok(v) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        if v.get("uuid").and_then(|x| x.as_str()) != Some(uuid) {
            continue;
        }
        let image = v["message"]["content"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|b| b.get("type").and_then(|x| x.as_str()) == Some("image"))
            .nth(index)
            .ok_or_else(|| "không có ảnh ở vị trí này".to_string())?;
        let data = image["source"]["data"]
            .as_str()
            .ok_or_else(|| "ảnh không có dữ liệu".to_string())?;
        let mime = image["source"]["media_type"]
            .as_str()
            .unwrap_or("image/jpeg")
            .to_string();
        let bytes = STANDARD
            .decode(data)
            .map_err(|_| "dữ liệu ảnh hỏng".to_string())?;
        return Ok((bytes, mime));
    }
    Err("không tìm thấy tin nhắn chứa ảnh".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn png_bytes(w: u32, h: u32, alpha: bool) -> Vec<u8> {
        let mut cursor = Cursor::new(Vec::new());
        if alpha {
            let img = image::RgbaImage::from_pixel(w, h, image::Rgba([200, 30, 30, 128]));
            image::DynamicImage::ImageRgba8(img)
                .write_to(&mut cursor, ImageFormat::Png)
                .unwrap();
        } else {
            let img = image::RgbImage::from_pixel(w, h, image::Rgb([200, 30, 30]));
            image::DynamicImage::ImageRgb8(img)
                .write_to(&mut cursor, ImageFormat::Png)
                .unwrap();
        }
        cursor.into_inner()
    }

    fn chat_image(raw: &[u8]) -> ChatImage {
        ChatImage {
            name: "test.png".into(),
            mime_type: "image/png".into(),
            data_base64: STANDARD.encode(raw),
        }
    }

    #[test]
    fn small_png_is_kept_as_is() {
        let raw = png_bytes(32, 16, false);
        let (bytes, mime, ext) = normalize(&raw).unwrap();
        assert_eq!(bytes, raw);
        assert_eq!((mime, ext), ("image/png", "png"));
    }

    #[test]
    fn large_image_is_resized_to_long_side_limit() {
        let raw = png_bytes(3000, 1500, false);
        let (bytes, mime, _) = normalize(&raw).unwrap();
        assert_eq!(mime, "image/jpeg");
        let out = image::load_from_memory(&bytes).unwrap();
        assert_eq!(out.width(), MAX_LONG_SIDE);
        assert!(out.height() <= MAX_LONG_SIDE);
    }

    #[test]
    fn png_with_alpha_stays_png_when_resized() {
        let raw = png_bytes(2000, 2000, true);
        let (_, mime, ext) = normalize(&raw).unwrap();
        assert_eq!((mime, ext), ("image/png", "png"));
    }

    #[test]
    fn non_image_payload_is_rejected() {
        let err = normalize(b"hello world, not an image").unwrap_err();
        assert!(err.contains("không phải file ảnh"));
    }

    #[test]
    fn bad_base64_is_rejected() {
        let img = ChatImage {
            name: "x.png".into(),
            mime_type: String::new(),
            data_base64: "!!!not-base64!!!".into(),
        };
        assert!(prepare_images(&[img]).is_err());
    }

    #[test]
    fn data_url_prefix_is_accepted() {
        let raw = png_bytes(8, 8, false);
        let data = format!("data:image/png;base64,{}", STANDARD.encode(&raw));
        assert_eq!(decode_payload(&data).unwrap(), raw);
    }

    #[test]
    fn too_many_images_is_rejected() {
        let raw = png_bytes(4, 4, false);
        let imgs: Vec<ChatImage> = (0..=MAX_IMAGES).map(|_| chat_image(&raw)).collect();
        assert!(prepare_images(&imgs).unwrap_err().contains("Tối đa"));
    }

    #[test]
    fn claude_line_has_image_block_before_text() {
        let img = PreparedImage {
            mime: "image/png",
            bytes: vec![1, 2, 3],
            path: PathBuf::from("/tmp/a.png"),
        };
        let line = claude_stream_input_line("Mô tả ảnh", &[img]);
        assert!(line.ends_with('\n'));
        let v: Value = serde_json::from_str(line.trim()).unwrap();
        assert_eq!(v["type"], "user");
        let content = &v["message"]["content"];
        assert_eq!(content[0]["type"], "image");
        assert_eq!(content[0]["source"]["media_type"], "image/png");
        assert_eq!(content[0]["source"]["data"], STANDARD.encode([1, 2, 3]));
        assert_eq!(content[1]["type"], "text");
        assert_eq!(content[1]["text"], "Mô tả ảnh");
    }

    #[test]
    fn agy_prompt_round_trips_through_split() {
        let imgs = vec![
            PreparedImage {
                mime: "image/png",
                bytes: vec![],
                path: PathBuf::from("/x/a.png"),
            },
            PreparedImage {
                mime: "image/jpeg",
                bytes: vec![],
                path: PathBuf::from("/x/b.jpg"),
            },
        ];
        let prompt = agy_prompt("So sánh hai ảnh", &imgs);
        assert!(prompt.contains("/x/a.png") && prompt.contains("/x/b.jpg"));
        let (text, paths) = split_agy_attachments(&prompt);
        assert_eq!(text, "So sánh hai ảnh");
        assert_eq!(paths, vec!["/x/a.png".to_string(), "/x/b.jpg".to_string()]);
    }

    #[test]
    fn split_without_block_keeps_text() {
        assert_eq!(
            split_agy_attachments("Chỉ có chữ"),
            ("Chỉ có chữ".to_string(), Vec::new())
        );
    }

    #[test]
    fn agy_prompt_without_images_is_plain_text() {
        assert_eq!(agy_prompt("hi", &[]), "hi");
    }

    #[test]
    fn transcript_image_is_read_back_by_uuid_and_index() {
        let raw = png_bytes(8, 8, false);
        let line = serde_json::json!({
            "type": "user",
            "uuid": "abc-123",
            "message": {"role": "user", "content": [
                {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": STANDARD.encode(&raw)}},
                {"type": "text", "text": "mô tả"}
            ]}
        });
        let dir = std::env::temp_dir().join(format!("muop-att-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("s.jsonl");
        std::fs::write(&file, format!("{{\"type\":\"assistant\"}}\n{line}\n")).unwrap();
        let (bytes, mime) = read_transcript_image(&file, "abc-123", 0).unwrap();
        assert_eq!(bytes, raw);
        assert_eq!(mime, "image/png");
        assert!(read_transcript_image(&file, "abc-123", 1).is_err());
        assert!(read_transcript_image(&file, "khong-co", 0).is_err());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn pct_encode_escapes_spaces_and_unicode() {
        assert_eq!(pct_encode("a b/é.png"), "a%20b/%C3%A9.png");
    }

    #[test]
    fn workdir_note_is_hidden_from_the_displayed_text() {
        let prompt = format!("Tạo file a.txt{}", agy_workdir_note("/mnt/p"));
        assert!(prompt.contains("/mnt/p"));
        assert_eq!(strip_agy_workdir_note(&prompt), "Tạo file a.txt");
        // Không có chỉ dẫn thì giữ nguyên
        assert_eq!(strip_agy_workdir_note("Chỉ có chữ"), "Chỉ có chữ");
    }

    #[test]
    fn workdir_note_survives_before_attachments_block() {
        let prompt = format!(
            "Xem ảnh{}\n\n{AGY_BLOCK_HEADER}\n- /tmp/x.png\n",
            agy_workdir_note("/mnt/p")
        );
        let (text, paths) = split_agy_attachments(&prompt);
        assert_eq!(paths, vec!["/tmp/x.png".to_string()]);
        assert_eq!(strip_agy_workdir_note(&text), "Xem ảnh");
    }
}
