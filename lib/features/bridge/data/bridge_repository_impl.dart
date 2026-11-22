import 'dart:async';

import 'package:muop_agent/core/network/rest_client.dart';
import 'package:muop_agent/core/network/socket_gateway.dart';
import 'package:muop_agent/features/bridge/domain/bridge_entities.dart';
import 'package:muop_agent/features/bridge/domain/bridge_repository.dart';
import 'package:muop_agent/features/interactions/domain/interaction_entities.dart';

/// Sự kiện `bridge:*` mà màn Cầu nối dùng (xem `FORWARDED_EVENTS` ở server/src/bridge/mod.rs)
const _watchedEvents = [
  'bridge:status',
  'bridge:chat:stream',
  'bridge:session:update',
];

class BridgeRepositoryImpl implements BridgeRepository {
  BridgeRepositoryImpl(this._socket);

  final SocketGateway _socket;

  /// Máy A nhận lệnh có ack tối đa 30 giây (xem server/src/bridge), cộng thời gian mạng
  static const _sendTimeout = Duration(seconds: 60);

  @override
  Future<BridgeStatus> fetchStatus(String address) async {
    try {
      final (_, body) = await restRequest(address, 'GET', '/api/bridge/status');
      return BridgeStatus.fromJson(body);
    } catch (e) {
      return BridgeStatus.failure('Không gọi được server: $e');
    }
  }

  @override
  Future<BridgeStatus> setPeer(String address, {required String url}) async {
    try {
      final (_, body) = await restRequest(
        address,
        'POST',
        '/api/bridge/peer',
        body: {'url': url},
      );
      return BridgeStatus.fromJson(body);
    } catch (e) {
      return BridgeStatus.failure('Không gọi được server: $e');
    }
  }

  @override
  Future<BridgeSendResult> sendPrompt(
    String address, {
    required String prompt,
    required String projectPath,
    String conversationId = '',
    String model = '',
    List<Map<String, dynamic>> images = const [],
  }) async {
    try {
      final (_, body) = await restRequest(
        address,
        'POST',
        '/api/bridge/send',
        body: {
          'prompt': prompt,
          'projectPath': projectPath,
          'conversationId': conversationId,
          'model': model,
          'agentName': '',
          'images': images,
        },
        timeout: _sendTimeout,
      );
      return BridgeSendResult.fromJson(body);
    } catch (e) {
      return BridgeSendResult.failure('Không gọi được server: $e');
    }
  }

  @override
  Future<PeerMeta> fetchPeerMeta(String address) async {
    try {
      final (_, body) = await restRequest(address, 'GET', '/api/bridge/meta');
      return PeerMeta.fromJson(body);
    } catch (e) {
      return PeerMeta.failure('Không gọi được server: $e');
    }
  }

  @override
  Future<List<Map<String, dynamic>>> fetchPeerSessions(String address) async {
    try {
      final (_, body) = await restRequest(address, 'GET', '/api/bridge/sessions');
      final raw = body['sessions'];
      if (raw is! List) return const [];
      return [
        for (final item in raw)
          if (item is Map) Map<String, dynamic>.from(item),
      ];
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<Map<String, dynamic>?> fetchPeerSession(
    String address, {
    required String id,
  }) async {
    try {
      final (code, body) = await restRequest(
        address,
        'GET',
        '/api/bridge/session?id=${Uri.encodeQueryComponent(id)}',
      );
      if (code != 200 || body['ok'] == false || body['id'] == null) return null;
      return body;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<BridgeSendResult> stopTurn(
    String address, {
    required String conversationId,
  }) async {
    try {
      final (_, body) = await restRequest(
        address,
        'POST',
        '/api/bridge/stop',
        body: {'conversationId': conversationId},
        timeout: _sendTimeout,
      );
      return BridgeSendResult(
        ok: body['ok'] == true,
        error: (body['error'] ?? '') as String,
        conversationId: conversationId,
      );
    } catch (e) {
      return BridgeSendResult.failure('Không gọi được server: $e');
    }
  }

  @override
  Future<({PendingClaudeInteraction? interaction, String error})> fetchPendingInteraction(
    String address, {
    required String conversationId,
  }) async {
    try {
      final (code, body) = await restRequest(
        address,
        'GET',
        '/api/bridge/pending?conversationId=${Uri.encodeQueryComponent(conversationId)}',
      );
      if (body['ok'] == false) {
        return (
          interaction: null,
          error: '${body['error'] ?? 'HTTP $code'}',
        );
      }
      final pending = body['pending'];
      if (pending is Map) {
        return (
          interaction: PendingClaudeInteraction.fromJson(Map<String, dynamic>.from(pending)),
          error: '',
        );
      }
      return (interaction: null, error: '');
    } catch (e) {
      return (interaction: null, error: 'Không gọi được server: $e');
    }
  }

  @override
  Future<String?> respondInteraction(
    String address, {
    required String conversationId,
    required String toolUseId,
    required String projectPath,
    required String model,
    required String decision,
    List<Map<String, String>> answers = const [],
    String feedback = '',
  }) async {
    try {
      final (code, body) = await restRequest(
        address,
        'POST',
        '/api/bridge/respond',
        body: {
          'conversationId': conversationId,
          'toolUseId': toolUseId,
          'projectPath': projectPath,
          'model': model,
          'answers': answers,
          'decision': decision,
          'feedback': feedback,
        },
        timeout: _sendTimeout,
      );
      if (body['ok'] == false || code >= 400) {
        return '${body['error'] ?? 'HTTP $code'}';
      }
      return null;
    } catch (e) {
      return 'Không gửi được phản hồi: $e';
    }
  }

  @override
  Stream<BridgeEvent> watchEvents() {
    final controller = StreamController<BridgeEvent>.broadcast();
    final subscriptions = <StreamSubscription<dynamic>>[];
    for (final name in _watchedEvents) {
      subscriptions.add(_socket.on(name).listen((raw) {
        controller.add(BridgeEvent(name: name, data: _normalize(raw)));
      }));
    }
    controller.onCancel = () {
      for (final sub in subscriptions) {
        sub.cancel();
      }
    };
    return controller.stream;
  }

  /// Socket.IO có thể đưa payload bọc trong danh sách đối số; lấy đối số đầu và chuẩn hoá thành Map
  Object? _normalize(Object? raw) {
    var value = raw;
    if (value is List && value.isNotEmpty) value = value.first;
    if (value is Map) return Map<String, dynamic>.from(value);
    return value;
  }
}
