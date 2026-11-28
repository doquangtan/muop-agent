import 'dart:async';
import 'dart:convert';

import 'package:muop_agent/core/config/server_config.dart';
import 'package:muop_agent/core/network/rest_client.dart';
import 'package:muop_agent/core/network/socket_gateway.dart';
import 'package:muop_agent/features/chat/domain/chat_entities.dart';
import 'package:muop_agent/features/chat/domain/chat_repository.dart';

class ChatRepositoryImpl implements ChatRepository {
  final SocketGateway _gateway;
  ChatRepositoryImpl(this._gateway) {
    _gateway.on('chat:stream').listen(_onStream);
    // Lượt chạy trên máy phụ (qua cầu nối) đi vào cùng luồng, khóa theo conversation id
    _gateway.on('bridge:chat:stream').listen(_onStream);
  }

  void _onStream(dynamic data) {
    if (_chatStreamController.isClosed || data == null) return;
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
        final streamState = ChatTurnStreamState.fromJson(map);
        _chatStreamController.add(streamState);
      }
    } catch (_) {}
  }

  final StreamController<ChatTurnStreamState> _chatStreamController =
      StreamController<ChatTurnStreamState>.broadcast();

  @override
  Stream<ChatTurnStreamState> get chatStream => _chatStreamController.stream;

  /// Gửi tin nhắn trò chuyện với Agent tới Rust Server
  @override
  Future<ChatSendResult> sendRemoteChatPrompt({
    required String address,
    required String prompt,
    required String projectPath,
    String? conversationId,
    String? agentName,
    String? model,
    List<ChatImageAttachment> images = const [],
  }) async {
    final baseUrl = normalizeBaseUrl(address);
    try {
      // Ảnh base64 làm body lớn hơn nhiều, nên cho thời gian gửi lâu hơn khi có ảnh
      final sendTimeout = Duration(seconds: images.isEmpty ? 15 : 90);
      final reply = await httpRequest(
        'POST',
        Uri.parse('$baseUrl/api/chat/send'),
        json: {
          'prompt': prompt,
          'projectPath': projectPath,
          'conversationId': conversationId ?? '',
          'agentName': agentName ?? '',
          'model': model ?? '',
          'images': images.map((image) => image.toJson()).toList(),
        },
        timeout: sendTimeout,
      );
      final map = jsonDecode(reply.text) as Map<String, dynamic>;
      if (reply.status == 200 && map['ok'] == true) {
        return ChatSendResult(
          ok: true,
          conversationId: '${map['conversationId'] ?? ''}',
          projectPath: '${map['projectPath'] ?? projectPath}',
          source: '${map['source'] ?? ''}',
        );
      }
      return ChatSendResult(
        ok: false,
        conversationId: '',
        projectPath: projectPath,
        error: '${map['error'] ?? 'HTTP ${reply.status}'}',
      );
    } catch (e) {
      return ChatSendResult(
        ok: false,
        conversationId: '',
        projectPath: projectPath,
        error: '$e',
      );
    }
  }

  /// Dừng lượt chạy Agent qua Rust Server
  @override
  Future<bool> stopRemoteChatTurn({
    required String address,
    required String conversationId,
  }) async {
    final baseUrl = normalizeBaseUrl(address);
    try {
      final reply = await httpRequest(
        'POST',
        Uri.parse('$baseUrl/api/chat/stop'),
        json: {'conversationId': conversationId},
        timeout: const Duration(seconds: 4),
      );
      return reply.status == 200;
    } catch (_) {
      return false;
    }
  }
}
