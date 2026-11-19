# HƯỚNG DẪN DÀNH CHO AI AGENT (AGENTS.md)
# DỰ ÁN: MƯỚP AGENT MONITOR (`muop-agent`)

> Tài liệu này được thiết kế dành riêng cho các AI Coding Agent (và nhà phát triển phần mềm) khi tiếp cận, phát triển, bảo trì và mở rộng mã nguồn trong kho lưu trữ **`muop-agent`**.

---

## 0. PHẠM VI THAY ĐỔI (QUAN TRỌNG)

> **Không sửa code App Slint (`app/`) khi người dùng không yêu cầu rõ ràng.**
> Mặc định chỉ thay đổi `server/` (Rust) và Flutter (`lib/`, `test/`). Nếu một thay đổi ở server hoặc Flutter làm ảnh hưởng `app/`, chỉ báo lại trong báo cáo, không tự sửa.

---

## 1. TỔNG QUAN HỆ THỐNG (SYSTEM OVERVIEW)

- **Tên dự án**: `muop-agent` (Mướp Agent Monitor & Chat Canvas)
- **Mục tiêu**: Nền tảng Giám sát thời gian thực và Trò chuyện trực tiếp với AI Coding Agent (tương tự Google Antigravity 2.0 IDE & Mobile Remote) phục vụ hệ sinh thái **`muop-ecosystem`** (đặc biệt là cặp song hành **`muop-erp-server` ↔ `muop-erp-app`**).
- **Hỗ trợ nền tảng**:
  - **Linux Desktop**: Giao diện máy bàn native hiệu năng cao, tích hợp quản trị nhiều workspace.
  - **Android Mobile**: Giao diện di động phản hồi mượt mà, kết nối qua mạng nội bộ LAN WiFi tới máy chủ.
- **Kiến trúc Hybrid (Pure Flutter Client + Rust Backend Engine)**:
  - **`server/` (Rust Engine)**: Máy chủ dịch vụ siêu nhẹ viết bằng Rust, lắng nghe tại `0.0.0.0:8787`. Đảm nhiệm toàn bộ việc quét CSDL SQLite `conversation_summaries.db`, phân tích logs `transcript.jsonl`, quản lý tiến trình CLI `agy`, và phát Socket.IO realtime.
  - **`lib/` (Flutter Client)**: Ứng dụng Material 3 đóng vai trò **Pure UI Client 100%**, hoàn toàn không chứa mã truy cập hệ thống file cục bộ. Mọi tương tác đều thông qua giao thức Socket.IO v4 và REST API tới Rust Server.

---

## 2. TECH STACK & CÁC THƯ VIỆN CHỦ ĐẠO

### 2.1. Backend Engine (`server/`)
| Phân hệ / Thư viện | Công nghệ / Crate | Ghi chú & Phiên bản |
| :--- | :--- | :--- |
| **Ngôn ngữ** | Rust | Edition `2021` |
| **Web Framework** | `axum = "0.7"` | REST API router hiệu năng cao, non-blocking |
| **Realtime Engine** | `socketioxide = "0.14"` | Hỗ trợ chuẩn Socket.IO v4, WebSocket & Polling fallback |
| **Bất đồng bộ** | `tokio = { version = "1", features = ["full"] }` | Multi-threaded async runtime |
| **Truy vấn SQLite** | `rusqlite = "0.31"` | Đọc trực tiếp `conversation_summaries.db` với `SQLITE_OPEN_READ_ONLY` |
| **Bóc tách Dữ liệu** | `regex = "1.10"`, `chrono = "0.4"` | Phân tích JSONL transcript, phân nhóm tool calls, regex subagent |
| **Serialization** | `serde = "1.0"`, `serde_json = "1.0"` | Chuyển đổi DTO JSON chuẩn `camelCase` cho client |
| **CORS Middleware** | `tower-http = { version = "0.5", features = ["cors"] }` | Cho phép kết nối an toàn từ mọi IP LAN |

### 2.2. Frontend Client (`lib/`)
| Phân hệ / Thư viện | Công nghệ / Package | Ghi chú & Phiên bản |
| :--- | :--- | :--- |
| **Framework** | Flutter SDK (Dart 3) | Material 3 Dynamic Theming |
| **Realtime Client** | `socket_io_client: ^3.0.2` | Kết nối WebSocket tới Rust Server `:8787` |
| **Mạng & HTTP** | Native `dart:io HttpClient` | Giao tiếp REST API phân trang và upload/download |
| **Đa nền tảng** | Linux Desktop & Android | Bản build Linux Release & APK Release di động |

---

## 3. CẤU TRÚC KHO LƯU TRỮ (REPOSITORY DIRECTORY LAYOUT)

```tree
muop-agent/
├── Makefile                        # Tự động hóa build, test, run cho cả Rust và Flutter
├── README.md                       # Tài liệu hướng dẫn sử dụng nhanh
├── pubspec.yaml / pubspec.lock     # Khai báo dependency Flutter
├── analysis_options.yaml           # Bộ quy tắc lint tĩnh cho Flutter (flutter_lints)
├── run-linux.sh                    # Script khởi chạy nhanh giao diện Linux
├── muop-agent-release.apk          # Bản cài đặt Android APK Release chính thức
│
├── server/                         # Máy chủ Rust Backend (Axum + Socket.IO)
│   ├── Cargo.toml / Cargo.lock     # Cấu hình package & dependencies Rust
│   └── src/
│       ├── main.rs                 # Entrypoint Axum, Router REST, Socket.IO event handlers, CORS
│       ├── scanner.rs              # Quét SQLite, phân tích transcript.jsonl, phân trang steps, subagents
│       ├── chat.rs                 # Quản trị tiến trình `agy cli` (-p prompt, --conversation id, stop turn)
│       └── models.rs               # Định nghĩa các struct DTO JSON (ConversationSession, AgentStep...)
│
├── lib/                            # Giao diện Pure Flutter Client
│   ├── main.dart                   # Entrypoint MaterialApp, chuyển đổi Dark/Light mode
│   │
│   ├── models/
│   │   ├── agent_core_models.dart  # Data models (Session, Step, ToolCall, SubagentLane, Quota, Page)
│   │   └── agent_models.dart       # UI Extensions: Icons, Colors, trạng thái hiển thị
│   │
│   ├── services/
│   │   └── brain_scanner_service.dart # Singleton Service: Quản lý Socket.IO, Snapshot stream, REST calls
│   │
│   └── ui/
│       ├── dashboard_screen.dart   # Màn hình chính (Sidebar danh sách Session, Project, Model Quotas)
│       ├── parallel_agent_flow_screen.dart # Màn hình sơ đồ trực quan hóa luồng chạy song song Parallel Agents
│       └── widgets/
│           ├── chat_canvas_view.dart      # Canvas chat thời gian thực, tasks running, cuộn phân trang
│           └── server_file_browser_sheet.dart # Modal duyệt file, đọc code & xem git diff trên máy chủ
│
├── android/                        # Dự án Android Runner (Gradle, NDK, Manifest)
└── linux/                          # Dự án Linux Desktop Runner (C++ CMake entrypoint)
```

---

## 4. CÁC NGUYÊN TẮC KIẾN TRÚC CỐT LÕI (CORE ARCHITECTURAL PATTERNS)

### 4.1. Nguyên tắc Client Thuần Túy (Pure UI Client vs. Headless Server Engine)
- **Quy tắc bất di bất dịch**:
  > Mã nguồn Flutter trong thư mục `lib/` **TUYỆT ĐỐI KHÔNG ĐƯỢC PHÉP** đọc ghi file hệ thống trên máy tính chủ, không import `dart:io` để quét thư mục `~/.gemini/antigravity`, và không chạy tiến trình shell trực tiếp.
  > Mọi dữ liệu phải đi qua Rust Server `:8787` thông qua REST API hoặc Socket.IO event.
- **Lý do**: Đảm bảo ứng dụng chạy đồng nhất 100% trên cả Android Mobile và Linux Desktop.

### 4.2. Giao thức Đồng bộ Realtime (Socket.IO + REST Paging)
- **Namespace mặc định**: `/`
- **Sự kiện Socket.IO**:
  - `snapshot:update`: Máy chủ tự động phát hiện thay đổi và broadcast trạng thái tổng thể xuống client.
  - `chat:send`: Client gửi yêu cầu trò chuyện kèm `conversation_id`, `prompt`, `project_path`, `model`.
  - `chat:stop`: Dừng khẩn cấp lượt xử lý đang chạy của Agent.
  - `chat:stream`: Server stream nội dung phản hồi theo thời gian thực (`token`, `tool_call`, `status`).
- **Chiến lược Merge Snapshot Thông minh (`_mergeNewerSteps`)**:
  - Khi snapshot định kỳ gửi về (mặc định giữ 100-150 steps gần nhất để payload nhẹ ~200KB), client **không được ghi đè làm mất các bước cũ đã được nạp qua phân trang**.
  - Hàm `_mergeNewerSteps` giữ nguyên toàn bộ steps lịch sử cũ và chỉ gộp thêm các steps mới phát sinh ở cuối danh sách.

### 4.3. Cơ chế Phân trang Lịch sử Cuộc trò chuyện (Conversation History Paging)
- **Yêu cầu cốt lõi**: Không tải toàn bộ transcript (thường hơn 2.500+ bước, nặng hàng chục MB) một lúc, tránh giật lag hoặc tràn bộ nhớ thiết bị di động.
- **Luồng hoạt động**:
  1. Ban đầu, app chỉ tải 100 bước gần nhất từ snapshot.
  2. Khi người dùng cuộn lên trên (`pixels >= maxScrollExtent - 240` trên `ListView(reverse: true)`):
     - App xác định `earliestStepIndex` hiện có.
     - Gọi API phân trang: `GET /api/session/steps?id=<sessionId>&before_step=<earliestStepIndex>&limit=50`.
  3. Phía Rust Server (`scanner.rs`):
     - Lọc các bước xảy ra trước `before_step`, lấy đúng 50 bước liền trước đó.
     - Trả về JSON gọn nhẹ `SessionStepsPageResponse` (`steps`, `hasMore`, `earliestStepIndex`, `totalSteps`).
  4. Phía Flutter Client:
     - Prepend (chèn lên đầu) 50 bước này vào danh sách `steps`.
     - Do dùng `ListView(reverse: true)`, vị trí cuộn của người dùng được giữ nguyên hoàn hảo, không bị nhảy hay giật về đáy.
     - Banner tải thêm tự nạp lặp lại khi còn nằm trong khung nhìn (`_maybeLoadOlderTurns`); khi `hasMore == false` hoặc trang không thêm bước mới thì banner bị ẩn.

### 4.4. Trực quan hóa Luồng Parallel Agents (`ParallelAgentFlowScreen`)
- **Tích hợp Quy chuẩn Parallel ERP Sync (`parallel-erp-sync.md`)**:
  - Khi Agent điều phối triển khai các subagent song song (`erp-server-agent`, `erp-app-agent`, `erp-contract-verifier`), ứng dụng trực quan hóa toàn bộ luồng hoạt động.
- **Nút chuyển đổi trong `Tasks Running`**:
  - Nằm ngay trong khối thanh tác vụ "tasks running" ở đáy `ChatCanvasView`.
  - Hiển thị badge số lượng Subagents đang hoạt động và cho phép một chạm mở màn hình `ParallelAgentFlowScreen`.
- **Thành phần trên màn hình `ParallelAgentFlowScreen`**:
  - **Sơ đồ Khối DAG (Visual Workflow Graph)**: Thể hiện luồng từ Coordinator (Antigravity Engine) rẽ nhánh song song tới Server Agent (`muop-erp-server`), App Agent (`muop-erp-app`), và Verifier Agent, hội tụ tại bước nghiệm thu `go build` & `flutter analyze`.
  - **Thẻ Agent Chi Tiết (Agent Lane Cards)**: Hiển thị tên, role, target repo, thanh tiến trình %, hành động hiện tại (`currentActionText`), công cụ đang gọi (`currentToolName`), danh sách file đã sửa đổi kèm chỉ số `+X / -Y`.
  - **Trạng thái Đối soát Chéo (Cross-Repo Sync Status)**: Trạng thái biên dịch Backend Go và trạng thái phân tích tĩnh Frontend Flutter.
  - **Nhật ký Sự kiện Song song (Live Parallel Event Log)**: Dòng thời gian hiển thị đan xen các thao tác của các subagents theo thời gian thực.

### 4.5. Cơ chế Tương tác CLI Agent (`agy cli`)
- Để đảm bảo tính ổn định tuyệt đối và tránh lỗi giới hạn tài nguyên (429 Resource Exhausted) của các cầu nối tự động, hệ thống sử dụng trực tiếp CLI chính thức của Antigravity:
  ```bash
  /home/john/.local/bin/agy -p "<prompt>" --conversation "<conversation_id>"
  ```
- Tiến trình con được quản lý qua `tokio::process::Command`, cho phép theo dõi `Child` ID và hủy tiến trình an toàn khi nhận được lệnh `chat:stop`.

### 4.6. Cơ chế Phê duyệt Kế hoạch (Plan Artifact Approval)
- Khi Agent tạo tệp kế hoạch (Artifact `.md`) có trường `RequestFeedback: true`:
  - Rust Server tự động phát hiện trong thư mục brain và gửi thông tin trong `pending_plans`.
  - Flutter Client hiển thị banner phê duyệt kế hoạch nổi bật:
    - Nút **"Duyệt kế hoạch & Chạy ngay"**: Gửi lệnh xác nhận phê duyệt vào phiên chat.
    - Nút **"Góp ý chỉnh sửa"**: Mở hộp thoại nhập ý kiến phản hồi cho Agent hoàn thiện lại kế hoạch.

---

## 5. CÁC QUY CHUẨN LẬP TRÌNH BẮT BUỘC (CODING CONVENTIONS)

### 5.1. Quy chuẩn Mã nguồn Flutter (`lib/`)
1. **Kiểm tra Phân tích Tĩnh (Static Analysis)**:
   > **BẮT BUỘC**: Mã nguồn Flutter phải luôn đạt trạng thái **CLEAN 100%** khi chạy:
   > ```bash
   > flutter analyze
   > # Kết quả bắt buộc: No issues found!
   > ```
   > Tuyệt đối không để tồn tại các cảnh báo `deprecated_member_use`, `unused_local_variable`, `missing_type_arguments`...
2. **Tuân thủ Material 3 & Tương thích Dark/Light Theme**:
   - Sử dụng màu từ `Theme.of(context).colorScheme` (ví dụ: `colorScheme.surface`, `colorScheme.primary`, `colorScheme.outlineVariant`).
   - Tuyệt đối không hardcode màu sắc cố định (như `Colors.white` hoặc `Colors.black`) cho nền hoặc văn bản để tránh lỗi hiển thị khi đổi theme.
3. **Quản lý Scroll Position trên `ListView(reverse: true)`**:
   - Lưu ý hệ tọa độ đảo ngược: `pixels = 0.0` là đáy (tin nhắn mới nhất), `pixels = maxScrollExtent` là đỉnh (tin nhắn cũ nhất).
   - Chỉ tự động cuộn xuống đáy (`_scrollToBottom`) khi người dùng đang ở gần đáy (`pixels < 120`). Không bao giờ tự động cuộn khi người dùng đang xem lịch sử phía trên hoặc đang nạp thêm dữ liệu cũ.

### 5.2. Quy chuẩn Mã nguồn Rust (`server/`)
1. **Kiểm tra Biên dịch & Định dạng**:
   ```bash
   cd server
   cargo check
   cargo fmt --check
   ```
2. **Xử lý Bất đồng bộ & I/O**:
   - Các thao tác đọc ghi file lớn hoặc quét SQLite nặng phải được bọc trong `tokio::task::spawn_blocking` để không làm nghẽn Event Loop của Axum server.
3. **Chuẩn hóa DTO Serialization**:
   - Mọi struct truyền nhận qua JSON đều phải có attribute `#[serde(rename_all = "camelCase")]` để đồng nhất với quy chuẩn camelCase của Flutter / Dart.

### 5.3. Quy tắc Bắt buộc Khi Build App (Dual-Platform Release & Auto-Restart Linux)
> **QUY TẮC BẮT BUỘC CHO AGENT**:
> Khi có yêu cầu build ứng dụng `muop-agent`, Agent **BẮT BUỘC PHẢI BUILD CẢ HAI BẢN**: **Android APK Release** và **Linux Desktop Release**.
> 1. **Android APK Release**:
>    - Chạy `flutter build apk --release` và copy bản build ra thư mục gốc: `cp build/app/outputs/flutter-apk/app-release.apk ./muop-agent-release.apk` (hoặc chạy `make build-apk`).
> 2. **Linux Desktop Release**:
>    - Chạy `flutter build linux --release` (hoặc chạy `make build-linux`).
> 3. **Kiểm tra & Khởi động lại App Linux (Auto-Restart Linux App)**:
>    - Ngay sau khi build xong bản Linux Release, Agent **BẮT BUỘC** phải kiểm tra xem app Linux (`muop_agent`) có đang chạy hay không bằng `pgrep -f muop_agent` (hoặc `pgrep -x muop_agent`).
>    - **Nếu đang chạy**: Tiến hành tắt (kill) tiến trình cũ đi (`pkill -f "bundle/muop_agent" || killall muop_agent`), chờ 1 giây, sau đó khởi động lại bản build Linux mới ở chế độ nền bằng lệnh `systemd-run --user ./build/linux/x64/release/bundle/muop_agent` (hoặc qua `make restart-linux`) để ứng dụng gắn trực tiếp vào phiên desktop Wayland/X11 của người dùng mà không bị ngắt khi terminal kết thúc.
>    - **Nếu không chạy**: Không cần khởi động, thông báo đường dẫn file build sẵn sàng.

---

## 6. DANH MỤC LỆNH VẬN HÀNH & PHÁT TRIỂN (COMMANDS CHEATSHEET)

### 6.1. Khởi chạy Môi trường Phát triển (Local Dev)
```bash
# Khởi chạy Rust Server trên cổng :8787 (với release mode để tối ưu tốc độ)
make server
# hoặc:
cd server && cargo run --release

# Khởi chạy ứng dụng Flutter trên Linux Desktop
make run
# hoặc:
flutter run -d linux
```

### 6.2. Biên dịch Bản Phát hành (Production Builds)
```bash
# Biên dịch binary Rust Server Release
make build-server
# Kết quả: server/target/release/muop-agent-server

# Biên dịch trọn gói Dual-Platform (cả Android APK và Linux Desktop, tự động restart Linux nếu đang mở)
make build-all

# Hoặc biên dịch riêng lẻ:
# 1. Biên dịch Android APK Release (tự động copy ra thư mục gốc)
make build-apk
# Kết quả: ./muop-agent-release.apk

# 2. Biên dịch Linux Desktop Release & Tự động restart app nếu đang mở
make build-linux
# Kết quả: build/linux/x64/release/bundle/muop_agent
```

### 6.3. Kiểm tra Chất lượng Mã Nguồn (Quality Assurance)
```bash
# Kiểm tra toàn diện cả Flutter analyze và Rust cargo check
make analyze
```

### 6.4. Chạy Daemon Máy Chủ Nền (Background Daemon)
```bash
# Khởi chạy server nền không phụ thuộc terminal session
nohup /home/john/Documents/muop-ecosystem/muop-agent/server/target/release/muop-agent-server > /tmp/muop-agent-server.log 2>&1 &

# Kiểm tra trạng thái cổng 8787
lsof -i :8787
```

---

## 7. QUY TRÌNH PHỐI HỢP AGENT (AGENT WORKFLOW GUIDELINES)

1. **Khi chỉnh sửa API hoặc Socket.IO trên Rust Server**:
   - Cập nhật DTO trong `server/src/models.rs`.
   - Cập nhật logic trong `server/src/scanner.rs` hoặc `server/src/main.rs`.
   - Kiểm tra `cargo check`.
   - Biên dịch lại binary: `cargo build --release`.
   - Khởi động lại daemon trên cổng `:8787`.
   - Đồng bộ ngay lập tức Model và Service tương ứng trong Flutter (`lib/models/agent_core_models.dart`, `lib/services/brain_scanner_service.dart`).
2. **Khi chỉnh sửa Giao diện Flutter**:
   - Đảm bảo widget tương thích cả màn hình Desktop và Mobile (Responsive Layout).
   - Kiểm tra `flutter analyze` sạch lỗi 100%.
   - **Quy tắc Build**: Luôn build cả hai bản Android và Linux (`make build-all` hoặc lần lượt `make build-apk` và `make build-linux`). Khi build xong bản Linux, kiểm tra nếu app Linux `muop_agent` đang mở thì kill tiến trình cũ và khởi động lại ngay lập tức để người dùng trải nghiệm ngay bản mới.
3. **Sau mỗi tác vụ chỉnh sửa (bắt buộc, áp dụng cho mọi thay đổi code)**:
   - **Nếu có sửa `server/`** (Rust): build lại server (`make build-server`) rồi khởi động lại daemon (`make restart-daemon`), sau đó xác nhận cổng `:8787` phản hồi.
   - **Nếu có sửa `lib/`** (Flutter UI): build cả Linux và Android (`make build-all`), sau đó kiểm tra app Linux `muop_agent` có đang chạy không. Nếu đang chạy thì kill tiến trình cũ và mở lại bản build mới (`make restart-linux`). Nếu không chạy thì chỉ báo đường dẫn bản build.
   - Nếu một tác vụ sửa cả hai phía thì thực hiện đủ cả hai nhánh trên.
   - Không kết thúc tác vụ khi chưa build/restart theo quy tắc này; nếu bước nào không thực hiện được thì phải nêu rõ trong báo cáo cuối.

## 8. GHI CHÚ BÀN GIAO (TRẠNG THÁI HIỆN TẠI — cập nhật theo từng đợt chỉnh sửa)

> Mục này ghi các quyết định kiến trúc và việc còn dở để người/agent tiếp theo không phải đọc lại toàn bộ lịch sử. Khi thay đổi các phần dưới đây, cập nhật luôn mục này.

### 8.1. Lưu trữ dữ liệu (SQLite)
- Server dùng một DB SQLite duy nhất: `~/.local/share/muop-agent/muop-agent.db` (WAL), mở qua `server/src/store.rs` bằng `rusqlite`.
- Bảng `agy_turn_models(conversation_id, started_at, model)`: model đã dùng cho từng lượt agy (transcript của agy không lưu model). Thay cho file `agy-turn-models.jsonl`, file cũ được import một lần rồi xóa.
- Bảng `conversation_models(conversation_id, model, updated_at)`: model người dùng chọn theo conversation. API: `GET /api/conversation/model?id=<cid>` và `POST /api/conversation/model` với body `{conversationId, model}`.
- **Chưa làm (chờ quyết định)**: địa chỉ server phía Flutter vẫn lưu ở `muop_agent_remote_config.json` trong thư mục temp (`brain_scanner_service.dart`). Client chưa nối với API `conversation/model`, nên lựa chọn model hiện chỉ nằm trong bộ nhớ app.

### 8.2. Provider, source và model
- Session có trường `source`: `claude-cli` (từ transcript Claude) hoặc `agy`. Server trả `source` trong phản hồi `chat:send` (`ChatSendResponse.source`).
- Model id: `claude-cli:<model-id>` (ID đầy đủ có version, ví dụ `claude-haiku-5-5`) hoặc `agy:<model>`. Alias `sonnet/opus/haiku` được ánh xạ sang ID đầy đủ trong `claude_code::normalize_model`, vì CLI tự phân giải alias sang bản cũ.
- Danh sách model `agy:` hoàn toàn động, không còn danh sách cố định: `scanner::agy_models()` chạy `agy models` (output `<id>\t<tên>`), cache 10 phút và làm mới nền; lỗi thì giữ danh sách cũ, thử lại sau 1 phút. Chưa lấy được thì danh sách rỗng. Snapshot gửi kèm `modelLabels` (id → nhãn từ `agy models`). Model Claude (`claude-cli:`) vẫn cố định trong `scanner::default_models`.
- Chọn model trên UI (`lib/models/model_grouping.dart`, `chat_canvas_view.dart::_buildModelSelector`): id được tách thành nhóm theo tên (ví dụ `agy:gemini-4-argon`) và mức ở cuối (`low/medium/high/xhigh/max`). Menu nhóm nằm cạnh menu mức. Chuyển nhóm giữ mức hiện tại nếu có, không thì lấy `medium`.
- **Model kèm mức của conversation** (`selectedModel`): server ghi `conversation_models` mỗi khi lượt bắt đầu (`TurnCtx::register`, lúc có init, cho cả Claude và agy), nên luôn là đúng model + effort của lượt gửi gần nhất. Trả về trong `ConversationSession.selected_model` (chi tiết, socket) và `SessionSummary.selected_model` (danh sách).
- Mở conversation (`dashboard_screen.dart::_syncDefaultSelections`): model vừa chọn trong phiên này → `selectedModel` của conversation (lịch sử) → model mặc định của provider. Conversation mới (`_isNewConversationMode`) không dùng lịch sử. Conversation cũ chưa có bản ghi thì fallback sang model gốc của lượt phản hồi gần nhất (`_modelFromHistory`, không có mức → mức mặc định của nhóm).
- Claude CLI được gọi với `--append-system-prompt` (ghi đường dẫn project) và `--add-dir <cwd>`.
- `AgentStep.model` lấy từ `message.model` của assistant (bỏ `<synthetic>`), dùng để hiển thị nhãn model dưới thẻ AI.
- Thứ tự chọn model khi mở conversation (`dashboard_screen.dart`, `_syncDefaultSelections`): model người dùng đã chọn trong phiên → `selectedModel` (lịch sử) → mặc định (`claude-cli:claude-sonnet-5-5` hoặc model đầu tiên cùng provider).
- `_activeSource` (dashboard) xác định provider: session trên server → `source` từ phản hồi chat → suy ra từ model đang chọn.

### 8.3. Đồng bộ realtime (dashboard)
- `_applySnapshot` giữ lại các stream đang chạy phía client mà snapshot chưa có (đặc biệt `pending_optimistic`), không ghi đè cả map.
- `_currentSessionStream` trả `pending_optimistic` khi chưa có `_selectedSessionId`.
- Listener `chatStream` chuyển sang cid thật khi stream đang chạy có id và đang ở new-conversation mode hoặc chưa chọn session.
- Snapshot cắt còn tối đa 100 step cho session Claude (`SNAPSHOT_STEP_LIMIT`). Cache dựng block của `ChatCanvasView` phải dựa trên chữ ký nội dung (số step, step cuối, `updatedAt`, `status`, `isRunning` của stream), không chỉ số lượng step.

### 8.4. Thay đổi file (`filesTouched`)
- Ghi nhận từ tool `Edit`/`Write`/`MultiEdit`/`NotebookEdit` (`record_side_effects`), `source` để trống.
- Thay đổi làm bằng `Bash` được suy ra bởi `detect_bash_file_changes`: `git status --porcelain` (cache 5 giây) và mtime nằm trong khoảng từ bước gọi Bash đến bước kế tiếp. Các bản ghi này có `source: "bash"`. Bỏ qua thư mục build/cache và file nhị phân (`is_build_or_binary_path`).
- Hạn chế: không có số dòng +/- cho thay đổi từ Bash; file lock (`Cargo.lock`, `pubspec.lock`) vẫn được tính.

### 8.5. Giao diện chat (`lib/ui/widgets/chat_canvas_view.dart`)
- Mỗi lượt là một thẻ AI (`aiTurnCard`) căn trái, bề rộng tối đa bằng bong bóng user (660 desktop, 320 mobile). Nhãn model nhỏ nằm ngoài thẻ, phía dưới bên trái.
- Trong thẻ: hàng nút tool action và chip "N tệp thay đổi" (`Row`), nội dung phản hồi có hiệu ứng gõ từng chữ (`_AiResponseTypewriter`, chỉ gõ phần nối thêm), thinking đang chạy (`_AnimatedThinkingRobotCard`) nằm trong thẻ khi `session.status == running`.
- Ô nhập (`_promptController`) lưu nháp theo conversation trong `_drafts` (khóa `_draftKey`: id conversation, hoặc `new:` + đường dẫn project khi soạn conversation mới). `didUpdateWidget` gọi `_switchDraft` khi đổi conversation: lưu nháp cũ, nạp nháp mới. Gửi tin thì nháp rỗng và không được giữ lại.
- Dialog: tool action (`_showToolActionsDialog`) và tệp thay đổi (`_showFilesChangedDialog`). Dòng file do Bash có ghi chú "sửa bởi Bash".
- Thinking card: không border, nền, padding; console ẩn mặc định (`_isTraceExpanded = false`).
- **Quota Claude Code CLI** (`server/src/claude/code.rs`, mục `LimitWindow`): hai nguồn gộp vào một danh sách cửa sổ theo khoá (`five_hour`, `seven_day`, `seven_day_sonnet`, `model:<tên>`):
  1. Sự kiện `rate_limit_event` trong stream-json của mỗi lượt chat (`chat/mod.rs` → `ingest_rate_limit_event`). Đọc `rate_limit_info.unifiedWindows`: `utilization` là **phân số 0–1**, `resetsAt` là **epoch giây**.
  2. Endpoint `https://api.anthropic.com/api/oauth/usage`: tối đa một lần mỗi 60 giây (`LIMITS_CACHE_TTL`). Khi bị rate limit thì backoff 5 phút (`USAGE_RATE_LIMIT_BACKOFF`). Trước đây server gọi mỗi 15 giây khi bị giới hạn nên không bao giờ thoát được. Phản hồi là `five_hour`/`seven_day`/`seven_day_sonnet`/`model_scoped` với `utilization` là **phần trăm** và `resets_at` là ISO. Định dạng cũ (`limits`) vẫn được đọc.
  - Cửa sổ có `resets_at` đã qua được coi là đã reset (0% dùng, không có thời điểm reset). Bản ghi mới hơn thay bản cũ theo từng cửa sổ.
  - `quotas:update` chỉ được phát khi số liệu đổi, nên mỗi kết nối socket mới được gửi quota hiện tại ngay (`socket/mod.rs`, `spawn_quotas_update(false, true)`). Trước đây client mới không thấy quota cho tới lần đổi kế tiếp.
  - Flutter hiển thị thời gian reset dưới mỗi bucket (`formatQuotaReset`, giờ địa phương, kèm thời gian còn lại).
- **Thanh % trên chat** (`_buildModelUsageMiddleBar`, cột "Tuần" và "5h"): dưới mỗi thanh có dòng `↻ 08:30` (cùng ngày) hoặc `↻ 20/11 13:00` (`formatQuotaResetCompact`), tooltip hiển thị đầy đủ kèm thời gian còn lại (`formatQuotaReset`). Không có thời điểm reset, hoặc đã reset, thì ẩn dòng này.
- **Cấu trúc module** (đã tách, không gộp lại một file):
  - Server: `scanner/` (catalog, types, system, running, watch, summary, quotas, meta_db, git_sync, projects, list, plans, detail, subagents, agy_turns, transcript, text), `claude/code/` (limits, status, cache, steps, file_changes, session_files, paths, extensions, cli, sessions, watch, transcript, lanes, side_effects), `chat/` (provider, state, turn, events, args, start, finish), `lsp/` (config, lang, discovery, status, client, util, pool, outline, navigation, tokens). `mod.rs` chỉ giữ hằng số, khai báo module và re-export. Hàm nội bộ dùng `pub(super)`, re-export bằng `pub use` hoặc `use` riêng tư tùy có item public hay không.
  - Flutter: `lib/features/chat/presentation/chat_canvas_view.dart` giữ widget `ChatCanvasView` và State (field, `initState`/`build`/`dispose`, helper nháp). Các method và widget khác nằm trong `canvas/*.dart` dạng `part of`: method của State đặt trong `extension` (`_CanvasExt*`), gọi `setState` qua `_applyState` (helper trong class vì `setState` là `@protected`). Static (`_formatTokensShort`, `_isTurnRunning`...) được gọi có tiền tố `_ChatCanvasViewState.`.
- Bảng quota (`lib/features/chat/presentation/quota_detail_sheet.dart`, mở từ thanh % của model): header cố định, danh sách nhóm nằm trong `ListView` cuộn được và không vượt 80% chiều cao màn hình. Mỗi bucket là một khối gọn (nhãn + %, thanh tiến trình, mô tả tối đa 2 dòng). Không đặt danh sách nhóm trong `Column` không cuộn, vì sẽ tràn trên điện thoại. Test: `test/quota_detail_sheet_test.dart` (viewport 360×640 và 320×568).
- Thẻ AI cuối lấy `streamingText` khi stream `isRunning`, không phụ thuộc `session.status` (`_buildAiTurnCard` trong `chat_canvas_view.dart`). Agy chỉ ghi transcript khi bước xong, nên status có thể chưa kịp là running. Agy CLI không phát nội dung suy nghĩ trong stream (chỉ có `thinking_tokens`), nên suy nghĩ của agy chỉ hiện sau khi bước hoàn tất.
- **Khoảng trống live text của agy là đúng theo giao thức**: đã đo bằng `agy -p ... --output-format=stream-json` có tool call. Sau bước tool xong, agy không gửi event nào trong khoảng 25–30 giây khi model đang suy nghĩ; `text_delta` chỉ xuất hiện khi bước trả lời bắt đầu (state `ACTIVE`, rồi `DONE`). Vì vậy trong lúc đó `streamingText` rỗng là bình thường, UI chỉ có dòng "đang xử lý". Đã kiểm chứng bằng `test/agy_live_text_test.dart`: khi stream có text, thẻ AI hiện text (cả khi session đang chạy, đã hoàn tất, hay chỉ có user step). Thử hub RPC `GetCascadeTrajectorySteps` trong lúc chạy không trả về dữ liệu (chưa tìm được hub đúng để đọc bước đang chạy), nên chưa có nguồn nào để hiện suy nghĩ live.
- `_AnimatedThinkingRobotIconState` (`thinking_widgets.dart`) phải `dispose()` `AnimationController`; thiếu thì Flutter báo lỗi Ticker khi unmount.
- Ghép văn bản agy (`chat/mod.rs::append_agy_text`): các `text_delta` của cùng một bước được nối liền; khi sang bước `agent_response` khác mà đoạn trước chưa kết thúc bằng khoảng trắng thì chèn `\n\n`, để phần nói trước/sau tool không dính chữ.
- Chữ ký cache khối chat (`currentStepsSignature`) phải gồm `streamingText.length`, `thinkingText.length`, `activeStepType` của stream. Khối `liveStreaming` (stream chưa gắn vào lượt) render stream hiện tại từ `widget.activeStream`, không dùng bản chụp trong block. Thiếu hai điều này thì văn bản đang stream không cập nhật khi transcript không đổi (đây là nguyên nhân thẻ agy hiện trống).

### 8.6. Nợ kỹ thuật đã biết
- **Phiên bản Flutter**: `Makefile` dùng SDK **3.47.7** (`~/flutter-3.47.7`, git worktree của tag `3.47.7` trong `~/flutter`), không dùng SDK 3.50 mặc định. Lý do: Flutter 3.50 trên Linux bị lỗi chỉ vẽ một phần cửa sổ (đen phần còn lại), đã kiểm chứng 3.47.7 hiển thị đúng; tham khảo [flutter/flutter#191245](https://github.com/flutter/flutter/issues/191245). Khi nâng cấp Flutter, kiểm tra lại lỗi này trước khi đổi.
- **Import Material**: dùng `package:material_ui/material_ui.dart` (dependency `material_ui: ^1.11.1`), không dùng `package:flutter/material.dart`. Flutter 3.50 đánh dấu import cũ là deprecated (`deprecated_member_use`); trộn hai import sẽ làm `ThemeData`/`ColorScheme` thành hai class khác nhau.
- Đã chuyển toàn bộ UI sang Material 3 theme động (`lib/ui/theme/app_theme.dart`): màu lấy từ `context.scheme` và `context.status`, không còn `Colors.<tên>` hay mã hex trong `lib/ui` (trừ bảng seed và màu bóng đổ). Khi thêm màu mới, dùng token; không hardcode.
- Màu chủ đạo (seed) chọn ở dashboard (nút palette) chỉ lưu trong bộ nhớ app. Lưu bền vững phụ thuộc quyết định phía client (mục 8.1).
- Không có test tự động cho UI. `test/widget_test.dart` là mặc định của Flutter.
- Lệnh `claude` trong `~/.local/bin/claude` có thể là symlink hỏng; server dự phòng bằng `claude` trong PATH (`claude_code::claude_bin`).
- Chưa có quy trình kiểm tra trực quan tự động. Sau khi sửa UI cần mở app để kiểm tra bố cục.

### 8.6b Cửa sổ context (context window)
- Session có `contextTokens` (token context đang dùng ở lượt gọi model gần nhất) và `contextModel` (model id của lượt đó). Snapshot có `modelContextLimits` (model id → giới hạn), lấy từ bảng `model_context_limits` trong SQLite.
- Nguồn agy, theo thứ tự ưu tiên (`server/src/context_window.rs`):
  1. RPC `GetCascadeTrajectoryGeneratorMetadata` của hub agy (`POST http://127.0.0.1:<httpPort>/exa.language_server_pb.LanguageServerService/...`, header `x-codeium-csrf-token`, lấy `httpPort`/`csrfToken` từ `~/.gemini/antigravity/daemon/hub_<port>.json` và kiểm tra pid còn sống). Dùng `chatModel.chatStartMetadata.contextWindowMetadata.estimatedTokensUsed` và `maxContextTokens` của lượt có bước lớn nhất. Token đi qua stdin của curl, không lộ trên dòng lệnh.
  2. Bảng `conversation_context` trong SQLite: kết quả RPC lần trước. Dùng khi hub không gọi được.
  3. `gen_metadata` trong `conversations/<cid>.db` (protobuf không có schema, `1.9.10.1` = token, `1.9.10.4` = giới hạn). Chỉ dùng cho conversation chưa từng đọc được qua RPC.
- Snapshot không chờ RPC. Conversation có `updated_at` mới hơn bản ghi DB được xếp vào hàng đợi, worker nền gọi RPC (timeout 120s, response có thể ~12MB) rồi ghi DB. Lỗi thì backoff 30s.
- `maxContextTokens` của agy là giá trị cấu hình, không phải cửa sổ thật: có session vượt 256000 mà estimate vẫn tăng. Chưa dùng làm giới hạn hiển thị cuối cùng.
- Nguồn Claude: `input_tokens + cache_creation_input_tokens + cache_read_input_tokens` của message assistant gần nhất (`claude_code.rs`). Giới hạn `claude-cli:*` được seed 1M (tài liệu Anthropic: Opus/Sonnet/Haiku 5.5 đều 1M), `INSERT OR IGNORE` nên không ghi đè giá trị đã sửa.
- Nguồn `source`: `agy-gen-metadata` (quét ghi đè), `seed`, `manual`. Bản `manual` không bị quét ghi đè. Sửa tay: `POST /api/model/context-limit` với body `{model, limit}`.
- UI: chip `used / limit` cạnh menu model trong `chat_canvas_view.dart::_buildContextChip`. Giới hạn lấy theo model đang chọn, rồi tới model của lượt gần nhất. Màu chuyển cảnh báo từ 70%, lỗi từ 90%.

### 8.6c Tự gửi lại khi rate limit (`server/src/rate_retry.rs`)
- Lượt chat kết thúc với lỗi khớp `is_rate_limit_error` (`usage limit`, `hit your limit`, `429`, `rate limit`, `resource_exhausted`, `quota`, `overloaded`, `model_capacity_exhausted`...) thì được xếp lịch gửi lại với cùng prompt, cùng conversation và model.
- Thời điểm gửi lại: đọc `retry in 90s`, `retry-after: 120` hoặc epoch reset (10 chữ số) trong thông điệp. Không có thì mặc định 5 phút. Kết quả giới hạn trong [15s, 6h]. Tối đa 8 lần tự gửi lại (`MAX_ATTEMPTS`).
- Lịch lưu trong bộ nhớ (`RETRIES`), không ghi DB. Server khởi động lại thì mất lịch.
- Gửi tin nhắn tay vào cùng conversation sẽ hủy lịch đang chờ (`start_chat_turn_attempt` với `attempt == 0`).
- Event `retry:update` gửi toàn bộ danh sách khi client kết nối và mỗi lần thay đổi. Hủy: `POST /api/chat/retry/cancel` với body `{conversationId}`.
- UI: popup đếm ngược (`RetryPopup`) bật một lần cho mỗi lần thử, tự đóng khi lịch biến mất. Banner trong conversation (`RetryBanner`, trong `_buildBottomDockStack`) hiện đếm ngược và nút Hủy. Model Dart: `PendingRetry`.
- Chưa kiểm chứng trên lỗi thật: chuỗi lỗi lấy từ binary của Claude CLI và agy, chưa gặp event rate limit thực tế. Khi gặp lần đầu, ghi lại thông điệp gốc và kiểm tra `is_rate_limit_error` có khớp không.

### 8.6c Tự gửi lại khi rate limit
- Lượt chat kết thúc với lỗi khớp `rate_retry::is_rate_limit_error` (`Usage limit reached`, `429`, `RESOURCE_EXHAUSTED`, `quota`, `overloaded`, `MODEL_CAPACITY_EXHAUSTED`...) thì `finish_turn` xếp lịch gửi lại cùng prompt và conversation (`server/src/rate_retry.rs`).
- Thời điểm gửi lại: đọc `retry in Ns` / `retry-after` / epoch reset trong thông điệp, giới hạn 15s..6h; không đọc được thì 5 phút. Tối đa 8 lần (`MAX_ATTEMPTS`).
- Lịch chỉ được xếp khi đã có conversation id. Gửi tay cho cùng conversation sẽ hủy lịch đang chờ. Hủy bằng `POST /api/chat/retry/cancel` `{conversationId}`.
- Socket `retry:update` gửi danh sách đầy đủ khi kết nối và mỗi lần thay đổi. Flutter: `PendingRetry` (models), `BrainScannerService.retryUpdateStream`, popup `RetryPopup` và banner `RetryBanner` (`lib/ui/widgets/rate_retry_widgets.dart`). Popup bật một lần cho mỗi lần thử; banner nằm trong dock của conversation đang mở.
- **Chưa kiểm chứng trên lỗi thật**: pattern lấy từ chuỗi trong binary của Claude CLI và agy, chưa có event rate limit thật để đối chiếu. Khi gặp lỗi thật, ghi lại thông điệp gốc và điều chỉnh pattern.

### 8.6d `/compact` của agy
- Lệnh `/compact` được agy mở rộng thành một slash command hệ thống và model phải gọi function. Lỗi thường gặp: `Malformed function call: Function call is empty`, sau 3 lần thử lại CLI kết thúc với lỗi, dù bước nén đã ghi `CHECKPOINT` vào transcript.
- `chat.rs::finish_turn`: nếu lượt `/compact` lỗi nhưng transcript (`brain/<cid>/.system_generated/logs/transcript.jsonl`, đọc 4MB cuối) có `CHECKPOINT` sau lệnh compact, lượt được coi là thành công và thêm ghi chú "Đã nén ngữ cảnh".
- stderr được gom đủ 20 dòng cuối (trước đây chỉ giữ dòng cuối, thường là `Retries remaining: 3`). Lỗi `Malformed function call` được đổi sang câu tiếng Việt.

### 8.6e Máy SSH đã lưu (`server/src/ssh_hosts.rs`, `lib/ui/ssh_hosts_screen.dart`)
- Nút "SSH" nằm ngay trên ô search trong sidebar, mở `SshHostsScreen`. Lưu nhiều máy: tên, host, port, username, và xác thực bằng mật khẩu hoặc SSH key.
- Bảng SQLite `ssh_hosts`. File DB được đặt quyền `0600` khi mở (`store::restrict_file_permissions`). **Mật khẩu và private key đang lưu dạng plaintext trong DB**, chưa mã hóa.
- API: `GET /api/ssh/hosts` (không trả bí mật, chỉ có `hasPassword`/`hasKey`), `POST /api/ssh/hosts/save` (để trống bí mật = giữ nguyên; đổi kiểu xác thực thì xóa bí mật của kiểu cũ), `POST /api/ssh/hosts/delete`, `POST /api/ssh/exec` `{hostId, command, timeoutSecs}`.
- Lệnh chạy bằng binary `ssh` của hệ thống (không có russh). Mật khẩu đưa qua biến môi trường cho script `SSH_ASKPASS` trong thư mục tạm 0700. Key ghi vào file tạm 0600 rồi xóa. `StrictHostKeyChecking=accept-new`.
- Chạy lệnh một lần (`exec`) và **terminal tương tác** (`server/src/ssh_terminal.rs`): `ssh -tt` gắn vào PTY (`openpty`, `setsid` + `TIOCSCTTY` trong `pre_exec`). Thread đọc master đẩy `ssh:data` (base64) tới room `ssh:<sessionId>`; socket mở phiên được join room trước khi PTY chạy. Sự kiện socket: `ssh:open` (ack `{ok, sessionId, error}`), `ssh:input`, `ssh:resize`, `ssh:close`; server phát `ssh:data`, `ssh:closed`. Tối đa 8 phiên.
- **Phiên tồn tại độc lập với client.** Server giữ bộ đệm đầu ra 256KB (`SCROLLBACK_BYTES`). Sự kiện mới: `ssh:list` (ack: danh sách phiên đang chạy `{sessionId, hostId, hostName, startedAt}`), `ssh:attach` `{sessionId}` (join room, ack `{ok, sessionId, hostName, buffer (base64), error}`). Phiên không được dùng (input/attach) quá 6 giờ (`IDLE_TIMEOUT`) thì tự đóng, task dọn chạy mỗi 10 phút.
- Flutter: thoát màn hình terminal chỉ **tách** (không gửi `ssh:close`); chỉ nút "Kết thúc phiên" mới đóng. **Nhiều máy chia sẻ cùng một phiên**: chạm vào máy có phiên đang chạy (trên server) sẽ gắn vào phiên đó (danh sách phiên tải lại ngay trước khi quyết định); nhấn giữ máy để mở phiên mới riêng. Server phát đầu ra cho mọi socket trong room `ssh:<sessionId>`, đã kiểm chứng với hai client.
- **Shell của máy đích**: cả terminal và "Chạy lệnh" đều chạy `"$SHELL" -i` (không phải shell đăng nhập). Lý do: máy user có `~/.bash_profile` nên shell đăng nhập không đọc `~/.bashrc`, PATH (flutter, go, android...) bị thiếu. Lệnh exec được bọc `"$SHELL" -i -c '<lệnh>'` (`ssh_hosts::remote_interactive_command`). Đã kiểm chứng: `command -v flutter` ra `/home/john/flutter/bin/flutter` ở cả hai đường.
- Flutter: `SshTerminalScreen` dùng package `xterm` (4.0.0). Dữ liệu đến trước khi có `sessionId` được đệm; UTF-8 bị cắt giữa chunk được ghép lại (`_completeUtf8Length`).
- Đã kiểm chứng: đường đi lỗi (sai mật khẩu / key) trả về `ok=false` kèm stderr `Permission denied` qua `ssh` thật tới `localhost`. Vòng đời PTY (mở, ghi phím, đổi size, ssh thoát, dọn phiên và thư mục tạm), `list`/`attach` và phiên sống độc lập đã test với `ssh` thật. Chưa kiểm chứng đăng nhập thành công vì không có credential hợp lệ. Chưa kiểm chứng end-to-end qua socket từ app.

### 8.6f Quản lý Docker qua SSH (`server/src/docker_sessions.rs`, `lib/ui/docker_screen.dart`)
- Nút "Docker" nằm cạnh nút "SSH" trong sidebar (`Wrap` trong `dashboard_screen.dart`), mở `DockerHostsScreen` (danh sách máy SSH đã lưu). Chạm vào máy: mở phiên Docker của máy đó rồi vào `DockerSessionScreen`.
- **Phiên Docker tách biệt với phiên terminal SSH.** Mỗi máy có tối đa một phiên, là một kết nối `ssh -MNf` (ControlMaster) giữ socket trong thư mục tạm 0700 `muop-docker-<id>`. Mở lại máy đã có phiên thì gắn vào phiên đó (đồng bộ giữa các app, giống SSH). Đóng màn hình **không** ngắt phiên; chỉ "Kết thúc phiên" (`POST /api/docker/sessions/close`) mới đóng, lần mở sau kết nối lại.
- Kết nối rớt thì tự kết nối lại: mỗi lần chạy lệnh kiểm tra `ssh -O check`, nếu lệnh lỗi giữa chừng và socket đã chết thì kết nối lại và chạy lại một lần. Idle `IDLE_TIMEOUT` 6 giờ. Khi server khởi động, `cleanup_stale()` thoát các master còn sót và xóa thư mục tạm.
- API: `GET /api/docker/sessions`, `POST /api/docker/sessions/open` `{hostId}`, `POST /api/docker/sessions/scan` `{sessionId}`, `POST /api/docker/sessions/action` `{sessionId, action: stop|restart, containerIds[]}`, `POST /api/docker/sessions/close` `{sessionId}`. Phản hồi `{ok, error, session}`; `404` nghĩa là phiên đã kết thúc (Flutter hiện nút "Mở phiên mới").
- Chỉ liệt kê container **đang chạy** (`docker ps --no-trunc --format '{{json .}}'`), nhóm theo label `com.docker.compose.project`. Stop/restart nhận danh sách ID (chỉ chấp nhận hex 12–64 ký tự); "cả component" = gửi mọi container của project. Màn hình tự quét lại mỗi 10 giây.
- Lệnh docker chạy qua `$SHELL -i -c` như lệnh SSH (PATH đầy đủ). Lỗi thường gặp được dịch: không có quyền docker, thiếu lệnh docker, daemon không chạy.
- Đã kiểm chứng với `sshd` thử nghiệm (key) và máy đã lưu dùng mật khẩu (`SSH_ASKPASS`): xem log qua socket (dòng log thật từ container, đóng luồng, tự dừng khi client mất ping 30s), mở, gắn lại phiên, tự kết nối lại khi master bị kill, stop/restart (kiểm tra `StartedAt`), kết thúc phiên dọn master và thư mục tạm, dọn master mồ côi khi khởi động lại server, từ chối ID/action không hợp lệ.
- **Xem log container** (`server/src/docker_logs.rs`, nút "Xem logs" trên mỗi container): mở một kênh SSH riêng (`docker logs -f --timestamps --tail N <id> 2>&1`) trên kết nối ControlMaster của phiên. Socket: `docker:logs:open` `{sessionId, containerId, tail}` (ack `{ok, streamId, error}`, socket join room `docker-logs:<streamId>` trước), server phát `docker:logs:data` `{streamId, lines[]}` (gom theo lô 150ms/80 dòng) và `docker:logs:end` `{streamId, exitCode}`. Client gửi `docker:logs:ping` mỗi 10 giây; quá 30 giây không ping (app thoát, mất mạng) thì server dừng và đóng kênh SSH. `docker:logs:close` dừng ngay khi thoát màn hình log. Tối đa 16 luồng.
- **Bố cục desktop**: màn SSH / Docker / log mở trong vùng chính bên phải, sidebar ghim bên trái giữ nguyên; khi panel mở, cây explorer bị ẩn để trang chiếm hết phần bên phải. Dashboard bọc layout desktop bằng `PanelScope` (`lib/ui/widgets/desktop_panel.dart`) và đặt một `Navigator` khai báo (`pages`, key `_panelNavKey`) trong vùng chính; trang gốc là `dashboard-main` (key `desktop-main` giữ cố định để Navigator không bị dựng lại), các trang panel xếp lên trên (`_panelPages`).
- Mở trang: từ sidebar dashboard dùng `_openFromSidebar(context, page)` (desktop ≥760px → `_openPanel`; mobile → push). Lý do không dùng `openPanelPage` ở đây: context của `State` nằm phía trên `PanelScope`, lookup scope sẽ thất bại. Màn con trong panel dùng `openPanelPage(context, page)` vì context của chúng nằm dưới scope; mobile không có scope nên push full-screen.
- Đóng về màn chính: bấm conversation, conversation mới, hoặc item sidebar gọi `_closePanelPages()`, hàm này `popUntil(isFirst)` qua Navigator. Trang được gỡ khỏi `_panelPages` trong `_onPanelRemovePage` (`onDidRemovePage`). Đừng gỡ danh sách rồi chờ Navigator tự pop: Navigator không gỡ route trong trường hợp này.
- Đã kiểm chứng bố cục bằng widget test tạm (đã xóa, không commit): panel chiếm `x 281→1600`, explorer ẩn, AppBar của trang ở đỉnh vùng chính, New Conversation đóng panel và trả explorer, nút Back đóng panel.
- Chưa làm: không có sự kiện socket đẩy realtime cho danh sách container (đồng bộ bằng REST + tự quét 10 giây); không có chế độ hiện container đã dừng; không có sudo cho máy chưa cấp quyền docker.

### 8.6g Language server (LSP) cho Go / Dart / Rust (`server/src/lsp.rs`, `lib/ui/lsp_settings_screen.dart`)
- Server chạy tiến trình LSP theo (ngôn ngữ, thư mục gốc project): `gopls serve`, `dart language-server --protocol=lsp`, `rust-analyzer`. Thư mục gốc là thư mục gần nhất chứa `go.mod` / `pubspec.yaml` / `Cargo.toml`. Giao tiếp JSON-RPC qua stdin/stdout, `kill_on_drop`. Tối đa 6 tiến trình (dừng cái ít dùng nhất), không dùng 20 phút thì dừng (`reap_idle`, chạy trong vòng 10 phút của main).
- **Đường dẫn tệp thực thi**: ưu tiên đường dẫn người dùng lưu trong bảng SQLite `lsp_settings` (`store::get/set/delete_lsp_path`), rồi tới tự dò (PATH, `~/go/bin`, `$GOPATH/bin`, `~/flutter/bin/dart`, `~/.cargo/bin`, extension VSCode `rust-lang.rust-analyzer-*`). Mọi ứng viên phải **chạy thử** (`gopls version`, `--version`) và kết quả được cache 5 phút (`lsp::runs`). Lý do: `~/.cargo/bin/rust-analyzer` là proxy rustup có thể tồn tại nhưng báo "Unknown binary" khi toolchain không có component.
- API: `GET /api/lsp/settings` → `{languages:[{language,label,configuredPath,detectedPath,effectivePath,source: config|auto|none,available,note}]}`; `POST /api/lsp/settings` `{language, path}` (path rỗng = xóa cấu hình; path phải chạy thử được). `GET /api/code/fold?path=`, `GET /api/code/symbols?path=` (dòng đếm từ 0), `POST /api/code/definition` `{path, line, character}`. Lỗi trả `{ok:false, error}` với HTTP 200 để client hiển thị.
- Kết quả rỗng từ LSP (thường khi vừa khởi động) được thử lại tối đa 4 lần, cách 1 giây (`request_until_ready`). Lần đầu gọi có thể mất 10–20 giây vì LSP đang khởi động và index.
- Flutter: `lib/models/code_models.dart`; service `fetchCodeFold`, `fetchCodeSymbols`, `fetchCodeDefinition`, `fetchLspSettings`, `saveLspSetting`. Nút **LSP** cạnh SSH/Docker mở `LspSettingsScreen` (nhập đường dẫn, lưu, xóa cấu hình, xem đường dẫn đang dùng).
- Viewer (`FileDiffAndContentPane`, chỉ tệp `.go` `.dart` `.rs`): chevron ở lề để gấp/mở, dòng gấp có `⋯ N dòng`; nút "Danh sách hàm", "Gấp/Mở tất cả", "Quay lại"; Ctrl+click (desktop) hoặc chạm (mobile, không có Ctrl) vào một từ để tới định nghĩa. Cùng file thì nhảy tại chỗ; khác file thì pane tự mở file đó và lưu vị trí cũ vào `_navStack`. Nhiều định nghĩa thì hiện hộp chọn. Chưa có LSP thì snackbar có nút "Cài đặt LSP".
- **Tô màu cú pháp**: `GET /api/code/tokens?path=` trả semantic tokens của LSP (`kinds` + `data` gồm bộ 4 số `[dòng, cột, độ dài, chỉ số loại]`). Client đổ vào `_tokensByLine` và tô màu bằng `colorScheme` / `context.status` (`_kindStyle`). Gopls chỉ gửi token khi client khai báo `STANDARD_TOKEN_TYPES` và bật `initializationOptions.semanticTokens` (xem `spawn_client`). Chưa có LSP thì không có màu (chỉ có chữ thường).
- **Hover**: `POST /api/code/hover` → nội dung markdown của LSP. Client chờ ~350ms khi chuột dừng trên một từ (`TextSpan.onEnter`/`onExit`), rồi hiện `_HoverCard` qua `Overlay`. Cache theo `tệp:dòng:cột`.
- **Tham chiếu**: `POST /api/code/references` (kể cả khai báo). **Alt+click** vào từ để mở danh sách; một kết quả thì nhảy tới luôn.
- Trong 60 giây đầu sau khi tiến trình LSP khởi động, hover/references rỗng được thử lại tối đa 4 lần (rust-analyzer còn đang index).
- **Chưa làm**: hover và Alt+click chưa kiểm chứng bằng thao tác chuột thật (đã kiểm chứng: token và màu bằng widget test; hover/references qua API bằng daemon thật). Trên mobile không có hover và Alt, chỉ chạm để tới định nghĩa; tham chiếu trên mobile chưa có. Chỉ một tiến trình LSP cho mỗi project.

### 8.6h System tray của server (`server/src/tray.rs`)
- Icon khay hệ thống dùng `ksni` (StatusNotifierItem). Server khởi động lúc boot thường đi **trước** phiên GNOME, nên watcher `org.kde.StatusNotifierWatcher` chưa có. Dùng `assume_sni_available(true)`: ksni giữ service và tự đăng ký lại khi watcher xuất hiện. Handle được giữ sống trong task (nếu bị drop, service dừng). Lỗi D-Bus thật thì thử lại mãi, backoff tới 30 giây.
- Đã kiểm chứng: server khởi động trước watcher giả trên session bus riêng, watcher xuất hiện sau 12 giây thì server đăng ký item (`RegisterStatusNotifierItem`). Trên máy thật, item `muop-agent-serv` hiện trong session bus sau khi restart daemon.
- Lịch sử lỗi: bản cũ thử 60 lần × 5 giây rồi bỏ cuộc, nên sau khi đăng nhập không có icon. Unit systemd (`service/muop-agent-server.service`) có `After=graphical-session.target`.

### 8.6i Nhận lại lượt chat sau khi server khởi động lại (`server/src/chat/recovery.rs`)
- `active_streams` và `running_pids` chỉ nằm trong bộ nhớ. Khi restart, server quét `/proc` tìm tiến trình `agy --conversation <cid>` và `claude ... --resume <cid>` (bỏ qua wrapper `systemd-run` và phiên của extension VSCode), đưa lại vào `active_streams` với `activeStepType: "recovered"` và `running_pids` để nút dừng vẫn hoạt động. Lượt được ghi trong `adopted_turns`.
- Watcher (mỗi 1.5 giây) kiểm tra từng lượt nhận lại. Khi tiến trình kết thúc (hoặc pid bị tái sử dụng bởi tiến trình khác), gỡ stream đang chạy và phát lại session update.
- Bảng SQLite `running_turns (conversation_id, provider, pid, start_ticks, cwd, started_at)`: ghi khi có init (`TurnCtx::register`), xóa khi lượt kết thúc. `start_ticks` là trường `starttime` của `/proc/<pid>/stat`, dùng để nhận diện đúng tiến trình (tránh pid bị tái sử dụng). Nhờ bảng này, lượt đầu tiên của conversation mới (argv không có `--conversation`/`--resume`) cũng được nhận lại. Quét argv chỉ còn là phương án dự phòng.
- **Lượt agy bị cắt** (`cut_short_turns`): khi khởi động, bản ghi `running_turns` của agy mà tiến trình đã chết được chuyển thành dấu "bị cắt". Scanner (`agy_turn_cut_short`) chỉ hiện `interrupted` khi dấu này còn và bước cuối transcript chưa phải `PLANNER_RESPONSE`. Agy chạy xong khi server tắt thì transcript có phản hồi nên vẫn `completed`. Lượt mới trên conversation đó sẽ xóa dấu này (`TurnCtx::register`).
- **Dừng chủ động** (`stop_chat_turn`) xóa bản ghi `running_turns`, nên lượt đã dừng không được nhận lại và không bị đánh dấu bị cắt. Lượt dừng giữ phần trả lời dở và session hiện `completed` (chưa có trạng thái riêng cho "đã dừng" trong transcript).
- **Chi tiết session phải truyền stream hiện tại**: `GET /api/session` (`api/sessions.rs`) dùng `get_single_session_with_streams` với `active_streams`. Trước đó dùng bản đồ rỗng nên lượt agy/claude đang chạy bị hiện là gián đoạn khi mở conversation.
- **Giới hạn**: văn bản đang stream dở không khôi phục được (stdout của lượt cũ đã mất); session vẫn hiện đầy đủ từ transcript.
- Đã kiểm chứng: unit test parse argv; test tích hợp với tiến trình giả lập argv agy (nhận lại, rồi đóng khi thoát); restart daemon thật nhận lại `fake-recovery-cid`, kết thúc tiến trình thì stream được gỡ. - Đã kiểm chứng với `claude` thật (haiku-5-5-low): server bị `kill -9` giữa lượt, tiến trình `claude` vẫn sống, server mới nhận lại đúng PID, stream đóng khi tiến trình kết thúc, transcript đầy đủ phản hồi.

### 8.6j Trạng thái lượt Claude chưa xong (`server/src/claude/code.rs`)
- Bản ghi hội thoại cuối là prompt/tool_result, hoặc assistant có `stop_reason: tool_use` → lượt chưa xong (`UNFINISHED_STATUS`, chỉ tồn tại trong parser và cache, không gửi ra client). Output lệnh slash (`<local-command…>`) không tính.
- `apply_live_status_at` (không cache): có stream đang chạy → `running`. Lượt chưa xong của conversation do server này chạy (bảng `claude_muop_conversations`, ghi ở `system/init`) mà không còn stream → `interrupted` kèm lý do. Lượt chưa xong của phiên tương tác (terminal/VSCode) → giữ `completed`, vì không biết tiến trình còn chạy hay không.
- Không dùng ngưỡng thời gian ghi file: một lệnh chạy lâu hoặc model đang sinh có thể im hơn 20 giây khi vẫn đang chạy. Lượt do muop chạy đã có stream nên không cần đoán.
- Hạn chế: lượt muop trước khi có bảng này không có trong tập, nên không được gắn `interrupted`.
- Đã kiểm chứng: kill server + tiến trình con giữa lượt → `interrupted` đúng; các session tương tác vẫn `completed` (40/40 sau khi sửa).

### 8.6k Ảnh đính kèm trong chat (`server/src/chat/attachments.rs`)
- Client gửi ảnh base64 trong `images: [{name, mimeType, dataBase64}]` của `POST /api/chat/send` (đi qua REST, không qua socket). Tối đa 6 ảnh, mỗi ảnh tối đa 20MB trước khi thu nhỏ. Body REST và gói socket được nâng lên 64MB (`MAX_REQUEST_BODY_BYTES` trong `main.rs`); mặc định của axum (2MB) và socket.io (100KB) đều quá nhỏ cho ảnh.
- Server nhận diện định dạng từ nội dung thật (PNG/JPEG/WebP), thu nhỏ cạnh dài về 1568px và chuyển WebP hoặc ảnh có alpha sang PNG/JPEG, rồi lưu vào `~/.local/share/muop-agent/uploads/`. Việc xử lý ảnh chạy trong `spawn_blocking`.
- **Claude CLI**: `claude -p --input-format stream-json` và ghi một dòng JSON có block `image` (base64) rồi đóng stdin. Đã kiểm chứng: model thấy đúng ảnh và `--resume` vẫn giữ ngữ cảnh. Khi không có ảnh, giữ nguyên đường `-p <prompt>`.
- **agy**: không có cờ ảnh (đã kiểm tra `agy --help`). Prompt được thêm khối `[Ảnh đính kèm]` liệt kê đường dẫn file, agent mở bằng tool `read_file`. Đã kiểm chứng: model trả lời đúng màu của ảnh. Scanner tách khối này khỏi nội dung hiển thị (`split_agy_attachments`) và đếm vào `imageCount`.
- Chỉ có ảnh, không có chữ: server dùng câu mặc định "Hãy mô tả các ảnh đính kèm." để lượt chat có nội dung trong lịch sử.
- `AgentStep.imageCount` và `AgentStep.imageUrls` (bước `USER_INPUT`) để bong bóng user hiện thumbnail khi mở lại conversation (bấm để xem lớn). Lấy ảnh qua `GET /api/chat/attachment`: agy dùng `?path=<file>` (chỉ đọc trong thư mục uploads); Claude dùng `?cid=<session>&uuid=<dòng user>&i=<n>` và đọc lại block base64 từ transcript. Không có `imageUrls` (lịch sử cũ) thì bong bóng chỉ hiện "N ảnh đính kèm". `ChatCanvasView.serverBaseUrl` cung cấp địa chỉ server để tải ảnh.
- Flutter: `file_picker` (13.x) chọn ảnh ở composer; ảnh chờ gửi lưu theo nháp của từng conversation (`_draftImages`). Gửi thất bại thì ảnh chờ đã bị xóa khỏi composer, giống cách xử lý với chữ.
- **Test API**: `python3 server/scripts/test_chat_images.py [--only claude|agy]` (cần server đang chạy và Pillow). Mỗi lượt là lượt chat thật, tốn quota model nhỏ. Mặc định dùng `claude-haiku-5-5` và `agy:gemini-4-hydrogen-low`.
- Lưu ý khi test agy: model `gemini-4-argon-low` đã hết quota (reset sau ~131h), lượt chat thất bại và `rate_retry` xếp lịch tự gửi lại. Hủy bằng `POST /api/chat/retry/cancel`. Chọn model khác khi cần test.

### 8.7. Skill liên quan
- `.claude/skills/design/SKILL.md`: quyết định thiết kế và vấn đề đã gặp của app này.
- `.claude/skills/design-uiux/SKILL.md`: nguyên tắc UI/UX khi chỉnh sửa giao diện Flutter.

### 8.8. Build IPA trên Mac (TrollStore)
- Khi APK Release build xong, Agent copy project sang Mac và build file IPA để người dùng cài bằng TrollStore.
- **Chỉ làm khi SSH tới Mac được.** Kiểm tra SSH trước bước đầu tiên. Nếu SSH không được, bỏ qua bước IPA và nêu rõ trong báo cáo cuối.
- Mac: `johndylan@192.168.31.206`, thư mục đích `/Volumes/Untitled/muop-agent`. Mật khẩu KHÔNG ghi trong repo; xem memory `mac-build-host` (cục bộ, ngoài repo).
- **Đọc `/home/john/Documents/muop-ecosystem/config/ssh-key/README.md` trước khi SSH.** Có key riêng `config/ssh-key/muop_build_ed25519` để đăng nhập không cần mật khẩu (`ssh -i <key> -o IdentitiesOnly=yes -o BatchMode=yes`). Chỉ khi key chưa được cài lên Mac thì dùng `SSH_ASKPASS` (mục 4 trong README). Không có `sshpass`. Script `SSH_ASKPASS` đặt trong thư mục tạm riêng (ngoài repo), xóa ngay sau khi xong.
- Quy trình:
  1. `make build-apk` ở máy Linux để chắc APK là bản mới nhất.
  2. `rsync -az --exclude='.git/' --exclude='build/' --exclude='.dart_tool/' --exclude='server/target/' --exclude='.idea/' --exclude='.vscode/' --exclude='*.ipa'` từ thư mục gốc project tới `/Volumes/Untitled/muop-agent/`. Không dùng `--delete`, vì thư mục đích có `ios/` và `.git/` không có trong repo này.
  3. Trên Mac, PATH phải có `$HOME/flutter/bin`. Flutter trên Mac được ghim tag `3.47.7` (cùng bản với Linux). Chạy `flutter pub get`, rồi `flutter build ios --release --no-codesign`.
  4. Ký ad-hoc `codesign --force --deep --sign - build/ios/iphoneos/Runner.app`, rồi đóng gói `Payload/Runner.app` thành `muop-agent-trollstore.ipa` trong `/Volumes/Untitled/muop-agent/`. File IPA cũ được đổi tên thành `muop-agent-trollstore.prev.ipa`.
  5. **Dọn rác trên Mac (bắt buộc sau mỗi lần build):** `rm -rf build .dart_tool` trong `/Volumes/Untitled/muop-agent`, và xóa thư mục tạm `Payload`/`ipa-stage` nếu còn. Giữ lại `muop-agent-trollstore.ipa`, `muop-agent-trollstore.prev.ipa` và `muop-agent-release.apk`.
  6. **Copy IPA về root project (bắt buộc sau khi build IPA thành công):** `scp johndylan@192.168.31.206:/Volumes/Untitled/muop-agent/muop-agent-trollstore.ipa ./muop-agent-trollstore.ipa` từ thư mục gốc project trên máy Linux (cùng cách dùng `SSH_ASKPASS` như trên). Kiểm tra kích thước khớp với file trên Mac (`stat -f %z` trên Mac, `stat -c %s` trên Linux). File này nằm trong `.gitignore` (`*.ipa`) nên không commit.
- Trạng thái: bundle `com.muop.muopAgent`. Build IPA đã chạy được; chưa kiểm chứng cài bằng TrollStore trên thiết bị. Lưu ý `flutter pub get` trên Mac có thể ghi lại `analysis_options.yaml` và `pubspec.lock` của bản copy đó.
