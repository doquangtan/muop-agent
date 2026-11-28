import 'package:muop_agent/features/screen/domain/screen_entities.dart';

/// Interface (domain) của luồng màn hình. Presentation chỉ phụ thuộc interface này.
abstract class ScreenRepository {
  /// Trạng thái hiện tại (rỗng trước khi nhận được sự kiện đầu tiên)
  ScreenStatus get current;

  /// Trạng thái bật/tắt quay màn hình trên server
  Stream<ScreenStatus> get statusStream;

  /// Hỏi server trạng thái hiện tại (dùng khi mở màn hình, vì sự kiện chỉ phát khi có thay đổi)
  void refresh();

  /// Các khung hình mới của luồng, theo long-poll tới server. Đóng subscription thì dừng gọi server.
  Stream<ScreenFrame> watchFrames();

  /// Địa chỉ trang xem cho app: giữ cổng server báo, nhưng lấy host từ địa chỉ server đang kết nối.
  String viewerUrl(String serverViewerUrl);
}
