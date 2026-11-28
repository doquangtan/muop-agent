//! Tách các khung JPEG từ luồng byte nối liền (gst `jpegenc` và ffmpeg `image2pipe` đều xuất như vậy).
//!
//! Không tìm chuỗi `FFD9` đơn giản: byte đó có thể nằm trong bảng lượng tử/Huffman hoặc đoạn APP.
//! Thay vào đó đi đúng cấu trúc marker: mỗi đoạn có độ dài, dữ liệu entropy (sau SOS) kết thúc
//! ở marker thật sự (`FFD9`), còn `FF00` và `FFD0`..`FFD7` là byte đệm/RST nằm trong dữ liệu.

/// Khung JPEG tối đa được chấp nhận (4 MB). Vượt quá thì coi là dữ liệu hỏng và bỏ.
const MAX_FRAME_BYTES: usize = 4 * 1024 * 1024;

#[derive(Debug, PartialEq, Eq)]
enum Scan {
    /// Khung đầy đủ, kết thúc ở vị trí này (không gồm)
    Frame(usize),
    /// Chưa đủ dữ liệu, đợi thêm
    NeedMore,
    /// Cấu trúc sai tại một điểm: bỏ SOI này và tìm khung sau
    Invalid,
}

/// Bộ tách khung: nạp dữ liệu theo từng đoạn, trả về các khung JPEG đã đủ.
#[derive(Default)]
pub struct JpegSplitter {
    buf: Vec<u8>,
}

impl JpegSplitter {
    pub fn push(&mut self, data: &[u8]) -> Vec<Vec<u8>> {
        self.buf.extend_from_slice(data);
        let mut frames = Vec::new();
        loop {
            // Bỏ rác trước SOI (FF D8)
            match find_soi(&self.buf) {
                Some(0) => {}
                Some(pos) => {
                    self.buf.drain(..pos);
                }
                None => {
                    // Giữ lại byte cuối nếu là FF (có thể là nửa đầu của SOI)
                    let keep = if self.buf.last() == Some(&0xFF) { 1 } else { 0 };
                    let drop = self.buf.len() - keep;
                    self.buf.drain(..drop);
                    break;
                }
            }
            if self.buf.len() > MAX_FRAME_BYTES {
                self.buf.clear();
                break;
            }
            match scan(&self.buf) {
                Scan::Frame(end) => {
                    frames.push(self.buf[..end].to_vec());
                    self.buf.drain(..end);
                }
                Scan::NeedMore => break,
                Scan::Invalid => {
                    self.buf.drain(..2);
                }
            }
        }
        frames
    }
}

fn find_soi(buf: &[u8]) -> Option<usize> {
    buf.windows(2).position(|w| w == [0xFF, 0xD8])
}

fn be16(buf: &[u8], at: usize) -> usize {
    ((buf[at] as usize) << 8) | buf[at + 1] as usize
}

/// Quét một khung bắt đầu bằng SOI tại `buf[0]`
fn scan(buf: &[u8]) -> Scan {
    let n = buf.len();
    let mut p = 2usize;
    loop {
        if p >= n {
            return Scan::NeedMore;
        }
        if buf[p] != 0xFF {
            return Scan::Invalid;
        }
        // Bỏ các byte FF đệm trước mã marker
        let mut q = p;
        while q < n && buf[q] == 0xFF {
            q += 1;
        }
        if q >= n {
            return Scan::NeedMore;
        }
        let code = buf[q];
        match code {
            0x00 => return Scan::Invalid,
            0xD9 => return Scan::Frame(q + 1),
            0x01 | 0xD0..=0xD7 => {
                p = q + 1;
                continue;
            }
            _ => {}
        }
        // Các marker còn lại có độ dài 2 byte (gồm chính nó)
        if q + 3 > n {
            return Scan::NeedMore;
        }
        let len = be16(buf, q + 1);
        if len < 2 {
            return Scan::Invalid;
        }
        let seg_end = q + 1 + len;
        if seg_end > n {
            return Scan::NeedMore;
        }
        if code != 0xDA {
            p = seg_end;
            continue;
        }
        // SOS: sau đoạn tiêu đề là dữ liệu entropy, kết thúc ở marker không phải FF00/RST
        let mut r = seg_end;
        loop {
            if r + 1 >= n {
                return Scan::NeedMore;
            }
            if buf[r] != 0xFF {
                r += 1;
                continue;
            }
            let c = buf[r + 1];
            if c == 0x00 || (0xD0..=0xD7).contains(&c) || c == 0xFF {
                r += if c == 0xFF { 1 } else { 2 };
                continue;
            }
            break;
        }
        p = r;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// JPEG tối thiểu nhưng đúng cấu trúc: SOI, APP0, DQT có byte FF D9 trong bảng (không phải marker),
    /// SOS, dữ liệu entropy có FF00 và RST0, rồi EOI.
    fn sample(tag: u8) -> Vec<u8> {
        let mut v = vec![0xFF, 0xD8];
        // APP0 (JFIF), độ dài 4 gồm chính nó
        v.extend_from_slice(&[0xFF, 0xE0, 0x00, 0x04, b'J', b'F']);
        // DQT, độ dài 2+1+4 = 7: bảng gồm FF D9 (giá trị dữ liệu, không phải marker)
        v.extend_from_slice(&[0xFF, 0xDB, 0x00, 0x07, 0x00, 0xFF, 0xD9, 0x01, 0x02]);
        // SOS, độ dài 2 + 1 (không có thành phần cụ thể cho đơn giản hoá: chỉ cần độ dài đúng)
        v.extend_from_slice(&[0xFF, 0xDA, 0x00, 0x03, 0x01]);
        // Dữ liệu entropy: FF00 là byte FF thật, FFD0 là RST0, tag để phân biệt khung
        v.extend_from_slice(&[0x12, 0xFF, 0x00, 0x34, 0xFF, 0xD0, tag]);
        v.extend_from_slice(&[0xFF, 0xD9]);
        v
    }

    #[test]
    fn splits_back_to_back_frames() {
        let mut s = JpegSplitter::default();
        let mut data = sample(1);
        data.extend(sample(2));
        let frames = s.push(&data);
        assert_eq!(frames, vec![sample(1), sample(2)]);
    }

    #[test]
    fn ignores_eoi_bytes_inside_tables() {
        // Khung đầu chứa FF D9 trong DQT; nếu tách theo chuỗi thì khung bị cắt sớm
        let mut s = JpegSplitter::default();
        let frames = s.push(&sample(7));
        assert_eq!(frames.len(), 1);
        assert_eq!(frames[0], sample(7));
    }

    #[test]
    fn joins_frame_split_across_pushes_byte_by_byte() {
        let mut s = JpegSplitter::default();
        let data = sample(3);
        let mut got = Vec::new();
        for b in &data {
            got.extend(s.push(std::slice::from_ref(b)));
        }
        assert_eq!(got, vec![data]);
    }

    #[test]
    fn skips_garbage_before_soi() {
        let mut s = JpegSplitter::default();
        let mut data = vec![0x00, 0x11, 0xFF];
        data.extend(sample(4));
        assert_eq!(s.push(&data), vec![sample(4)]);
    }

    #[test]
    fn recovers_after_invalid_segment() {
        let mut s = JpegSplitter::default();
        // SOI rồi byte không phải marker: bỏ qua rồi lấy khung hợp lệ phía sau
        let mut data = vec![0xFF, 0xD8, 0x42, 0x42];
        data.extend(sample(5));
        assert_eq!(s.push(&data), vec![sample(5)]);
    }

    #[test]
    fn real_encoder_output_splits_into_frames() {
        // Đầu ra thật của gst jpegenc (tạo khi kiểm thử, không nằm trong repo): chỉ chạy nếu có file
        let path = std::env::var("MUOP_TEST_MJPEG").unwrap_or_default();
        if path.is_empty() {
            return;
        }
        let data = std::fs::read(path).unwrap();
        let mut s = JpegSplitter::default();
        let frames = s.push(&data);
        assert!(!frames.is_empty());
        for f in &frames {
            assert_eq!(&f[..2], &[0xFF, 0xD8]);
            assert_eq!(&f[f.len() - 2..], &[0xFF, 0xD9]);
        }
    }
}
