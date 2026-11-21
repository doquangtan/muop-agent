import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:muop_agent/core/config/server_config.dart';

/// Địa chỉ Rust Server đang kết nối, dùng chung cho toàn app.
/// Khi địa chỉ đổi, mọi màn đang mount được dựng lại và tải lại dữ liệu từ server mới.
final serverAddressProvider = NotifierProvider<ServerAddressNotifier, String>(
  ServerAddressNotifier.new,
);

class ServerAddressNotifier extends Notifier<String> {
  @override
  String build() => defaultHostAddress;

  /// Đặt địa chỉ server (chuỗi rỗng dùng mặc định). Không làm gì nếu địa chỉ không đổi.
  void change(String address) {
    final clean = address.trim().isEmpty ? defaultHostAddress : address.trim();
    if (clean != state) state = clean;
  }
}
