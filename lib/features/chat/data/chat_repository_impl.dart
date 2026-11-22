import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:muop_agent/core/config/server_config.dart';
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
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 6);
    try {
      final uri = Uri.parse('$baseUrl/api/chat/send');
      final req = await client.postUrl(uri);
      req.headers.contentType = ContentType.json;
      req.write(
        jsonEncode({
          'prompt': prompt,
          'projectPath': projectPath,
          'conversationId': conversationId ?? '',
          'agentName': agentName ?? '',
          'model': model ?? '',
          'images': images.map((image) => image.toJson()).toList(),
        }),
      );
      // Ảnh base64 làm body lớn hơn nhiều, nên cho thời gian gửi lâu hơn khi có ảnh
      final sendTimeout = Duration(seconds: images.isEmpty ? 15 : 90);
      final resp = await req.close().timeout(sendTimeout);
      final body = await resp.transform(utf8.decoder).join();
      final map = jsonDecode(body) as Map<String, dynamic>;
      if (resp.statusCode == 200 && map['ok'] == true) {
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
        error: '${map['error'] ?? 'HTTP ${resp.statusCode}'}',
      );
    } catch (e) {
      return ChatSendResult(
        ok: false,
        conversationId: '',
        projectPath: projectPath,
        error: '$e',
      );
    } finally {
      client.close(force: true);
    }
  }

  /// Dừng lượt chạy Agent qua Rust Server
  @override
  Future<bool> stopRemoteChatTurn({
    required String address,
    required String conversationId,
  }) async {
    final baseUrl = normalizeBaseUrl(address);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 4);
    try {
      final uri = Uri.parse('$baseUrl/api/chat/stop');
      final req = await client.postUrl(uri);
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({'conversationId': conversationId}));
      final resp = await req.close().timeout(const Duration(seconds: 4));
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }
}
