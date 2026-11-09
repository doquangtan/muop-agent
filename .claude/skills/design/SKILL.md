---
name: design
description: Quyết định thiết kế và các vấn đề giao diện đã gặp trong muop-agent (chat canvas, thẻ AI, thinking, tool action, file thay đổi, nhãn model). Dùng khi sửa giao diện chat/dashboard của app Flutter muop-agent hoặc khi cần biết vì sao giao diện đang như vậy.
---

# Design — muop-agent

Đọc `AGENTS.md` mục 8 trước để nắm kiến trúc. Skill này chỉ ghi quyết định thiết kế và vấn đề đã biết.

## Quyết định đã chốt

1. **Thẻ phản hồi AI căn trái, bong bóng user căn phải.** Bề rộng tối đa của thẻ AI bằng bong bóng user: 660 px desktop, 320 px mobile (`_buildAiCardShell`). Khoảng cách hai bên đối xứng khi bong bóng ở độ rộng tối đa.
2. **Mỗi lượt là một thẻ AI duy nhất** (`aiTurnCard`). Không tách tool action, file, thinking thành block riêng trên danh sách.
3. **Tool action ẩn mặc định.** Chỉ hiện nút "Xem N tool actions • M thought"; danh sách mở trong dialog.
4. **File thay đổi là chip** "N tệp thay đổi" (cùng hàng với nút tool action, `Row`). Bấm mở dialog danh sách. Dòng file do Bash ghi có chữ nhỏ "sửa bởi Bash".
5. **Thinking đang chạy nằm trong thẻ AI.** Không border, nền, padding. Console (chi tiết suy nghĩ) ẩn mặc định, bấm "Chi tiết" mới hiện.
6. **Nhãn model** nằm ngoài thẻ, phía dưới bên trái, định dạng "Claude Haiku 5.5" (không phải ID thô). Di chuột hiện ID đầy đủ.
7. **Nội dung phản hồi gõ từng chữ** khi có dữ liệu mới, nối tiếp phần đã hiện. Lịch sử cũ hiện ngay, không gõ lại.

## Vấn đề đã gặp (đừng lặp lại)

- **Thinking "mất" khi chạy**: nguyên nhân nằm ở state dashboard, không ở widget. Snapshot định kỳ ghi đè `_activeStreams` làm mất `pending_optimistic`, và `_currentSessionStream` trả null khi chưa có cid. Đã sửa ở `dashboard_screen.dart`. Khi thấy thẻ thinking không hiện, kiểm tra `activeStream` được truyền vào `ChatCanvasView` trước khi sửa widget.
- **Chip file không hiện cho lượt sửa bằng Bash**: trước đây chỉ đếm tool Edit/Write. Đã thêm phát hiện từ Bash (mục 8.4 của AGENTS.md). Nếu chip vẫn trống, kiểm tra `filesTouched` của session trong `/api/snapshot`.
- **Cache block không cập nhật**: so sánh chỉ số lượng step làm cache không dựng lại khi snapshot cắt còn 100 step. Dùng chữ ký nội dung.
- **Model bị reset khi đổi conversation**: `_syncDefaultSelections` ghi đè model theo provider. Lựa chọn người dùng phải được ghi nhớ theo conversation.
- **Nhãn model sai (Haiku 4.5)**: alias `haiku` của CLI trỏ bản cũ. Hiển thị phải dùng ID đầy đủ.

## Hệ thống màu (Material 3 động)

- Theme: `lib/ui/theme/app_theme.dart` (`buildAppTheme`). Bảng màu sinh từ một seed color (`ColorScheme.fromSeed`) cho sáng và tối.
- Người dùng chọn seed ở dashboard (nút palette cạnh nút đổi sáng/tối). Bảng gợi ý: `kThemeSeedPresets`.
- Ánh xạ ngữ nghĩa: lỗi → `scheme.error`; AI/thinking → `scheme.tertiary`; thông tin → `scheme.secondary`; thành công/cảnh báo → `context.status` (`AppStatusColors`, một `ThemeExtension`).
- Nền và chữ: `surfaceContainer*`, `onSurface`, `onSurfaceVariant`. Viền: `outlineVariant`. Chữ trên nền màu nhấn: `onPrimary`.
- Component M3 chung (card, dialog, bottom sheet, ô nhập liệu) được cấu hình trong `buildAppTheme`. Sửa tại đó, không sửa từng widget.

## Nợ thiết kế còn lại

- Chọn màu chưa được lưu sau khi khởi động lại app (chờ quyết định phía client).
- Thẻ thinking và một số nhãn tool vẫn dùng nhiều màu nhấn để phân loại. Cần kiểm tra độ tương phản ở chế độ sáng.
- Chưa kiểm tra trực quan tự động. Sau khi đổi bố cục, mở app ở cả desktop và mobile (dưới 760 px).

## Khi sửa giao diện chat

- Giữ thứ tự block trong `_buildFlatBlocks` (`ListView(reverse: true)`): push block dưới cùng trước.
- Không tự cuộn xuống khi người dùng đang xem lịch sử (AGENTS.md 5.1).
- Sau mỗi sửa UI: `flutter analyze` sạch, `make build-all`, restart app Linux (AGENTS.md mục 7).
