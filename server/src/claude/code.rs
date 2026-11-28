//! Đọc session của Claude Code CLI từ `~/.claude/projects/<slug>/<session-id>.jsonl`
//! và chuyển thành `ConversationSession` để hiển thị chung với session Antigravity.
//!
//! Các session được cache theo (mtime, size) nên chỉ parse lại khi file thay đổi.

use crate::models::{
    AgentStep, ChatTurnStreamState, CommandExecutionRecord, ConversationSession, CustomAgentSpec,
    FileTouchRecord, ModelQuotaBucket, ModelQuotaGroup, SessionStepsPageResponse, SubagentLane,
    ToolCallInfo,
};
use crate::scanner::parse_markdown_frontmatter;
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant, UNIX_EPOCH};

/// Tên hiển thị của nhóm limit Claude Code trong danh sách quota
pub const CLAUDE_LIMIT_GROUP_PREFIX: &str = "Claude Code CLI";

mod cache;
mod cli;
mod extensions;
mod file_changes;
mod lanes;
mod limits;
mod paths;
mod session_files;
mod sessions;
mod side_effects;
mod status;
mod steps;
mod transcript;
mod transcript_index;
mod watch;

use cache::*;
pub use cli::*;
pub use extensions::*;
use file_changes::*;
use lanes::*;
pub use limits::*;
pub use paths::*;
pub(crate) use session_files::*;
pub use sessions::*;
use side_effects::*;
use status::*;
use steps::*;
use transcript::*;
use transcript_index::*;
pub use watch::*;
