# Website Mướp Agents

Trang giới thiệu app và tài liệu API của server. Trang tĩnh (HTML, CSS, JS thuần), không cần build.

## Cấu trúc

```
website/
├── index.html                 # Trang giới thiệu: tính năng, ảnh, kiến trúc, tải về, ủng hộ
├── api.html                   # Tài liệu API (dựng từ assets/js/api-data.js)
├── docker-compose.yml         # Chạy website bằng nginx nhẹ (cổng host 446)
├── deploy/
│   └── nginx.conf             # Cấu hình nginx tối giản dùng cho compose
└── assets/
    ├── css/style.css          # Giao diện dùng chung (nền than chì, accent cam)
    ├── js/api-data.js         # Dữ liệu toàn bộ endpoint REST, sự kiện Socket.IO, RTSP
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

## Khi API thay đổi

Tài liệu API có hai nơi phải giữ đồng bộ:

1. `docs/API.md` (tài liệu gốc trong repo).
2. `website/assets/js/api-data.js` (dữ liệu hiển thị trên website).

Đối chiếu với `server/src/api/mod.rs` (route REST) và các file `socket.rs` trong `server/src` (sự kiện Socket.IO). Sau khi sửa, kiểm tra trang `api.html` không có lỗi JS và số endpoint hiển thị đúng.
