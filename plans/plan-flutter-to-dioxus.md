# Plan: Chuyển App Flutter Sang Dioxus

> Trạng thái: **Đã chốt, đang triển khai (2026-11-27).** Slint đã xóa; Flutter giữ nguyên; Dioxus ở `app/`, Linux trước. Tiến độ: `app/README.md`.
> Phạm vi: client Flutter ở root repo (`lib/`, `test/`, `android/`, `ios/`, `linux/`, `macos/`, `pubspec.yaml`).
> Không đụng `server/` (Rust) và không đụng `app/` (Slint, theo AGENTS.md mục 0).

---

## 1. Kết luận ngắn

- **Chưa xóa gì ở bước này.** Ba lý do:
  1. "Folder app" chưa rõ. `app/` là client **Slint** (`app/Cargo.toml`, `app/ui/`), không phải Flutter. Flutter nằm rải ở root. AGENTS.md mục 0 cấm sửa `app/` nếu người dùng không yêu cầu rõ.
  2. Có 61 file đang modified/untracked chưa commit (`git status`). Xóa bây giờ sẽ mất các thay đổi đó, và Flutter cũ không còn để đối chiếu khi port.
  3. Máy hiện chưa có `cargo`, `rustc`, `dx` (Dioxus CLI) và `flutter` trên PATH. Makefile dùng Flutter ở `~/flutter`.
- **Đề xuất:** Tạo Dioxus song song ở thư mục mới `app/`. Giữ Flutter chạy được cho tới khi Dioxus đạt parity trên Linux desktop. Sau đó mới xóa Flutter ở root trong một commit riêng.

---

## 2. Hiện trạng Flutter (đo được)

- `lib/`: **138 file Dart, ~42.7k dòng**. `test/`: 40 file.
- 28 thư mục feature trong `lib/features/` (chat, dashboard, agent_map, agy_auth, claude_auth, bridge, docker, ssh, sftp, lsp, setup, screen, quota, explore, settings, sessions, projects, interactions, server_files, connection, accounts_common...).
- Phụ thuộc và mức độ khó khi port:

| Package | Số file dùng | Thay bằng (Dioxus) | Độ khó |
| :--- | :--- | :--- | :--- |
| `material_ui` | 52 | Bộ widget tự viết bằng CSS (button, sheet, list, chip, dialog, menu) | Cao (khối lượng lớn) |
| `flutter_riverpod` | 18 | Signals / context của Dioxus | Trung bình |
| `liquid_glass_easy` | 4 | CSS `backdrop-filter` + viền hairline | Trung bình (không 1:1) |
| `media_kit` | — (đã bỏ; màn hình dùng khung JPEG qua HTTP) | không cần | — |
| `xterm` | 2 (SSH terminal) | xterm.js trong webview | Cao |
| `file_picker` | 2 | `rfd` hoặc API dialog của Dioxus | Thấp |
| `socket_io_client` | 1 | Socket.IO client Rust (xem mục 3) | Trung bình |
| `url_launcher` | 3 | Mở trình duyệt hệ thống | Thấp |

---

## 3. Kiến trúc đích

- **Framework:** Dioxus. Desktop chạy bằng webview (WebKitGTK trên Linux). Có thể mở rộng sang web/mobile.
- **Giữ nguyên nguyên tắc Pure UI Client** (AGENTS.md mục 4.1): không đọc filesystem, không chạy shell. Mọi dữ liệu đi qua REST và Socket.IO tới `muop-agent-server` ở `:8787`.
- **Tái sử dụng DTO của server:** `server/src/models.rs` (1178 dòng, 82 struct có `serde(rename_all = "camelCase")`). Đề xuất tách thành crate chung `muop-models`, cả server và client Dioxus cùng dùng. Thay cho `lib/models/*.dart`. Cần quyết định: workspace chung hay copy.
- **Socket.IO:** server dùng `socketioxide 0.14`. AGENTS.md mục 8.9 ghi `rust_socketio 0.6` lỗi với server này. Đề xuất tách client tự viết ở `server/src/bridge/client.rs` (tokio-tungstenite) thành crate chung, rồi client Dioxus dùng lại.
- **Theme:** port `lib/core/theme/app_theme.dart` sang CSS custom properties. Giữ nguyên bảng màu (nền `#141519`, accent `#4C8DFF`, 3 lớp surface). Khi `highContrast` thì chuyển sang bề mặt đục.
- **Thư mục đích:** `app/` (mới). Sau khi Flutter bị xóa mới cân nhắc đổi tên, vì `app/` vẫn là Slint và không được đụng.

---

## 4. Lộ trình

**P0 — Chốt quyết định và bảo vệ mã cũ (trước mọi thao tác xóa)**
- Chốt vị trí đích (mục 6).
- Commit 61 thay đổi hiện tại theo yêu cầu riêng của người dùng. Tạo tag `flutter-final` trỏ vào commit đó để có điểm đối chiếu.

**P1 — Toolchain và khung project**
- Cài rustup, Dioxus CLI (`dx`) đúng phiên bản được ghim. Kiểm tra bản mới nhất trước khi ghim.
- Tạo project trong `app/`. Chạy được `dx serve` cho desktop Linux.
- Quy ước kiểm tra thay `flutter analyze`: `cargo check`, `cargo fmt --check`, `cargo clippy -- -D warnings`, `cargo test`.

**P2 — Lớp dữ liệu**
- Crate `muop-models` (DTO dùng chung với server).
- Socket.IO client và REST client. Ánh xạ từng repository trong `lib/features/*/data/` sang Rust.
- Đối chiếu các sự kiện: `snapshot:update`, `chat:send`, `chat:stop`, `chat:stream`, `quotas:update`, `retry:update`, `ssh:*`, `docker:logs:*`, `explore:update`, `agy:auth:update`, `setup:update`.

**P3 — Design system**
- Port tokens sang CSS. Viết bộ widget thay `material_ui`.
- Hiệu ứng kính bằng CSS. Chấp nhận khác biệt với bản Flutter, chỉ giữ cảm giác chung.

**P4 — Màn chính (parity trước)**
- Dashboard: sidebar, danh sách session, chat canvas, composer, thanh model, chip context, quota.
- Port logic cuộn của `ListView(reverse: true)` (AGENTS.md mục 5.1.3 và 4.3): phân trang ngược, giữ vị trí khi prepend, chỉ tự cuộn xuống khi `pixels < 120`.
- Port `_mergeNewerSteps` (AGENTS.md mục 4.2).

**P5 — Tính năng phụ**
- Agent map (vẽ tùy chỉnh bằng SVG), Cài đặt, Tài khoản (agy/claude), wizard Khởi tạo, SSH hosts, Docker, SFTP, LSP viewer, Cầu nối, cấu hình retry, chi tiết quota, trình duyệt file, duyệt plan.

**P6 — Phần khó**
- Màn hình: đã đổi sang khung JPEG qua HTTP long-poll, không còn RTSP/libmpv.
- SSH terminal: xterm.js trong webview, nối với `ssh:*`.
- Chọn/lưu file và mở link ngoài.

**P7 — Mobile (quyết định riêng)**
- Android (APK) và iOS (IPA TrollStore). Dioxus mobile kém trưởng thành hơn desktop. Có thể để sau desktop.

**P8 — Đóng gói và cắt Flutter**
- Viết lại các target Makefile: `build-linux`, `build-apk`, `build-all`, `deb`, `build-macos-app`, `install-macos-pkg`.
- Viết lại `packaging/build-deb.sh` (đang đóng gói bundle Flutter), `packaging/macos/`, `macos/Runner/AppDelegate.swift` (logic ping/kickstart server của Flutter). Giữ `macos/menubar/` vì là helper Swift của server, không phải của Flutter.
- Cập nhật AGENTS.md (mục 2, 3, 4, 5.1, 5.3, 6, 7 và các mục nhắc Flutter). File này dài ~149KB, cần soát kỹ.
- Chỉ khi parity đạt mới xóa thư mục Flutter ở root, trong commit riêng.

---

## 5. Rủi ro

- **Độ trưởng thành:** Dioxus còn trẻ hơn Flutter. API có thể đổi giữa các phiên bản nên phải ghim.
- **Webview:** Linux dùng WebKitGTK. Android và iOS dùng WebView hệ thống. Hành vi `backdrop-filter`, cuộn và nhập liệu có thể khác nhau. Cần kiểm tra trên từng nền tảng.
- **Danh sách dài:** chat có 2.500+ bước. Phải tự làm virtual list để không lag.
- **Màn hình:** đã đổi sang khung JPEG (`GET /api/screen/frame`), Dioxus chỉ cần hiển thị JPEG; không còn phụ thuộc libmpv.
- **Kiểm thử:** hiện không có test UI tự động (AGENTS.md mục 8.6). Cần checklist parity thủ công theo từng màn, ghi lại trong `docs/`.
- **Khối lượng:** ~42.7k dòng Dart, nhiều tuần công. Không nên ước lượng cứng. Giữ Flutter chạy song song đến khi xong P4 và P5.
- **Môi trường:** chưa có Rust, `dx` và Flutter trên PATH. P1 phải cài trước.

---

## 6. Quyết định cần người dùng chốt

1. **"Folder app" là gì?**
   - (a) Client Flutter ở root (`lib/`, `test/`, `android/`, `ios/`, `linux/`, `macos/`, `pubspec.yaml`). **Đề xuất.**
   - (b) `app/` (Slint). Cần xác nhận rõ vì AGENTS.md cấm sửa.
2. **Vị trí Dioxus:** `app/` song song, xóa Flutter sau parity (**đề xuất**), hay xóa Flutter trước rồi tạo Dioxus?
3. **Commit trạng thái hiện tại** (61 file) và tag `flutter-final` trước khi xóa. Cần lệnh commit riêng.
4. **Nền tảng:** desktop Linux trước; Android/iOS/macOS làm sau hay giữ?
5. **Crate `muop-models` và client Socket.IO dùng chung:** chấp nhận đổi cấu trúc workspace hay copy DTO?

**Đề xuất chung:** 1(a), 2 song song, 3 commit và tag trước, 4 desktop Linux trước, 5 dùng chung.

---

## 7. Quyết định đã chốt (2026-11-27)

1. **Xóa Slint hoàn toàn.** `app/` cũ đã bị xóa khỏi git và working tree. Thư mục `app/` nay là client Dioxus.
2. **Flutter giữ nguyên ở root**, chưa xóa. Đã commit toàn bộ phần Flutter (`ed96bdb` trên nhánh `feature/dioxus-app`): `flutter analyze` sạch, `flutter test` 204/204.
3. **Dioxus đặt trong `app/`.** Linux desktop trước. Đa nền tảng bằng feature `desktop | web | mobile`; tầng `data/` không phụ thuộc Dioxus.
4. **DTO và client Socket.IO không dùng chung với server.** App giữ DTO riêng trong `app/src/data/models.rs`.
5. **Làm xong P0 và P1 của plan này; P2 có REST và danh sách conversation.** Socket.IO, gửi chat và các màn còn lại vẫn theo lộ trình ở mục 4.
