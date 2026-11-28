import 'dart:async';

import 'package:muop_agent/core/config/server_config.dart';
import 'package:muop_agent/core/network/rest_client.dart';
import 'package:muop_agent/core/network/socket_gateway.dart';
import 'package:muop_agent/features/screen/domain/screen_entities.dart';
import 'package:muop_agent/features/screen/domain/screen_repository.dart';

/// Thời gian server giữ một yêu cầu khung khi chưa có khung mới (ms)
const _frameWaitMs = 2500;

/// Nghỉ trước khi thử lại khi mất kết nối; tăng dần tới mức trần
const _retryBase = Duration(seconds: 1);
const _retryMax = Duration(seconds: 8);

class ScreenRepositoryImpl implements ScreenRepository {
  /// [baseUrlOf] mặc định là địa chỉ server đang kết nối; test truyền địa chỉ giả
  ScreenRepositoryImpl(SocketGateway gateway, {String Function()? baseUrlOf})
      : _gateway = gateway,
        _baseUrlOf = baseUrlOf ?? (() => gateway.connectedBaseUrl) {
    gateway.on('screen:status').listen((data) {
      if (data is! Map) return;
      _current = ScreenStatus.fromJson(Map<String, dynamic>.from(data));
      if (!_controller.isClosed) _controller.add(_current);
    });
  }

  final SocketGateway _gateway;
  final String Function() _baseUrlOf;
  ScreenStatus _current = const ScreenStatus();

  @override
  void refresh() => _gateway.emit('request-screen-status');

  final StreamController<ScreenStatus> _controller =
      StreamController<ScreenStatus>.broadcast();

  @override
  ScreenStatus get current => _current;

  @override
  Stream<ScreenStatus> get statusStream => _controller.stream;

  @override
  Stream<ScreenFrame> watchFrames() {
    final out = StreamController<ScreenFrame>();
    var stopped = false;
    out.onCancel = () => stopped = true;
    unawaited(_pollFrames(out, () => stopped || out.isClosed));
    return out.stream;
  }

  /// Vòng lấy khung: mỗi lượt hỏi khung có `seq` lớn hơn khung đã nhận. Server chỉ trả khi có khung mới
  /// (204 nếu hết giờ đợi), nên không có vòng lặp chờ bận. Lỗi mạng thì nghỉ rồi thử lại.
  Future<void> _pollFrames(
    StreamController<ScreenFrame> out,
    bool Function() stop,
  ) async {
    var after = 0;
    var failures = 0;
    while (!stop()) {
      final base = _baseUrlOf();
      if (base.isEmpty) {
        await Future<void>.delayed(_retryBase);
        continue;
      }
      try {
        final reply = await httpRequest(
          'GET',
          Uri.parse(
            '${normalizeBaseUrl(base)}/api/screen/frame?after=$after&wait=$_frameWaitMs',
          ),
          timeout: const Duration(milliseconds: _frameWaitMs + 5000),
        );
        failures = 0;
        if (reply.status == 200) {
          final seq = int.tryParse(reply.headers['x-frame-seq'] ?? '') ?? after + 1;
          after = seq;
          if (!stop()) out.add(ScreenFrame(seq: seq, jpeg: reply.bytes));
        } else if (reply.status != 204) {
          throw StateError('HTTP ${reply.status}');
        }
      } catch (_) {
        failures++;
        final wait = _retryBase * (1 << (failures - 1).clamp(0, 3));
        await Future<void>.delayed(wait > _retryMax ? _retryMax : wait);
      }
    }
    if (!out.isClosed) await out.close();
  }

  @override
  String viewerUrl(String serverViewerUrl) {
    final served = Uri.tryParse(serverViewerUrl);
    final base = _baseUrlOf();
    if (served == null || served.host.isEmpty) return serverViewerUrl;
    if (base.isEmpty) return serverViewerUrl;
    final app = Uri.tryParse(normalizeBaseUrl(base));
    final host = app?.host ?? '';
    if (host.isEmpty) return serverViewerUrl;
    return served.replace(host: host).toString();
  }
}
