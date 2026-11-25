import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Địa chỉ máy chủ mà luồng kiểm tra cài đặt (splash, wizard) đã được mở cho nó.
/// Dashboard được dựng lại khi đổi IP, nên dùng provider này để chỉ mở luồng một lần cho mỗi địa chỉ.
final setupCheckedAddressProvider =
    NotifierProvider<SetupCheckedAddressNotifier, String>(
  SetupCheckedAddressNotifier.new,
);

class SetupCheckedAddressNotifier extends Notifier<String> {
  @override
  String build() => '';

  /// Đánh dấu [address] đã có luồng kiểm tra. Trả về `false` nếu địa chỉ này đã được đánh dấu rồi.
  bool claim(String address) {
    if (state == address) return false;
    state = address;
    return true;
  }

  /// Đánh dấu [address] mà không kiểm tra (dùng khi luồng được mở trực tiếp từ màn Cài đặt).
  void mark(String address) => state = address;
}
