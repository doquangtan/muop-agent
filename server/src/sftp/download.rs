//! Tải xuống từ SFTP: một file thì tải trực tiếp, nhiều mục hoặc thư mục thì đóng thành một gói zip.
//!
//! - `prepare`: chuẩn bị bản tạm trên server (máy đích: `sftp get` vào thư mục phiên; "Máy này": dùng
//!   đường dẫn gốc), trả về `downloadId`.
//! - `GET /api/sftp/download/{id}`: phục vụ file đó dạng stream. Liên kết hết hạn sau [`TTL`].
//! - Liên kết mềm bên trong thư mục không được đóng gói (tránh vòng lặp); liên kết tới file vẫn đi theo.

use super::listing::{join, quote, quote_local};
use super::zip::{self, Source};
use super::{check_path, list_dir, run, session_of, split_parent, stat, touch, Failure, Session};
use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;
use std::sync::{Mutex, MutexGuard, OnceLock};
use std::time::{Duration, Instant};

/// Thời gian một liên kết tải xuống còn hiệu lực
pub const TTL: Duration = Duration::from_secs(15 * 60);

/// Kết quả chuẩn bị, gửi cho app
pub struct Prepared {
    pub id: String,
    pub name: String,
    pub size: u64,
}

/// File sẵn sàng để phục vụ
pub struct Served {
    pub path: PathBuf,
    pub name: String,
    pub size: u64,
}

struct Entry {
    path: PathBuf,
    name: String,
    size: u64,
    /// File tạm do server tạo (xóa khi hết hạn). False: file gốc trên "Máy này", không xóa.
    owned: bool,
    created: Instant,
    session_id: String,
}

static REGISTRY: OnceLock<Mutex<HashMap<String, Entry>>> = OnceLock::new();

fn registry() -> &'static Mutex<HashMap<String, Entry>> {
    REGISTRY.get_or_init(|| Mutex::new(HashMap::new()))
}

fn lock(m: &Mutex<HashMap<String, Entry>>) -> MutexGuard<'_, HashMap<String, Entry>> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

fn new_id() -> String {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    format!("dl-{}-{}", std::process::id(), nanos)
}

/// Mục cần đưa vào gói
struct Item {
    /// Đường dẫn trên máy đích
    path: String,
    /// Đường dẫn trong gói (thư mục kết thúc bằng `/`)
    name: String,
    is_dir: bool,
}

/// Lấy danh sách mục (cả cây thư mục) cần đóng gói, kiểm tra số lượng và dung lượng.
async fn collect(
    s: &Session,
    path: &str,
    name: &str,
    is_dir: bool,
    size: u64,
    out: &mut Vec<Item>,
    total: &mut u64,
) -> Result<(), Failure> {
    let mut stack = vec![(path.to_string(), name.to_string(), is_dir, size)];
    while let Some((path, name, is_dir, size)) = stack.pop() {
        if out.len() >= zip::MAX_ZIP_ENTRIES {
            return Err(Failure::msg(
                "Quá nhiều mục để tải xuống một lần (tối đa 5000)",
            ));
        }
        if is_dir {
            out.push(Item {
                path: path.clone(),
                name: format!("{name}/"),
                is_dir: true,
            });
            for e in list_dir(s, &path).await? {
                if e.is_link {
                    continue;
                }
                stack.push((
                    join(&path, &e.name),
                    format!("{name}/{}", e.name),
                    e.is_dir,
                    e.size,
                ));
            }
        } else {
            *total += size;
            if *total > zip::MAX_ZIP_BYTES {
                return Err(Failure::msg("Dữ liệu tải xuống vượt quá 1GB"));
            }
            out.push(Item {
                path,
                name,
                is_dir: false,
            });
        }
    }
    Ok(())
}

/// Tải các file từ máy đích về thư mục tạm của server, một lần chạy sftp cho cả danh sách
async fn fetch_remote(s: &Session, pairs: &[(String, PathBuf)]) -> Result<(), Failure> {
    if pairs.is_empty() {
        return Ok(());
    }
    let mut batch = String::new();
    for (remote, local) in pairs {
        let qr = quote(remote).map_err(Failure::msg)?;
        let ql = quote_local(local).map_err(Failure::msg)?;
        batch.push_str(&format!("get {qr} {ql}\n"));
    }
    run(s, &batch).await?;
    Ok(())
}

fn register(
    id: &str,
    session_id: &str,
    path: PathBuf,
    name: String,
    size: u64,
    owned: bool,
) -> Prepared {
    lock(registry()).insert(
        id.to_string(),
        Entry {
            path,
            name: name.clone(),
            size,
            owned,
            created: Instant::now(),
            session_id: session_id.to_string(),
        },
    );
    Prepared {
        id: id.to_string(),
        name,
        size,
    }
}

/// Chuẩn bị tải xuống các mục đã chọn trong một phiên SFTP.
pub async fn prepare(session_id: &str, paths: &[String]) -> Result<Prepared, Failure> {
    let s = session_of(session_id)?;
    if paths.is_empty() {
        return Err(Failure::msg("Chưa chọn mục nào để tải xuống"));
    }
    if paths.len() > zip::MAX_ZIP_ENTRIES {
        return Err(Failure::msg("Chọn quá nhiều mục (tối đa 5000)"));
    }
    for p in paths {
        check_path(p)?;
    }
    touch(&s);
    let id = new_id();

    // Thông tin từng mục được chọn
    let mut roots = Vec::with_capacity(paths.len());
    for p in paths {
        let Some((_, name)) = split_parent(p) else {
            return Err(Failure::msg("Không tải xuống thư mục gốc"));
        };
        let Some(entry) = stat(&s, p).await? else {
            return Err(Failure::msg(format!("Không tìm thấy {name}")));
        };
        roots.push((p.clone(), name, entry));
    }

    // Một file: tải trực tiếp, không đóng gói
    if roots.len() == 1 && !roots[0].2.is_dir {
        let (p, name, entry) = &roots[0];
        if entry.size > zip::MAX_ZIP_BYTES {
            return Err(Failure::msg("File quá lớn để tải xuống (tối đa 1GB)"));
        }
        if s.local {
            return Ok(register(
                &id,
                session_id,
                PathBuf::from(p),
                name.clone(),
                entry.size,
                false,
            ));
        }
        let stage = s.dir.join(format!("stage-{id}"));
        fs::create_dir_all(&stage)
            .map_err(|e| Failure::msg(format!("Không tạo được thư mục tạm: {e}")))?;
        let target = stage.join("file");
        fetch_remote(&s, &[(p.clone(), target.clone())]).await?;
        let size = fs::metadata(&target).map(|m| m.len()).unwrap_or(entry.size);
        return Ok(register(&id, session_id, target, name.clone(), size, true));
    }

    // Nhiều mục hoặc thư mục: đóng thành zip
    let mut items: Vec<Item> = Vec::new();
    let mut total: u64 = 0;
    for (p, name, entry) in &roots {
        collect(
            &s,
            p,
            name,
            entry.is_dir,
            entry.size,
            &mut items,
            &mut total,
        )
        .await?;
    }
    let archive_name = if roots.len() == 1 {
        format!("{}.zip", roots[0].1)
    } else {
        "muop-download.zip".to_string()
    };
    let zip_path = s.dir.join(format!("{id}.zip"));

    let (sources, stage) = if s.local {
        let sources = items
            .iter()
            .map(|it| Source {
                name: it.name.clone(),
                path: if it.is_dir {
                    None
                } else {
                    Some(PathBuf::from(&it.path))
                },
            })
            .collect::<Vec<_>>();
        (sources, None)
    } else {
        let stage = s.dir.join(format!("stage-{id}"));
        fs::create_dir_all(&stage)
            .map_err(|e| Failure::msg(format!("Không tạo được thư mục tạm: {e}")))?;
        let mut pairs = Vec::new();
        let mut sources = Vec::with_capacity(items.len());
        for (i, it) in items.iter().enumerate() {
            if it.is_dir {
                sources.push(Source {
                    name: it.name.clone(),
                    path: None,
                });
            } else {
                let local = stage.join(i.to_string());
                pairs.push((it.path.clone(), local.clone()));
                sources.push(Source {
                    name: it.name.clone(),
                    path: Some(local),
                });
            }
        }
        fetch_remote(&s, &pairs).await?;
        (sources, Some(stage))
    };

    // Ghi zip là việc đọc/ghi đĩa nặng: chạy ngoài luồng async
    let zp = zip_path.clone();
    let written = tokio::task::spawn_blocking(move || zip::write_zip(&zp, &sources))
        .await
        .map_err(|e| Failure::msg(format!("Lỗi khi đóng gói: {e}")))?;
    if let Some(stage) = stage {
        let _ = fs::remove_dir_all(stage);
    }
    written.map_err(Failure::msg)?;
    let size = fs::metadata(&zip_path).map(|m| m.len()).unwrap_or(0);
    Ok(register(
        &id,
        session_id,
        zip_path,
        archive_name,
        size,
        true,
    ))
}

/// Tra cứu liên kết tải xuống còn hạn. Không xóa khỏi danh sách (tải lại được trong thời gian hạn).
pub fn lookup(id: &str) -> Option<Served> {
    let mut map = lock(registry());
    let expired = map
        .get(id)
        .map(|e| e.created.elapsed() > TTL)
        .unwrap_or(false);
    if expired {
        if let Some(e) = map.remove(id) {
            if e.owned {
                let _ = fs::remove_file(&e.path);
            }
        }
        return None;
    }
    map.get(id).map(|e| Served {
        path: e.path.clone(),
        name: e.name.clone(),
        size: e.size,
    })
}

/// Xóa các liên kết hết hạn (và file tạm của chúng). Trả về số liên kết đã xóa.
pub fn reap_expired() -> usize {
    let mut map = lock(registry());
    let expired: Vec<String> = map
        .iter()
        .filter(|(_, e)| e.created.elapsed() > TTL)
        .map(|(id, _)| id.clone())
        .collect();
    for id in &expired {
        if let Some(e) = map.remove(id) {
            if e.owned {
                let _ = fs::remove_file(&e.path);
            }
        }
    }
    expired.len()
}

/// Bỏ các liên kết của một phiên đã đóng (file tạm nằm trong thư mục phiên nên đã được dọn)
pub fn forget_session(session_id: &str) {
    lock(registry()).retain(|_, e| e.session_id != session_id);
}
