import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:muop_agent/core/config/server_config.dart';
import 'package:muop_agent/core/network/socket_gateway.dart';
import 'package:muop_agent/features/connection/domain/connection_entities.dart';
import 'package:muop_agent/features/connection/domain/connection_repository.dart';

class ConnectionRepositoryImpl implements ConnectionRepository {
  final SocketGateway _gateway;
  ConnectionRepositoryImpl(this._gateway);

  File get _configFile =>
      File('${Directory.systemTemp.path}/muop_agent_remote_config.json');

  @override
  Future<String> loadSavedServerAddress() async {
    try {
      if (await _configFile.exists()) {
        final content = await _configFile.readAsString();
        final map = jsonDecode(content) as Map<String, dynamic>;
        final saved = '${map['serverAddress'] ?? ''}'.trim();
        if (saved.isNotEmpty) return saved;
      }
    } catch (_) {}
    return defaultHostAddress;
  }

  @override
  Future<void> saveServerAddress(String address) async {
    try {
      final clean =
          address.trim().isEmpty ? defaultHostAddress : address.trim();
      await _configFile.writeAsString(
        jsonEncode({
          'serverAddress': clean,
          'updatedAt': DateTime.now().toIso8601String(),
        }),
      );
    } catch (_) {}
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
