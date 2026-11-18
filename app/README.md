# Mướp Agent — giao diện Slint (`app/`)

Giao diện desktop được viết lại bằng [Slint](https://slint.dev). Đây là client thuần UI:
không đọc file hay chạy tiến trình cục bộ, mọi dữ liệu lấy qua REST của `muop-agent-server`.

## Cấu trúc

```
app/
├── Cargo.toml          # slint =1.16.0 (ghim, xem bên dưới), ureq, serde
├── build.rs            # biên dịch ui/app.slint
├── ui/
│   ├── theme.slint     # bảng màu dark/light (port app_theme.dart)
│   ├── types.slint     # SideRow, MessageItem, PlanItem
│   ├── widgets.slint   # SideRowView (sidebar), MessageView (chat), Chip
│   └── app.slint       # AppWindow: sidebar, header, chat, banner plan/câu hỏi, composer, dialog
└── src/
    ├── main.rs         # state, render, callback
    ├── live.rs         # Socket.IO: sessions:list, session:update, meta:update, streams:update, retry:update
    ├── api.rs          # DTO của server + các lệnh REST (chat, stop, plan, câu hỏi AI)
    ├── model_groups.rs # port model_grouping.dart: nhóm model + mức suy luận
    └── turns.rs        # gom steps thành lượt (user / AI / thao tác / tệp thay đổi)
```

## Chạy

Server phải đang chạy ở `:8787` (`make server`), sau đó:

```bash
cd app
cargo run
```

Đổi địa chỉ server bằng biến môi trường `MUOP_SERVER_URL` (mặc định `http://127.0.0.1:8787`).

## Xem giao diện mà không cần màn hình

Khi không có display (ví dụ máy chủ, SSH), app có thể chụp ảnh giao diện bằng renderer phần mềm của Slint.
Dữ liệu là snapshot thật từ server đang chạy:

```bash
cd app
MUOP_SCREENSHOT=$PWD/target/screenshots/dark.png cargo run
# theme sáng:       MUOP_SCREENSHOT_LIGHT=1
# màn hẹp kiểu điện thoại: MUOP_SCREENSHOT_WIDTH=390 MUOP_SCREENSHOT_HEIGHT=800
# ẩn sidebar (như sau khi chọn chat trên màn hẹp): MUOP_SCREENSHOT_HIDE_SIDEBAR=1
# nội dung nháp trong composer: MUOP_SCREENSHOT_DRAFT="..."
```

Trên máy có màn hình thì chỉ cần `cargo run --release` để mở cửa sổ thật.

## Ảo hóa danh sách

Khung chat và sidebar chỉ đưa vào giao diện các mục trong vùng nhìn (cộng đệm), phần còn lại là spacer:
- Dữ liệu đầy đủ giữ trong bộ nhớ Rust (`window.rs`: `VirtualList` cộng dồn chiều cao từng mục).
- Vị trí cuộn được Rust đọc định kỳ (100 ms) từ giao diện; chỉ khi vùng nhìn đổi mới tính lại khoảng mục.
- Chiều cao mục chat là **ước lượng** theo độ dài nội dung. Slint 1.16 không cho đo chiều cao mục rồi đẩy về Rust (gây lỗi đệ quy), nên spacer có sai số nhỏ; các mục đang hiển thị vẫn được layout theo chiều cao thật.
- Khi đang bám đáy, tin mới được giữ ở cuối; khi đang đọc lịch sử, vị trí cuộn được giữ nguyên.

Nên chạy bản release để đo CPU: bản debug parse JSON snapshot rất chậm.

## Đã port từ Flutter

- Sidebar: tìm kiếm, nhóm theo project (thu gọn/mở rộng), nút `+` tạo chat trong project, đánh dấu phiên đang chạy, chuyển dark/light.
- Khung chat: lượt user / AI gom theo turn, chip "N thao tác" và "N tệp thay đổi" (bấm để xem chi tiết), thinking, lỗi.
- Header: tên, project · nguồn · model, chip context (cảnh báo ≥70%, nguy hiểm ≥90%).
- Composer: chọn nhóm model và mức suy luận (cùng logic `model_grouping.dart`), nháp lưu theo conversation, gửi, dừng.
- Banner kế hoạch chờ duyệt: duyệt & chạy, góp ý chỉnh sửa, hủy.
- Banner câu hỏi AI đang chờ: trả lời câu đầu tiên.
- Màn hẹp (<760px): sidebar phủ toàn màn, bấm conversation để quay lại chat.
- Banner retry sau rate limit (từ socket `retry:update`), có nút hủy lịch gửi lại.
- Realtime qua Socket.IO bằng event nhỏ: khi kết nối gửi `request-sessions`, `request-meta`, `request-streams`; sau đó nhận các event cập nhật từng phần. Render được gộp trong 60 ms.

## Chưa port (còn trong Flutter `lib/`)

- SSH (danh sách máy, terminal tương tác), Docker, LSP settings.
- Parallel agent flow, subagent lanes.
- File explorer, file viewer, git history / push, duyệt file trên server.
- Dialog quyền / câu hỏi của Claude (`/api/claude/pending`), tạo project, custom agents.
- Markdown đầy đủ (hiện hiển thị văn bản thuần), chọn màu seed.

## Ghi chú

- **Ghim Slint 1.16.0**: máy hiện có rustc 1.92; Slint 1.19 cần rustc 1.95. Khi nâng rustc có thể nâng Slint (sửa `Cargo.toml`, xóa `Cargo.lock`).
- Bố cục đã kiểm chứng bằng ảnh chụp (theme tối, sáng, màn hẹp). Tương tác chuột/bàn phím trong cửa sổ thật chưa kiểm chứng vì môi trường không có display.
