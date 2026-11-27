# Mướp Agent — client Dioxus (`app/`)

Client Rust dùng [Dioxus](https://dioxuslabs.com) 0.7. Đây là client thuần giao diện:
không đọc file hệ thống, không chạy tiến trình cục bộ. Mọi dữ liệu lấy qua REST và
(sắp tới) Socket.IO của `muop-agent-server` (AGENTS.md mục 4.1).

Ưu tiên Linux Desktop trước. Cấu trúc đã tách để đổi sang Android, macOS, iOS hoặc web
mà không sửa tầng dữ liệu (`src/data/`).

## Lệnh

```bash
make app-run     # chạy thử trên Linux Desktop, tự tải lại khi sửa mã
make app-build   # build Linux Desktop Release → target/dx/muop-agent-app/release/linux/app/
make app-check   # cargo fmt --check + clippy -D warnings + test
```

Test trực tiếp với máy chủ đang chạy (không chạy mặc định):

```bash
cargo test live -- --ignored --nocapture
# MUOP_SERVER=http://192.168.1.10:8787 để trỏ máy khác
```

## Cấu trúc

```
app/
├── Cargo.toml          # dioxus 0.7.2; feature desktop | web | mobile
├── Dioxus.toml         # tên app, bundle id vn.muop.agents
├── assets/main.css     # token màu (dark mặc định, light theo hệ thống)
└── src/
    ├── main.rs         # điểm vào: App → Shell
    ├── data/           # KHÔNG phụ thuộc Dioxus: test được trên máy
    │   ├── api.rs      # REST client (ping, sessions, session)
    │   ├── config.rs   # chuẩn hóa địa chỉ máy chủ, cổng 8787
    │   ├── models.rs   # DTO camelCase, null-tolerant (không dùng chung với server)
    │   └── time.rs     # timer: tokio (native) | gloo-timers (web)
    └── ui/
        ├── shell.rs      # trạng thái kết nối, poll 3 giây, ghép layout
        ├── sidebar.rs    # ô địa chỉ máy chủ, danh sách conversation theo project
        ├── conversation.rs # tiêu đề, số liệu, danh sách bước (chỉ đọc)
        └── format.rs     # định dạng token, giờ, nhãn trạng thái (thuần, có test)
```

## Đã làm

- Kết nối máy chủ theo địa chỉ người dùng nhập (mặc định `127.0.0.1:8787`), hiện tên máy.
- Danh sách conversation nhóm theo project, làm mới mỗi 3 giây.
- Mở conversation: bước người dùng và trả lời của agent, dòng hoạt động cho các bước khác.
- DTO null-tolerant: server trả `null` ở trường nào cũng không làm vỡ app.
- Test: 12 test đơn vị + 1 test live với máy chủ thật (114 session, 100 bước).

## Chưa làm (theo thứ tự ưu tiên)

1. Socket.IO realtime (`snapshot:update`, `chat:stream`) thay cho poll REST.
   Dùng client tự viết kiểu `server/src/bridge/client.rs`, không dùng `rust_socketio`.
2. Gửi tin nhắn, dừng lượt, ảnh đính kèm.
3. Phân trang lịch sử (`/api/session/steps`) và Markdown trong phản hồi agent.
4. Lưu địa chỉ máy chủ giữa các lần mở app (hiện chỉ nhớ trong bộ nhớ).
5. Các màn còn lại của Flutter: Agent map, Tài khoản agy/Claude, wizard Khởi tạo,
   SSH, Docker, SFTP, LSP, Cầu nối, quota, cấu hình retry.
6. Đa nền tảng: `make` mới chỉ có Linux Desktop. Web/Android sẽ kiểm tra khi có nhu cầu.
