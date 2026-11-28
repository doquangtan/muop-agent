import 'dart:typed_data';

/// Trạng thái quay màn hình trên server (`screen:status`)
class ScreenStatus {
  const ScreenStatus({
    this.streaming = false,
    this.starting = false,
    this.error = '',
    this.height = 720,
    this.viewerUrl = '',
  });

  /// Luồng đang chạy
  final bool streaming;

  /// Đang chờ người dùng xác nhận chia sẻ màn hình trên máy chủ
  final bool starting;

  /// Lỗi của lần bật gần nhất, rỗng nếu không có
  final String error;

  /// Chiều cao khung hình (px)
  final int height;

  /// Địa chỉ trang xem trên máy chủ (web app), rỗng khi chưa bật. Host được thay theo địa chỉ app đang kết nối.
  final String viewerUrl;

  factory ScreenStatus.fromJson(Map<String, dynamic> json) {
    return ScreenStatus(
      streaming: json['streaming'] == true,
      starting: json['starting'] == true,
      error: '${json['error'] ?? ''}',
      height: (json['height'] as num?)?.toInt() ?? 720,
      viewerUrl: '${json['viewerUrl'] ?? ''}',
    );
  }
}

/// Một khung hình JPEG của luồng màn hình. `seq` tăng dần theo server; gửi lại làm `after` khi xin khung kế tiếp.
class ScreenFrame {
  const ScreenFrame({required this.seq, required this.jpeg});

  final int seq;
  final Uint8List jpeg;
}
