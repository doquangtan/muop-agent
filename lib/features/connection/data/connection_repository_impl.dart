import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:muop_agent/core/config/server_config.dart';
import 'package:muop_agent/core/network/rest_client.dart';
import 'package:muop_agent/core/network/socket_gateway.dart';
import 'package:muop_agent/core/storage/local_config_store.dart';
import 'package:muop_agent/features/connection/domain/connection_entities.dart';
import 'package:muop_agent/features/connection/domain/connection_repository.dart';
import 'package:muop_agent/features/connection/domain/lan_scan.dart';
import 'package:muop_agent/features/connection/domain/saved_servers.dart';

class ConnectionRepositoryImpl implements ConnectionRepository {
  final SocketGateway _gateway;
  ConnectionRepositoryImpl(this._gateway);

  static const String _configFileName = 'muop_agent_remote_config.json';

  /// Đọc file cấu hình bền vững: `serverAddress` (địa chỉ đang dùng) và `servers` (danh sách đã kết nối).
  Future<Map<String, dynamic>> _readConfig() =>
      LocalConfigStore.readJson(_configFileName);

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

  /// Tên máy đã nhớ: `serverNames` là map địa chỉ → hostname
  Map<String, String> _names(Map<String, dynamic> config) {
    final names = <String, String>{};
    final raw = config['serverNames'];
    if (raw is Map) {
      raw.forEach((key, value) {
        final name = '$value'.trim();
        if ('$key'.trim().isNotEmpty && name.isNotEmpty) {
          names['$key'.trim()] = name;
        }
      });
    }
    return names;
  }

  Future<void> _writeConfig(
    String address,
    List<String> servers,
    Map<String, String> names,
  ) =>
      LocalConfigStore.writeJson(_configFileName, {
        'serverAddress': address,
        'servers': servers,
        'serverNames': names,
        'updatedAt': DateTime.now().toIso8601String(),
      });

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
    await _writeConfig(clean, rememberServer(known, clean), _names(config));
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
    final names = _names(config)..remove(address.trim());
    final current = '${config['serverAddress'] ?? ''}'.trim();
    // Xóa địa chỉ đang dùng thì chuyển sang mục đầu còn lại (hoặc mặc định)
    final nextCurrent = current == address.trim()
        ? (servers.isNotEmpty ? servers.first : defaultHostAddress)
        : (current.isNotEmpty ? current : defaultHostAddress);
    await _writeConfig(nextCurrent, servers, names);
  }

  @override
  Future<Map<String, String>> loadServerNames() async =>
      _names(await _readConfig());

  @override
  Future<void> saveServerName(String address, String name) async {
    final clean = address.trim();
    final hostname = name.trim();
    if (clean.isEmpty || hostname.isEmpty) return;
    final config = await _readConfig();
    final names = _names(config)..[clean] = hostname;
    await _writeConfig(
      '${config['serverAddress'] ?? ''}'.trim().isNotEmpty
          ? '${config['serverAddress']}'.trim()
          : defaultHostAddress,
      _servers(config),
      names,
    );
  }

  /// Quét mạng LAN của máy client: thăm `/api/ping` cổng 8787 trên mọi IP của các dải /24
  /// (song song, tối đa [_scanConcurrency] kết nối cùng lúc).
  @override
  Future<List<LanServer>> scanLanServers({
    void Function(int done, int total)? onProgress,
  }) async {
    // Trình duyệt không liệt kê được giao diện mạng: web không quét LAN
    if (kIsWeb) return const [];
    final locals = <String>[];
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final iface in interfaces) {
        if (isVirtualInterfaceName(iface.name)) continue;
        for (final addr in iface.addresses) {
          locals.add(addr.address);
        }
      }
    } catch (_) {}
    final hosts = lanHostsFor(locals);
    final total = hosts.length;
    final found = <LanServer>[];
    var next = 0;
    var done = 0;

    Future<void> worker() async {
      while (next < hosts.length) {
        final ip = hosts[next++];
        final server = await _probeLanServer(ip);
        if (server != null) found.add(server);
        done++;
        onProgress?.call(done, total);
      }
    }

    await Future.wait([
      for (var i = 0; i < _scanConcurrency; i++) worker(),
    ]);
    return sortByIp(found);
  }

  static const int _scanConcurrency = 48;
  static const Duration _scanTimeout = Duration(milliseconds: 700);

  /// Thăm `http://<ip>:8787/api/ping`; trả về server nếu đúng là muop-agent
  Future<LanServer?> _probeLanServer(String ip) async {
    try {
      final uri = Uri.parse('http://$ip:$defaultBridgePort/api/ping');
      final reply = await httpRequest('GET', uri, timeout: _scanTimeout);
      if (reply.status != 200) return null;
      final decoded = jsonDecode(reply.text);
      if (decoded is! Map || !isMuopServerPing(decoded)) return null;
      return LanServer(
        ip: ip,
        hostname: '${decoded['hostname'] ?? ''}',
        engine: '${decoded['engine'] ?? ''}',
      );
    } catch (_) {
      return null;
    }
  }

  /// Kiểm tra kết nối tới Rust Server qua HTTP `/api/ping`
  @override
  Future<RemotePingResult> pingRemoteServer(String address) async {
    final baseUrl = normalizeBaseUrl(address);
    final sw = Stopwatch()..start();
    try {
      final uri = Uri.parse('$baseUrl/api/ping');
      final reply = await httpRequest('GET', uri, timeout: const Duration(seconds: 4));
      sw.stop();
      if (reply.status == 200) {
        final map = jsonDecode(reply.text) as Map<String, dynamic>;
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
        errorMessage: 'HTTP ${reply.status}',
      );
    } catch (e) {
      sw.stop();
      return RemotePingResult(
        isOnline: false,
        latencyMs: sw.elapsedMilliseconds,
        errorMessage: '$e',
      );
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
