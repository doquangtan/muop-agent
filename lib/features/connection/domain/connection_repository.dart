import 'dart:async';

import 'package:muop_agent/features/connection/domain/connection_entities.dart';

/// Interface (domain) của feature connection. Presentation chỉ phụ thuộc interface này.
abstract class ConnectionRepository {
  Future<String> loadSavedServerAddress();

  /// Ghi nhận địa chỉ đang dùng (đưa lên đầu danh sách đã lưu)
  Future<void> saveServerAddress(String address);

  /// Các server đã kết nối trước đây, mới nhất đứng đầu
  Future<List<String>> loadSavedServers();

  /// Xóa một server khỏi danh sách đã lưu
  Future<void> removeSavedServer(String address);

  Future<RemotePingResult> pingRemoteServer(String address);

  void connectSocket(String address);

  void disconnectSocket();

  bool get isSocketConnected;

  Stream<bool> get socketConnectionStream;
}
