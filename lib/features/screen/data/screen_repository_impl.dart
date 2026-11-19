import 'dart:async';

import 'package:muop_agent/core/config/server_config.dart';
import 'package:muop_agent/core/network/socket_gateway.dart';
import 'package:muop_agent/features/screen/domain/screen_entities.dart';
import 'package:muop_agent/features/screen/domain/screen_repository.dart';

class ScreenRepositoryImpl implements ScreenRepository {
  ScreenRepositoryImpl(SocketGateway gateway) : _gateway = gateway {
    gateway.on('screen:status').listen((data) {
      if (data is! Map) return;
      _current = ScreenStatus.fromJson(Map<String, dynamic>.from(data));
      if (!_controller.isClosed) _controller.add(_current);
    });
  }

  final SocketGateway _gateway;
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
  String playbackUrl(String serverRtspUrl) {
    final served = Uri.tryParse(serverRtspUrl);
    if (served == null || served.host.isEmpty) return serverRtspUrl;
    if (_gateway.connectedBaseUrl.isEmpty) return serverRtspUrl;
    final app = Uri.tryParse(normalizeBaseUrl(_gateway.connectedBaseUrl));
    final host = app?.host ?? '';
    if (host.isEmpty) return serverRtspUrl;
    return served.replace(host: host).toString();
  }
}
