import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:muop_agent/core/config/server_config.dart';
import 'package:muop_agent/core/network/json_utils.dart';
import 'package:muop_agent/core/network/rest_client.dart';
import 'package:muop_agent/core/network/socket_gateway.dart';
import 'package:muop_agent/features/chat/domain/chat_entities.dart';
import 'package:muop_agent/features/sessions/domain/session_entities.dart';
import 'package:muop_agent/features/sessions/domain/session_repository.dart';

class SessionRepositoryImpl implements SessionRepository {
  final SocketGateway _gateway;
  SessionRepositoryImpl(this._gateway) {
    _gateway.on('sessions:list').listen((data) {
      if (_sessionsListController.isClosed) return;
      try {
        final map = asJsonMap(data);
        if (map == null) return;
        final list = <ConversationSession>[];
        if (map['sessions'] is List) {
          for (final item in map['sessions'] as List) {
            if (item is Map) {
              list.add(ConversationSession.fromJson(Map<String, dynamic>.from(item)));
            }
          }
        }
        _sessionsListController.add(list);
      } catch (_) {}
    });
    _gateway.on('meta:update').listen((data) {
      if (_metaController.isClosed) return;
      try {
        final map = asJsonMap(data);
        if (map != null) _metaController.add(ServerMeta.fromJson(map));
      } catch (_) {}
    });
    _gateway.on('streams:update').listen((data) {
      if (_activeStreamsController.isClosed) return;
      try {
        final map = asJsonMap(data);
        if (map == null) return;
        _activeStreamsController.add(parseActiveStreams(map['activeStreams']));
      } catch (_) {}
    });
    _gateway.on('session:removed').listen((data) {
      if (_sessionRemovedController.isClosed) return;
      try {
        final map = asJsonMap(data);
        final id = map?['id'];
        if (id is String && id.isNotEmpty) _sessionRemovedController.add(id);
      } catch (_) {}
    });
    _gateway.on('session:update').listen((data) {
      if (_sessionUpdateController.isClosed || data == null) return;
      try {
        Map<String, dynamic>? map;
        if (data is Map<String, dynamic>) {
          map = data;
        } else if (data is Map) {
          map = Map<String, dynamic>.from(data);
        } else if (data is String) {
          map = jsonDecode(data) as Map<String, dynamic>;
        }
        if (map != null) {
          final session = ConversationSession.fromJson(map);
          _sessionUpdateController.add(session);
        }
      } catch (_) {}
    });
    _gateway.on('quotas:update').listen((data) {
      if (_quotasUpdateController.isClosed || data == null) return;
      try {
        List? list;
        if (data is List) {
          list = data;
        } else if (data is String) {
          list = jsonDecode(data) as List?;
        }
        if (list != null) {
          final quotas = list
              .map((item) => ModelQuotaGroup.fromJson(item is Map<String, dynamic>
                  ? item
                  : Map<String, dynamic>.from(item as Map)))
              .toList();
          _quotasUpdateController.add(quotas);
        }
      } catch (_) {}
    });
    _gateway.on('fileschange').listen((data) {
      if (_filesChangeController.isClosed || data == null) return;
      try {
        Map<String, dynamic> sessionMap;
        if (data is Map<String, dynamic>) {
          sessionMap = data;
        } else if (data is String) {
          sessionMap = jsonDecode(data) as Map<String, dynamic>;
        } else {
          sessionMap = Map<String, dynamic>.from(data as Map);
        }
        final session = ConversationSession.fromJson(sessionMap);
        _filesChangeController.add(session);
      } catch (_) {}
    });
    _gateway.connectEvents.listen((_) => _requestSyncOn());
  }

  final StreamController<List<ConversationSession>> _sessionsListController =
      StreamController<List<ConversationSession>>.broadcast();

  final StreamController<ServerMeta> _metaController =
      StreamController<ServerMeta>.broadcast();

  final StreamController<Map<String, ChatTurnStreamState>> _activeStreamsController =
      StreamController<Map<String, ChatTurnStreamState>>.broadcast();

  final StreamController<String> _sessionRemovedController =
      StreamController<String>.broadcast();

  final StreamController<ConversationSession> _sessionUpdateController =
      StreamController<ConversationSession>.broadcast();

  final StreamController<List<ModelQuotaGroup>> _quotasUpdateController =
      StreamController<List<ModelQuotaGroup>>.broadcast();

  final StreamController<ConversationSession> _filesChangeController =
      StreamController<ConversationSession>.broadcast();

  /// Tóm tắt toàn bộ conversation (`sessions:list`), không kèm steps
  @override
  Stream<List<ConversationSession>> get sessionsListStream => _sessionsListController.stream;

  /// Metadata server: project, model, máy chủ (`meta:update`)
  @override
  Stream<ServerMeta> get metaStream => _metaController.stream;

  /// Các lượt chat đang chạy (`streams:update`), là danh sách đầy đủ tại thời điểm phát
  @override
  Stream<Map<String, ChatTurnStreamState>> get activeStreamsStream => _activeStreamsController.stream;

  /// Id conversation vừa bị xoá khỏi đĩa (`session:removed`)
  @override
  Stream<String> get sessionRemovedStream => _sessionRemovedController.stream;

  @override
  Stream<ConversationSession> get sessionUpdateStream =>
      _sessionUpdateController.stream;

  @override
  Stream<List<ModelQuotaGroup>> get quotasUpdateStream =>
      _quotasUpdateController.stream;

  @override
  Stream<ConversationSession> get filesChangeStream => _filesChangeController.stream;

  /// Join vào room conversation để nhận file changes updates từ server
  @override
  void joinConversation(String conversationId) {
    if (_gateway.connected) {
      _gateway.emit('join-conversation', {'conversationId': conversationId});
    }
  }

  /// Leave khỏi room conversation cũ
  @override
  void leaveConversation(String conversationId) {
    if (_gateway.connected) {
      _gateway.emit('leave-conversation', {'conversationId': conversationId});
    }
  }

  /// Danh sách conversation qua HTTP `/api/sessions` (dùng khi socket chưa kết nối)
  @override
  Future<List<ConversationSession>?> fetchRemoteSessions(String address) async {
    final map = await restGetJson(address, '/api/sessions');
    if (map == null || map['sessions'] is! List) return null;
    return [
      for (final item in map['sessions'] as List)
        if (item is Map) ConversationSession.fromJson(Map<String, dynamic>.from(item)),
    ];
  }

  /// Metadata server qua HTTP `/api/meta`
  @override
  Future<ServerMeta?> fetchRemoteMeta(String address) async {
    final map = await restGetJson(address, '/api/meta');
    if (map == null || map.containsKey('error')) return null;
    return ServerMeta.fromJson(map);
  }

  /// Các lượt đang chạy qua HTTP `/api/streams`
  @override
  Future<Map<String, ChatTurnStreamState>?> fetchRemoteStreams(String address) async {
    final map = await restGetJson(address, '/api/streams');
    if (map == null) return null;
    return parseActiveStreams(map['activeStreams']);
  }

  /// Lấy chi tiết toàn bộ các steps của một session cụ thể qua HTTP `/api/session?id=...`
  @override
  Future<ConversationSession?> fetchSessionDetail({
    required String address,
    required String sessionId,
  }) async {
    final baseUrl = normalizeBaseUrl(address);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 4);
    try {
      final uri = Uri.parse('$baseUrl/api/session?id=$sessionId');
      final req = await client.getUrl(uri);
      final resp = await req.close().timeout(const Duration(seconds: 6));
      if (resp.statusCode == 200) {
        final body = await resp.transform(utf8.decoder).join();
        final map = jsonDecode(body) as Map<String, dynamic>;
        return ConversationSession.fromJson(map);
      }
    } catch (_) {
    } finally {
      client.close(force: true);
    }
    return null;
  }

  /// Nạp một trang các bước cũ (AgentStep) phục vụ cuộn phân trang mượt mà
  @override
  Future<SessionStepsPageResult?> fetchSessionStepsPage({
    required String address,
    required String sessionId,
    int? beforeStepIndex,
    int limit = 30,
  }) async {
    final baseUrl = normalizeBaseUrl(address);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 4);
    try {
      final uri = Uri.parse('$baseUrl/api/session/steps').replace(
        queryParameters: {
          'id': sessionId.trim(),
          if (beforeStepIndex != null && beforeStepIndex > 0)
            'beforeStep': beforeStepIndex.toString(),
          'limit': limit.toString(),
        },
      );
      final req = await client.getUrl(uri);
      final resp = await req.close().timeout(const Duration(seconds: 6));
      if (resp.statusCode == 200) {
        final body = await resp.transform(utf8.decoder).join();
        final map = jsonDecode(body) as Map<String, dynamic>;
        return SessionStepsPageResult.fromJson(map);
      }
    } catch (_) {
    } finally {
      client.close(force: true);
    }
    return null;
  }

  @override
  void requestSync() {
    if (_gateway.connected) _requestSyncOn();
  }

  void _requestSyncOn() {
    _gateway.emit('request-sessions');
    _gateway.emit('request-meta');
    _gateway.emit('request-streams');
  }
}
