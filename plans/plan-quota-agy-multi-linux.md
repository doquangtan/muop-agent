# Plan: Lấy Quota Antigravity (agy) Trên Nhiều Máy Linux

> Trạng thái: **Đề xuất, chưa triển khai.** Phạm vi: `server/` (Rust) và, nếu cần, `lib/` (Flutter). Không sửa `app/` (theo AGENTS.md mục 0).

---

## 1. Kết luận ngắn

- Cách hiện tại (gọi RPC `RetrieveUserQuotaSummary` của **hub** agy chạy local) **dùng được trên máy Linux khác**, miễn là 4 điều kiện đúng trên từng máy (mục 3).
- Hiện code **chưa portable**: nhiều đường dẫn cứng `/home/john/...` (mục 4). Máy khác có user khác thì sẽ không đọc được hub.
- Quota **thuộc về tài khoản Google đăng nhập trên máy đó**, không thuộc về app. Vì vậy số quota là "của server đang kết nối", không phải số chung của cả hệ thống.
- Điểm dễ hỏng nhất: **hub chỉ tồn tại khi agy đang chạy**, và server chỉ tự mở agy để lấy quota khi người dùng vừa thao tác màn Tài khoản (`Need::Background`, `HOST_IDLE` 30 phút). Máy không có agy chạy thì quota sẽ rỗng.

---

## 2. Cơ chế hiện tại (đã kiểm chứng trên máy phát triển)

| Bước | Nguồn | File/Hàm |
| :--- | :--- | :--- |
| Tìm hub | `~/.gemini/antigravity/daemon/hub_<port>.json` (`httpPort`, `csrfToken`, `pid`) | `scanner/quotas.rs` (`query_daemon_quota_summary`), `chat/context_window.rs` (`discover_hub`) |
| Kiểm tra còn sống | `/proc/<pid>` tồn tại | `discover_hub` |
| Gọi RPC | `POST http://127.0.0.1:<port>/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary`, header `x-codeium-csrf-token` | `call_retrieve_user_quota_summary` |
| Kiểm tra đăng nhập trước khi lấy quota | `hub_logged_in(Need::Background)` | `scanner/quotas.rs` |
| Gắn gói tài khoản | RPC `GetUserStatus` (`planName`) | `query_agy_account` |
| Cache | 10 giây (quota), xóa khi đăng nhập/đăng xuất (`sync_quotas`) | `QUOTA_CACHE` |

Dữ liệu trả về (ví dụ thật, chỉ đọc):
- `groups[].displayName`, `groups[].buckets[]`
- Mỗi bucket: `bucketId`, `displayName`, `window` (`5h` | `weekly`), `remainingFraction` (0–1), `resetTime` (ISO 8601).

Không có lệnh CLI công khai nào của agy trả quota (đã kiểm tra `--help`, `models`, `--output-format json|stream-json`). Đây là RPC nội bộ, **không có tài liệu ổn định**: có thể đổi theo phiên bản agy.

---

## 3. Điều kiện để dùng trên một máy Linux

Mỗi máy (ví dụ Laptop `192.168.31.216`, và máy khác) phải thỏa đủ:

1. **agy đã cài** và đúng cách (`~/.local/bin/agy`). Phiên bản đã biết chạy: `1.5.13`.
2. **agy đã đăng nhập** Google trên máy đó. Token nằm trong keyring hệ thống, fallback `~/.config/antigravity/plugin-secrets.json`.
3. **Hub đang chạy**: có `hub_<port>.json` với `pid` còn sống. Hub được tạo khi agy chạy (TUI/chat/host).
4. **Server cùng user với người đăng nhập agy**, vì `HOME` và keyring phải trùng. Nếu server chạy bằng user khác, nó không thấy `~/.gemini`.

Nếu thiếu điều kiện 3, `ensure_hub(Need::Background)` chỉ mở host khi người dùng vừa thao tác màn Tài khoản. Các trường hợp còn lại trả về danh sách rỗng, và UI hiện không có quota (đúng với nguyên tắc "không dùng số cũ hay số mặc định").

---

## 4. Các vấn đề cần sửa để portable

### 4.1. Đường dẫn cứng `/home/john` (phải sửa)

| Vị trí | Vấn đề | Cách sửa |
| :--- | :--- | :--- |
| `server/src/scanner/mod.rs:20-23` | `BRAIN_DIR_PATH`, `DAEMON_DIR_PATH`, `SUMMARY_DB_PATH`, `ECOSYSTEM_DIR_PATH` hằng số | Tính từ `HOME` (giống `claude/code/paths.rs`) |
| `server/src/scanner/quotas.rs` (dùng `DAEMON_DIR_PATH`) | Quota đọc hub ở `/home/john` | Dùng chung `discover_hub()` của `context_window.rs` |
| `server/src/chat/quota_stall.rs:29` | `LOG_DIR` cứng | Từ `HOME` |
| `server/src/chat/provider.rs:48` | `/home/john/.gemini/bin/agy` | Dò PATH rồi `~/.local/bin/agy` |
| `server/src/chat/recovery.rs:287,311` | `/home/john/.local/bin/agy` | Dùng cùng hàm tìm agy |
| `server/src/scanner/projects.rs:203` | Built-in skills cứng | Từ `HOME` |
| `server/src/infra/store.rs:12,19` | DB legacy và fallback `/home/john` | Từ `HOME` (chỉ fallback) |
| `server/src/infra/tray.rs:27,116,176,183` | Đường dẫn app cứng | Ngoài phạm vi plan quota, ghi nhận để làm sau |
| `server/src/api/plans.rs:78,114` | `project_path` cứng | Ngoài phạm vi, ghi nhận |

Ghi chú: `ECOSYSTEM_DIR_PATH` và `.agents` của `muop-erp-server` là dữ liệu riêng của máy phát triển, không phải để dùng chung. Với máy khác, cần cấu hình hoặc bỏ qua.

### 4.2. Hai cách tìm hub khác nhau

- `quotas.rs` dùng `DAEMON_DIR_PATH` (cứng), còn `context_window.rs::discover_hub` dùng `HOME` và kiểm tra pid.
- **Hợp nhất**: `quotas.rs` gọi `discover_hub()` (đã kiểm tra pid, đã validate token) thay vì đọc lại thư mục. Điều này cũng bỏ được việc thử từng hub cũ (`hub_35063.json`, `hub_40635.json` từ 17/11 trên máy phát triển).

### 4.3. Kiểm tra và khắc phục phiên bản agy

- Ghi `agy --version` vào snapshot hoặc log khi lấy quota lần đầu.
- Parse phòng thủ: thiếu `groups`/`buckets` → coi là "không rõ", không phải 0%.
- Khi RPC trả lỗi hoặc đổi cấu trúc: log raw response (đã cắt) một lần, không spam.

---

## 5. Thiết kế đa máy

### 5.1. Quota là theo máy đang kết nối

- App kết nối tới **một** server (cấu hình IP). Quota hiển thị là của **tài khoản agy trên server đó**.
- Không gộp quota giữa các máy. Nếu hai máy cùng tài khoản Google, số sẽ giống nhau; khác tài khoản thì khác.
- Không cần đổi protocol: `quotas:update` đã được gửi cho từng socket khi kết nối (`spawn_quotas_update(false, true)`).

### 5.2. Hiển thị trạng thái rõ ràng

Thêm trường trạng thái quota vào snapshot (đề xuất, cần thống nhất DTO):

- `ok`: có số thật, kèm thời điểm lấy.
- `hubMissing`: agy không chạy hoặc không có hub.
- `loggedOut`: hub báo chưa đăng nhập.
- `unsupported`: RPC lỗi hoặc đổi schema.

UI chỉ hiện con số khi `ok`. Các trường hợp còn lại hiện nhãn ngắn ("Chưa có quota: agy chưa chạy trên máy này").

### 5.3. Giữ hub sống (tùy chọn, cần quyết định)

Hai lựa chọn:
- **A (đề xuất)**: giữ nguyên hành vi hiện tại, chỉ hiện trạng thái `hubMissing`. Không tự chạy agy nền.
- **B**: server tự mở host agy nền định kỳ để lấy quota. Tốn tài nguyên và có thể đụng quota khi TUI chạy. Chỉ làm nếu người dùng thật sự cần số luôn có.

---

## 6. Triển khai trên máy Linux khác

Các bước lặp lại cho mỗi máy:

1. Cài agy (job setup `setup:install agy` hoặc tay).
2. Đăng nhập agy trên máy (màn Tài khoản hoặc wizard).
3. Cài server: copy binary `muop-agent-server` (theo quy trình mục 8.6m AGENTS.md), đặt `HOME` đúng user đăng nhập agy.
4. Unit systemd user: `service/muop-agent-server.service` hiện **hardcode** `WorkingDirectory` và `ExecStart` tới `/home/john/...`. Cần bản unit template cho máy khác, hoặc để script cài đặt tự sinh unit từ đường dẫn thật.
5. **Kiểm tra DBus session**: keyring cần `DBUS_SESSION_BUS_ADDRESS`. Unit user thường có sẵn, nhưng nếu server chạy khi chưa có session (`After=graphical-session.target` không đảm bảo trên máy headless), token không đọc được. Trên máy headless: thêm `Environment=DBUS_SESSION_BUS_ADDRESS=...` hoặc dùng `plugin-secrets.json` nếu keyring không có. Cần kiểm tra thực tế.
6. Kiểm tra bằng REST/socket: quota có `ok` không.

### 5.4. Kiểm tra trên Laptop (bước chưa làm được)

Lần thử SSH đọc-chỉ tới Laptop (`192.168.31.216`) đã bị chặn bởi quyền truy cập, nên chưa xác nhận được:
- Laptop có `~/.gemini/antigravity/daemon/hub_*.json` không?
- agy trên Laptop đã đăng nhập chưa (`~/.config/antigravity/plugin-secrets.json` hoặc keyring)?
- Server Laptop (systemd user) có đọc được token không?

Các lệnh cần chạy, do người dùng tự chạy trên Laptop hoặc cấp quyền:

```bash
ls -la ~/.gemini/antigravity/daemon/ 2>&1
pgrep -a agy | head
ls -la ~/.config/antigravity/ 2>&1
systemctl --user show muop-agent-server -p Environment -p ExecStart
echo "$DBUS_SESSION_BUS_ADDRESS"
```

---

## 7. Các bước thực hiện

| # | Việc | Phạm vi | Kiểm chứng |
| :- | :--- | :--- | :--- |
| P0 | Kiểm tra hub, đăng nhập và DBus trên Laptop (lệnh mục 5.4) | Đọc, máy Laptop | Có/không hub, có/không token |
| P1 | Hợp nhất discovery: `quotas.rs` gọi `discover_hub()`, bỏ `DAEMON_DIR_PATH` cho quota | `server/src/scanner/quotas.rs`, `scanner/mod.rs` | `cargo check`, `cargo test` (thêm test parse JSON với fixture) |
| P2 | Thay đường dẫn `/home/john` bằng `HOME` trong nhóm quota, agy path, skills | `scanner/`, `chat/provider.rs`, `chat/recovery.rs`, `chat/quota_stall.rs` | `grep -rn "/home/john" server/src` chỉ còn ở fallback có chủ đích |
| P3 | Thêm trạng thái quota (`ok`/`hubMissing`/`loggedOut`/`unsupported`) vào DTO (`models.rs`) | `server/src/models.rs`, `scanner/quotas.rs` | Unit test từng trạng thái |
| P4 | Log phiên bản agy và raw response khi lỗi (một lần) | `scanner/quotas.rs` | Log rõ, không spam |
| P5 | Hiển thị nhãn trạng thái trên chat | `lib/` (`chat_canvas_view.dart`, `quota_detail_sheet.dart`) | `flutter analyze` sạch, test widget cho từng trạng thái |
| P6 | Template unit systemd và script cài server cho máy khác | `service/` | Cài thử trên một máy Linux thứ hai |
| P7 | Build và restart theo AGENTS.md (`make build-server`, `make restart-daemon`; `make build-all` nếu có `lib/`) | — | `lsof -i :8787`, quota trả về |
| P8 | Cập nhật AGENTS.md mục 8 (trạng thái, nợ kỹ thuật) | `AGENTS.md` | — |

Thứ tự: P0 trước (quyết định có cần P1–P4 không). P1–P4 không phụ thuộc máy khác nên làm được ngay trên máy phát triển.

---

## 8. Rủi ro

| Rủi ro | Mức | Giảm thiểu |
| :--- | :--- | :--- |
| RPC là nội bộ, đổi schema khi agy cập nhật | Cao | Parse phòng thủ, trạng thái `unsupported`, log phiên bản |
| Hub không chạy trên máy headless | Cao | Trạng thái `hubMissing`, quyết định mục 5.3 |
| Keyring không đọc được khi server chạy như service | Trung bình | Kiểm tra P0, dùng `plugin-secrets.json` làm fallback đã có |
| Hub của user khác hoặc hub cũ bị chọn nhầm | Thấp | `discover_hub` kiểm tra pid và token; tách theo `HOME` |
| Gọi RPC quá nhiều làm tốn tài nguyên | Thấp | Cache 10 giây đã có; không tăng tần suất |
| Quota khác nhau theo tài khoản, người dùng nhầm là "tổng" | Trung bình | Hiển thị tên tài khoản (`GetUserStatus.email`) cạnh quota |

---

## 9. Ngoài phạm vi

- Gộp quota nhiều máy hoặc nhiều tài khoản thành một số tổng.
- Đọc SQLite hay file nội bộ của agy để suy ra quota.
- Đăng nhập agy từ xa qua mạng (đã có luồng SSH riêng, xem AGENTS.md mục 8.6l).
- Sửa `app/` (Slint).

---

## 10. Câu hỏi cần người dùng trả lời

1. Những máy Linux nào cần quota (ngoài Laptop 192.168.31.216 và máy phát triển)?
2. Mỗi máy đăng nhập **tài khoản Google nào**? Nếu cùng tài khoản thì quota giống nhau, không cần hiển thị riêng.
3. Có cho phép chạy lệnh đọc-chỉ trên Laptop (mục 5.4) không? Nếu không, bạn có thể tự chạy và gửi kết quả.
4. Chọn phương án **A** (chỉ hiện trạng thái, mặc định đề xuất) hay **B** (server tự giữ hub để lấy quota) ở mục 5.3?
