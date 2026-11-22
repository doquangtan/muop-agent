# API của muop-agent Server

Tài liệu này mô tả toàn bộ REST API và sự kiện Socket.IO do Rust Server (`server/`) cung cấp. Viết tay theo mã nguồn ngày 2026-11-21; khi thêm hoặc đổi route/event, cập nhật file này.

- **Địa chỉ:** `http://<host>:8787` (server lắng nghe trên `0.0.0.0:8787`).
- **Định dạng:** JSON, khóa camelCase (`#[serde(rename_all = "camelCase")]`). Ngoại lệ: `GET /api/files/download` trả nội dung nhị phân.
- **Kích thước body:** tối đa 64MB (`MAX_REQUEST_BODY_BYTES`), đủ cho ảnh đính kèm base64.
- **Lỗi:** phần lớn endpoint trả `{"ok": false, "error": "<thông báo>"}` kèm HTTP 400, 404, 409, 403 hoặc 500 tùy trường hợp. Các endpoint đăng nhập và đọc code (LSP) trả HTTP 200 kèm `ok`/`error` để client hiển thị.
- **CORS:** cho phép mọi origin trong mạng LAN.
- **Nguồn khai báo:** route REST trong `server/src/api/mod.rs`; event Socket.IO trong `server/src/socket/mod.rs` và các module `*/socket.rs`, `setup/mod.rs`; DTO trong `server/src/models.rs`, `server/src/claude/questions.rs`.

## Mục lục

1. [Trạng thái, meta, quota](#1-trạng-thái-meta-quota)
2. [Session và lịch sử](#2-session-và-lịch-sử)
3. [Chat](#3-chat)
4. [Dự án](#4-dự-án)
5. [Git](#5-git)
6. [Kế hoạch (Plan)](#6-kế-hoạch-plan)
7. [Tương tác Claude Code](#7-tương-tác-claude-code)
8. [Câu hỏi AI (agy)](#8-câu-hỏi-ai-agy)
9. [Model theo conversation](#9-model-theo-conversation)
10. [File trên server](#10-file-trên-server)
11. [Đăng nhập agy](#11-đăng-nhập-agy)
12. [Đăng nhập Claude Code](#12-đăng-nhập-claude-code)
13. [Khởi tạo server (setup)](#13-khởi-tạo-server-setup)
14. [Máy SSH](#14-máy-ssh)
15. [Language server và mã nguồn](#15-language-server-và-mã-nguồn)
16. [Docker qua SSH](#16-docker-qua-ssh)
17. [Socket.IO](#17-socketio)
18. [Bridge (máy B điều khiển máy A)](#18-bridge-máy-b-điều-khiển-máy-a)

---

## 1. Trạng thái, meta, quota

### `GET /api/sessions`

`{ "sessions": [SessionSummary] }`: tóm tắt mọi conversation (không kèm steps, files, lanes). Tối đa 500.

### `GET /api/meta`

`MetaPayload`: `projects`, `availableModels`, `effortLevels`, `modelLabels`, `modelContextLimits`, `hostname`, `lanIps`, `port`, `timestamp`. Khi chưa sẵn sàng trả `{ "error": "meta không sẵn sàng" }`.

`effortLevels` là các mức suy nghĩ CLI `claude` hỗ trợ, đọc từ `claude --help` (ví dụ `low, medium, high, xhigh, max`). Model Claude được phát dạng `claude-cli:<model>-<mức>`; khi chạy server tách hậu tố và truyền `--effort <mức>`. Rỗng nếu không đọc được CLI.

### `GET /api/streams`

`{ "activeStreams": { <conversationId>: ChatTurnStreamState } }`: các lượt chat đang chạy.

### `GET /ping`, `GET /health`, `GET /api/ping`

Kiểm tra server sống:

```json
{
  "status": "ok",
  "app": "muop-agent-rust-server",
  "engine": "rust-axum-socketio",
  "hostname": "...",
  "ips": ["192.168.x.x"],
  "port": 8787,
  "timestamp": "2026-11-21T10:00:00+07:00"
}
```

### `GET /api/quota`

`QuotaSnapshot`: `{ "agy": QuotaReport, "claude": QuotaReport }`. Hai nguồn lấy song song; nguồn lỗi thì `error` ghi lý do, nguồn còn lại vẫn có dữ liệu. Quota agy được phép mở TUI agy để đọc `/usage` khi không có hub đang chạy (lần đầu mất khoảng 5–30 giây).

`QuotaReport`: `{ "provider": "agy" | "claude", "groups": [ModelQuotaGroup], "error": "" }`. `ModelQuotaGroup`: `{ displayName, description, buckets: [ModelQuotaBucket] }`. `ModelQuotaBucket`: `{ bucketId, displayName, description, window, remainingFraction, remainingPercent, resetTime }`.

Không có dữ liệu thì `groups` rỗng và `error` ghi lý do; server không trả số cũ hay số mặc định.

### `GET /api/quota/agy`

Quota Antigravity. Có thể mở TUI agy (`allow_host`) nếu không có hub. Kết quả đọc từ TUI giữ 5 phút, lỗi giữ 10 giây.

### `GET /api/quota/claude`

Quota Claude Code CLI, đọc từ endpoint usage của Anthropic (không phụ thuộc tiến trình).

---

## 2. Session và lịch sử

### `GET /api/session?id=<sessionId>`

Alias: `GET /api/session/detail?id=<sessionId>`.

Trả `ConversationSession`: `id`, `title`, `createdAt`, `updatedAt`, `status`, `currentPhase`, `steps` (tối đa 100 bước gần nhất), `subagentLanes`, `lanesLoaded`, `filesTouched`, `selectedModel`, `contextTokens`, `contextModel`, và các trường khác. Thiếu `id` trả 400 (`{"error": "Missing session id"}`), không tìm thấy trả 404.

Lượt đang chạy được lấy từ stream hiện tại, nên trạng thái `running` đúng khi mở conversation.

### `GET /api/session/steps?id=<sessionId>&before_step=<index>&limit=<n>`

Phân trang lịch sử. Lấy `limit` bước (mặc định 50) nằm ngay trước `before_step`. Alias tham số: `beforeStep`, `before_step_index`. Trả `SessionStepsPageResponse`:

```json
{
  "sessionId": "...",
  "steps": [AgentStep],
  "hasMore": true,
  "earliestStepIndex": 1200,
  "totalSteps": 2560
}
```

Thiếu `id` trả 400, không tìm thấy trả 404.

---

## 3. Chat

### `POST /api/chat/send`

Gửi một prompt tới agent. Body `ChatSendRequest`:

| Trường | Kiểu | Ghi chú |
| :--- | :--- | :--- |
| `prompt` | string | Nội dung. Bắt đầu bằng `/plan` để chạy claude-cli ở plan mode. |
| `projectPath` | string | Thư mục làm việc. |
| `conversationId` | string | Để trống để tạo conversation mới. |
| `agentName` | string | Ví dụ `Coordinator`. |
| `model` | string | `claude-cli:<model-id>` hoặc `agy:<model>`. |
| `images` | array | Tối đa 6 ảnh: `[{ "name", "mimeType", "dataBase64" }]`. Mỗi ảnh tối đa 20MB trước khi thu nhỏ. |

Phản hồi `ChatSendResponse`: `{ "ok", "conversationId", "projectPath", "error", "source" }`. `source` là `claude-cli` hoặc `agy`. HTTP 200 khi `ok`, 400 khi lỗi.

Lượt chat chạy bất đồng bộ. Tiến độ phát qua `chat:stream`; khi xong, `session:update` và `fileschange` được phát.

Ảnh được server nhận diện định dạng từ nội dung (PNG/JPEG/WebP), thu nhỏ cạnh dài về 1568px, lưu vào `~/.local/share/muop-agent/uploads/`. Claude CLI nhận ảnh qua `stream-json`; agy nhận prompt có khối `[Ảnh đính kèm]` liệt kê đường dẫn file.

Nếu lượt lỗi khớp mẫu rate limit, server tự xếp lịch gửi lại (xem `retry:update`).

### `POST /api/chat/stop`

Body: `{ "conversationId": "..." }`. Dừng lượt đang chạy của conversation. Phản hồi: `{ "ok": true, "stopped": <bool> }`.

### `GET /api/chat/attachment`

Tải ảnh đính kèm trong lịch sử, hai cách:

- agy: `?path=<file>`, chỉ đọc trong thư mục uploads.
- Claude: `?cid=<sessionId>&uuid=<uuid dòng user>&i=<n>`, server đọc lại block base64 từ transcript.

Trả nội dung ảnh. Lỗi trả JSON `{ "ok": false, "error" }` với 404 hoặc 500.

### `POST /api/chat/retry/cancel`

Hủy lịch tự gửi lại sau rate limit. Body: `{ "conversationId": "..." }`. Phản hồi: `{ "ok": true, "cancelled": <bool>, "conversationId" }`. Thiếu `conversationId` trả 400.

---

## 4. Dự án

### `POST /api/project/create`

Body `CreateProjectRequest`: `{ "name", "template": "standard", "description" }`. Tạo thư mục project mới theo template. Phản hồi `CreateProjectResponse`: `{ "ok", "message", "project", "error" }`; lỗi trả 400.

### `GET /api/project/agents?path=<projectPath>`

Alias: `?name=<projectName>`. Phản hồi `ProjectAgentsResponse`: `{ "ok", "projectPath", "projectName", "availableAgents", "customAgents", "skills", "rules", "error" }`.

### `GET /api/claude/extensions?path=<projectPath>`

Phản hồi `{ "ok", "items": [CustomAgentSpec] }`: skill, agent, command của Claude Code trong project.

---

## 5. Git

### `GET /api/git/history?projectPath=<path>&branch=<name>&limit=<n>`

Lịch sử commit. `limit` mặc định 100, tối đa 500. Phản hồi `GitHistoryResponse`: `{ ok, projectPath, projectName, currentBranch, branches, totalCommits, commits: [GitCommitSummary], error }`.

### `GET /api/git/status?projectPath=<path>`

Trạng thái git của project so với HEAD, dùng để tô màu explorer:

```json
{ "ok": true, "isRepo": true, "kinds": { "/abs/path/file.dart": "modified", "/abs/path/new.dart": "created" }, "truncated": false, "error": "" }
```

- `isRepo = false` nếu thư mục không nằm trong git repository; khi đó client dựa vào thay đổi do agent ghi.
- `kinds`: `created` (file mới hoặc chưa được theo dõi), `modified`, `deleted`. Tối đa 5000 mục; `truncated = true` nếu bị cắt.

### `GET /api/git/commit?projectPath=<path>&hash=<hash>`

Chi tiết một commit (`GitCommitDetailResponse`, kèm danh sách `GitCommitFileChange`: `path`, `status`, `additions`, `deletions`). `hash` phải là hex từ 4 đến 40 ký tự, không thì 400.

### `POST /api/git/push`

Body `GitPushRequest`: `{ "projectPath", "branch" }`. Chạy `git push` cho branch đã chọn. Phản hồi `GitPushResponse`: `{ ok, message, output, error }`.

---

## 6. Kế hoạch (Plan)

### `GET /api/plan/pending?id=<conversationId>`

Alias: `conversationId`. Trả `{ "ok": true, "plans": [PlanArtifactInfo] }` (`fileName`, `filePath`, `title`, `summary`, `updatedAt`, `requestFeedback`, `content`). Thiếu id trả 400.

### `POST /api/plan/action`

Body `PlanActionRequest`:

| Trường | Ghi chú |
| :--- | :--- |
| `conversationId` | Conversation chứa kế hoạch. Thiếu thì 400. |
| `fileName` | Tên file kế hoạch. |
| `action` | `approve`, `reject` hoặc `cancel`. |
| `feedback` | Góp ý khi `reject`. |
| `model` | Model dùng để chạy lượt tiếp theo. |

- `approve` gửi prompt `approved` vào conversation.
- `cancel` gửi prompt `cancel plan`.
- `reject` gửi góp ý để agent cập nhật kế hoạch.

---

## 7. Tương tác Claude Code

Các tương tác `AskUserQuestion` và `ExitPlanMode` của Claude Code đang chờ người dùng trả lời.

### `GET /api/claude/pending?id=<conversationId>`

Alias: `conversationId`.

```json
{
  "ok": true,
  "conversationId": "...",
  "pending": {
    "conversationId": "...",
    "toolUseId": "toolu_...",
    "kind": "question | plan",
    "createdAt": "...",
    "questions": [ { "question": "...", "header": "...", "multiSelect": false, "options": [ { "label": "...", "description": "..." } ] } ],
    "plan": "<markdown>"
  }
}
```

`pending` là `null` khi không có gì chờ. Không trả về khi lượt đang chạy.

### `POST /api/claude/respond`

Body `ClaudeInteractionResponse`:

| Trường | Ghi chú |
| :--- | :--- |
| `conversationId` | Conversation đang chờ. Thiếu thì 400. |
| `toolUseId` | Phải khớp với `pending.toolUseId`, nếu không trả 409. |
| `projectPath`, `model` | Dùng để chạy lượt tiếp theo. |
| `answers` | Với `question`: `[ { "question", "answer" } ]`. |
| `decision` | Với `plan`: `approve`, `cancel` hoặc `feedback`. |
| `feedback` | Nội dung góp ý khi `decision = feedback`. |

Lỗi: 409 khi tương tác không còn chờ hoặc phiên đang chạy; 400 khi thiếu câu trả lời hoặc lỗi khác.

---

## 8. Câu hỏi AI (agy)

### `GET /api/ai-questions?conversationId=<id>`

Trả `{ "ok", "conversationId", "questions": [AIQuestion], "error" }`. `AIQuestion`: `id`, `conversationId`, `stepIndex`, `question`, `createdAt`, `answeredAt`, `answer`, `isPending`. Thiếu `conversationId` trả 400.

### `POST /api/ai-questions/answer`

Body: `{ "questionId": "...", "answer": "..." }`. Ghi câu trả lời, phát `ai-question:answered` và trả `AIQuestionResponse` (`questionId`, `answer`). Body không đọc được hoặc JSON sai trả 400.

---

## 9. Model theo conversation

Dữ liệu lưu trong SQLite `~/.local/share/muop-agent/muop-agent.db`.

### `GET /api/conversation/model?id=<conversationId>`

Trả `{ "conversationId", "model" }`. Thiếu `id` trả 400.

### `POST /api/conversation/model`

Body `{ "conversationId", "model" }`. Phản hồi `{ "ok", "conversationId", "model" }`. Thiếu một trong hai trả 400; lưu lỗi trả 500.

### `POST /api/model/context-limit`

Sửa tay giới hạn context của một model. Body `{ "model": "claude-cli:...", "limit": 1000000 }` (`limit` > 0). Lưu với nguồn `manual`, không bị quét ghi đè. Phản hồi `{ "ok", "model", "limit" }`.

---

## 10. File trên server

Đường dẫn là đường dẫn tuyệt đối trên máy server. Các endpoint này không có kiểm tra giới hạn thư mục riêng.

### `GET /api/files/list?path=<dir>&showHidden=<bool>`

Phản hồi `ServerDirListResponse`: `{ "ok", "currentPath", "parentPath", "entries": [ServerFileEntry], "error" }`. `ServerFileEntry`: `name`, `path`, `isDir`, `size`, `modifiedAt`, `permissions`.

### `GET /api/files/read?path=<file>`

Phản hồi `ServerFileReadResponse`: `{ "ok", "path", "name", "size", "isBinary", "isImage", "content", "gitDiff", "error" }`.

### `GET /api/files/lines?path=<file>&offset=<dòng>&limit=<số dòng>`

Đọc một đoạn dòng của tệp văn bản mà không nạp cả tệp. Server đánh chỉ mục byte offset của từng dòng (cache theo mtime và kích thước). `limit` mặc định 200, tối đa 400. Mỗi dòng được cắt tối đa 2000 ký tự.

```json
{
  "ok": true,
  "path": "...",
  "name": "...",
  "size": 86745462,
  "isBinary": false,
  "totalLines": 36310,
  "offset": 0,
  "lines": ["..."],
  "hasMore": true,
  "gitDiff": "...",
  "error": ""
}
```

`gitDiff` chỉ có khi `offset = 0`, cắt tối đa 200KB, và bỏ qua với file lớn hơn 20MB. Tệp nhị phân trả `isBinary: true` và không có dòng.

### `GET /api/files/download?path=<file>`

Tải file với `Content-Type` theo đuôi, `Content-Length` và `Cache-Control: no-cache`. Thiếu `path` trả 400; file không tồn tại trả 404 kèm JSON lỗi.

---

## 11. Đăng nhập agy

Trạng thái đăng nhập là `AgyAuthEvent`:

```json
{
  "ok": true,
  "phase": "idle | logged_out | unknown | login_terminal | logged_in | failed | cancelled | expired",
  "loggedIn": false,
  "loginUrl": "",
  "loginStage": "waiting_link | awaiting_token | verifying | awaiting_terms | ''",
  "error": "",
  "sshSessionId": "",
  "sshHostId": 0
}
```

- `login_terminal`: đang có terminal chạy `agy` (`sshSessionId`) để người dùng đăng nhập; dùng socket `ssh:attach` để hiện terminal.
- Mã Google dán vào app đi qua `POST /api/agy/auth/login/submit`. Mã trống, có khoảng trắng hoặc không có terminal thì `ok: false`, phase giữ nguyên.

| Method | Path | Ghi chú |
| :--- | :--- | :--- |
| GET | `/api/agy/auth/status` | Trạng thái hiện tại (`AgyAuthEvent`). |
| POST | `/api/agy/auth/check` | Kiểm tra đã đăng nhập chưa; nếu đang có terminal và đã vào màn chat thì kết thúc luồng. |
| POST | `/api/agy/auth/logout` | Đăng xuất qua TUI agy (`/logout`). |
| POST | `/api/agy/auth/login/start` | Mở terminal đăng nhập. Bị từ chối nếu đã đăng nhập. |
| POST | `/api/agy/auth/login/submit` | Body `{ "code": "..." }`. Ghi mã vào terminal đăng nhập. |
| POST | `/api/agy/auth/login/cancel` | Đóng terminal, phase `cancelled`. |

Trạng thái đăng nhập không dùng hub; dùng `agy models` và log agy. Luồng đăng nhập và các phase chi tiết nằm trong `AGENTS.md` mục 8.6l.

---

## 12. Đăng nhập Claude Code

`ClaudeAuthResponse`: `{ "ok", "loggedIn", "email", "subscriptionType", "loginUrl", "error" }`. `loginUrl` là link Anthropic đang chờ mã xác thực (rỗng nếu không có phiên đăng nhập).

| Method | Path | Ghi chú |
| :--- | :--- | :--- |
| GET | `/api/claude/auth/status` | Trạng thái đăng nhập. |
| POST | `/api/claude/auth/logout` | Đăng xuất. |
| POST | `/api/claude/auth/login/start` | Alias: `/api/claude/auth/start`. |
| POST | `/api/claude/auth/login/submit` | Alias: `/api/claude/auth/submit`. Body `{ "code": "..." }`. |
| POST | `/api/claude/auth/login/cancel` | Alias: `/api/claude/auth/cancel`. |

---

## 13. Khởi tạo server (setup)

`SetupStatus`: `{ "ok", "error", "completed", "selectedClis", "tools": [ToolStatus], "job": JobStatus | null, "ssh": SshStatus }`.

| Method | Path | Body | Ghi chú |
| :--- | :--- | :--- | :--- |
| GET | `/api/setup/status` | | Trạng thái công cụ và job cài. |
| POST | `/api/setup/install` | `{ "tool": "agy" \| "claude" }` | Cài trên **máy chạy server**. Chỉ hai tool này cài tự động; id khác bị từ chối (400). Một job tại một thời điểm, timeout 20 phút. |
| POST | `/api/setup/select` | `{ "clis": ["agy", "claude"] }` | Lưu CLI đã chọn. Lỗi trả 400. |
| POST | `/api/setup/complete` | | Đánh dấu hoàn tất wizard. Lỗi trả 500. |
| POST | `/api/setup/ssh/configure` | `{ "username" }` | Cấu hình SSH cho user. |
| POST | `/api/setup/ssh/auto` | | Sinh khóa, publish vào `authorized_keys`, thử đăng nhập. |
| POST | `/api/setup/ssh/verify` | `{ "publicKey" }` | Kiểm tra khóa đã dán có trong `authorized_keys` và đăng nhập được. |

Tiến trình đẩy qua socket `setup:update`. Các endpoint `ssh/*` vẫn còn nhưng wizard không dùng bước SSH nữa.

---

## 14. Máy SSH

`SshHostDto`: `{ id, name, host, port, username, authType: "password" | "key" | "local", hasPassword, hasKey, builtin }`. Không trả mật khẩu hay private key.

"Máy này" (`builtin: true`) luôn có, đứng đầu danh sách. Sửa hoặc xóa trả 403.

| Method | Path | Body / Query | Ghi chú |
| :--- | :--- | :--- | :--- |
| GET | `/api/ssh/hosts` | | Trả **mảng** `SshHostDto`. |
| POST | `/api/ssh/hosts/save` | `SshHostSaveRequest` | `{ id, name, host, port, username, authType, password, privateKey }`. Để trống `password`/`privateKey` khi sửa = giữ nguyên. Trả `{ ok, id }`. Lỗi 400/500. |
| POST | `/api/ssh/hosts/delete` | `{ "id" }` | Trả `{ ok }`; 404 nếu không có. |
| POST | `/api/ssh/exec` | `{ hostId, command, timeoutSecs }` (mặc định 30s) | Chạy lệnh một lần. Trả `SshExecResponse`: `{ ok, exitCode, stdout, stderr, error }`. Máy này chạy `$SHELL -i -c`. Không tìm thấy máy 404. |
| GET | `/api/ssh/sessions` | | Trả **mảng** `SshSessionInfo`: `{ sessionId, hostId, hostName, startedAt }` (phiên terminal đang chạy). |

Lệnh chạy bằng binary `ssh` của hệ thống. Mật khẩu đi qua `SSH_ASKPASS` trong thư mục tạm 0700; key ghi vào file tạm 0600 rồi xóa. Trừ "Máy này" (chạy shell trực tiếp, không qua ssh).

---

## 15. Language server và mã nguồn

Hỗ trợ Go (`gopls`), Dart (`dart language-server`), Rust (`rust-analyzer`).

### `GET /api/lsp/settings`

`{ "ok", "error", "languages": [ { language, label, configuredPath, detectedPath, effectivePath, source: "config" | "auto" | "none", available, note } ] }`.

### `POST /api/lsp/settings`

Body `{ "language": "go" | "dart" | "rust", "path": "..." }`. `path` rỗng = xóa cấu hình. `path` phải chạy thử được (`--version`), không thì `ok: false`. Phản hồi có `languages` mới.

### `GET /api/code/fold?path=<file>`

`{ "ok", "error", "language", "ranges" }`: vùng gấp của file.

### `GET /api/code/symbols?path=<file>`

`{ "ok", "error", "symbols" }`: danh sách hàm/ký hiệu. Dòng đếm từ 0.

### `GET /api/code/tokens?path=<file>`

Semantic tokens: `{ "ok", "error", "kinds": [...], "data": [dòng, cột, độ dài, chỉ số loại, ...] }`. Client giải mã bộ 4 số theo `kinds`.

### `POST /api/code/definition`

Body `CodeDefinitionRequest`: `{ "path", "line", "character" }` (đếm từ 0). Phản hồi `{ "ok", "error", "locations" }`.

### `POST /api/code/references`

Cùng body. Phản hồi `{ "ok", "error", "locations" }`, kể cả khai báo.

### `POST /api/code/hover`

Cùng body. Phản hồi `{ "ok", "error", "contents" }` (markdown từ LSP).

Lỗi LSP trả `{ "ok": false, "error" }` với HTTP 200. Kết quả rỗng khi LSP vừa khởi động được thử lại tối đa 4 lần.

---

## 16. Docker qua SSH

Mỗi máy SSH có tối đa một phiên Docker (kết nối `ssh -MNf` giữ sẵn). Đóng màn hình không ngắt phiên; chỉ `close` mới đóng.

`DockerSessionDto`: `{ sessionId, hostId, hostName, startedAt, connected, scannedAt, error, containers: [DockerContainerDto] }`. `DockerContainerDto`: `{ id, name, image, state, status, ports, project, service, created }`. Chỉ liệt kê container đang chạy, nhóm theo label compose.

`DockerSessionResponse`: `{ "ok", "error", "session" }`. `404` nghĩa là phiên đã kết thúc (client hiện nút "Mở phiên mới").

| Method | Path | Body | Ghi chú |
| :--- | :--- | :--- | :--- |
| GET | `/api/docker/sessions` | | Trả **mảng** `DockerSessionDto`. |
| POST | `/api/docker/sessions/open` | `{ "hostId" }` | Mở phiên cho máy, hoặc gắn vào phiên đang chạy. |
| POST | `/api/docker/sessions/scan` | `{ "sessionId" }` | Quét lại container. |
| POST | `/api/docker/sessions/action` | `{ "sessionId", "action": "stop" \| "restart", "containerIds": [...] }` | ID phải là hex 12–64 ký tự. Trả `{ ok, error }`. |
| POST | `/api/docker/sessions/close` | `{ "sessionId" }` | Kết thúc phiên, dọn master và thư mục tạm. |

Xem log container không dùng REST mà dùng socket `docker:logs:*` (mục 17).

---

## 17. Socket.IO

Namespace mặc định `/`, Socket.IO v4, WebSocket và polling. Ack là giá trị trả về của callback.

Ngay khi kết nối, server gửi: `retry:update`, `screen:status`, `setup:update`, `agy:auth:update`, `claude:auth:update`, và `quotas:update` (quota hiện tại). Client mới nên gọi `request-sessions`, `request-meta`, `request-streams` ngay sau khi kết nối (và sau khi kết nối lại).

### 17.1. Client gửi (có ack)

| Event | Payload | Ack / phản hồi |
| :--- | :--- | :--- |
| `request-sessions` | | Server phát `sessions:list`. |
| `request-meta` | | Server phát `meta:update`. |
| `request-streams` | | Server phát `streams:update`. |
| `request-screen-status` | | Server phát `screen:status`. |
| `chat:send` | `ChatSendRequest` (như REST) | `ChatSendResponse`. |
| `chat:stop` | `{ "conversationId" }` | `{ "ok": true, "stopped": <bool> }`. |
| `join-conversation` | `{ "conversationId" }` | Phát `joined-conversation`; vào room `conv:<id>` để nhận `fileschange`. |
| `leave-conversation` | `{ "conversationId" }` | Rời room. |
| `ssh:list` | | Mảng `SshSessionInfo`. |
| `ssh:open` | `{ "hostId", "cols", "rows" }` | `{ ok, sessionId, error }`. Socket tự join room `ssh:<sessionId>` trước khi PTY chạy. |
| `ssh:attach` | `{ "sessionId" }` | `{ ok, sessionId, hostName, buffer (base64), error }`. Join room, nhận đầu ra đã đệm (256KB). |
| `ssh:input` | `{ "sessionId", "data" (base64) }` | Không ack. |
| `ssh:resize` | `{ "sessionId", "cols", "rows" }` | Không ack. |
| `ssh:close` | `{ "sessionId" }` | Đóng phiên. |
| `docker:logs:open` | `{ "sessionId", "containerId", "tail" }` | `{ ok, streamId, error }`. Join room `docker-logs:<streamId>` trước. Tối đa 16 luồng. |
| `docker:logs:ping` | `{ "streamId" }` | Gọi mỗi 10 giây. Quá 30 giây không ping thì server dừng luồng. |
| `docker:logs:close` | `{ "streamId" }` | Dừng luồng ngay. |
| `agy:auth:status` | | `AgyAuthEvent`. |
| `agy:auth:check` | | `AgyAuthEvent`. |
| `agy:auth:start` | | `AgyAuthEvent`. |
| `agy:auth:submit` | `{ "code" }` | `AgyAuthEvent`. |
| `agy:auth:cancel` | | `AgyAuthEvent`. |
| `agy:auth:logout` | | `AgyAuthEvent`. |
| `accounts:status` | | `AgyAuthEvent`. |
| `claude:auth:status` | | `ClaudeAuthResponse`. |
| `claude:auth:start` | | `ClaudeAuthResponse`. |
| `claude:auth:submit` | `{ "code" }` | `ClaudeAuthResponse`. |
| `claude:auth:cancel` | | `ClaudeAuthResponse`. |
| `claude:auth:logout` | | `ClaudeAuthResponse`. |
| `setup:status` | | `SetupStatus`. |
| `setup:install` | `{ "tool" }` | `SetupStatus`. |
| `setup:select` | `{ "clis": [...] }` | `SetupStatus`. |
| `setup:complete` | | `SetupStatus`. |
| `setup:ssh:configure` | `{ "username" }` | `SetupStatus`. |
| `setup:ssh:auto` | | `SetupStatus`. |
| `setup:ssh:verify` | `{ "publicKey" }` | `SetupStatus`. |

### 17.2. Server phát

| Event | Khi nào | Payload |
| :--- | :--- | :--- |
| `sessions:list` | Sau `request-sessions` | `{ "sessions": [SessionSummary] }`. |
| `meta:update` | Sau `request-meta` | `MetaPayload` (mục 1). |
| `streams:update` | Sau `request-streams`, và khi danh sách lượt đang chạy đổi | `{ "activeStreams": { <id>: ChatTurnStreamState } }`. |
| `chat:stream` | Trong lượt chat | `ChatTurnStreamState`: `conversationId`, `projectPath`, `userPrompt`, `streamingText`, `thinkingText`, `isRunning`, `activeStepType`, `startedAt`, `error`. |
| `session:update` | Một conversation thay đổi | `ConversationSession` đầy đủ của conversation đó. |
| `session:removed` | Conversation bị xóa khỏi đĩa | `{ "id" }`. |
| `fileschange` | File trong conversation thay đổi (phát vào room `conv:<id>`) | Dữ liệu thay đổi file của conversation. |
| `joined-conversation` | Sau `join-conversation` | `{ "ok": true, "conversationId" }`. |
| `projects:update` | Danh sách project thay đổi | Mảng `ProjectWorkspace`. |
| `quotas:update` | Số liệu quota đổi (và khi kết nối) | `QuotaSnapshot`: `{ "agy": QuotaReport, "claude": QuotaReport }` (mục 1). Client tải lại quota khi nhận. |
| `retry:update` | Khi kết nối và mỗi lần lịch tự gửi lại đổi | Mảng `PendingRetryDto`: `conversationId`, `provider`, `reason`, `retryAt` (RFC3339 UTC), `attempt`, `maxAttempts`. |
| `ai-question:answered` | Sau khi trả lời câu hỏi AI | `AIQuestion` đã trả lời. |
| `screen:status` | Khi kết nối, sau `request-screen-status`, khi trạng thái quay màn hình đổi | Trạng thái quay màn hình (có URL RTSP khi đang bật). |
| `setup:update` | Khi kết nối và khi tiến trình cài đổi | `SetupStatus`, kèm `job.log` 300 dòng cuối. |
| `agy:auth:update` | Khi kết nối và khi trạng thái đăng nhập agy đổi (chỉ phát khi nội dung đổi) | `AgyAuthEvent`. |
| `claude:auth:update` | Khi kết nối và khi trạng thái đăng nhập Claude đổi | `ClaudeAuthResponse`. |
| `ssh:data` | Đầu ra terminal SSH | `{ sessionId, data (base64) }`, phát vào room `ssh:<sessionId>`. |
| `ssh:closed` | Phiên terminal kết thúc | `{ sessionId, exitCode }`. |
| `docker:logs:data` | Có dòng log mới | `{ streamId, lines: [...] }`, gom theo lô 150ms hoặc 80 dòng. |
| `docker:logs:end` | Luồng log kết thúc | `{ streamId, exitCode }`. |

### 17.3. Lưu ý

- Socket.IO tách mảng cấp cao nhất của một event thành nhiều đối số. Vì vậy `sessions:list` được bọc trong object; `projects:update` vẫn là mảng, client đọc mọi đối số để ghép lại.
- `chat:send` ghi lại ack `ChatSendResponse`, còn `chat:stream` là luồng tiến độ. Trạng thái các lượt đang chạy lấy từ `streams:update`, không suy ra từ `chat:stream` đã nhận trước đó.
- Phiên terminal SSH và Docker tồn tại độc lập với client. Thoát màn hình chỉ tách khỏi phiên; mở lại bằng `ssh:list` và `ssh:attach`.
- Phiên SSH không được dùng (input/attach) quá 6 giờ thì tự đóng.

---

## 18. Bridge (máy B điều khiển máy A)

Server máy B kết nối tới server máy A để gửi lệnh tới agent đang chạy trên A và nhận sự kiện của A. Mã nguồn: `server/src/bridge/` (kết nối, giao thức Socket.IO tối thiểu), `server/src/api/bridge.rs` (REST). Chỉ dùng WebSocket; chưa có xác thực (chỉ dùng trong LAN/VPN tin cậy).

Địa chỉ máy A lưu trong `app_settings` (khoá `bridge_peer_url`). Server tự kết nối lại khi khởi động và khi mất kết nối (backoff 1 → 30 giây).

### 18.1. REST trên máy B

| Route | Body | Phản hồi |
| :--- | :--- | :--- |
| `GET /api/bridge/status` | | `{ url, connected, error }` |
| `POST /api/bridge/peer` | `{ "url": "http://IP:8787" }` (rỗng để ngắt) | Trạng thái mới. Chỉ nhận `http://`. |
| `POST /api/bridge/send` | Như `POST /api/chat/send` của A (`prompt`, `conversationId`, `projectPath`, `model`, `images`) | Ack của A (`ChatSendResponse`). |
| `POST /api/bridge/stop` | `{ "conversationId" }` | Ack của A (`chat:stop`). |
| `POST /api/bridge/respond` | Như `POST /api/claude/respond` của A | Proxy phản hồi của A. |

Lỗi kết nối tới A trả HTTP 503 (`send`, `stop`) hoặc 502 (`respond`) kèm `{ ok: false, error }`. Lỗi nghiệp vụ của A (ví dụ 409 khi tương tác không còn chờ) được trả nguyên trong body.

Nhãn nguồn: `send` thêm `[Từ máy <hostname máy B>] ` vào đầu `prompt` trước khi gửi tới A.

**Trả lời agy:** không có route riêng. `POST /api/ai-questions/answer` của A chỉ cập nhật trạng thái hiển thị và không gửi gì tới tiến trình agy. Muốn agent nhận câu trả lời, gửi lượt mới bằng `POST /api/bridge/send` với `conversationId` của conversation đó.

### 18.2. Sự kiện trên máy B

Các sự kiện của A được chuyển tiếp với tiền tố `bridge:`: `bridge:chat:stream`, `bridge:session:update`, `bridge:streams:update`, `bridge:ai-question:answered`, `bridge:retry:update`, `bridge:quotas:update`. Không chuyển `sessions:list` và `meta:update` (payload hàng trăm KB).

`bridge:status` (`{ url, connected, error }`) phát khi trạng thái kết nối đổi.

### 18.3. Ghi chú kỹ thuật

- Client Socket.IO tự viết trên `tokio-tungstenite`, không dùng `rust_socketio` 0.6: đã kiểm chứng với server này, bản đó không nhận được payload lớn qua polling và không nhận được gì qua WebSocket (spike ngoài repo).
- Lệnh gửi tới A dùng ack với thời hạn 30 giây. Khi chưa kết nối, lệnh bị từ chối ngay (không xếp hàng).

---

## Ghi chú

- Server là nguồn dữ liệu duy nhất cho client. Client không đọc file hệ thống trực tiếp.
- Các endpoint đọc transcript Claude và agy dùng `spawn_blocking` để không chặn event loop.
- Danh sách route được khai báo trong `server/src/api/mod.rs`. Kiểm tra lại file này khi thêm route.
