# HƯỚNG DẪN DÀNH CHO AI AGENT (AGENTS.md)
# DỰ ÁN: MƯỚP AGENT MONITOR (`muop-agent`)

> Tài liệu này được thiết kế dành riêng cho các AI Coding Agent (và nhà phát triển phần mềm) khi tiếp cận, phát triển, bảo trì và mở rộng mã nguồn trong kho lưu trữ **`muop-agent`**.

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
     - Nếu `hasMore == false`, hiển thị thông báo "Đầu cuộc hội thoại (Đã nạp toàn bộ lịch sử)".

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
