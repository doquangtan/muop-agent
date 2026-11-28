# Website Mướp Agents

Trang giới thiệu app và tài liệu API của server. Trang tĩnh (HTML, CSS, JS thuần), không cần build.

## Cấu trúc

```
website/
├── index.html                 # Trang giới thiệu: tính năng, ảnh, kiến trúc, tải về, ủng hộ
├── api.html                   # Tài liệu API (dựng từ assets/js/api-data.js)
├── docker-compose.yml         # Chạy website bằng nginx nhẹ (cổng host 446)
├── deploy/
│   ├── nginx.conf             # Cấu hình nginx tối giản dùng cho compose
│   └── stats/count_downloads.py  # Tổng hợp lượt tải từ log nginx
└── assets/
    ├── css/style.css          # Giao diện dùng chung (nền than chì, accent cam)
    ├── js/api-data.js         # Dữ liệu toàn bộ endpoint REST, sự kiện Socket.IO, luồng màn hình
    ├── js/api.js              # Render trang API, ô địa chỉ server, tìm kiếm
    ├── js/main.js             # Menu mobile, phóng to ảnh, nút sao chép
    ├── downloads/             # File cài đặt (.deb, .apk, .ipa, .zip); không commit, xem .gitignore
    └── img/                   # Ảnh chụp, logo, mã QR
```

## Xem trên máy

```bash
python3 -m http.server 8080 -d website
# mở http://localhost:8080
```

Hoặc mở trực tiếp `website/index.html` trong trình duyệt. Trang API mặc định trỏ tới `http://<máy đang mở trang>:8787`; đổi trong ô "Địa chỉ server" để các lệnh curl dùng đúng máy.

## Chạy bằng Docker (nginx nhẹ)

Compose dùng image `nginxinc/nginx-unprivileged` (chạy không root), mount trực tiếp thư mục này, không cần build. Giới hạn 32 MB RAM và 0.25 CPU; khi kiểm thử, container dùng khoảng 2 MB RAM.

```bash
cd website
docker compose up -d                 # mở http://localhost:446
WEB_PORT=8080 docker compose up -d   # đổi cổng host (mặc định 446)
docker compose logs -f web           # xem log
docker compose down                  # dừng
```

Các file ẩn, `deploy/` và `docker-compose.yml` không được phục vụ qua HTTP. Thêm hoặc sửa nội dung website chỉ cần sửa file trong thư mục này; không cần khởi động lại container.

## Đếm lượt tải

Trang "Tải về" hiển thị số lượt tải của từng bản. Cách hoạt động:

1. nginx ghi log các request tải file trong `/assets/downloads/` **chỉ khi host là domain công khai** (`agents.muop.vn`, khai báo trong `deploy/nginx.conf`). Truy cập qua localhost hoặc LAN không được ghi. Log không chứa IP, user-agent hay referer.
2. Service `dl-stats` (`deploy/stats/count_downloads.py`) đọc phần log mới mỗi 5 phút và ghi `/stats/downloads.json`.
3. Trang chủ đọc `/stats/downloads.json` và hiển thị số liệu. Nếu chưa có file, hiển thị "—".

Một lượt tải = một request `GET` trả `200` cho file. HEAD, tải tiếp (`206`) và 404 không được tính.

**Đổi domain:** sửa dòng `agents.muop.vn 1;` trong `deploy/nginx.conf`, rồi `docker compose up -d --force-recreate web`. Nếu Cloudflare hoặc Origin Rule đổi header `Host` gửi tới origin, phải khớp với giá trị đó.

**Không cache file tải:** nginx trả `Cache-Control: no-store` cho `/assets/downloads/`, nên trình duyệt và Cloudflare không cache file. Nhờ vậy mọi lượt tải đều tới máy chủ và được đếm. Nếu bạn đã bật Cache Rule riêng cho domain, hãy đặt bypass cho `/assets/downloads/*`.

**Giới hạn:**
- Đây là số lượt tải thành công, không phải số người dùng duy nhất.
- Lượt tải của chính bạn từ domain công khai cũng được đếm.
- Số liệu tính theo giờ của máy chủ; "last30" là 30 ngày gần nhất.

Xem số liệu trực tiếp: `curl https://agents.muop.vn/stats/downloads.json`.

## Khi API thay đổi

Tài liệu API có hai nơi phải giữ đồng bộ:

1. `docs/API.md` (tài liệu gốc trong repo).
2. `website/assets/js/api-data.js` (dữ liệu hiển thị trên website).

Đối chiếu với `server/src/api/mod.rs` (route REST) và các file `socket.rs` trong `server/src` (sự kiện Socket.IO). Sau khi sửa, kiểm tra trang `api.html` không có lỗi JS và số endpoint hiển thị đúng.
