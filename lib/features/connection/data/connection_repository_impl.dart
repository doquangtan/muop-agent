import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:muop_agent/core/config/server_config.dart';
import 'package:muop_agent/core/network/socket_gateway.dart';
import 'package:muop_agent/features/connection/domain/connection_entities.dart';
import 'package:muop_agent/features/connection/domain/connection_repository.dart';
import 'package:muop_agent/features/connection/domain/saved_servers.dart';

class ConnectionRepositoryImpl implements ConnectionRepository {
  final SocketGateway _gateway;
  ConnectionRepositoryImpl(this._gateway);

  File get _configFile =>
      File('${Directory.systemTemp.path}/muop_agent_remote_config.json');

  /// Đọc file cấu hình: `serverAddress` (địa chỉ đang dùng) và `servers` (danh sách đã kết nối).
  /// File cũ chỉ có `serverAddress` vẫn đọc được.
  Future<Map<String, dynamic>> _readConfig() async {
    try {
      if (await _configFile.exists()) {
        final decoded = jsonDecode(await _configFile.readAsString());
        if (decoded is Map<String, dynamic>) return decoded;
      }
    } catch (_) {}
    return <String, dynamic>{};
  }

  List<String> _servers(Map<String, dynamic> config) {
    final list = <String>[];
    if (config['servers'] is List) {
      for (final item in config['servers'] as List) {
        final s = '$item'.trim();
        if (s.isNotEmpty && !list.contains(s)) list.add(s);
      }
    }
    return list;
  }

  Future<void> _writeConfig(String address, List<String> servers) async {
    try {
      await _configFile.writeAsString(
        jsonEncode({
          'serverAddress': address,
          'servers': servers,
          'updatedAt': DateTime.now().toIso8601String(),
        }),
      );
    } catch (_) {}
  }

  @override
  Future<String> loadSavedServerAddress() async {
    final saved = '${(await _readConfig())['serverAddress'] ?? ''}'.trim();
    return saved.isNotEmpty ? saved : defaultHostAddress;
  }

  @override
  Future<void> saveServerAddress(String address) async {
    final clean =
        address.trim().isEmpty ? defaultHostAddress : address.trim();
    final config = await _readConfig();
    final known = _servers(config);
    final previous = '${config['serverAddress'] ?? ''}'.trim();
    if (previous.isNotEmpty && !known.contains(previous)) known.add(previous);
    await _writeConfig(clean, rememberServer(known, clean));
  }

  @override
  Future<List<String>> loadSavedServers() async {
    final config = await _readConfig();
    final servers = _servers(config);
    final current = '${config['serverAddress'] ?? ''}'.trim();
    // Địa chỉ đang dùng luôn có trong danh sách (kể cả file cũ chưa có `servers`)
    if (current.isNotEmpty && !servers.contains(current)) {
      return rememberServer(servers, current);
    }
    return servers;
  }

  @override
  Future<void> removeSavedServer(String address) async {
    final config = await _readConfig();
    final servers = forgetServer(_servers(config), address);
    final current = '${config['serverAddress'] ?? ''}'.trim();
    // Xóa địa chỉ đang dùng thì chuyển sang mục đầu còn lại (hoặc mặc định)
    final nextCurrent = current == address.trim()
        ? (servers.isNotEmpty ? servers.first : defaultHostAddress)
        : (current.isNotEmpty ? current : defaultHostAddress);
    await _writeConfig(nextCurrent, servers);
  }

  /// Kiểm tra kết nối tới Rust Server qua HTTP `/api/ping`
  @override
  Future<RemotePingResult> pingRemoteServer(String address) async {
    final baseUrl = normalizeBaseUrl(address);
    final sw = Stopwatch()..start();
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 3);
    try {
      final uri = Uri.parse('$baseUrl/api/ping');
      final req = await client.getUrl(uri);
      final resp = await req.close().timeout(const Duration(seconds: 4));
      sw.stop();
      if (resp.statusCode == 200) {
        final body = await resp.transform(utf8.decoder).join();
        final map = jsonDecode(body) as Map<String, dynamic>;
        final ips = <String>[];
        if (map['ips'] is List) {
          for (final item in map['ips'] as List) {
            ips.add('$item');
          }
        }
        return RemotePingResult(
          isOnline: true,
          latencyMs: sw.elapsedMilliseconds,
          hostname: '${map['hostname'] ?? 'Linux PC'}',
          engine: '${map['engine'] ?? 'rust-axum-socketio'}',
          lanIps: ips,
        );
      }
      return RemotePingResult(
        isOnline: false,
        latencyMs: sw.elapsedMilliseconds,
        errorMessage: 'HTTP ${resp.statusCode}',
      );
    } catch (e) {
      sw.stop();
      return RemotePingResult(
        isOnline: false,
        latencyMs: sw.elapsedMilliseconds,
        errorMessage: '$e',
      );
    } finally {
      client.close(force: true);
    }
  }

  @override
  void connectSocket(String address) {
    _gateway.connect(normalizeBaseUrl(address));
  }

  @override
  void disconnectSocket() => _gateway.disconnect();

  @override
  bool get isSocketConnected => _gateway.connected;

  @override
  Stream<bool> get socketConnectionStream => _gateway.statusStream;
}
