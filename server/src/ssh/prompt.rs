//! Nhận diện prompt mật khẩu trong đầu ra PTY.
//!
//! - [`PromptKind::Ssh`]: `ssh` in `user@host's password: ` (hoặc `Password: ` với keyboard-interactive)
//!   và đọc mật khẩu từ chính PTY. Từ chối: `Permission denied, please try again.`.
//! - [`PromptKind::Sudo`]: `sudo` trên máy này in `[sudo] password for <user>: ` (sudo cũ) hoặc
//!   `[sudo: authenticate] Password: ` (sudo-rs, Ubuntu mới); bản địa hóa vẫn chứa `[sudo`. Từ chối:
//!   `Sorry, try again.` / `sudo: Authentication failed, try again.`.
//!
//! Bộ theo dõi báo khi đang chờ mật khẩu, và khi mật khẩu vừa gửi bị từ chối. Các prompt khác
//! (`Enter passphrase ...`, `passwd`...) bị bỏ qua.

/// Loại prompt đang theo dõi trong một phiên PTY
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum PromptKind {
    #[default]
    Ssh,
    Sudo,
}

impl PromptKind {
    /// Nhãn gửi cho client (`ssh` | `sudo`)
    pub fn label(self) -> &'static str {
        match self {
            PromptKind::Ssh => "ssh",
            PromptKind::Sudo => "sudo",
        }
    }
}

/// Thông báo từ chối của sudo (sudo cũ, sudo-rs, tiếng Việt). Hết lượt cũng chứa một mẫu trong danh sách.
pub const SUDO_REJECTIONS: &[&str] = &[
    "Sorry, try again.",
    "Xin lỗi, hãy thử lại.",
    "Authentication failed, try again.",
    "incorrect password attempt",
    "incorrect authentication attempt",
];

/// Thông báo từ chối của `ssh` (dạng dòng, khi đọc từ PTY)
const SSH_REJECTIONS: &[&str] = &[
    "Permission denied, please try again.",
    "Permission denied (",
];

/// Đầu ra (stderr của lệnh đã chạy xong) có phải là lỗi sai mật khẩu của loại prompt này không
pub fn is_rejected_output(kind: PromptKind, text: &str) -> bool {
    match kind {
        // ssh: mọi "Permission denied" trong stderr của chính ssh (lệnh một lần)
        PromptKind::Ssh => text.contains("Permission denied"),
        PromptKind::Sudo => SUDO_REJECTIONS.iter().any(|p| text.contains(p)),
    }
}

/// Nguồn của mật khẩu vừa gửi vào PTY
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Source {
    /// Mật khẩu nằm trong DB (tự dùng, hoặc người dùng chọn lưu)
    Stored,
    /// Người dùng gõ, không lưu
    Typed,
}

/// Sự kiện rút ra từ đầu ra
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Signal {
    /// `ssh` đang chờ mật khẩu
    Prompt,
    /// Mật khẩu vừa gửi bị từ chối
    Rejected(Source),
}

const MAX_LINE: usize = 512;

#[derive(Debug, Default)]
pub struct PromptDetector {
    kind: PromptKind,
    /// Dòng hiện tại dạng byte (sau ký tự xuống dòng cuối), đã bỏ mã ANSI. Giải mã UTF-8 khi so khớp.
    line: Vec<u8>,
    /// Đã báo prompt cho dòng này; chỉ báo lại sau khi có dòng mới
    announced: bool,
    /// Mật khẩu vừa gửi, chưa biết kết quả
    submitted: Option<Source>,
    /// Lần gửi trước bị từ chối: prompt kế tiếp phải hỏi lại người dùng
    pub rejected: bool,
    /// Trạng thái bỏ mã điều khiển: 0 bình thường, 1 vừa gặp ESC, 2 trong chuỗi CSI,
    /// 3 trong chuỗi OSC (ví dụ shell integration `ESC ] 3008;... BEL`)
    esc: u8,
}

impl PromptDetector {
    pub fn new(kind: PromptKind) -> Self {
        Self {
            kind,
            ..Self::default()
        }
    }

    pub fn kind(&self) -> PromptKind {
        self.kind
    }

    /// Đưa một đoạn đầu ra vào bộ theo dõi, trả về các sự kiện theo đúng thứ tự xuất hiện
    pub fn feed(&mut self, bytes: &[u8]) -> Vec<Signal> {
        let mut out = Vec::new();
        for &b in bytes {
            match self.esc {
                1 => {
                    self.esc = match b {
                        b'[' => 2,
                        b']' => 3,
                        _ => 0,
                    };
                    continue;
                }
                2 => {
                    if (0x40..=0x7e).contains(&b) {
                        self.esc = 0;
                    }
                    continue;
                }
                3 => {
                    // OSC kết thúc bằng BEL hoặc ESC \ (ESC mở đầu ký tự kế tiếp là '\', xử lý ở state 1)
                    match b {
                        0x07 => self.esc = 0,
                        0x1b => self.esc = 1,
                        _ => {}
                    }
                    continue;
                }
                _ => {}
            }
            match b {
                0x1b => self.esc = 1,
                b'\r' | b'\n' => {
                    let done =
                        String::from_utf8_lossy(&std::mem::take(&mut self.line)).into_owned();
                    if let Some(src) = self.submitted {
                        if self.is_rejection(&done) {
                            self.submitted = None;
                            self.rejected = true;
                            out.push(Signal::Rejected(src));
                        }
                    }
                    self.announced = false;
                }
                0x20..=0x7e | 0x80..=0xff | b'\t' => {
                    if self.line.len() < MAX_LINE {
                        self.line.push(b);
                    }
                    if b == b':' && !self.announced && self.is_prompt(&self.line) {
                        self.announced = true;
                        out.push(Signal::Prompt);
                    }
                }
                _ => {}
            }
        }
        out
    }

    /// Mật khẩu vừa được gửi vào PTY. Xóa cờ từ chối của lần trước.
    pub fn on_submit(&mut self, src: Source) {
        self.submitted = Some(src);
        self.rejected = false;
        self.announced = true;
    }
}

impl PromptDetector {
    fn is_prompt(&self, line: &[u8]) -> bool {
        let line = String::from_utf8_lossy(line);
        let t = line.trim_end();
        match self.kind {
            PromptKind::Ssh => t.to_ascii_lowercase().ends_with("password:"),
            // Có thể nằm sau chuỗi điều khiển của shell trên cùng dòng: chỉ cần chứa "[sudo"
            PromptKind::Sudo => t.contains("[sudo") && t.ends_with(':'),
        }
    }

    fn is_rejection(&self, line: &str) -> bool {
        let patterns = match self.kind {
            PromptKind::Ssh => SSH_REJECTIONS,
            PromptKind::Sudo => SUDO_REJECTIONS,
        };
        patterns.iter().any(|p| line.contains(p))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sudo_rs_prompt_and_rejection_formats() {
        // Đầu ra thật của sudo-rs 0.2.13 (đo bằng PTY với mật khẩu sai)
        let mut d = PromptDetector::new(PromptKind::Sudo);
        assert_eq!(
            d.feed("[sudo: authenticate] Password: ".as_bytes()),
            vec![Signal::Prompt]
        );
        d.on_submit(Source::Typed);
        let sig = d.feed(
            "****\r\nsudo: Authentication failed, try again.\r\n[sudo: authenticate] Password: "
                .as_bytes(),
        );
        assert_eq!(sig, vec![Signal::Rejected(Source::Typed), Signal::Prompt]);
        d.on_submit(Source::Typed);
        let sig =
            d.feed("****\r\nsudo: maximum 3 incorrect authentication attempts\r\n".as_bytes());
        assert_eq!(sig, vec![Signal::Rejected(Source::Typed)]);
    }

    #[test]
    fn sudo_prompt_after_shell_osc_on_same_line() {
        let mut d = PromptDetector::new(PromptKind::Sudo);
        let out = "\x1b]3008;start=abc;cwd=/tmp\x07john@h:~$ sudo ls\r\n\x1b]3008;end\x1b\\[sudo] password for john: ";
        assert_eq!(d.feed(out.as_bytes()), vec![Signal::Prompt]);
    }

    #[test]
    fn sudo_prompt_detected_and_ssh_ignores_it() {
        let mut d = PromptDetector::new(PromptKind::Sudo);
        assert_eq!(d.feed(b"[sudo] password for john: "), vec![Signal::Prompt]);
        let mut ssh = PromptDetector::new(PromptKind::Ssh);
        assert!(ssh.feed(b"[sudo] password for john: ").is_empty());
    }

    #[test]
    fn sudo_localized_prompt_and_rejection() {
        let mut d = PromptDetector::new(PromptKind::Sudo);
        assert_eq!(
            d.feed("[sudo] mật khẩu cho john: ".as_bytes()),
            vec![Signal::Prompt]
        );
        d.on_submit(Source::Typed);
        let sig = d.feed("\r\nXin lỗi, hãy thử lại.\r\n[sudo] mật khẩu cho john: ".as_bytes());
        assert_eq!(sig, vec![Signal::Rejected(Source::Typed), Signal::Prompt]);
        assert!(d.rejected);
    }

    #[test]
    fn sudo_ignores_passwd_and_plain_permission_denied() {
        let mut d = PromptDetector::new(PromptKind::Sudo);
        assert!(d.feed(b"New password: ").is_empty());
        d.on_submit(Source::Stored);
        // Lệnh khác in "Permission denied" không được coi là sai mật khẩu sudo
        assert!(d
            .feed(b"\r\ncat: /root/x: Permission denied\r\n")
            .is_empty());
        assert!(!d.rejected);
    }

    #[test]
    fn rejected_output_per_kind() {
        assert!(is_rejected_output(
            PromptKind::Ssh,
            "Permission denied (publickey,password)."
        ));
        assert!(!is_rejected_output(PromptKind::Ssh, "hello"));
        assert!(is_rejected_output(
            PromptKind::Sudo,
            "sudo: 3 incorrect password attempts"
        ));
        assert!(is_rejected_output(
            PromptKind::Sudo,
            "sudo: maximum 3 incorrect authentication attempts"
        ));
        assert!(!is_rejected_output(
            PromptKind::Sudo,
            "cat: x: Permission denied"
        ));
    }

    #[test]
    fn detects_ssh_password_prompt() {
        let mut d = PromptDetector::default();
        assert_eq!(d.feed(b"john@10.0.0.5's password: "), vec![Signal::Prompt]);
    }

    #[test]
    fn detects_keyboard_interactive_prompt_and_strips_ansi() {
        let mut d = PromptDetector::default();
        assert_eq!(
            d.feed(b"\x1b[1m(john@h) Password:\x1b[0m "),
            vec![Signal::Prompt]
        );
    }

    #[test]
    fn ignores_other_prompts() {
        let mut d = PromptDetector::default();
        assert!(d.feed(b"[sudo] password for john: ").is_empty());
        assert!(d.feed(b"\r\nEnter passphrase for key '/x': ").is_empty());
    }

    #[test]
    fn announces_once_per_line() {
        let mut d = PromptDetector::default();
        assert_eq!(d.feed(b"john's password: "), vec![Signal::Prompt]);
        assert!(d.feed(b"").is_empty());
        assert!(d.feed(b"x").is_empty());
    }

    #[test]
    fn reports_rejection_then_prompt_again() {
        let mut d = PromptDetector::default();
        assert_eq!(d.feed(b"john's password: "), vec![Signal::Prompt]);
        d.on_submit(Source::Typed);
        let sig = d.feed(b"\r\nPermission denied, please try again.\r\njohn's password: ");
        assert_eq!(sig, vec![Signal::Rejected(Source::Typed), Signal::Prompt]);
        assert!(d.rejected);
    }

    #[test]
    fn rejection_on_same_line_as_prompt() {
        // Không có ký tự xuống dòng sau khi gửi mật khẩu: thông báo nối vào dòng prompt
        let mut d = PromptDetector::default();
        d.feed(b"john's password: ");
        d.on_submit(Source::Stored);
        let sig = d.feed(b"Permission denied, please try again.\r\njohn's password: ");
        assert_eq!(sig, vec![Signal::Rejected(Source::Stored), Signal::Prompt]);
    }

    #[test]
    fn success_is_not_a_rejection() {
        let mut d = PromptDetector::default();
        d.feed(b"john's password: ");
        d.on_submit(Source::Stored);
        assert!(d.feed(b"\r\nWelcome to host\r\n$ ").is_empty());
        assert!(!d.rejected);
    }

    #[test]
    fn remote_permission_denied_is_ignored_without_submit() {
        let mut d = PromptDetector::default();
        assert!(d.feed(b"cat: /root/x: Permission denied\r\n").is_empty());
    }

    #[test]
    fn submit_clears_rejected_flag() {
        let mut d = PromptDetector::default();
        d.feed(b"john's password: ");
        d.on_submit(Source::Typed);
        d.feed(b"\r\nPermission denied (publickey,password).\r\n");
        assert!(d.rejected);
        d.on_submit(Source::Typed);
        assert!(!d.rejected);
    }
}
