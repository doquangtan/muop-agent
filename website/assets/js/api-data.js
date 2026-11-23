/*
 * Dữ liệu tài liệu API của Mướp Agents server (cổng 8787).
 * Nguồn đối chiếu: server/src/api/mod.rs (route REST), các file socket.rs trong server/src
 * (event Socket.IO), docs/API.md. Khi đổi route hoặc event, cập nhật file này.
 *
 * Cấu trúc endpoint:
 *   m: method, p: đường dẫn, s: tóm tắt, d: mô tả (tùy chọn), alias: đường dẫn thay thế (tùy chọn)
 *   q: tham số query  [tên, kiểu, bắt buộc?, mô tả]
 *   b: trường trong body JSON  [tên, kiểu, bắt buộc?, mô tả]
 *   body: ví dụ body JSON; res: ví dụ phản hồi; note: ghi chú; curl: lệnh curl tùy chỉnh ({BASE} là địa chỉ server)
 */
window.MUOP_API = {
  groups: [
    {
      id: "status",
      title: "Trạng thái và meta",
      desc: "Kiểm tra server còn sống, lấy danh sách project, model và thông tin máy, cùng quota của agent.",
      endpoints: [
        {
          m: "GET", p: "/ping", alias: "/health, /api/ping",
          s: "Kiểm tra server còn sống",
          res: `{
  "status": "ok",
  "app": "muop-agent-rust-server",
  "engine": "rust-axum-socketio",
  "hostname": "may-chu",
  "ips": ["192.168.1.10"],
  "port": 8787,
  "timestamp": "2026-11-23T10:00:00+07:00"
}`
        },
        {
          m: "GET", p: "/api/meta",
          s: "Metadata: project, model, mức suy luận, thông tin máy",
          d: "Gồm danh sách project, `availableModels` (id dạng `claude-cli:<model>-<mức>` hoặc `agy:<model>`), `effortLevels` đọc từ CLI `claude`, nhãn model, giới hạn context và địa chỉ LAN của máy.",
          res: `{
  "projects": [ { "id": "muop-agent", "name": "muop-agent", "path": "/home/user/projects/muop-agent", "sessionCount": 50, "runningCount": 1 } ],
  "availableModels": ["claude-cli:claude-haiku-5-5-medium", "agy:gemini-4-argon-low"],
  "effortLevels": ["low", "medium", "high", "xhigh", "max"],
  "modelLabels": { "agy:gemini-4-argon-low": "Gemini 4 Argon" },
  "modelContextLimits": { "claude-cli:claude-haiku-5-5": 1000000 },
  "hostname": "may-chu",
  "lanIps": ["192.168.1.10"],
  "port": 8787,
  "timestamp": "2026-11-23T10:00:00+07:00",
  "workspaceRoot": "/home/user/projects",
  "homeDir": "/home/user"
}`,
          note: "`workspaceRoot` rỗng khi chưa chọn thư mục project. Khi chưa sẵn sàng, trả `{\"error\": \"meta không sẵn sàng\"}`."
        },
        {
          m: "GET", p: "/api/streams",
          s: "Các lượt chat đang chạy",
          res: `{
  "activeStreams": {
    "conv-123": {
      "conversationId": "conv-123",
      "projectPath": "/home/user/projects/muop-agent",
      "userPrompt": "Sửa lỗi build",
      "streamingText": "Đang kiểm tra...",
      "thinkingText": "",
      "isRunning": true,
      "activeStepType": "tool",
      "startedAt": "2026-11-23T10:00:00+07:00",
      "error": ""
    }
  }
}`
        },
        {
          m: "GET", p: "/api/quota",
          s: "Quota của cả agy và Claude Code",
          d: "Hai nguồn lấy song song. Nguồn lỗi có `error` ghi lý do, nguồn còn lại vẫn có dữ liệu. Không có số liệu thì `groups` rỗng; server không trả số cũ hay số mặc định.",
          res: `{
  "agy": { "provider": "agy", "groups": [], "error": "Chưa đăng nhập agy" },
  "claude": {
    "provider": "claude",
    "groups": [
      {
        "displayName": "Claude",
        "description": "",
        "buckets": [
          {
            "bucketId": "five_hour",
            "displayName": "Phiên 5 giờ",
            "description": "",
            "window": "five_hour",
            "remainingFraction": 0.8,
            "remainingPercent": 80,
            "resetTime": "2026-11-23T15:00:00Z"
          }
        ]
      }
    ],
    "error": ""
  }
}`
        },
        {
          m: "GET", p: "/api/quota/agy",
          s: "Quota Antigravity (agy)",
          d: "Đọc số liệu từ hub do server quản lý. Nếu chưa có trong DB, server hỏi hub ngay; lần đầu có thể mất tới khoảng 60 giây.",
          res: `{ "provider": "agy", "groups": [ /* như /api/quota */ ], "error": "" }`
        },
        {
          m: "GET", p: "/api/quota/claude",
          s: "Quota Claude Code CLI",
          d: "Đọc từ endpoint usage của Anthropic, không phụ thuộc tiến trình CLI nào đang chạy.",
          res: `{ "provider": "claude", "groups": [ /* như /api/quota */ ], "error": "" }`
        }
      ]
    },
    {
      id: "sessions",
      title: "Session và lịch sử",
      desc: "Conversation được đọc từ transcript của agent. Chỉ trả về một phần lịch sử; phần còn lại tải theo trang.",
      endpoints: [
        {
          m: "GET", p: "/api/sessions",
          s: "Tóm tắt mọi conversation",
          d: "Không kèm steps, file hay lanes. Tối đa 500 conversation.",
          res: `{
  "sessions": [
    {
      "id": "conv-123",
      "title": "Sửa lỗi build",
      "projectPath": "/home/user/projects/muop-agent",
      "projectName": "muop-agent",
      "status": "completed",
      "source": "claude-cli",
      "updatedAt": "2026-11-23T10:00:00+07:00",
      "selectedModel": "claude-cli:claude-haiku-5-5-medium"
    }
  ]
}`
        },
        {
          m: "GET", p: "/api/session", alias: "/api/session/detail",
          s: "Chi tiết một conversation",
          q: [["id", "string", true, "Id conversation"]],
          d: "Trả `ConversationSession` gồm `steps` (tối đa 100 bước gần nhất), `subagentLanes`, `filesTouched`, `selectedModel`, `contextTokens`, `contextModel`. Lượt đang chạy lấy từ stream hiện tại nên trạng thái `running` đúng ngay khi mở.",
          res: `{
  "id": "conv-123",
  "title": "Sửa lỗi build",
  "status": "completed",
  "steps": [
    { "stepIndex": 0, "stepType": "USER_INPUT", "createdAt": "2026-11-23T10:00:00+07:00", "content": "Sửa lỗi build", "imageCount": 0, "imageUrls": [] },
    { "stepIndex": 1, "stepType": "PLANNER_RESPONSE", "createdAt": "2026-11-23T10:00:09+07:00", "content": "Đã sửa xong.", "model": "claude-haiku-5-5", "inputTokens": 1200, "outputTokens": 310 }
  ],
  "subagentLanes": [],
  "lanesLoaded": true,
  "filesTouched": [ { "path": "lib/main.dart", "action": "edit", "agentName": "Coordinator", "stepIndex": 1, "timestamp": "2026-11-23T10:00:09+07:00", "addedLines": 4, "removedLines": 1, "source": "" } ],
  "selectedModel": "claude-cli:claude-haiku-5-5-medium",
  "contextTokens": 77000,
  "contextModel": "claude-haiku-5-5"
}`,
          err: "400 `Missing session id`; 404 không tìm thấy."
        },
        {
          m: "GET", p: "/api/session/steps",
          s: "Phân trang lịch sử bước",
          d: "Lấy `limit` bước nằm ngay trước `before_step`. Dùng khi người dùng cuộn lên trên để tải thêm lịch sử.",
          q: [
            ["id", "string", true, "Id conversation"],
            ["before_step", "integer", false, "Lấy các bước có chỉ số nhỏ hơn giá trị này. Alias: `beforeStep`, `before_step_index`"],
            ["limit", "integer", false, "Số bước mỗi trang, mặc định 50"]
          ],
          res: `{
  "sessionId": "conv-123",
  "steps": [ /* AgentStep */ ],
  "hasMore": true,
  "earliestStepIndex": 1200,
  "totalSteps": 2560
}`,
          err: "400 thiếu `id`; 404 không tìm thấy."
        }
      ]
    },
    {
      id: "chat",
      title: "Chat",
      desc: "Gửi prompt tới agent và theo dõi tiến độ. Lượt chat chạy bất đồng bộ; tiến độ đến qua Socket.IO `chat:stream`.",
      endpoints: [
        {
          m: "POST", p: "/api/chat/send",
          s: "Gửi prompt tới agent",
          d: "Bắt đầu prompt với `/plan` để chạy Claude ở chế độ plan. Khi lượt xong, server phát `session:update` và `fileschange`. Ảnh được nhận diện theo nội dung (PNG, JPEG, WebP), thu nhỏ cạnh dài về 1568px rồi lưu vào thư mục uploads của server.",
          b: [
            ["prompt", "string", false, "Nội dung. Có thể rỗng nếu chỉ gửi ảnh (server dùng câu mặc định)"],
            ["projectPath", "string", true, "Đường dẫn tuyệt đối tới thư mục làm việc"],
            ["conversationId", "string", false, "Để trống để tạo conversation mới"],
            ["agentName", "string", false, "Ví dụ `Coordinator`"],
            ["model", "string", true, "`claude-cli:<model>-<mức>` hoặc `agy:<model>`"],
            ["images", "array", false, "Tối đa 6 ảnh: `{name, mimeType, dataBase64}`, mỗi ảnh tối đa 20MB trước khi thu nhỏ"],
            ["remoteProject", "object", false, "Thư mục project nằm trên máy khác (do cầu nối gắn vào). Xem mục Mount project"]
          ],
          body: `{
  "prompt": "Liệt kê các file TODO trong project",
  "projectPath": "/home/user/projects/muop-agent",
  "model": "claude-cli:claude-haiku-5-5-medium"
}`,
          res: `{
  "ok": true,
  "conversationId": "conv-123",
  "projectPath": "/home/user/projects/muop-agent",
  "error": "",
  "source": "claude-cli"
}`,
          note: "Trả 200 khi `ok`, 400 khi lỗi. `source` là `claude-cli` hoặc `agy`. Lỗi khớp mẫu rate limit thì server tự xếp lịch gửi lại (xem `retry:update`)."
        },
        {
          m: "POST", p: "/api/chat/stop",
          s: "Dừng lượt đang chạy",
          b: [["conversationId", "string", true, "Conversation cần dừng"]],
          body: `{ "conversationId": "conv-123" }`,
          res: `{ "ok": true, "stopped": true }`
        },
        {
          m: "GET", p: "/api/chat/attachment",
          s: "Tải ảnh đính kèm trong lịch sử",
          d: "Hai cách lấy ảnh tùy nguồn: agy dùng `path` (chỉ đọc trong thư mục uploads); Claude dùng `cid`, `uuid` và `i`, server đọc lại khối base64 từ transcript.",
          q: [
            ["path", "string", false, "Đường dẫn file ảnh (agy)"],
            ["cid", "string", false, "Id session (Claude)"],
            ["uuid", "string", false, "uuid của dòng user chứa ảnh (Claude)"],
            ["i", "integer", false, "Thứ tự ảnh trong dòng (Claude)"]
          ],
          res: `Nội dung ảnh (Content-Type theo định dạng). Lỗi trả JSON {"ok": false, "error": "..."} với 404 hoặc 500.`,
          curl: `curl -o anh.png "{BASE}/api/chat/attachment?cid=conv-123&uuid=<uuid>&i=0"`
        },
        {
          m: "POST", p: "/api/chat/retry/cancel",
          s: "Hủy lịch tự gửi lại sau rate limit",
          b: [["conversationId", "string", true, "Conversation đang có lịch chờ"]],
          body: `{ "conversationId": "conv-123" }`,
          res: `{ "ok": true, "cancelled": true, "conversationId": "conv-123" }`,
          err: "400 nếu thiếu `conversationId`."
        }
      ]
    },
    {
      id: "models",
      title: "Model theo conversation",
      desc: "Lưu model và mức suy luận đã chọn cho từng conversation trong SQLite của server.",
      endpoints: [
        {
          m: "GET", p: "/api/conversation/model",
          s: "Đọc model đã lưu của conversation",
          q: [["id", "string", true, "Id conversation"]],
          res: `{ "conversationId": "conv-123", "model": "claude-cli:claude-haiku-5-5-medium" }`,
          err: "400 thiếu `id`."
        },
        {
          m: "POST", p: "/api/conversation/model",
          s: "Lưu model cho conversation",
          b: [
            ["conversationId", "string", true, "Id conversation"],
            ["model", "string", true, "Id model đầy đủ"]
          ],
          body: `{ "conversationId": "conv-123", "model": "agy:gemini-4-argon-low" }`,
          res: `{ "ok": true, "conversationId": "conv-123", "model": "agy:gemini-4-argon-low" }`,
          err: "400 thiếu trường; 500 khi lưu lỗi."
        },
        {
          m: "POST", p: "/api/model/context-limit",
          s: "Sửa tay giới hạn context của một model",
          d: "Lưu với nguồn `manual`, không bị quét ghi đè. Giới hạn dùng để hiển thị `đã dùng / giới hạn` trên app.",
          b: [
            ["model", "string", true, "Id model, ví dụ `claude-cli:claude-haiku-5-5`"],
            ["limit", "integer", true, "Số token, lớn hơn 0"]
          ],
          body: `{ "model": "claude-cli:claude-haiku-5-5", "limit": 1000000 }`,
          res: `{ "ok": true, "model": "claude-cli:claude-haiku-5-5", "limit": 1000000 }`
        }
      ]
    },
    {
      id: "projects",
      title: "Dự án và extension",
      desc: "Quản lý thư mục project và các agent, skill, command của Claude Code trong project.",
      endpoints: [
        {
          m: "POST", p: "/api/project/create",
          s: "Tạo project mới theo template",
          b: [
            ["name", "string", true, "Tên thư mục project"],
            ["template", "string", false, "Mặc định `standard`"],
            ["description", "string", false, "Mô tả project"]
          ],
          body: `{ "name": "my-service", "template": "standard", "description": "API nội bộ" }`,
          res: `{
  "ok": true,
  "message": "Đã tạo project",
  "project": { "id": "my-service", "name": "my-service", "path": "/home/user/projects/my-service", "sessionCount": 0, "runningCount": 0 },
  "error": null
}`,
          err: "400 khi lỗi."
        },
        {
          m: "GET", p: "/api/project/agents",
          s: "Agent, skill và rule của một project",
          q: [
            ["path", "string", false, "Đường dẫn tuyệt đối tới project (hoặc dùng `name`)"],
            ["name", "string", false, "Tên project (alias)"]
          ],
          res: `{
  "ok": true,
  "projectPath": "/home/user/projects/muop-agent",
  "projectName": "muop-agent",
  "availableAgents": ["Coordinator"],
  "customAgents": [],
  "skills": [],
  "rules": [],
  "error": ""
}`
        },
        {
          m: "GET", p: "/api/claude/extensions",
          s: "Skill, agent và command của Claude Code",
          q: [["path", "string", true, "Đường dẫn tuyệt đối tới project"]],
          res: `{ "ok": true, "items": [ { "name": "review", "kind": "command", "description": "..." } ] }`
        }
      ]
    },
    {
      id: "git",
      title: "Git",
      desc: "Lịch sử commit, trạng thái file so với HEAD và push nhánh. Các thao tác chạy trong project đã chọn.",
      endpoints: [
        {
          m: "GET", p: "/api/git/history",
          s: "Lịch sử commit",
          q: [
            ["projectPath", "string", true, "Đường dẫn tuyệt đối tới project"],
            ["branch", "string", false, "Nhánh cần xem, mặc định nhánh hiện tại"],
            ["limit", "integer", false, "Mặc định 100, tối đa 500"]
          ],
          res: `{
  "ok": true,
  "projectPath": "/home/user/projects/muop-agent",
  "projectName": "muop-agent",
  "currentBranch": "main",
  "branches": ["main"],
  "totalCommits": 412,
  "commits": [ { "hash": "a1b2c3d4e5f6...", "shortHash": "a1b2c3d", "authorName": "Tên tác giả", "committedAt": "2026-11-22T18:30:00+07:00", "relativeTime": "2 giờ trước", "subject": "Fix build", "filesCount": 2, "isHead": true } ],
  "error": ""
}`
        },
        {
          m: "GET", p: "/api/git/status",
          s: "Trạng thái file so với HEAD",
          d: "Dùng để tô màu cây thư mục. `kinds` gồm `created`, `modified`, `deleted`. Tối đa 5000 mục; `truncated: true` nếu bị cắt.",
          q: [["projectPath", "string", true, "Đường dẫn tuyệt đối tới project"]],
          res: `{
  "ok": true,
  "isRepo": true,
  "kinds": { "/home/user/projects/muop-agent/lib/main.dart": "modified" },
  "truncated": false,
  "error": ""
}`,
          note: "`isRepo: false` nếu thư mục không nằm trong git. Khi đó app dựa vào thay đổi do agent ghi."
        },
        {
          m: "GET", p: "/api/git/commit",
          s: "Chi tiết một commit",
          q: [
            ["projectPath", "string", true, "Đường dẫn tuyệt đối tới project"],
            ["hash", "string", true, "Hash commit, 4 đến 40 ký tự hex"]
          ],
          res: `{
  "ok": true,
  "hash": "a1b2c3d",
  "subject": "Fix build",
  "files": [ { "path": "lib/main.dart", "status": "M", "additions": 4, "deletions": 1 } ]
}`,
          err: "400 nếu `hash` không phải hex."
        },
        {
          m: "POST", p: "/api/git/push",
          s: "Push nhánh",
          b: [
            ["projectPath", "string", true, "Đường dẫn tuyệt đối tới project"],
            ["branch", "string", true, "Tên nhánh cần push"]
          ],
          body: `{ "projectPath": "/home/user/projects/muop-agent", "branch": "main" }`,
          res: `{ "ok": true, "message": "Đã push", "output": "...", "error": "" }`
        }
      ]
    },
    {
      id: "plan",
      title: "Kế hoạch và tương tác",
      desc: "Duyệt kế hoạch (plan artifact) và trả lời các tương tác đang chờ: câu hỏi AskUserQuestion và ExitPlanMode của Claude Code, câu hỏi của agy.",
      endpoints: [
        {
          m: "GET", p: "/api/plan/pending",
          s: "Kế hoạch đang chờ duyệt",
          q: [["id", "string", true, "Id conversation. Alias: `conversationId`"]],
          res: `{
  "ok": true,
  "plans": [
    {
      "fileName": "plan.md",
      "filePath": "/home/user/.local/share/.../plan.md",
      "title": "Kế hoạch refactor",
      "summary": "...",
      "updatedAt": "2026-11-23T10:00:00+07:00",
      "requestFeedback": true,
      "content": "# Kế hoạch ..."
    }
  ]
}`,
          err: "400 thiếu id."
        },
        {
          m: "POST", p: "/api/plan/action",
          s: "Duyệt, từ chối hoặc hủy kế hoạch",
          b: [
            ["conversationId", "string", true, "Conversation chứa kế hoạch"],
            ["fileName", "string", false, "Tên file kế hoạch"],
            ["action", "string", true, "`approve`, `reject` hoặc `cancel`"],
            ["feedback", "string", false, "Góp ý khi `reject`"],
            ["model", "string", false, "Model dùng cho lượt tiếp theo"]
          ],
          body: `{ "conversationId": "conv-123", "fileName": "plan.md", "action": "approve", "model": "claude-cli:claude-haiku-5-5-medium" }`,
          note: "`approve` gửi prompt `approved` vào conversation; `cancel` gửi `cancel plan`; `reject` gửi góp ý để agent cập nhật kế hoạch."
        },
        {
          m: "GET", p: "/api/claude/pending",
          s: "Tương tác Claude Code đang chờ trả lời",
          q: [["id", "string", true, "Id conversation. Alias: `conversationId`"]],
          res: `{
  "ok": true,
  "conversationId": "conv-123",
  "pending": {
    "conversationId": "conv-123",
    "toolUseId": "toolu_01",
    "kind": "question",
    "createdAt": "2026-11-23T10:00:00+07:00",
    "questions": [
      {
        "question": "Dùng thư viện nào?",
        "header": "Thư viện",
        "multiSelect": false,
        "options": [ { "label": "A", "description": "Nhẹ" } ]
      }
    ],
    "plan": ""
  }
}`,
          note: "`pending` là `null` khi không có gì chờ, hoặc khi lượt đang chạy."
        },
        {
          m: "POST", p: "/api/claude/respond",
          s: "Trả lời tương tác Claude Code",
          b: [
            ["conversationId", "string", true, "Conversation đang chờ"],
            ["toolUseId", "string", true, "Phải khớp `pending.toolUseId`"],
            ["projectPath", "string", false, "Dùng cho lượt tiếp theo"],
            ["model", "string", false, "Model dùng cho lượt tiếp theo"],
            ["answers", "array", false, "Với `question`: `[{question, answer}]`"],
            ["decision", "string", false, "Với `plan`: `approve`, `cancel` hoặc `feedback`"],
            ["feedback", "string", false, "Nội dung góp ý khi `decision = feedback`"]
          ],
          body: `{
  "conversationId": "conv-123",
  "toolUseId": "toolu_01",
  "projectPath": "/home/user/projects/muop-agent",
  "model": "claude-cli:claude-haiku-5-5-medium",
  "answers": [ { "question": "Dùng thư viện nào?", "answer": "A" } ]
}`,
          err: "409 khi tương tác không còn chờ hoặc phiên đang chạy; 400 khi thiếu câu trả lời."
        },
        {
          m: "GET", p: "/api/ai-questions",
          s: "Câu hỏi của agent (agy)",
          q: [["conversationId", "string", true, "Id conversation"]],
          res: `{
  "ok": true,
  "conversationId": "conv-123",
  "questions": [
    {
      "id": "q-1",
      "conversationId": "conv-123",
      "stepIndex": 14,
      "question": "Ghi đè file hiện có?",
      "createdAt": "2026-11-23T10:00:00+07:00",
      "answeredAt": null,
      "answer": null,
      "isPending": true
    }
  ],
  "error": ""
}`
        },
        {
          m: "POST", p: "/api/ai-questions/answer",
          s: "Ghi câu trả lời cho câu hỏi của agent",
          d: "Ghi nhận câu trả lời và phát `ai-question:answered`. Route này chỉ cập nhật trạng thái hiển thị; để agent nhận câu trả lời, gửi một lượt mới qua `/api/chat/send` (hoặc `/api/bridge/send`) vào cùng conversation.",
          b: [
            ["questionId", "string", true, "Id câu hỏi"],
            ["answer", "string", true, "Nội dung trả lời"]
          ],
          body: `{ "questionId": "q-1", "answer": "Có" }`,
          res: `{ "questionId": "q-1", "answer": "Có" }`,
          err: "400 nếu body không đọc được."
        }
      ]
    },
    {
      id: "files",
      title: "File trên server (đọc nhanh)",
      desc: "Đọc file và thư mục theo đường dẫn tuyệt đối trên máy server. Các endpoint này không giới hạn thư mục riêng.",
      endpoints: [
        {
          m: "GET", p: "/api/files/list",
          s: "Liệt kê thư mục",
          q: [
            ["path", "string", true, "Đường dẫn thư mục tuyệt đối"],
            ["showHidden", "boolean", false, "Hiện file ẩn, mặc định false"]
          ],
          res: `{
  "ok": true,
  "currentPath": "/home/user/projects",
  "parentPath": "/home/user",
  "entries": [
    { "name": "muop-agent", "path": "/home/user/projects/muop-agent", "isDir": true, "size": 4096, "modifiedAt": "...", "permissions": "rwxr-xr-x" }
  ],
  "error": ""
}`
        },
        {
          m: "GET", p: "/api/files/read",
          s: "Đọc nội dung một file",
          q: [["path", "string", true, "Đường dẫn file tuyệt đối"]],
          res: `{
  "ok": true,
  "path": "/home/user/projects/muop-agent/README.md",
  "name": "README.md",
  "size": 2576,
  "isBinary": false,
  "isImage": false,
  "content": "# muop-agent ...",
  "gitDiff": "",
  "error": ""
}`
        },
        {
          m: "GET", p: "/api/files/lines",
          s: "Đọc một đoạn dòng của file lớn",
          d: "Server đánh chỉ mục byte offset của từng dòng (cache theo mtime và kích thước), nên không cần nạp cả file. Mỗi dòng cắt tối đa 2000 ký tự. `gitDiff` chỉ có khi `offset = 0`, cắt tối đa 200KB, và bỏ qua với file lớn hơn 20MB.",
          q: [
            ["path", "string", true, "Đường dẫn file tuyệt đối"],
            ["offset", "integer", false, "Dòng bắt đầu (đếm từ 0), mặc định 0"],
            ["limit", "integer", false, "Số dòng, mặc định 200, tối đa 400"]
          ],
          res: `{
  "ok": true,
  "path": "/home/user/logs/app.log",
  "name": "app.log",
  "size": 86745462,
  "isBinary": false,
  "totalLines": 36310,
  "offset": 0,
  "lines": ["..."],
  "hasMore": true,
  "gitDiff": "",
  "error": ""
}`
        },
        {
          m: "GET", p: "/api/files/download",
          s: "Tải file",
          d: "Trả nội dung nhị phân với `Content-Type` theo đuôi file, `Content-Length` và `Cache-Control: no-cache`.",
          q: [["path", "string", true, "Đường dẫn file tuyệt đối"]],
          res: `Nội dung file (nhị phân). Thiếu \`path\` trả 400; không tồn tại trả 404 kèm JSON lỗi.`,
          curl: `curl -O "{BASE}/api/files/download?path=/home/user/projects/muop-agent/README.md"`
        }
      ]
    },
    {
      id: "fs",
      title: "Hệ thống file (/api/fs)",
      desc: "API đọc và ghi file trong thư mục project đã cấu hình ở bước Khởi tạo. Đây là nền để máy khác mount project qua FUSE.",
      note: "Mọi `path` phải là đường dẫn tuyệt đối, không chứa `..`, và sau khi giải symlink phải nằm trong thư mục project. Ngoài phạm vi trả 403 với `code: \"outside_root\"`. Xóa hoặc đổi tên symlink xử lý chính symlink, không theo vào đích. Không có xác thực.",
      endpoints: [
        {
          m: "GET", p: "/api/fs/stat",
          s: "Thông tin một đường dẫn",
          q: [["path", "string", true, "Đường dẫn tuyệt đối"]],
          res: `{ "ok": true, "path": "/home/user/projects/muop-agent/a.txt", "name": "a.txt", "isDir": false, "size": 5, "mtime": 1763892000, "mode": 420 }`
        },
        {
          m: "GET", p: "/api/fs/list",
          s: "Liệt kê thư mục",
          q: [["path", "string", true, "Đường dẫn thư mục tuyệt đối"]],
          res: `{ "ok": true, "path": "/home/user/projects/muop-agent", "entries": [ { "name": "lib", "isDir": true, "size": 4096, "mtime": 1763892000, "mode": 493 } ] }`,
          note: "Sắp xếp theo tên."
        },
        {
          m: "GET", p: "/api/fs/read",
          s: "Đọc một đoạn nội dung file",
          d: "Trả nhị phân. Đọc theo đoạn; mỗi lần tối đa 16MB.",
          q: [
            ["path", "string", true, "Đường dẫn file tuyệt đối"],
            ["offset", "integer", false, "Byte bắt đầu, mặc định 0"],
            ["length", "integer", false, "Số byte, tối đa 16MB"]
          ],
          res: `Nội dung nhị phân. Header: \`X-Fs-Size\` (kích thước file), \`X-Fs-Eof\` (\`true\` khi đã tới cuối).`
        },
        {
          m: "PUT", p: "/api/fs/write",
          s: "Ghi file",
          d: "Body là nội dung file (nhị phân). Ghi qua file tạm rồi đổi tên, giữ quyền truy cập cũ.",
          q: [["path", "string", true, "Đường dẫn file tuyệt đối"]],
          res: `{ "ok": true, "path": "/home/user/projects/muop-agent/a.txt", "size": 5 }`,
          curl: `curl -X PUT "{BASE}/api/fs/write?path=/home/user/projects/muop-agent/a.txt" --data-binary "hello"`
        },
        {
          m: "POST", p: "/api/fs/mkdir",
          s: "Tạo thư mục",
          b: [["path", "string", true, "Đường dẫn thư mục cần tạo"]],
          body: `{ "path": "/home/user/projects/muop-agent/docs/new" }`,
          res: `{ "ok": true, "path": "/home/user/projects/muop-agent/docs/new" }`
        },
        {
          m: "POST", p: "/api/fs/delete",
          s: "Xóa file hoặc thư mục",
          b: [
            ["path", "string", true, "Đường dẫn cần xóa"],
            ["recursive", "boolean", false, "Xóa thư mục chưa rỗng. Mặc định false"]
          ],
          body: `{ "path": "/home/user/projects/muop-agent/tmp", "recursive": true }`,
          res: `{ "ok": true, "path": "/home/user/projects/muop-agent/tmp" }`,
          err: "409 `not_empty` khi thư mục chưa rỗng và `recursive` là false."
        },
        {
          m: "POST", p: "/api/fs/rename",
          s: "Đổi tên hoặc di chuyển",
          b: [
            ["from", "string", true, "Đường dẫn nguồn"],
            ["to", "string", true, "Đường dẫn đích"],
            ["overwrite", "boolean", false, "Thay thế đích nếu đích là file. Đích là thư mục luôn bị từ chối"]
          ],
          body: `{ "from": "/home/user/projects/muop-agent/a.txt", "to": "/home/user/projects/muop-agent/b.txt", "overwrite": false }`,
          res: `{ "ok": true, "from": "...a.txt", "to": "...b.txt" }`
        }
      ],
      errors: "Lỗi có dạng `{ \"ok\": false, \"code\": \"...\", \"error\": \"...\" }`. Mã HTTP: 400 (`invalid`, `is_dir`, `not_dir`), 403 (`outside_root`), 404 (`not_found`), 409 (`exists`, `not_empty`), 500 (`io`)."
    },
    {
      id: "fsmount",
      title: "Mount project từ máy khác",
      desc: "Cơ chế để agent trên máy này làm việc trực tiếp trên project của máy khác. Máy gửi gắn thông tin project vào lượt chat; máy nhận mount thư mục đó qua FUSE bằng `/api/fs/*`.",
      endpoints: [
        {
          m: "POST", p: "/api/fsmount/register",
          s: "Đăng ký máy gửi (kiểm tra kết nối)",
          d: "Máy chính gọi endpoint này khi thêm máy này vào cầu nối. Máy này kiểm tra FUSE và kết nối tới máy chính, không mount gì.",
          b: [
            ["urls", "array", true, "Các địa chỉ `http://IP:PORT` của máy gửi, IP LAN trước"],
            ["projectPath", "string", true, "Đường dẫn project trên máy gửi"],
            ["originHost", "string", false, "Tên máy gửi"]
          ],
          body: `{ "urls": ["http://192.168.1.10:8787"], "projectPath": "/home/user/projects/muop-agent", "originHost": "may-chu" }`,
          res: `{ "ok": true, "origin": "http://192.168.1.10:8787" }`,
          err: "503 kèm `error` nếu thiếu FUSE hoặc không kết nối được."
        },
        {
          m: "POST", p: "/api/fsmount/ensure",
          s: "Kiểm tra và mount project từ máy gửi",
          d: "Chạy đủ các bước: kiểm tra FUSE, chọn địa chỉ, mount tại `~/.local/share/muop-agent/mounts/<mã>`. Dùng để kiểm tra thủ công; lượt chat tự gọi bước này khi có `remoteProject`.",
          b: [
            ["urls", "array", true, "Như `register`"],
            ["projectPath", "string", true, "Đường dẫn project trên máy gửi"],
            ["originHost", "string", false, "Tên máy gửi (dùng để tính mã điểm mount)"]
          ],
          body: `{ "urls": ["http://192.168.1.10:8787", "http://127.0.0.1:8787"], "projectPath": "/home/user/projects/muop-agent", "originHost": "may-chu" }`,
          res: `{ "ok": true, "mountPoint": "/home/user/.local/share/muop-agent/mounts/3f9a...", "origin": "http://192.168.1.10:8787" }`,
          err: "503 kèm `error` khi lỗi."
        }
      ],
      note: "Máy gửi chỉ cần biết địa chỉ máy nhận trong cầu nối. Khi gửi lượt chat qua `/api/bridge/send`, máy gửi tự thêm `remoteProject` vào yêu cầu. Lượt chat không có `remoteProject` chạy trên chính máy này. Cần `fuse3` (`/dev/fuse` và `fusermount3`)."
    },
    {
      id: "agy-auth",
      title: "Đăng nhập Antigravity (agy)",
      desc: "Trạng thái và luồng đăng nhập của agy. Đăng nhập chạy trong một terminal SSH ảo trên server; mã Google dán vào app được ghi vào terminal đó.",
      endpoints: [
        {
          m: "GET", p: "/api/agy/auth/status",
          s: "Trạng thái đăng nhập hiện tại",
          d: "Trả `AgyAuthEvent`. `phase` gồm `idle`, `logged_out`, `unknown`, `login_terminal`, `logged_in`, `failed`, `cancelled`, `expired`. `loginStage` gồm `waiting_link`, `awaiting_token`, `verifying`, `awaiting_terms`.",
          res: `{
  "ok": true,
  "phase": "logged_in",
  "loggedIn": true,
  "loginUrl": "",
  "loginStage": "",
  "error": "",
  "sshSessionId": "",
  "sshHostId": 0
}`
        },
        {
          m: "POST", p: "/api/agy/auth/check",
          s: "Kiểm tra lại đã đăng nhập chưa",
          d: "Nếu đang có terminal đăng nhập và agy đã vào màn chat, luồng kết thúc. Không dùng hub để kiểm tra.",
          res: `{ "ok": true, "phase": "logged_in", "loggedIn": true, "loginUrl": "", "loginStage": "", "error": "", "sshSessionId": "", "sshHostId": 0 }`
        },
        {
          m: "POST", p: "/api/agy/auth/logout",
          s: "Đăng xuất agy",
          d: "Đăng xuất qua hub do server quản lý. Token nằm trong keyring hệ thống, nên đăng xuất cũng ảnh hưởng Antigravity IDE dùng chung keyring.",
          res: `{ "ok": true, "phase": "logged_out", "loggedIn": false, "loginUrl": "", "loginStage": "", "error": "", "sshSessionId": "", "sshHostId": 0 }`
        },
        {
          m: "POST", p: "/api/agy/auth/login/start",
          s: "Mở terminal đăng nhập",
          d: "Mở terminal chạy `agy` để người dùng đăng nhập Google. Bị từ chối nếu đã đăng nhập. Tiến trình đến qua `agy:auth:update`, và terminal hiện trong app qua `ssh:attach`.",
          res: `{ "ok": true, "phase": "login_terminal", "loggedIn": false, "loginUrl": "", "loginStage": "waiting_link", "error": "", "sshSessionId": "s-1", "sshHostId": 1 }`
        },
        {
          m: "POST", p: "/api/agy/auth/login/submit",
          s: "Gửi mã Google vào terminal đăng nhập",
          b: [["code", "string", true, "Mã Google, không có khoảng trắng"]],
          body: `{ "code": "4/0AbCdEf..." }`,
          res: `{ "ok": true, "phase": "login_terminal", "loginStage": "verifying", "loggedIn": false, "loginUrl": "", "error": "", "sshSessionId": "s-1", "sshHostId": 1 }`,
          note: "Mã trống, có khoảng trắng hoặc không có terminal thì `ok: false`, phase giữ nguyên. Lỗi xác thực từ agy đến qua `agy:auth:update` với `phase = failed`."
        },
        {
          m: "POST", p: "/api/agy/auth/login/cancel",
          s: "Hủy đăng nhập",
          d: "Đóng terminal, phase thành `cancelled`.",
          res: `{ "ok": true, "phase": "cancelled", "loggedIn": false, "loginUrl": "", "loginStage": "", "error": "", "sshSessionId": "", "sshHostId": 0 }`
        }
      ]
    },
    {
      id: "claude-auth",
      title: "Đăng nhập Claude Code",
      desc: "Trạng thái và luồng đăng nhập của Claude Code CLI. Luồng: mở link Anthropic, người dùng đăng nhập và dán mã vào app.",
      endpoints: [
        {
          m: "GET", p: "/api/claude/auth/status",
          s: "Trạng thái đăng nhập Claude Code",
          res: `{
  "ok": true,
  "loggedIn": true,
  "email": "",
  "subscriptionType": "pro",
  "loginUrl": "",
  "error": ""
}`,
          note: "`loginUrl` là link Anthropic đang chờ mã xác thực (rỗng nếu không có phiên đăng nhập)."
        },
        {
          m: "POST", p: "/api/claude/auth/logout",
          s: "Đăng xuất Claude Code",
          res: `{ "ok": true, "loggedIn": false, "email": "", "subscriptionType": "", "loginUrl": "", "error": "" }`
        },
        {
          m: "POST", p: "/api/claude/auth/login/start", alias: "/api/claude/auth/start",
          s: "Bắt đầu đăng nhập",
          res: `{ "ok": true, "loggedIn": false, "email": "", "subscriptionType": "", "loginUrl": "https://claude.ai/oauth/...", "error": "" }`
        },
        {
          m: "POST", p: "/api/claude/auth/login/submit", alias: "/api/claude/auth/submit",
          s: "Gửi mã xác thực",
          b: [["code", "string", true, "Mã hiển thị sau khi đăng nhập trên trình duyệt"]],
          body: `{ "code": "abc123#xyz" }`,
          res: `{ "ok": true, "loggedIn": true, "email": "", "subscriptionType": "pro", "loginUrl": "", "error": "" }`
        },
        {
          m: "POST", p: "/api/claude/auth/login/cancel", alias: "/api/claude/auth/cancel",
          s: "Hủy đăng nhập",
          res: `{ "ok": true, "loggedIn": false, "email": "", "subscriptionType": "", "loginUrl": "", "error": "" }`
        }
      ]
    },
    {
      id: "setup",
      title: "Khởi tạo server",
      desc: "Kiểm tra và cài công cụ trên máy chạy server, chọn CLI, chọn thư mục project và đánh dấu hoàn tất wizard. Tiến trình cài đặt đẩy qua `setup:update`.",
      endpoints: [
        {
          m: "GET", p: "/api/setup/status",
          s: "Trạng thái công cụ và wizard",
          res: `{
  "ok": true,
  "error": "",
  "completed": false,
  "selectedClis": ["agy"],
  "workspaceRoot": "/home/user/projects",
  "workspaceReady": true,
  "homeDir": "/home/user",
  "tools": [
    { "id": "git", "installed": true, "path": "/usr/bin/git", "source": "which", "overridden": "" },
    { "id": "agy", "installed": false, "path": "", "source": "", "overridden": "" }
  ],
  "job": null,
  "ssh": { }
}`,
          note: "`source`: `override` (người dùng chọn), `which` (dò bằng PATH), `dev` (bản build trong repo), rỗng (không có)."
        },
        {
          m: "POST", p: "/api/setup/install",
          s: "Cài agy hoặc Claude Code",
          d: "Chỉ hai công cụ `agy` và `claude` được cài tự động, vào `~/.local/bin`. Một job chạy tại một thời điểm, timeout 20 phút.",
          b: [["tool", "string", true, "`agy` hoặc `claude`"]],
          body: `{ "tool": "agy" }`,
          res: `{ "ok": true, "job": { "tool": "agy", "running": true, "log": [] } }`,
          err: "400 với id không thuộc danh sách."
        },
        {
          m: "POST", p: "/api/setup/tool-path",
          s: "Đặt đường dẫn công cụ thủ công",
          d: "Dùng khi `which` không tìm thấy công cụ hoặc muốn dùng bản khác. Đường dẫn phải tuyệt đối và là tệp thực thi. Để `path` rỗng để bỏ lựa chọn và dò lại.",
          b: [
            ["tool", "string", true, "Id công cụ trong `tools[]`"],
            ["path", "string", true, "Đường dẫn tuyệt đối, hoặc rỗng"]
          ],
          body: `{ "tool": "agy", "path": "/opt/agy/bin/agy" }`,
          res: `{ "ok": true, "error": "", "tools": [ /* ... */ ] }`,
          err: "400 nếu đường dẫn sai."
        },
        {
          m: "POST", p: "/api/setup/select",
          s: "Chọn CLI sẽ dùng",
          b: [["clis", "array", true, "Danh sách trong `agy`, `claude`"]],
          body: `{ "clis": ["agy", "claude"] }`,
          res: `{ "ok": true, "selectedClis": ["agy", "claude"] }`
        },
        {
          m: "POST", p: "/api/setup/workspace",
          s: "Chọn thư mục project",
          d: "Không có mặc định. Đường dẫn phải tuyệt đối, không chứa `..`, và phải là thư mục tồn tại. Việc quét project chỉ bắt đầu sau khi khởi tạo xong.",
          b: [["path", "string", true, "Đường dẫn tuyệt đối tới thư mục project"]],
          body: `{ "path": "/home/user/projects" }`,
          res: `{ "ok": true, "workspaceRoot": "/home/user/projects", "workspaceReady": true }`,
          err: "400 nếu đường dẫn sai."
        },
        {
          m: "POST", p: "/api/setup/complete",
          s: "Đánh dấu hoàn tất wizard",
          d: "Từ chối nếu chưa chọn thư mục project.",
          res: `{ "ok": true, "completed": true }`,
          err: "500 nếu lưu lỗi."
        },
        {
          m: "POST", p: "/api/setup/ssh/configure",
          s: "Cấu hình SSH cho user",
          b: [["username", "string", true, "Tên user SSH"]],
          body: `{ "username": "user" }`,
          res: `{ "ok": true, "ssh": { } }`
        },
        {
          m: "POST", p: "/api/setup/ssh/auto",
          s: "Tự thiết lập khóa SSH",
          d: "Sinh khóa, đưa vào `authorized_keys` và thử đăng nhập. Không tự bật sshd (cần quyền root).",
          res: `{ "ok": true, "ssh": { "ready": true } }`
        },
        {
          m: "POST", p: "/api/setup/ssh/verify",
          s: "Kiểm tra khóa đã dán",
          b: [["publicKey", "string", true, "Dòng khóa công khai đã đưa vào `authorized_keys`"]],
          body: `{ "publicKey": "ssh-ed25519 AAAA... user@host" }`,
          res: `{ "ok": true, "ssh": { "ready": true } }`
        }
      ]
    },
    {
      id: "ssh",
      title: "Máy SSH",
      desc: "Lưu nhiều máy và chạy lệnh một lần. Máy \"Máy này\" luôn có sẵn, dùng shell trực tiếp của server (không qua SSH). Mật khẩu và private key đang lưu dạng chưa mã hóa trong SQLite.",
      endpoints: [
        {
          m: "GET", p: "/api/ssh/hosts",
          s: "Danh sách máy đã lưu",
          d: "Trả về mảng. Không trả mật khẩu hay private key; chỉ có `hasPassword` và `hasKey`.",
          res: `[
  { "id": 1, "name": "Máy này", "host": "localhost", "port": 22, "username": "user", "authType": "local", "hasPassword": false, "hasKey": false, "builtin": true },
  { "id": 2, "name": "Laptop", "host": "192.168.1.20", "port": 22, "username": "user", "authType": "password", "hasPassword": true, "hasKey": false, "builtin": false }
]`,
          note: "\"Máy này\" (`builtin: true`) luôn đứng đầu danh sách. Sửa hoặc xóa trả 403."
        },
        {
          m: "GET", p: "/api/ssh/sessions",
          s: "Phiên terminal đang chạy",
          d: "Trả về mảng. Phiên tồn tại độc lập với app; mở lại bằng socket `ssh:attach`.",
          res: `[ { "sessionId": "s-1", "hostId": 2, "hostName": "Laptop", "startedAt": "2026-11-23T10:00:00+07:00" } ]`
        },
        {
          m: "POST", p: "/api/ssh/hosts/save",
          s: "Thêm hoặc sửa máy",
          d: "Để trống `password` hoặc `privateKey` khi sửa để giữ nguyên. Đổi kiểu xác thực thì xóa bí mật của kiểu cũ.",
          b: [
            ["id", "integer", false, "Id khi sửa, bỏ trống khi thêm mới"],
            ["name", "string", true, "Tên hiển thị"],
            ["host", "string", true, "Địa chỉ hoặc tên máy"],
            ["port", "integer", false, "Mặc định 22"],
            ["username", "string", true, "Tên user"],
            ["authType", "string", true, "`password` hoặc `key`"],
            ["password", "string", false, "Mật khẩu (khi `authType` là `password`)"],
            ["privateKey", "string", false, "Nội dung private key (khi `authType` là `key`)"]
          ],
          body: `{ "name": "Laptop", "host": "192.168.1.20", "port": 22, "username": "user", "authType": "password", "password": "********" }`,
          res: `{ "ok": true, "id": 2 }`,
          err: "400 nếu thiếu trường; 500 khi lưu lỗi."
        },
        {
          m: "POST", p: "/api/ssh/hosts/delete",
          s: "Xóa máy",
          b: [["id", "integer", true, "Id máy"]],
          body: `{ "id": 2 }`,
          res: `{ "ok": true }`,
          err: "404 nếu không có; 403 với \"Máy này\"."
        },
        {
          m: "POST", p: "/api/ssh/exec",
          s: "Chạy lệnh một lần trên máy",
          d: "Lệnh chạy bằng binary `ssh` của hệ thống. Mật khẩu đi qua `SSH_ASKPASS` trong thư mục tạm quyền 0700. Máy này chạy `$SHELL -i -c` để có đủ PATH.",
          b: [
            ["hostId", "integer", true, "Id máy"],
            ["command", "string", true, "Lệnh cần chạy"],
            ["timeoutSecs", "integer", false, "Mặc định 30 giây"]
          ],
          body: `{ "hostId": 2, "command": "uptime", "timeoutSecs": 30 }`,
          res: `{ "ok": true, "exitCode": 0, "stdout": " 10:00:00 up 3 days ...", "stderr": "", "error": "" }`,
          err: "404 nếu không tìm thấy máy."
        }
      ]
    },
    {
      id: "lsp",
      title: "Language server và mã nguồn",
      desc: "Hỗ trợ Go (`gopls`), Dart (`dart language-server`) và Rust (`rust-analyzer`). Tiến trình LSP được tạo theo cặp (ngôn ngữ, thư mục gốc project), tối đa 6 tiến trình.",
      endpoints: [
        {
          m: "GET", p: "/api/lsp/settings",
          s: "Trạng thái LSP của từng ngôn ngữ",
          res: `{
  "ok": true,
  "error": "",
  "languages": [
    {
      "language": "go",
      "label": "Go",
      "configuredPath": "",
      "detectedPath": "/home/user/go/bin/gopls",
      "effectivePath": "/home/user/go/bin/gopls",
      "source": "auto",
      "available": true,
      "note": ""
    }
  ]
}`,
          note: "`source`: `config` (người dùng cấu hình), `auto` (tự dò), `none` (không có)."
        },
        {
          m: "POST", p: "/api/lsp/settings",
          s: "Cấu hình đường dẫn LSP",
          d: "`path` rỗng để xóa cấu hình. `path` phải chạy thử được (`--version`), nếu không trả `ok: false`.",
          b: [
            ["language", "string", true, "`go`, `dart` hoặc `rust`"],
            ["path", "string", true, "Đường dẫn tuyệt đối tới tệp thực thi, hoặc rỗng"]
          ],
          body: `{ "language": "rust", "path": "/home/user/.cargo/bin/rust-analyzer" }`,
          res: `{ "ok": true, "error": "", "languages": [ /* như GET */ ] }`
        },
        {
          m: "GET", p: "/api/code/fold",
          s: "Vùng gấp của file",
          q: [["path", "string", true, "Đường dẫn file tuyệt đối"]],
          res: `{ "ok": true, "error": "", "language": "go", "ranges": [ { "startLine": 10, "endLine": 40, "kind": "region" } ] }`
        },
        {
          m: "GET", p: "/api/code/symbols",
          s: "Danh sách hàm và ký hiệu",
          d: "Số dòng đếm từ 0. `depth` là độ lồng (method trong struct có depth 1).",
          q: [["path", "string", true, "Đường dẫn file tuyệt đối"]],
          res: `{ "ok": true, "error": "", "symbols": [ { "name": "main", "kind": 12, "kindLabel": "function", "line": 5, "endLine": 20, "depth": 0 } ] }`
        },
        {
          m: "GET", p: "/api/code/tokens",
          s: "Semantic tokens để tô màu",
          d: "`data` là các bộ bốn số `[dòng, cột, độ dài, chỉ số loại]`, mã hóa tương đối. Giải mã theo `kinds`.",
          q: [["path", "string", true, "Đường dẫn file tuyệt đối"]],
          res: `{ "ok": true, "error": "", "kinds": ["keyword", "function", "variable"], "data": [0, 0, 4, 0, 0, 5, 4, 1, 1, 2] }`
        },
        {
          m: "POST", p: "/api/code/definition",
          s: "Tới định nghĩa",
          d: "`line` và `character` đếm từ 0.",
          b: [
            ["path", "string", true, "Đường dẫn file tuyệt đối"],
            ["line", "integer", true, "Dòng, đếm từ 0"],
            ["character", "integer", true, "Cột, đếm từ 0"]
          ],
          body: `{ "path": "/home/user/projects/app/lib/main.dart", "line": 12, "character": 8 }`,
          res: `{ "ok": true, "error": "", "locations": [ { "path": "/home/user/projects/app/lib/util.dart", "line": 3, "character": 4 } ] }`,
          note: "Lỗi LSP trả `{ \"ok\": false, \"error\": ... }` với HTTP 200. Kết quả rỗng khi LSP vừa khởi động được thử lại tối đa 4 lần."
        },
        {
          m: "POST", p: "/api/code/references",
          s: "Tìm tham chiếu",
          d: "Cùng body với `definition`. Kết quả gồm cả khai báo.",
          b: [
            ["path", "string", true, "Đường dẫn file tuyệt đối"],
            ["line", "integer", true, "Dòng, đếm từ 0"],
            ["character", "integer", true, "Cột, đếm từ 0"]
          ],
          body: `{ "path": "/home/user/projects/app/lib/main.dart", "line": 12, "character": 8 }`,
          res: `{ "ok": true, "error": "", "locations": [ { "path": "...", "line": 12, "character": 8 } ] }`
        },
        {
          m: "POST", p: "/api/code/hover",
          s: "Nội dung hover",
          d: "Cùng body với `definition`. Trả markdown do LSP sinh ra.",
          b: [
            ["path", "string", true, "Đường dẫn file tuyệt đối"],
            ["line", "integer", true, "Dòng, đếm từ 0"],
            ["character", "integer", true, "Cột, đếm từ 0"]
          ],
          body: `{ "path": "/home/user/projects/app/lib/main.dart", "line": 12, "character": 8 }`,
          res: `{ "ok": true, "error": "", "contents": "\`\`\`dart\\nString name\\n\`\`\`" }`
        }
      ]
    },
    {
      id: "docker",
      title: "Docker qua SSH",
      desc: "Mỗi máy có tối đa một phiên Docker, là một kết nối SSH ControlMaster giữ sẵn. Đóng màn hình không ngắt phiên; chỉ `close` mới đóng. Xem log container dùng socket `docker:logs:*`.",
      endpoints: [
        {
          m: "GET", p: "/api/docker/sessions",
          s: "Danh sách phiên Docker",
          d: "Trả về mảng `DockerSessionDto`. Mỗi container có `id`, `name`, `image`, `state`, `status`, `ports`, `project`, `service`. Chỉ liệt kê container đang chạy, nhóm theo label compose.",
          res: `[
  {
    "sessionId": "d-1",
    "hostId": 1,
    "hostName": "Máy này",
    "startedAt": "2026-11-23T10:00:00+07:00",
    "connected": true,
    "scannedAt": "2026-11-23T10:00:05+07:00",
    "error": "",
    "containers": [
      { "id": "9f2c1a0b7e3d", "name": "web-1", "image": "nginx:1.27", "state": "running", "status": "Up 2 hours", "ports": "0.0.0.0:8080->80/tcp", "project": "shop", "service": "web", "created": "..." }
    ]
  }
]`
        },
        {
          m: "POST", p: "/api/docker/sessions/open",
          s: "Mở hoặc gắn vào phiên Docker của máy",
          d: "Nếu máy đã có phiên đang chạy thì gắn vào phiên đó.",
          b: [["hostId", "integer", true, "Id máy trong `/api/ssh/hosts`"]],
          body: `{ "hostId": 2 }`,
          res: `{ "ok": true, "error": "", "session": { "sessionId": "d-1", "connected": true, "containers": [] } }`
        },
        {
          m: "POST", p: "/api/docker/sessions/scan",
          s: "Quét lại container",
          d: "Nếu kết nối đã rớt, server kết nối lại và chạy lại lệnh một lần. Ứng dụng tự quét lại mỗi 10 giây.",
          b: [["sessionId", "string", true, "Id phiên"]],
          body: `{ "sessionId": "d-1" }`,
          res: `{ "ok": true, "error": "", "session": { "sessionId": "d-1", "containers": [] } }`,
          err: "404 nghĩa là phiên đã kết thúc."
        },
        {
          m: "POST", p: "/api/docker/sessions/action",
          s: "Dừng hoặc khởi động lại container",
          d: "`containerIds` là danh sách ID, mỗi ID là chuỗi hex 12 đến 64 ký tự. Gửi toàn bộ container của một project để tác động lên cả component.",
          b: [
            ["sessionId", "string", true, "Id phiên"],
            ["action", "string", true, "`stop` hoặc `restart`"],
            ["containerIds", "array", true, "Danh sách ID container"]
          ],
          body: `{ "sessionId": "d-1", "action": "restart", "containerIds": ["9f2c1a0b7e3d"] }`,
          res: `{ "ok": true, "error": "" }`
        },
        {
          m: "POST", p: "/api/docker/sessions/close",
          s: "Kết thúc phiên",
          d: "Đóng kết nối, dọn master và thư mục tạm.",
          b: [["sessionId", "string", true, "Id phiên"]],
          body: `{ "sessionId": "d-1" }`,
          res: `{ "ok": true, "error": "" }`
        }
      ]
    },
    {
      id: "bridge",
      title: "Cầu nối giữa hai máy",
      desc: "Máy B (chạy server này) điều khiển agent trên máy A qua REST và Socket.IO của A. Địa chỉ máy A lưu trong cài đặt. Chưa có xác thực; chỉ dùng trong LAN hoặc VPN tin cậy.",
      endpoints: [
        {
          m: "GET", p: "/api/bridge/status",
          s: "Trạng thái kết nối tới máy A",
          res: `{ "url": "http://192.168.1.10:8787", "connected": true, "error": "" }`
        },
        {
          m: "POST", p: "/api/bridge/peer",
          s: "Đặt hoặc ngắt máy A",
          d: "Chỉ nhận `http://`. Gửi `url` rỗng để ngắt. Khi thêm máy, server gọi `/api/fsmount/register` trên máy A và trả thêm `registered`, `registerError`.",
          b: [["url", "string", true, "`http://IP:8787` của máy A, hoặc rỗng"]],
          body: `{ "url": "http://192.168.1.10:8787" }`,
          res: `{ "url": "http://192.168.1.10:8787", "connected": true, "error": "", "registered": true, "registerError": "" }`
        },
        {
          m: "POST", p: "/api/bridge/send",
          s: "Gửi lượt chat tới máy A",
          d: "Có cùng tham số với `/api/chat/send`. Máy B tự thêm `remoteProject` để máy A mount project của B. Ack là phản hồi của máy A.",
          b: [
            ["prompt", "string", false, "Nội dung prompt"],
            ["projectPath", "string", true, "Đường dẫn project trên máy B"],
            ["conversationId", "string", false, "Conversation cần tiếp tục"],
            ["model", "string", true, "Model trên máy A"],
            ["images", "array", false, "Như `/api/chat/send`"]
          ],
          body: `{ "prompt": "Thêm test cho module auth", "projectPath": "/home/user/projects/muop-agent", "model": "agy:gemini-4-argon-low" }`,
          res: `{ "ok": true, "conversationId": "conv-456", "projectPath": "/tmp/mount/...", "error": "", "source": "agy" }`,
          err: "503 khi không kết nối được máy A."
        },
        {
          m: "POST", p: "/api/bridge/stop",
          s: "Dừng lượt trên máy A",
          b: [["conversationId", "string", true, "Conversation trên máy A"]],
          body: `{ "conversationId": "conv-456" }`,
          res: `{ "ok": true, "stopped": true }`,
          err: "503 khi không kết nối được máy A."
        },
        {
          m: "POST", p: "/api/bridge/respond",
          s: "Trả lời tương tác Claude Code trên máy A",
          d: "Proxy của `/api/claude/respond` trên máy A. Lỗi nghiệp vụ của máy A (ví dụ 409) được trả nguyên trong body.",
          b: [
            ["conversationId", "string", true, "Conversation trên máy A"],
            ["toolUseId", "string", true, "Phải khớp tương tác đang chờ"],
            ["answers", "array", false, "Như `/api/claude/respond`"],
            ["decision", "string", false, "Như `/api/claude/respond`"]
          ],
          body: `{ "conversationId": "conv-456", "toolUseId": "toolu_01", "decision": "approve" }`,
          err: "502 khi không kết nối được máy A."
        },
        {
          m: "GET", p: "/api/bridge/pending",
          s: "Tương tác đang chờ trên máy A",
          d: "Proxy của `/api/claude/pending`. `pending` là `null` khi không có gì chờ.",
          q: [["conversationId", "string", true, "Chỉ chứa chữ, số, `-` và `_`"]],
          res: `{ "ok": true, "conversationId": "conv-456", "pending": null }`
        },
        {
          m: "GET", p: "/api/bridge/meta",
          s: "Model và thông tin của máy A",
          d: "Proxy của `/api/meta` trên máy A, gồm `availableModels`, `modelLabels`, `hostname`.",
          res: `{ "availableModels": ["agy:gemini-4-argon-low"], "modelLabels": {}, "hostname": "may-a" }`
        },
        {
          m: "GET", p: "/api/bridge/quota",
          s: "Quota của máy A",
          q: [["provider", "string", true, "`agy` hoặc `claude`"]],
          res: `{ "provider": "agy", "groups": [], "error": "" }`,
          err: "400 nếu `provider` không hợp lệ."
        },
        {
          m: "GET", p: "/api/bridge/sessions",
          s: "Conversation trên máy A",
          d: "Proxy của `/api/sessions` trên máy A (dạng tóm tắt).",
          res: `{ "sessions": [ { "id": "conv-456", "title": "Thêm test", "projectPath": "/tmp/mount/...", "status": "running" } ] }`
        },
        {
          m: "GET", p: "/api/bridge/session",
          s: "Chi tiết conversation trên máy A",
          d: "Proxy của `/api/session?id=` trên máy A, có đầy đủ steps.",
          q: [["id", "string", true, "Id conversation trên máy A"]],
          res: `{ "id": "conv-456", "title": "Thêm test", "steps": [ /* AgentStep */ ] }`
        }
      ],
      note: "Trả lời câu hỏi agy: không có route riêng. Gửi lượt mới bằng `/api/bridge/send` với `conversationId` của conversation đó. Sự kiện của máy A được chuyển tiếp với tiền tố `bridge:` (xem mục Socket.IO)."
    }
  ],

  /* ---------- Socket.IO ---------- */
  socket: {
    intro: "Namespace mặc định `/`, Socket.IO v4 qua WebSocket hoặc polling. Với event có ack, callback nhận giá trị trả về. Khi kết nối, server gửi ngay `retry:update`, `screen:status`, `setup:update`, `agy:auth:update`, `claude:auth:update` và `quotas:update`. Client nên gọi `request-sessions`, `request-meta` và `request-streams` sau khi kết nối (và sau khi kết nối lại).",
    client: [
      { e: "request-sessions", p: "—", a: "Server phát `sessions:list`" },
      { e: "request-meta", p: "—", a: "Server phát `meta:update`" },
      { e: "request-streams", p: "—", a: "Server phát `streams:update`" },
      { e: "request-screen-status", p: "—", a: "Server phát `screen:status`" },
      { e: "chat:send", p: "ChatSendRequest (như REST)", a: "ChatSendResponse" },
      { e: "chat:stop", p: "{ conversationId }", a: "{ ok, stopped }" },
      { e: "join-conversation", p: "{ conversationId }", a: "Phát `joined-conversation`. Vào room `conv:<id>` để nhận `fileschange`" },
      { e: "leave-conversation", p: "{ conversationId }", a: "Rời room" },
      { e: "ssh:list", p: "—", a: "Mảng `SshSessionInfo`" },
      { e: "ssh:open", p: "{ hostId, cols, rows }", a: "{ ok, sessionId, error }. Socket tự vào room `ssh:<sessionId>` trước khi PTY chạy" },
      { e: "ssh:attach", p: "{ sessionId }", a: "{ ok, sessionId, hostName, buffer (base64), error }. Nhận đệm 256KB" },
      { e: "ssh:input", p: "{ sessionId, data (base64) }", a: "Không ack" },
      { e: "ssh:resize", p: "{ sessionId, cols, rows }", a: "Không ack" },
      { e: "ssh:close", p: "{ sessionId }", a: "Đóng phiên" },
      { e: "docker:logs:open", p: "{ sessionId, containerId, tail }", a: "{ ok, streamId, error }. Vào room `docker-logs:<streamId>` trước. Tối đa 16 luồng" },
      { e: "docker:logs:ping", p: "{ streamId }", a: "Gửi mỗi 10 giây; quá 30 giây không ping thì server dừng luồng" },
      { e: "docker:logs:close", p: "{ streamId }", a: "Dừng luồng ngay" },
      { e: "explore:watch", p: "{ path }", a: "{ ok, room, error }. Theo dõi nội dung trực tiếp của thư mục" },
      { e: "explore:unwatch", p: "{ room }", a: "{ ok, room, error }" },
      { e: "agy:auth:status", p: "—", a: "AgyAuthEvent" },
      { e: "agy:auth:check", p: "—", a: "AgyAuthEvent" },
      { e: "agy:auth:start", p: "—", a: "AgyAuthEvent" },
      { e: "agy:auth:submit", p: "{ code }", a: "AgyAuthEvent" },
      { e: "agy:auth:cancel", p: "—", a: "AgyAuthEvent" },
      { e: "agy:auth:logout", p: "—", a: "AgyAuthEvent" },
      { e: "accounts:status", p: "—", a: "AgyAuthEvent (trạng thái tài khoản agy)" },
      { e: "claude:auth:status", p: "—", a: "ClaudeAuthResponse" },
      { e: "claude:auth:start", p: "—", a: "ClaudeAuthResponse" },
      { e: "claude:auth:submit", p: "{ code }", a: "ClaudeAuthResponse" },
      { e: "claude:auth:cancel", p: "—", a: "ClaudeAuthResponse" },
      { e: "claude:auth:logout", p: "—", a: "ClaudeAuthResponse" },
      { e: "setup:status", p: "—", a: "SetupStatus" },
      { e: "setup:install", p: "{ tool }", a: "SetupStatus" },
      { e: "setup:tool-path", p: "{ tool, path }", a: "SetupStatus" },
      { e: "setup:workspace", p: "{ path }", a: "SetupStatus" },
      { e: "setup:select", p: "{ clis }", a: "SetupStatus" },
      { e: "setup:complete", p: "—", a: "SetupStatus" },
      { e: "setup:ssh:configure", p: "{ username }", a: "SetupStatus" },
      { e: "setup:ssh:auto", p: "—", a: "SetupStatus" },
      { e: "setup:ssh:verify", p: "{ publicKey }", a: "SetupStatus" }
    ],
    server: [
      { e: "sessions:list", w: "Sau `request-sessions`", p: "{ sessions: [SessionSummary] }" },
      { e: "meta:update", w: "Sau `request-meta`", p: "MetaPayload" },
      { e: "streams:update", w: "Sau `request-streams` và khi danh sách lượt đang chạy đổi", p: "{ activeStreams: { <id>: ChatTurnStreamState } }" },
      { e: "screen:status", w: "Khi kết nối và khi trạng thái màn hình đổi", p: "{ streaming, starting, error, height, fps, rtspUrl }" },
      { e: "chat:stream", w: "Trong lượt chat", p: "ChatTurnStreamState: conversationId, projectPath, userPrompt, streamingText, thinkingText, isRunning, activeStepType, startedAt, error" },
      { e: "session:update", w: "Conversation thay đổi", p: "ConversationSession đầy đủ" },
      { e: "session:removed", w: "Conversation bị xóa khỏi đĩa", p: "{ id }" },
      { e: "fileschange", w: "File trong conversation đổi (room `conv:<id>`)", p: "Dữ liệu thay đổi file" },
      { e: "joined-conversation", w: "Sau `join-conversation`", p: "{ ok, conversationId }" },
      { e: "projects:update", w: "Danh sách project đổi", p: "Mảng ProjectWorkspace" },
      { e: "quotas:update", w: "Số liệu quota đổi và khi kết nối", p: "QuotaSnapshot. Client tải lại quota khi nhận" },
      { e: "retry:update", w: "Khi kết nối và khi lịch gửi lại đổi", p: "Mảng PendingRetryDto: conversationId, provider, reason, retryAt (RFC3339 UTC), attempt, maxAttempts" },
      { e: "ai-question:answered", w: "Sau khi trả lời câu hỏi AI", p: "AIQuestion đã trả lời" },
      { e: "setup:update", w: "Khi kết nối và khi tiến trình cài đổi", p: "SetupStatus kèm job.log (300 dòng cuối)" },
      { e: "agy:auth:update", w: "Khi kết nối và khi trạng thái đăng nhập agy đổi (chỉ khi nội dung đổi)", p: "AgyAuthEvent" },
      { e: "claude:auth:update", w: "Khi kết nối và khi trạng thái đăng nhập Claude đổi", p: "ClaudeAuthResponse" },
      { e: "ssh:data", w: "Đầu ra terminal SSH", p: "{ sessionId, data (base64) } vào room `ssh:<sessionId>`" },
      { e: "ssh:closed", w: "Phiên terminal kết thúc", p: "{ sessionId, exitCode }" },
      { e: "docker:logs:data", w: "Có dòng log mới", p: "{ streamId, lines: [...] }. Gom theo lô 150ms hoặc 80 dòng" },
      { e: "docker:logs:end", w: "Luồng log kết thúc", p: "{ streamId, exitCode }" },
      { e: "explore:update", w: "Nội dung thư mục đang xem đổi (gom trong 300ms)", p: "{ room, path }. Client nạp lại thư mục đó" }
    ],
    bridge: [
      "bridge:chat:stream", "bridge:session:update", "bridge:streams:update",
      "bridge:ai-question:answered", "bridge:retry:update", "bridge:quotas:update", "bridge:status"
    ],
    notes: [
      "Socket.IO tách mảng cấp cao nhất của một event thành nhiều đối số. `sessions:list` nên được bọc trong object; `projects:update` là mảng, client đọc mọi đối số để ghép lại.",
      "Trạng thái các lượt đang chạy lấy từ `streams:update`, không suy ra từ các `chat:stream` đã nhận trước đó.",
      "Phiên SSH và Docker tồn tại độc lập với client. Phiên không được dùng (input hoặc attach) quá 6 giờ sẽ tự đóng.",
      "Explorer: thư mục chỉ được theo dõi khi có ít nhất một socket đang xem. Watcher dùng inotify, không đệ quy."
    ]
  },

  /* ---------- Màn hình (RTSP) ---------- */
  screen: {
    url: "rtsp://<ip-server>:8554/screen",
    desc: "Luồng màn hình của máy server, phát qua RTSP. Bật và tắt từ icon khay hệ thống. Lần bật đầu có thể cần xác nhận chia sẻ màn hình qua xdg-desktop-portal. Server không có REST cho luồng này; trạng thái đến qua `screen:status`.",
    status: `{
  "streaming": true,
  "starting": false,
  "error": "",
  "height": 720,
  "fps": 30,
  "rtspUrl": "rtsp://192.168.1.10:8554/screen"
}`
  },

  /* ---------- Quy ước chung ---------- */
  conventions: [
    ["Địa chỉ", "`http://<ip-server>:8787`. Server lắng nghe trên `0.0.0.0`."],
    ["Định dạng", "JSON, khóa camelCase. Ngoại lệ: các endpoint trả nội dung nhị phân (`/api/files/download`, `/api/fs/read`, `/api/chat/attachment`)."],
    ["Kích thước body", "Tối đa 64MB, đủ cho ảnh đính kèm dạng base64."],
    ["Lỗi", "Phần lớn endpoint trả `{ \"ok\": false, \"error\": \"...\" }` kèm 400, 403, 404, 409, 500 tùy trường hợp. Đăng nhập và LSP trả 200 kèm `ok` và `error` để giao diện hiển thị."],
    ["CORS", "Cho phép mọi origin, để trình duyệt trong LAN gọi trực tiếp."],
    ["Xác thực", "Không có. Chỉ dùng trong LAN hoặc VPN tin cậy, không mở cổng 8787 ra internet."],
    ["Đường dẫn", "Đường dẫn file và project luôn là đường dẫn tuyệt đối trên máy server."],
    ["Id model", "`claude-cli:<model>-<mức>` cho Claude Code (mức: low, medium, high, xhigh, max), `agy:<model>` cho Antigravity."]
  ]
};
