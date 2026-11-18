# API của muop-agent Server

Tài liệu này mô tả toàn bộ REST API và sự kiện Socket.IO do Rust Server (`server/`) cung cấp.

- **Địa chỉ:** `http://<host>:8787` (server lắng nghe trên `0.0.0.0:8787`).
- **Định dạng:** JSON, khóa camelCase. Ngoại lệ là `GET /api/files/download` trả về nội dung file nhị phân.
- **Lỗi:** phần lớn endpoint trả `{"ok": false, "error": "<thông báo>"}` kèm mã HTTP 400, 404, 409 hoặc 500 tùy trường hợp.
- **CORS:** cho phép mọi origin trong mạng LAN.

Các route được khai báo trong `server/src/main.rs`. Các struct DTO nằm trong `server/src/models.rs`, `server/src/claude_questions.rs` và `server/src/main.rs`.

---

## 1. Trạng thái và dữ liệu nhỏ

Không còn endpoint snapshot đầy đủ. Mỗi phần dữ liệu có endpoint riêng (cùng dữ liệu với các event socket tương ứng).

### `GET /api/sessions`

`{ "sessions": [SessionSummary] }`: tóm tắt mọi conversation (không kèm steps, files, lanes). Tối đa 500.

### `GET /api/meta`

`MetaPayload`: `projects`, `availableModels`, `effortLevels`, `modelLabels`, `modelContextLimits`, `hostname`, `lanIps`, `port`, `timestamp`.

`effortLevels` là các mức suy nghĩ CLI `claude` hỗ trợ, đọc từ `claude --help` (ví dụ `low, medium, high, xhigh, max`). Model Claude được phát dạng `claude-cli:<model>-<mức>`; khi chạy server tách hậu tố và truyền `--effort <mức>`. Rỗng nếu không đọc được CLI.

### `GET /api/streams`

`{ "activeStreams": { <conversationId>: ChatTurnStreamState } }`: các lượt chat đang chạy.

### `GET /ping`, `GET /health`, `GET /api/ping`

Kiểm tra server sống. Trả về:

```json
{
  "status": "ok",
  "app": "muop-agent-rust-server",
  "engine": "rust-axum-socketio",
  "hostname": "...",
  "ips": ["192.168.x.x", "..."],
  "port": 8787,
  "timestamp": "2026-11-15T10:00:00+07:00"
}
```

---

## 2. Session và lịch sử

### `GET /api/session?id=<sessionId>`

Alias: `GET /api/session/detail?id=<sessionId>`

Trả về chi tiết một session (`ConversationSession`), gồm tối đa 100 bước gần nhất, `subagentLanes` và `filesTouched`. Thiếu `id` trả 400.

### `GET /api/session/steps?id=<sessionId>&before_step=<index>&limit=<n>`

Phân trang lịch sử. Lấy `limit` bước (mặc định 50) nằm ngay trước `before_step`. Có thể dùng alias `beforeStep` hoặc `before_step_index`. Trả về:

```json
{
  "sessionId": "...",
  "steps": [ { "stepIndex": 12, "...": "..." } ],
  "hasMore": true,
  "earliestStepIndex": 12,
  "totalSteps": 2500
}
```

---

## 3. Chat

### `POST /api/chat/send`

Gửi một prompt tới agent. Body (`ChatSendRequest`):

| Trường | Kiểu | Ghi chú |
| :--- | :--- | :--- |
| `prompt` | string | Nội dung. Bắt đầu bằng `/plan` để chạy claude-cli ở plan mode. |
| `projectPath` | string | Thư mục làm việc. |
| `conversationId` | string | Để trống để tạo conversation mới. |
| `agentName` | string | Ví dụ `Coordinator`. |
| `model` | string | `claude-cli:<model-id>` hoặc `agy:<model>`. |

Phản hồi (`ChatSendResponse`): `{ "ok", "conversationId", "projectPath", "error", "source" }`. `source` là `claude-cli` hoặc `agy`.

Lượt chat chạy bất đồng bộ. Tiến độ được phát qua sự kiện `chat:stream`.

### `POST /api/chat/stop`

Body: `{ "conversationId": "..." }`. Dừng lượt đang chạy của conversation đó.

---

## 4. Dự án

### `POST /api/project/create`

Body (`CreateProjectRequest`): `{ "name", "template", "description" }`. Tạo thư mục project mới theo template.

### `GET /api/project/agents?path=<projectPath>`

Alias: `?name=<projectName>`. Liệt kê agent tùy chỉnh (`customAgents`) của project.

### `GET /api/claude/extensions?path=<projectPath>`

Liệt kê extension của Claude Code (skill, agent, command) trong project.

---

## 5. Git

### `GET /api/git/history?projectPath=<path>&branch=<name>&limit=<n>`

Lịch sử commit. `limit` mặc định 100, tối đa 500.

### `GET /api/git/status?projectPath=<path>`

Trạng thái git của project so với HEAD đang checkout, dùng để tô màu explorer. Trả về:

```json
{ "ok": true, "isRepo": true, "kinds": { "/abs/path/file.dart": "modified", "/abs/path/new.dart": "created" }, "truncated": false, "error": "" }
```

- `isRepo = false` nếu thư mục không nằm trong git repository; khi đó client dựa vào thay đổi do agent ghi.
- `kinds`: `created` (file mới hoặc chưa được theo dõi), `modified`, `deleted`. Tối đa 5000 mục, `truncated = true` nếu bị cắt.

### `GET /api/git/commit?projectPath=<path>&hash=<hash>`

Chi tiết một commit. `hash` phải là chuỗi hex từ 4 đến 40 ký tự.

### `POST /api/git/push`

Body (`GitPushRequest`): `{ "projectPath", "branch" }`. Thực hiện `git push` cho branch đã chọn.

---

## 6. Kế hoạch (Plan)

### `GET /api/plan/pending?id=<conversationId>`

Alias: `conversationId`. Trả về `{ "ok": true, "plans": [...] }`, danh sách kế hoạch đang chờ duyệt (`PlanArtifactInfo`).

### `POST /api/plan/action`

Body (`PlanActionRequest`):

| Trường | Ghi chú |
| :--- | :--- |
| `conversationId` | Conversation chứa kế hoạch. |
| `fileName` | Tên file kế hoạch. |
| `action` | `approve`, `reject` hoặc `cancel`. |
| `feedback` | Góp ý khi `reject`. |
| `model` | Model dùng để chạy lượt tiếp theo. |

- `approve` gửi prompt `approved` vào conversation.
- `cancel` gửi prompt `cancel plan`.
- `reject` gửi góp ý để agent cập nhật kế hoạch.

---

## 7. Tương tác Claude Code (câu hỏi và kế hoạch)

Đây là các tương tác `AskUserQuestion` và `ExitPlanMode` của Claude Code, cùng plan được ghi vào `~/.claude/plans/`, đang chờ người dùng trả lời.

### `GET /api/claude/pending?id=<conversationId>`

Trả về:

```json
{
  "conversationId": "...",
  "ok": true,
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

Body (`ClaudeInteractionResponse`):

| Trường | Ghi chú |
| :--- | :--- |
| `conversationId` | Conversation đang chờ. |
| `toolUseId` | Phải khớp với `pending.toolUseId`, nếu không trả 409. |
| `projectPath`, `model` | Dùng để chạy lượt tiếp theo. |
| `answers` | Với `question`: `[ { "question", "answer" } ]`, phải có đủ câu trả lời cho mọi câu hỏi. |
| `decision` | Với `plan`: `approve`, `cancel` hoặc `feedback`. |
| `feedback` | Nội dung góp ý khi `decision = feedback`. |

Lỗi thường gặp: 409 khi tương tác không còn chờ hoặc lượt đang chạy, 400 khi thiếu câu trả lời.

---

## 8. Câu hỏi AI (agy)

### `GET /api/ai-questions?conversationId=<id>`

Trả về các câu hỏi do agent đặt trong conversation.

### `POST /api/ai-questions/answer`

Body: `{ "questionId": "...", "answer": "..." }`. Ghi câu trả lời và phát sự kiện `ai-question:answered`.

---

## 9. Model theo conversation

Dữ liệu được lưu trong SQLite (`~/.local/share/muop-agent/muop-agent.db`).

### `GET /api/conversation/model?id=<conversationId>`

Trả về model người dùng đã chọn cho conversation.

### `POST /api/conversation/model`

Body: `{ "conversationId": "...", "model": "..." }`.

---

## 10. File trên server

Đường dẫn tương đối được tính từ thư mục gốc mặc định `/home/john/Documents/muop-ecosystem`. Server hiện không có kiểm tra giới hạn thư mục riêng cho các endpoint này.

### `GET /api/files/list?path=<dir>`

Liệt kê thư mục.

### `GET /api/files/read?path=<file>`

Đọc nội dung text của file.

### `GET /api/files/lines?path=<file>&offset=<dòng>&limit=<số dòng>`

Đọc một đoạn dòng của tệp văn bản mà không nạp cả tệp. Server đánh chỉ mục byte offset của từng dòng (cache theo mtime và kích thước), `limit` mặc định 200, tối đa 400. Mỗi dòng được cắt tối đa 2000 ký tự.

Phản hồi:

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

Tải file. Trả về nội dung nhị phân với `Content-Type` theo đuôi file và `Content-Length`. Thiếu `path` hoặc file không tồn tại trả JSON lỗi.

---

## 11. Socket.IO

Namespace mặc định `/`, Socket.IO v4, hỗ trợ WebSocket và polling.

### Client gửi

| Event | Payload | Phản hồi |
| :--- | :--- | :--- |
| `request-sessions` | không | Server gửi `sessions:list` cho client này. |
| `request-meta` | không | Server gửi `meta:update` cho client này. |
| `request-streams` | không | Server gửi `streams:update` cho client này. |
| `chat:send` | như `ChatSendRequest` | Ack là `ChatSendResponse`. Server phát `session:update` và `fileschange` sau khi xong. |
| `chat:stop` | `{ "conversationId" }` | Ack là `{ "ok": true, "stopped": <bool> }`. |
| `join-conversation` | `{ "conversationId" }` | Server trả `joined-conversation`, và client nhận `fileschange` của room. |
| `leave-conversation` | `{ "conversationId" }` | Rời room. |

### Server phát

| Event | Khi nào | Nội dung |
| :--- | :--- | :--- |
| `sessions:list` | Khi có `request-sessions` | `{ "sessions": [SessionSummary] }`: tóm tắt từng conversation, không kèm steps, files, lanes. |
| `meta:update` | Khi có `request-meta` | `MetaPayload`: `projects`, `availableModels`, `effortLevels`, `modelLabels`, `modelContextLimits`, `hostname`, `lanIps`, `port`, `timestamp`. |
| `streams:update` | Khi có `request-streams`, và khi danh sách lượt đang chạy thay đổi | `{ "activeStreams": { <id>: ChatTurnStreamState } }`. |
| `session:removed` | Conversation bị xoá khỏi đĩa | `{ "id" }`. |
| `session:update` | Một conversation thay đổi | `ConversationSession` của conversation đó. |
| `chat:stream` | Trong lượt chat | `ChatTurnStreamState`: `conversationId`, `projectPath`, `userPrompt`, `streamingText`, `thinkingText`, `isRunning`, `activeStepType`, `startedAt`, `error`. |
| `projects:update` | Danh sách project thay đổi | Mảng `ProjectWorkspace`. |
| `quotas:update` | Quota model thay đổi | Mảng `ModelQuotaGroup`. |
| `fileschange` | File trong conversation thay đổi | `ConversationSession` rút gọn. |
| `joined-conversation` | Sau `join-conversation` | `{ "ok": true, "conversationId" }`. |
| `ai-question:answered` | Sau khi trả lời câu hỏi AI | Câu hỏi đã trả lời. |

Client mới nên gọi `request-sessions`, `request-meta`, `request-streams` ngay sau khi kết nối (và sau khi kết nối lại) rồi áp dụng các event nhỏ. Trạng thái các lượt đang chạy lấy từ `streams:update`, không suy ra từ các `chat:stream` đã nhận trước đó.

Lưu ý: socket.io tách mảng cấp cao nhất của một event thành nhiều đối số. Vì vậy `sessions:list` được bọc trong object; `projects:update` vẫn là mảng để giữ tương thích, client đọc mọi đối số để ghép lại.

---

## Ghi chú

- Server là nguồn dữ liệu duy nhất cho client. Client không đọc file hệ thống trực tiếp.
- Các endpoint đọc transcript Claude và agy dùng `spawn_blocking` để không chặn event loop.
- Tài liệu này viết tay theo mã nguồn hiện tại. Khi thêm hoặc đổi route, cập nhật file này.
