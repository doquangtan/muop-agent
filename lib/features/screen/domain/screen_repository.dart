import 'package:muop_agent/features/screen/domain/screen_entities.dart';

/// Interface (domain) của luồng màn hình. Presentation chỉ phụ thuộc interface này.
abstract class ScreenRepository {
  /// Trạng thái hiện tại (rỗng trước khi nhận được sự kiện đầu tiên)
  ScreenStatus get current;

  /// Trạng thái bật/tắt quay màn hình và URL RTSP trên server
  Stream<ScreenStatus> get statusStream;

  /// Hỏi server trạng thái hiện tại (dùng khi mở màn hình, vì sự kiện chỉ phát khi có thay đổi)
  void refresh();

  /// Địa chỉ phát cho app: giữ cổng và đường dẫn server báo, nhưng lấy host từ địa chỉ server
  /// mà app đang cấu hình (không dùng IP cứng).
  String playbackUrl(String serverRtspUrl);
}
