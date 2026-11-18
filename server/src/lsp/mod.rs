//! Language server (LSP) cho Go, Dart, Rust.
//!
//! - Mỗi (ngôn ngữ, thư mục gốc project) có một tiến trình LSP (`gopls`, `dart language-server`, `rust-analyzer`).
//!   Server nói JSON-RPC với tiến trình đó qua stdin/stdout và trả kết quả cho client qua REST.
//! - Đường dẫn tiến trình: ưu tiên cấu hình người dùng đặt (bảng `lsp_settings`), rồi tới đường dẫn tự dò.
//! - Tiến trình không dùng quá `IDLE_TIMEOUT` sẽ bị dừng (`kill_on_drop`).

use serde::Serialize;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::atomic::{AtomicBool, AtomicI64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};
use std::time::{Duration, Instant};
use tokio::io::{AsyncBufRead, AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, Command};
use tokio::sync::{oneshot, Mutex as AsyncMutex};

mod client;
/// Số tiến trình LSP cùng lúc; vượt quá thì dừng tiến trình ít dùng nhất
mod config;
mod discovery;
mod lang;
mod navigation;
mod outline;
mod pool;
mod status;
#[cfg(test)]
mod tests;
mod tokens;
mod util;

pub use client::*;
use config::*;
pub use discovery::*;
pub use lang::*;
pub use navigation::*;
pub use outline::*;
pub use pool::*;
pub use status::*;
pub use tokens::*;
pub use util::*;
