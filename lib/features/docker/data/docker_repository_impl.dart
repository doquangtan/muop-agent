import 'dart:async';

import 'package:muop_agent/core/network/rest_client.dart';
import 'package:muop_agent/core/network/socket_gateway.dart';
import 'package:muop_agent/features/docker/domain/docker_entities.dart';
import 'package:muop_agent/features/docker/domain/docker_repository.dart';

class DockerRepositoryImpl implements DockerRepository {
  final SocketGateway _gateway;
  DockerRepositoryImpl(this._gateway) {
    _gateway.on('docker:logs:data').listen((data) {
      if (_dockerLogsController.isClosed || data is! Map) return;
      final map = Map<String, dynamic>.from(data);
      final lines = (map['lines'] as List?) ?? const [];
      _dockerLogsController.add(DockerLogsChunk(
        streamId: '${map['streamId'] ?? ''}',
        lines: lines.map((e) => '$e').toList(),
      ));
    });
    _gateway.on('docker:logs:end').listen((data) {
      if (_dockerLogsEndController.isClosed || data is! Map) return;
      final map = Map<String, dynamic>.from(data);
      _dockerLogsEndController.add(DockerLogsEnd(
        streamId: '${map['streamId'] ?? ''}',
        exitCode: (map['exitCode'] as num?)?.toInt(),
      ));
    });
  }

  final StreamController<DockerLogsChunk> _dockerLogsController =
      StreamController<DockerLogsChunk>.broadcast();

  final StreamController<DockerLogsEnd> _dockerLogsEndController =
      StreamController<DockerLogsEnd>.broadcast();

  /// Dòng log container (lọc theo streamId ở phía UI)
  @override
  Stream<DockerLogsChunk> get dockerLogsStream => _dockerLogsController.stream;

  @override
  Stream<DockerLogsEnd> get dockerLogsEndStream => _dockerLogsEndController.stream;

  /// Mở phiên Docker cho máy SSH đã lưu. Nếu máy đã có phiên thì gắn vào phiên đó.
  @override
  Future<DockerSessionResult> openDockerSession(
    String address, {
    required int hostId,
  }) =>
      _dockerCall(
        address,
        '/api/docker/sessions/open',
        {'hostId': hostId},
        timeout: const Duration(seconds: 60),
      );

  @override
  Stream<DockerSessionResult> watchDockerSession(String sessionId) {
    final controller = StreamController<DockerSessionResult>();
    StreamSubscription<dynamic>? updates;
    StreamSubscription<void>? reconnects;

    // Vào room của phiên trên server (gọi lại sau khi socket kết nối lại, vì server quên room khi ngắt)
    Future<void> join() async {
      try {
        await _gateway.emitWithAck('docker:session:watch', {'sessionId': sessionId});
      } catch (_) {
        // Chưa kết nối: sẽ đăng ký lại khi kết nối xong
      }
    }

    controller.onListen = () {
      updates = _gateway.on('docker:session:update').listen((data) {
        if (controller.isClosed || data is! Map) return;
        final map = Map<String, dynamic>.from(data);
        if ('${map['sessionId'] ?? ''}' != sessionId) return;
        controller.add(DockerSessionResult.fromJson(map, ended: map['ended'] == true));
      });
      reconnects = _gateway.connectEvents.listen((_) => unawaited(join()));
      unawaited(join());
    };
    controller.onCancel = () {
      updates?.cancel();
      reconnects?.cancel();
      _gateway.emit('docker:session:unwatch', {'sessionId': sessionId});
    };
    return controller.stream;
  }

  /// Quét lại container đang chạy của phiên (thao tác thủ công)
  @override
  Future<DockerSessionResult> scanDockerSession(
    String address,
    String sessionId,
  ) =>
      _dockerCall(
        address,
        '/api/docker/sessions/scan',
        {'sessionId': sessionId},
        timeout: const Duration(seconds: 45),
      );

  /// Dừng (`stop`) hoặc khởi động lại (`restart`) các container; có thể là cả compose project
  @override
  Future<DockerSessionResult> dockerContainerAction(
    String address, {
    required String sessionId,
    required String action,
    required List<String> containerIds,
  }) =>
      _dockerCall(
        address,
        '/api/docker/sessions/action',
        {
          'sessionId': sessionId,
          'action': action,
          'containerIds': containerIds,
        },
        timeout: const Duration(seconds: 320),
      );

  /// Kết thúc phiên Docker. Lần mở sau sẽ kết nối lại.
  @override
  Future<bool> closeDockerSession(String address, String sessionId) async {
    try {
      final (code, _) = await restRequest(
        address,
        'POST',
        '/api/docker/sessions/close',
        body: {'sessionId': sessionId},
      );
      return code == 200;
    } catch (_) {
      return false;
    }
  }

  /// Các phiên Docker đang chạy trên server (đồng bộ giữa các app)
  @override
  Future<List<DockerSession>> listDockerSessions(String address) async {
    final (code, body) = await restRequest(address, 'GET', '/api/docker/sessions');
    if (code != 200) throw Exception('Không tải được phiên Docker ($code)');
    final items = (body['items'] as List?) ?? const [];
    return items
        .whereType<Map>()
        .map((e) => DockerSession.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  // ---- LSP: gấp code, danh sách hàm, định nghĩa (Ctrl+click) ----

  /// Mở luồng log của một container trong phiên Docker (kênh SSH riêng trên server).
  /// Dòng log về qua [dockerLogsStream] theo streamId.
  @override
  Future<DockerLogsOpenResult> openDockerLogs({
    required String sessionId,
    required String containerId,
    int tail = 300,
  }) async {
    if (!_gateway.connected) {
      return const DockerLogsOpenResult(
        ok: false,
        streamId: '',
        error: 'Chưa kết nối tới server',
      );
    }
    try {
      final ack = await _gateway.emitWithAck('docker:logs:open', {
        'sessionId': sessionId,
        'containerId': containerId,
        'tail': tail,
      }).timeout(sshAckTimeout);
      final map = Map<String, dynamic>.from(
        (ack is List ? ack.first : ack) as Map,
      );
      return DockerLogsOpenResult(
        ok: map['ok'] == true,
        streamId: '${map['streamId'] ?? ''}',
        error: '${map['error'] ?? ''}',
      );
    } catch (e) {
      return DockerLogsOpenResult(ok: false, streamId: '', error: '$e');
    }
  }

  /// Báo server vẫn đang xem luồng log (không có ping quá 30 giây thì server tự dừng)
  @override
  void pingDockerLogs(String streamId) {
    _gateway.emit('docker:logs:ping', {'streamId': streamId});
  }

  /// Dừng luồng log và đóng kênh SSH trên server
  @override
  void closeDockerLogs(String streamId) {
    _gateway.emit('docker:logs:close', {'streamId': streamId});
  }

  Future<DockerSessionResult> _dockerCall(
    String address,
    String path,
    Map<String, dynamic> body, {
    required Duration timeout,
  }) async {
    try {
      final (code, json) = await restRequest(
        address,
        'POST',
        path,
        body: body,
        timeout: timeout,
      );
      return DockerSessionResult.fromJson(json, ended: code == 404);
    } catch (e) {
      return DockerSessionResult.failure('Không gọi được server: $e');
    }
  }
}
