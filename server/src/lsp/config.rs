use super::*;

pub(super) const MAX_CLIENTS: usize = 6;
pub(super) const IDLE_TIMEOUT: Duration = Duration::from_secs(20 * 60);
pub(super) const INIT_TIMEOUT: Duration = Duration::from_secs(120);
pub(super) const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);
/// Số lần thử lại khi kết quả rỗng (LSP có thể chưa phân tích xong tệp vừa mở)
pub(super) const RETRY_EMPTY_TIMES: usize = 4;
/// Loại token chuẩn LSP mà client khai báo hỗ trợ; server chỉ gửi token thuộc danh sách này
pub(super) const STANDARD_TOKEN_TYPES: &[&str] = &[
    "namespace",
    "type",
    "class",
    "enum",
    "interface",
    "struct",
    "typeParameter",
    "parameter",
    "variable",
    "property",
    "enumMember",
    "event",
    "function",
    "method",
    "macro",
    "keyword",
    "modifier",
    "comment",
    "string",
    "number",
    "regexp",
    "operator",
    "decorator",
];
