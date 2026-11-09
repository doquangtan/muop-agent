---
name: design-uiux
description: Nguyên tắc UI/UX cho app Flutter muop-agent (Material 3, dark/light theme, desktop Linux và mobile Android). Dùng khi thiết kế hoặc chỉnh layout, màu, khoảng cách, trạng thái loading/lỗi/rỗng, hoặc danh sách và hội thoại trong muop-agent.
---

# Design UI/UX — muop-agent

Áp dụng cho mọi màn hình trong `lib/`. Đọc cùng skill `design` (quyết định riêng của app) và `AGENTS.md` mục 5.1.

## Nguyên tắc bắt buộc

1. **Màu theo token.** Dùng `Theme.of(context).colorScheme` (`surface`, `surfaceContainerLow`, `primary`, `onSurfaceVariant`, `outlineVariant`). Không dùng `Colors.white/black` và mã hex cố định cho nền hoặc chữ. Trường hợp accent có nghĩa (ví dụ đang chạy, lỗi) thì dùng token tương ứng, không hardcode.
2. **Dark và light đều phải đọc được.** Kiểm tra cả hai theme sau mỗi thay đổi màu. Dùng `withAlpha` trên token thay cho màu cố định.
3. **Responsive.** Ngưỡng mobile là 760 px (`MediaQuery.sizeOf(context).width < 760`). Desktop và mobile dùng cùng widget, khác padding và maxWidth.
4. **Khoảng cách theo bội số 2–4 px.** Padding thẻ: 12–16 px. Khoảng giữa các block trong danh sách chat: 14–20 px (`turnSpacing`).
5. **Căn lề có nghĩa.** Người dùng căn phải, AI căn trái. Thẻ AI và bong bóng user có cùng `maxWidth` để cân đối.
6. **Thông tin phụ nhỏ và mờ.** Nhãn model, ghi chú "sửa bởi Bash", thời gian: `labelSmall` với `onSurfaceVariant`.
7. **Ẩn chi tiết mặc định.** Tool action, console suy nghĩ, danh sách file: hiện khi người dùng bấm (dialog hoặc mở rộng tại chỗ).

## Trạng thái giao diện

- **Đang chạy**: có chỉ báo (`CircularProgressIndicator` nhỏ hoặc thẻ thinking) cạnh nội dung, không chặn thao tác khác.
- **Rỗng**: thông điệp ngắn và hành động gợi ý (ví dụ "Bắt đầu cuộc trò chuyện mới").
- **Lỗi**: màu `colorScheme.error` hoặc `Colors.redAccent` (lỗi là ngoại lệ được phép), kèm thông điệp có thể hành động. Không chỉ hiện màu đỏ.
- **Nạp thêm lịch sử**: banner ở đầu danh sách, không làm nhảy vị trí cuộn.

## Hiệu năng hiển thị

- Danh sách chat dùng `ListView.builder` với `RepaintBoundary` và `ValueKey` ổn định theo `keyId`.
- Cache block dựng lại chỉ khi nội dung đổi (chữ ký nội dung, không chỉ số lượng).
- Hiệu ứng gõ chữ chỉ chạy khi có dữ liệu mới nối vào cuối.

## Ngôn ngữ giao diện

- Toàn bộ nhãn và thông báo bằng tiếng Việt có dấu, giống các chuỗi hiện có.
- Ngắn gọn: nhãn nút là động từ hoặc danh từ ngắn ("Xem", "Thu gọn", "Xem toàn bộ").

## Checklist sau khi sửa UI

- [ ] `flutter analyze` không có issue.
- [ ] Không thêm `Colors.*` hoặc hex mới trong vùng đã sửa.
- [ ] Kiểm tra dark và light.
- [ ] Kiểm tra bố cục dưới 760 px và trên 760 px.
- [ ] `make build-all` và restart app Linux theo AGENTS.md.
