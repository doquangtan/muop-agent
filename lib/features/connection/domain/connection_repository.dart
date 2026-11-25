import 'dart:async';

import 'package:muop_agent/features/connection/domain/connection_entities.dart';
import 'package:muop_agent/features/connection/domain/lan_scan.dart';

/// Interface (domain) của feature connection. Presentation chỉ phụ thuộc interface này.
abstract class ConnectionRepository {
  Future<String> loadSavedServerAddress();

  /// Ghi nhận địa chỉ đang dùng (đưa lên đầu danh sách đã lưu)
  Future<void> saveServerAddress(String address);

  /// Các server đã kết nối trước đây, mới nhất đứng đầu
  Future<List<String>> loadSavedServers();

  /// Xóa một server khỏi danh sách đã lưu (kể cả tên đã nhớ)
  Future<void> removeSavedServer(String address);

  /// Tên máy (hostname) đã nhớ theo địa chỉ, lấy từ lần kết nối/kiểm tra thành công
  Future<Map<String, String>> loadServerNames();

  /// Ghi tên máy cho một địa chỉ đã lưu
  Future<void> saveServerName(String address, String name);

  Future<RemotePingResult> pingRemoteServer(String address);

  /// Quét các dải /24 của mạng LAN (cổng mặc định 8787) tìm máy chủ muop-agent.
  /// [onProgress] báo số IP đã thăm / tổng số IP.
  Future<List<LanServer>> scanLanServers({void Function(int done, int total)? onProgress});

  void connectSocket(String address);

  void disconnectSocket();

  bool get isSocketConnected;

  Stream<bool> get socketConnectionStream;
}
