# Mướp Agent Monitor (`muop-agent`) — Pure Flutter UI + Rust Socket.IO Server

Ứng dụng **Linux Desktop & Android Mobile** trực quan hóa theo thời gian thực và **trò chuyện trực tiếp với Agent theo từng Project** (tương tự Google Antigravity 2.0) cho hệ sinh thái **`muop-erp-server` ↔ `muop-erp-app`**.

## Ủng hộ

Nếu Mướp Agents hữu ích cho bạn, bạn có thể ủng hộ tác giả qua một trong các hình thức dưới đây (hoàn toàn tự nguyện).

<p align="center">
  <a href="https://buymeacoffee.com/johndylan1r" target="_blank" rel="noopener noreferrer"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy me a beer" style="height: 60px !important;width: 217px !important;" ></a>
</p>

<p align="center">
  <b>MoMo / VietQR / Napas 247</b><br>
  <img src="https://agents.muop.vn/assets/img/donate-qr.jpg" alt="Mã QR ủng hộ qua MoMo, VietQR và Napas 247" width="260">
</p>

---

## Kiến trúc Hệ thống (Rust Backend + Pure Flutter UI)

1. **Rust Backend Server (`server/`)**:
   - Viết hoàn toàn bằng **Rust** (`axum` + `socketioxide` Socket.IO v4 + `rusqlite` + `tokio`), lắng nghe tại cổng **`0.0.0.0:8787`**.
   - Đọc trực tiếp SQLite `/home/john/.gemini/antigravity/conversation_summaries.db` (tốc độ micro-second, không qua tiến trình trung gian), quét `/home/john/.gemini/antigravity/brain/<id>/.system_generated/logs/transcript.jsonl`, danh sách Project `/home/john/Documents/muop-ecosystem/*`, và cấu hình `.agents/`.
   - Quản lý khởi chạy & dừng tiến trình `/home/john/.local/bin/agy` cho từng Project / Conversation.
   - **Socket.IO Realtime Push**:
     - Các event nhỏ (`session:update`, `sessions:list`, `meta:update`, `streams:update`, `session:removed`, `projects:update`, `quotas:update`): chỉ phát phần thay đổi, không gửi snapshot đầy đủ.
     - `chat:stream`: Đẩy từng token (`text_delta`, `step_update`, `result`) theo thời gian thực khi Agent đang trả lời.
2. **Pure Flutter UI (`lib/`)**:
   - Đảm nhiệm **100% vai trò hiển thị Giao diện (Desktop & Mobile)**, hoàn toàn không chứa code server hay quét file cục bộ.
   - Kết nối tới Rust Server qua **`socket_io_client`** (`ws://<IP>:8787/socket.io/?EIO=4&transport=websocket`) và REST API (`/api/ping`, `/api/sessions`, `/api/meta`, `/api/streams`, `/api/chat/send`, `/api/chat/stop`).
   - Cho phép đổi địa chỉ IP của máy tính chạy Rust Server ngay trên giao diện ứng dụng.

---

## Cách khởi chạy

### 1. Khởi chạy Rust Server trên Máy tính Linux (Cổng `8787`)
```bash
cd /home/john/Documents/muop-ecosystem/muop-agent
make server
# Hoặc chạy trực tiếp binary release:
./server/target/release/muop-agent-server
```

### 2. Chạy Giao diện Flutter trên Linux Desktop
```bash
cd /home/john/Documents/muop-ecosystem/muop-agent
make run
```

### 3. Build file cài đặt Android APK Release
```bash
cd /home/john/Documents/muop-ecosystem/muop-agent
make build-apk
```
File APK đầu ra:
- `/home/john/Documents/muop-ecosystem/muop-agent/muop-agent-release.apk`
# muop-agent
