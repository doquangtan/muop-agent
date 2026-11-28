# Mướp Agent — client Dioxus (`app/`)

Client Rust dùng [Dioxus](https://dioxuslabs.com) 0.7. **Hiện tại Flutter (`lib/` ở root) vẫn là
app chính.** Dioxus đang được clone tính năng từ Flutter; Flutter chỉ bị thay khi Dioxus đạt parity
và có quyết định riêng.

Client thuần giao diện: không đọc file hệ thống, không chạy tiến trình cục bộ. Dữ liệu đi qua
Socket.IO và REST của `muop-agent-server` (AGENTS.md mục 4.1). Linux trước; cấu trúc tách để sang
Android, macOS, iOS hoặc web mà không sửa tầng dữ liệu (`src/data/`).

## Lệnh

```bash
make app-run     # chạy thử trên Linux Desktop, tự tải lại khi sửa mã
make app-build   # build Linux Desktop Release → target/dx/muop-agent-app/release/linux/app/
make app-check   # cargo fmt --check + clippy -D warnings + test
```

Test với máy chủ đang chạy (không chạy mặc định):

```bash
cargo test -- --ignored --nocapture
# MUOP_SERVER=http://192.168.1.10:8787 để trỏ máy khác
```

## Cấu trúc

```
app/
├── Cargo.toml / Dioxus.toml
├── assets/main.css          # token màu (dark mặc định, light theo hệ thống)
└── src/
    ├── main.rs              # điểm vào: tạo Store, mount Shell
    ├── store.rs             # trạng thái dùng chung + hành động (chọn, gửi, dừng, plan, retry, quota)
    ├── data/                # không phụ thuộc Dioxus
    │   ├── socket.rs        # Socket.IO v4 qua WebSocket (tự viết, tự kết nối lại)
    │   ├── api.rs           # REST: session, steps phân trang, chat send/stop, quota, retry, plan
    │   ├── models.rs        # DTO camelCase, null-tolerant (không dùng chung với server)
    │   ├── config.rs        # chuẩn hóa địa chỉ máy chủ (mặc định cổng 8787)
    │   ├── persist.rs       # lưu máy đang dùng + danh sách máy đã kết nối (app.json)
    │   └── rt.rs            # runtime I/O riêng (tokio); UI await kết quả qua `run`
    └── ui/
        ├── shell.rs         # mở socket theo địa chỉ, ghép layout
        ├── sidebar.rs       # máy chủ, máy đã lưu, conversation mới, danh sách theo project
        ├── conversation.rs  # tiêu đề, bước, tải lịch sử, lượt đang chạy, banner retry, thẻ plan
        ├── composer.rs      # ô nhập, project (conversation mới), model + mức, quota, gửi/dừng
        ├── markdown.rs      # Markdown tối thiểu cho phản hồi agent (có test)
        ├── model_groups.rs  # gom model theo nhóm và mức (port model_groups.dart, có test)
        ├── format.rs        # định dạng token, giờ, nhãn trạng thái
        └── render_tests.rs  # test SSR: nạp dữ liệu như từ socket, kiểm tra HTML
```

## Trạng thái so với Flutter

Đã có:

- Kết nối Socket.IO tự kết nối lại; `request-meta/sessions/streams` khi kết nối; `quotas:update`, `retry:update`.
- Máy chủ: nhập địa chỉ, chuẩn hóa, lưu máy đã kết nối, chọn lại nhanh.
- Danh sách conversation theo project; conversation mới; chọn project khi tạo mới.
- Chat: gửi (Enter), dừng, nội dung đang stream, suy nghĩ (text), bước lịch sử, Markdown.
- Tải lịch sử trước đó (50 bước/lần); snapshot mới giữ bước cũ đã tải (`_mergeNewerSteps`).
- Chọn model theo nhóm và mức suy luận (theo meta của server).
- Chip quota theo provider của model.
- Banner tự gửi lại sau rate limit, có nút hủy lịch.
- Thẻ kế hoạch chờ duyệt: duyệt và chạy, góp ý chỉnh sửa, hủy.
- Cột workspace (project + số session) và cây tệp của project đang chọn, tải lười từng thư mục qua `/api/sftp/list` ("Máy này"). Ẩn mục bắt đầu bằng "." mặc định. Nút "Tệp" trên sidebar để ẩn/hiện.
- Cửa sổ desktop 1360×860, không có menu mặc định của Dioxus.
- Ảnh đính kèm: nút "+ Ảnh" mở hộp thoại của hệ điều hành (PNG, JPEG, WebP; tối đa 6 ảnh, 20MB mỗi ảnh), xem trước trong composer, gửi qua `/api/chat/send`. Ảnh trong lịch sử hiện thành thumbnail. Gửi thất bại thì ảnh vẫn còn (Flutter bỏ ảnh khi gửi lỗi).
- Tương tác Claude đang chờ: câu hỏi `AskUserQuestion` (chọn một hoặc nhiều đáp án, hoặc nhập khác; phải trả lời đủ mọi câu) và kế hoạch `ExitPlanMode` (duyệt, góp ý, hủy). Câu hỏi của agy trả lời ngay tại chỗ.
- Menu chọn model theo khối provider như Flutter: "Claude Code CLI · limit tài khoản Claude" và "Antigravity (agy) · quota Gemini/Claude". Chip quota hiện `Tuần 24% (03/12 18:56)`, tuần trước rồi đến 5 giờ.
- Theme sáng/tối (nút ☀/☾ ở sidebar, lưu lại cho lần mở sau).
- Xem nội dung tệp: bấm tệp trong cây mở khung xem có số dòng (tối đa 2000 dòng hiển thị, tệp nhị phân báo không hiển thị).
- Git: tệp đã đổi được tô màu trong cây (đổi, mới, xóa), thư mục có thay đổi bên trong được đánh dấu, tiêu đề cột tệp đếm số tệp đã đổi.
- Trạng thái đăng nhập agy và Claude (email, gói) hiện ở đầu sidebar (chỉ đọc, không đăng nhập từ app).
- Docker (chỉ đọc + khởi động lại/dừng): nút "Docker" ở sidebar, chọn máy đã lưu, container đang chạy nhóm theo project Compose, quét lại mỗi 10 giây.
- Lịch sử commit (chỉ đọc): nút "Lịch sử" ở tiêu đề cột tệp, 100 commit gần nhất với nhánh và refs.
- SSH (không terminal): nút "SSH" ở sidebar. Danh sách máy (Máy này đứng đầu, không sửa/xóa được), thêm/sửa/xóa máy (xóa cần bấm hai lần), chạy một lệnh (timeout 30 giây) và hỏi mật khẩu khi server yêu cầu, có tùy chọn lưu. Bí mật không bao giờ tải về app.
- Nháp soạn dở được giữ riêng theo từng conversation (và một nháp cho conversation mới).
- Mỗi lượt AI có nút "N thao tác" (tool call, mở hộp thoại tham số) và "N tệp thay đổi · +a −b" (mở danh sách tệp). Tệp được gán theo lượt: từ tin người dùng này đến tin kế tiếp.

Chưa có (theo thứ tự ưu tiên gợi ý):

1. Chat theme và màu nhấn. Thanh model trên Flutter còn có menu mức suy luận dạng chip và thanh quota chi tiết (`quota_detail_sheet`).
2. Cây tự động (`explore:*`), commit chi tiết và diff, sửa tệp, commit/push.
3. Cài đặt: thư mục project (setup), LSP, cầu nối máy phụ.
4. Đăng nhập agy và Claude, wizard Khởi tạo.
5. SSH terminal tương tác (xterm trong WebView, chưa có), SFTP, LSP viewer, sơ đồ Agent map, log container.
6. Màn hình quay (RTSP, để làm cuối cùng theo yêu cầu) và quota chi tiết (bảng đầy đủ). Màn RTSP cần quyết định kỹ thuật trước: webview WebKitGTK không phát được `rtsp://`, nên phải chọn giữa endpoint MJPEG/WebSocket phía server và libmpv/GStreamer phía client.
7. Đa nền tảng: build Android/macOS/web (chưa thử).

## Ghi chú kỹ thuật

- Mạng chạy trên runtime tokio riêng (`rt::runtime`), UI nhận kết quả qua `rt::run`. Trên web sẽ thay bằng `spawn_local`.
- `store::handle` là nơi duy nhất đưa sự kiện realtime vào Signal. Logic này được kiểm tra bằng test SSR.
- Test live (`--ignored`) cần máy chủ đang chạy: kiểm tra socket nhận `meta:update` và `sessions:list`, rồi đọc chi tiết conversation đầu tiên.
