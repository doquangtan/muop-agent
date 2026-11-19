pub mod attachments;
pub mod context_window;
pub mod quota_stall;
pub mod recovery;
pub mod retry;

use crate::models::{ChatSendRequest, ChatSendResponse, ChatTurnStreamState};
use crate::scanner;
use chrono::Utc;
use serde_json::Value;
use socketioxide::SocketIo;
use std::collections::HashMap;
use std::path::Path;
use std::process::Stdio;
use std::sync::{Arc, Mutex};
use std::time::Instant;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::Command;
use tokio::sync::oneshot;
use tokio::time::{timeout, Duration};

/// Tiền tố id model để UI chọn đúng backend (phải khớp với `scanner::default_models`)
pub const AGY_PREFIX: &str = "agy:";
pub const CLAUDE_PREFIX: &str = "claude-cli:";

mod args;
mod events;
mod finish;
mod provider;
mod start;
mod state;
mod turn;

pub use args::*;
use events::*;
pub use finish::*;
pub use provider::*;
pub use start::*;
pub use state::*;
use turn::*;
