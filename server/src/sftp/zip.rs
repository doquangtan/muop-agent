//! Ghi file zip không nén (method 0 "stored") để đóng gói nhiều file/thư mục khi tải xuống.
//! Không dùng crate ngoài: định dạng đơn giản, giới hạn trong [`MAX_ZIP_BYTES`] và số mục, không cần zip64.

use chrono::{Datelike, Local, Timelike};
use std::fs::File;
use std::io::{BufReader, BufWriter, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

/// Tổng dung lượng tối đa của một gói zip (dưới 4GB để không cần zip64)
pub const MAX_ZIP_BYTES: u64 = 1024 * 1024 * 1024;
/// Số mục tối đa trong một gói
pub const MAX_ZIP_ENTRIES: usize = 5000;

/// Một mục cần đóng gói
#[derive(Debug, Clone)]
pub struct Source {
    /// Đường dẫn trong gói, dùng `/`. Thư mục kết thúc bằng `/`.
    pub name: String,
    /// File nguồn trên đĩa. None = thư mục.
    pub path: Option<PathBuf>,
}

fn crc_table() -> &'static [u32; 256] {
    static TABLE: OnceLock<[u32; 256]> = OnceLock::new();
    TABLE.get_or_init(|| {
        let mut t = [0u32; 256];
        for (i, slot) in t.iter_mut().enumerate() {
            let mut c = i as u32;
            for _ in 0..8 {
                c = if c & 1 != 0 {
                    0xEDB8_8320 ^ (c >> 1)
                } else {
                    c >> 1
                };
            }
            *slot = c;
        }
        t
    })
}

/// CRC-32 (chuẩn zip) cộng dồn trên `data`
pub fn crc32_update(crc: u32, data: &[u8]) -> u32 {
    let t = crc_table();
    let mut c = !crc;
    for b in data {
        c = t[((c ^ *b as u32) & 0xFF) as usize] ^ (c >> 8);
    }
    !c
}

/// Thời gian và ngày theo định dạng DOS của zip
fn dos_datetime() -> (u16, u16) {
    let now = Local::now();
    let year = (now.year().clamp(1980, 2107) - 1980) as u16;
    let date = (year << 9) | ((now.month() as u16) << 5) | now.day() as u16;
    let time =
        ((now.hour() as u16) << 11) | ((now.minute() as u16) << 5) | (now.second() as u16 / 2);
    (time, date)
}

/// Ghi toàn bộ dữ liệu, theo dõi vị trí hiện tại trong file
struct Out<W: Write> {
    w: W,
    pos: u64,
}

impl<W: Write> Out<W> {
    fn put(&mut self, data: &[u8]) -> std::io::Result<()> {
        self.w.write_all(data)?;
        self.pos += data.len() as u64;
        Ok(())
    }
    fn u16(&mut self, v: u16) -> std::io::Result<()> {
        self.put(&v.to_le_bytes())
    }
    fn u32(&mut self, v: u32) -> std::io::Result<()> {
        self.put(&v.to_le_bytes())
    }
}

struct Central {
    name: Vec<u8>,
    crc: u32,
    size: u32,
    offset: u32,
    is_dir: bool,
}

/// CRC và kích thước của một file (đọc một lượt)
fn file_crc(path: &Path) -> std::io::Result<(u32, u64)> {
    let mut r = BufReader::new(File::open(path)?);
    let mut buf = vec![0u8; 64 * 1024];
    let mut crc = 0u32;
    let mut size = 0u64;
    loop {
        let n = r.read(&mut buf)?;
        if n == 0 {
            break;
        }
        crc = crc32_update(crc, &buf[..n]);
        size += n as u64;
    }
    Ok((crc, size))
}

/// Ghi gói zip vào `out`. Trả về số byte đã ghi. Lỗi nếu vượt giới hạn.
pub fn write_zip(out: &Path, sources: &[Source]) -> Result<u64, String> {
    if sources.len() > MAX_ZIP_ENTRIES {
        return Err("Quá nhiều mục để tải xuống một lần (tối đa 5000)".into());
    }
    let file = File::create(out).map_err(|e| format!("Không tạo được gói zip: {e}"))?;
    let mut w = Out {
        w: BufWriter::new(file),
        pos: 0,
    };
    let (time, date) = dos_datetime();
    let mut central: Vec<Central> = Vec::with_capacity(sources.len());
    let mut total: u64 = 0;

    let io = |e: std::io::Error| format!("Lỗi khi ghi gói zip: {e}");
    for src in sources {
        let name = src.name.as_bytes().to_vec();
        let (crc, size, is_dir) = match &src.path {
            None => (0u32, 0u64, true),
            Some(p) => {
                let (crc, size) =
                    file_crc(p).map_err(|e| format!("Không đọc được {}: {e}", src.name))?;
                (crc, size, false)
            }
        };
        total += size;
        if total > MAX_ZIP_BYTES {
            return Err("Dữ liệu tải xuống vượt quá 1GB".into());
        }
        let offset = w.pos as u32;
        // Local file header (cờ 0x0800: tên UTF-8)
        w.u32(0x0403_4B50).map_err(io)?;
        w.u16(20).map_err(io)?; // phiên bản cần để giải nén
        w.u16(0x0800).map_err(io)?;
        w.u16(0).map_err(io)?; // stored
        w.u16(time).map_err(io)?;
        w.u16(date).map_err(io)?;
        w.u32(crc).map_err(io)?;
        w.u32(size as u32).map_err(io)?;
        w.u32(size as u32).map_err(io)?;
        w.u16(name.len() as u16).map_err(io)?;
        w.u16(0).map_err(io)?; // extra
        w.put(&name).map_err(io)?;
        if let Some(p) = &src.path {
            let mut r = BufReader::new(
                File::open(p).map_err(|e| format!("Không đọc được {}: {e}", src.name))?,
            );
            let mut buf = vec![0u8; 64 * 1024];
            loop {
                let n = r
                    .read(&mut buf)
                    .map_err(|e| format!("Không đọc được {}: {e}", src.name))?;
                if n == 0 {
                    break;
                }
                w.put(&buf[..n]).map_err(io)?;
            }
        }
        central.push(Central {
            name,
            crc,
            size: size as u32,
            offset,
            is_dir,
        });
    }

    // Thư mục trung tâm
    let cd_offset = w.pos;
    for c in &central {
        w.u32(0x0201_4B50).map_err(io)?;
        w.u16(20).map_err(io)?; // phiên bản tạo
        w.u16(20).map_err(io)?; // phiên bản cần
        w.u16(0x0800).map_err(io)?;
        w.u16(0).map_err(io)?;
        w.u16(time).map_err(io)?;
        w.u16(date).map_err(io)?;
        w.u32(c.crc).map_err(io)?;
        w.u32(c.size).map_err(io)?;
        w.u32(c.size).map_err(io)?;
        w.u16(c.name.len() as u16).map_err(io)?;
        w.u16(0).map_err(io)?; // extra
        w.u16(0).map_err(io)?; // comment
        w.u16(0).map_err(io)?; // disk
        w.u16(0).map_err(io)?; // internal attrs
                               // external attrs: thư mục đặt cờ 0x10 (DOS directory)
        w.u32(if c.is_dir { 0x10 } else { 0 }).map_err(io)?;
        w.u32(c.offset).map_err(io)?;
        w.put(&c.name).map_err(io)?;
    }
    let cd_size = w.pos - cd_offset;

    // Kết thúc thư mục trung tâm
    w.u32(0x0605_4B50).map_err(io)?;
    w.u16(0).map_err(io)?;
    w.u16(0).map_err(io)?;
    w.u16(central.len() as u16).map_err(io)?;
    w.u16(central.len() as u16).map_err(io)?;
    w.u32(cd_size as u32).map_err(io)?;
    w.u32(cd_offset as u32).map_err(io)?;
    w.u16(0).map_err(io)?;
    w.w.flush().map_err(io)?;
    Ok(w.pos)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn crc32_matches_standard_check_value() {
        assert_eq!(crc32_update(0, b"123456789"), 0xCBF4_3926);
        assert_eq!(crc32_update(0, b""), 0);
    }

    #[test]
    fn writes_archive_with_files_and_directories() {
        let dir = std::env::temp_dir().join(format!("muop-zip-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let f = dir.join("a.txt");
        std::fs::write(&f, b"hello zip").unwrap();
        let out = dir.join("out.zip");
        let sources = vec![
            Source {
                name: "docs/".into(),
                path: None,
            },
            Source {
                name: "docs/a b.txt".into(),
                path: Some(f.clone()),
            },
        ];
        let n = write_zip(&out, &sources).unwrap();
        let bytes = std::fs::read(&out).unwrap();
        assert_eq!(bytes.len() as u64, n);
        // Chữ ký end-of-central-directory ở cuối và đủ 2 mục
        let eocd = bytes.len() - 22;
        assert_eq!(&bytes[eocd..eocd + 4], &[0x50, 0x4B, 0x05, 0x06]);
        assert_eq!(u16::from_le_bytes([bytes[eocd + 10], bytes[eocd + 11]]), 2);
        std::fs::remove_dir_all(&dir).ok();
    }
}
