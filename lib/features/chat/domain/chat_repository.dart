import 'dart:async';

import 'package:muop_agent/features/chat/domain/chat_entities.dart';

/// Interface (domain) của feature chat. Presentation chỉ phụ thuộc interface này.
abstract class ChatRepository {
  Stream<ChatTurnStreamState> get chatStream;

  Future<ChatSendResult> sendRemoteChatPrompt({
    required String address,
    required String prompt,
    required String projectPath,
    String? conversationId,
    String? agentName,
    String? model,
  });

  Future<bool> stopRemoteChatTurn({
    required String address,
    required String conversationId,
  });
}
