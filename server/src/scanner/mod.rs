use crate::models::{
    AgentStep, ChatTurnStreamState, CommandExecutionRecord, ConversationSession, CustomAgentSpec,
    FileTouchRecord, GitSyncStatus, ModelQuotaBucket, ModelQuotaGroup, PlanArtifactInfo,
    ProjectWorkspace, QuotaReport, QuotaSnapshot, SessionStepsPageResponse, SubagentLane,
    ToolCallInfo,
};
use chrono::{DateTime, Utc};
use regex::Regex;
use rusqlite::{Connection, OpenFlags};
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::{Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant, SystemTime};

pub const DEFAULT_PORT: u16 = 8787;
pub const BRAIN_DIR_PATH: &str = "/home/john/.gemini/antigravity/brain";
pub const DAEMON_DIR_PATH: &str = "/home/john/.gemini/antigravity/daemon";
pub const SUMMARY_DB_PATH: &str = "/home/john/.gemini/antigravity/conversation_summaries.db";
pub const ECOSYSTEM_DIR_PATH: &str = "/home/john/Documents/muop-ecosystem";
#[allow(dead_code)]
pub const AGENTS_CONFIG_DIR_PATH: &str =
    "/home/john/Documents/muop-ecosystem/muop-erp-server/.agents";

mod agy_turns;
mod catalog;
mod detail;
mod git_sync;
mod list;
mod meta_db;
mod plans;
mod projects;
mod quotas;
mod running;
mod subagents;
mod summary;
mod system;
mod text;
mod transcript;
mod types;
mod watch;

pub use agy_turns::*;
pub use catalog::*;
pub use detail::*;
pub use git_sync::*;
pub use list::*;
use meta_db::*;
pub use plans::*;
pub use projects::*;
pub use quotas::*;
pub use running::*;
use subagents::*;
pub use summary::*;
pub use system::*;
use text::*;
use transcript::*;
use types::*;
pub use watch::*;
