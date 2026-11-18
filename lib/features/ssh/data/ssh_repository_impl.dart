import 'dart:async';
import 'dart:convert';

import 'package:muop_agent/core/network/rest_client.dart';
import 'package:muop_agent/core/network/socket_gateway.dart';
import 'package:muop_agent/features/ssh/domain/ssh_entities.dart';
import 'package:muop_agent/features/ssh/domain/ssh_repository.dart';

class SshRepositoryImpl implements SshRepository {
  final SocketGateway _gateway;
  SshRepositoryImpl(this._gateway) {
    _gateway.on('ssh:data').listen((data) {
      if (_sshDataController.isClosed || data is! Map) return;
      try {
        final map = Map<String, dynamic>.from(data);
        _sshDataController.add(SshTerminalData(
          sessionId: '${map['sessionId'] ?? ''}',
          bytes: base64Decode('${map['data'] ?? ''}'),
        ));
      } catch (_) {}
    });
    _gateway.on('ssh:closed').listen((data) {
      if (_sshClosedController.isClosed || data is! Map) return;
      final map = Map<String, dynamic>.from(data);
      _sshClosedController.add(SshTerminalClosed(
        sessionId: '${map['sessionId'] ?? ''}',
        exitCode: (map['exitCode'] as num?)?.toInt(),
      ));
    });
  }

  final StreamController<SshTerminalData> _sshDataController =
      StreamController<SshTerminalData>.broadcast();

  final StreamController<SshTerminalClosed> _sshClosedController =
      StreamController<SshTerminalClosed>.broadcast();

  /// Đầu ra của các phiên terminal SSH (lọc theo sessionId)
  @override
  Stream<SshTerminalData> get sshDataStream => _sshDataController.stream;

  @override
  Stream<SshTerminalClosed> get sshClosedStream => _sshClosedController.stream;

  /// Danh sách máy SSH đã lưu trên server
  @override
  Future<List<SshHost>> fetchSshHosts(String address) async {
    final (code, body) = await restRequest(address, 'GET', '/api/ssh/hosts');
    if (code != 200) throw Exception('Không tải được danh sách SSH ($code)');
    final items = (body['items'] as List?) ?? const [];
    return items
        .whereType<Map>()
        .map((e) => SshHost.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  /// Thêm (id = 0) hoặc sửa máy SSH. Trả về thông báo lỗi, null nếu thành công.
  @override
  Future<String?> saveSshHost(
    String address, {
    required int id,
    required String name,
    required String host,
    required int port,
    required String username,
    required String authType,
    required String password,
    required String privateKey,
  }) async {
    final (code, body) = await restRequest(
      address,
      'POST',
      '/api/ssh/hosts/save',
      body: {
        'id': id,
        'name': name,
        'host': host,
        'port': port,
        'username': username,
        'authType': authType,
        'password': password,
        'privateKey': privateKey,
      },
    );
    if (code == 200) return null;
    return '${body['error'] ?? 'Lỗi không xác định ($code)'}';
  }

  @override
  Future<bool> deleteSshHost(String address, int id) async {
    final (code, _) = await restRequest(
      address,
      'POST',
      '/api/ssh/hosts/delete',
      body: {'id': id},
    );
    return code == 200;
  }

  /// Chạy một lệnh trên máy SSH đã lưu
  @override
  Future<SshExecResult> execSshCommand(
    String address, {
    required int hostId,
    required String command,
    int timeoutSecs = 30,
  }) async {
    try {
      final (_, body) = await restRequest(
        address,
        'POST',
        '/api/ssh/exec',
        body: {
          'hostId': hostId,
          'command': command,
          'timeoutSecs': timeoutSecs,
        },
        timeout: Duration(seconds: timeoutSecs + 10),
      );
      return SshExecResult.fromJson(body);
    } catch (e) {
      return SshExecResult(
        ok: false,
        exitCode: null,
        stdout: '',
        stderr: '',
        error: 'Không gọi được server: $e',
      );
    }
  }

  // ---- Docker qua SSH: phiên giữ sẵn trên server, tách biệt với phiên terminal ----

  /// Mở phiên terminal SSH tương tác qua socket (server join socket vào room của phiên)
  @override
  Future<SshTerminalOpenResult> openSshTerminal(
    int hostId, {
    int cols = 100,
    int rows = 30,
  }) async {
    if (!_gateway.connected) {
      return const SshTerminalOpenResult(
        ok: false,
        sessionId: '',
        error: 'Chưa kết nối tới server',
      );
    }
    try {
      final ack = await _gateway.emitWithAck('ssh:open', {
        'hostId': hostId,
        'cols': cols,
        'rows': rows,
      }).timeout(sshAckTimeout);
      final map = Map<String, dynamic>.from(
        (ack is List ? ack.first : ack) as Map,
      );
      return SshTerminalOpenResult(
        ok: map['ok'] == true,
        sessionId: '${map['sessionId'] ?? ''}',
        error: '${map['error'] ?? ''}',
      );
    } catch (e) {
      return SshTerminalOpenResult(ok: false, sessionId: '', error: '$e');
    }
  }

  /// Các phiên terminal SSH đang chạy trên server
  @override
  Future<List<SshTerminalSession>> listSshTerminalSessions(
    String address,
  ) async {
    try {
      final (code, body) = await restRequest(
        address,
        'GET',
        '/api/ssh/sessions',
        timeout: const Duration(seconds: 5),
      );
      if (code != 200) return const [];
      final items = (body['items'] as List?) ?? const [];
      return items
          .whereType<Map>()
          .map((e) => SshTerminalSession.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// Gắn socket vào phiên đang chạy, nhận lại đầu ra đã đệm
  @override
  Future<SshTerminalAttachResult> attachSshTerminal(String sessionId) async {
    if (!_gateway.connected) {
      return const SshTerminalAttachResult(
        ok: false,
        sessionId: '',
        hostName: '',
        buffer: [],
        error: 'Chưa kết nối tới server',
      );
    }
    try {
      final ack = await _gateway.emitWithAck(
        'ssh:attach',
        {'sessionId': sessionId},
      ).timeout(sshAckTimeout);
      final map = Map<String, dynamic>.from(
        (ack is List ? ack.first : ack) as Map,
      );
      return SshTerminalAttachResult(
        ok: map['ok'] == true,
        sessionId: '${map['sessionId'] ?? ''}',
        hostName: '${map['hostName'] ?? ''}',
        buffer: map['buffer'] is String && (map['buffer'] as String).isNotEmpty
            ? base64Decode(map['buffer'] as String)
            : const [],
        error: '${map['error'] ?? ''}',
      );
    } catch (e) {
      return SshTerminalAttachResult(
        ok: false,
        sessionId: '',
        hostName: '',
        buffer: const [],
        error: '$e',
      );
    }
  }

  /// Gửi dữ liệu bàn phím vào phiên terminal
  @override
  void sendSshInput(String sessionId, List<int> bytes) {
    _gateway.emit('ssh:input', {
      'sessionId': sessionId,
      'data': base64Encode(bytes),
    });
  }

  @override
  void resizeSshTerminal(String sessionId, int cols, int rows) {
    _gateway.emit('ssh:resize', {
      'sessionId': sessionId,
      'cols': cols,
      'rows': rows,
    });
  }

  @override
  void closeSshTerminal(String sessionId) {
    _gateway.emit('ssh:close', {'sessionId': sessionId});
  }
}
