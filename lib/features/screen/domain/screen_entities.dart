/// Trạng thái quay màn hình trên server (`screen:status`)
class ScreenStatus {
  const ScreenStatus({
    this.streaming = false,
    this.starting = false,
    this.error = '',
    this.height = 720,
    this.rtspUrl = '',
  });

  /// Luồng RTSP đang chạy
  final bool streaming;

  /// Đang chờ người dùng xác nhận chia sẻ trên máy chủ
  final bool starting;

  /// Lỗi của lần bật gần nhất, rỗng nếu không có
  final String error;

  /// Chiều cao khung hình (px)
  final int height;

  /// Địa chỉ RTSP để mở bằng trình phát (VLC, mpv...), rỗng khi chưa bật
  final String rtspUrl;

  factory ScreenStatus.fromJson(Map<String, dynamic> json) {
    return ScreenStatus(
      streaming: json['streaming'] == true,
      starting: json['starting'] == true,
      error: '${json['error'] ?? ''}',
      height: (json['height'] as num?)?.toInt() ?? 720,
      rtspUrl: '${json['rtspUrl'] ?? ''}',
    );
  }
}
