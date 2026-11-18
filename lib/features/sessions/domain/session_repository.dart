import 'dart:async';

import 'package:muop_agent/features/chat/domain/chat_entities.dart';
import 'package:muop_agent/features/sessions/domain/session_entities.dart';

/// Interface (domain) của feature sessions. Presentation chỉ phụ thuộc interface này.
abstract class SessionRepository {
  Stream<List<ConversationSession>> get sessionsListStream;

  Stream<ServerMeta> get metaStream;

  Stream<Map<String, ChatTurnStreamState>> get activeStreamsStream;

  Stream<String> get sessionRemovedStream;

  Stream<ConversationSession> get sessionUpdateStream;

  Stream<List<ModelQuotaGroup>> get quotasUpdateStream;

  Stream<ConversationSession> get filesChangeStream;

  void joinConversation(String conversationId);

  void leaveConversation(String conversationId);

  Future<List<ConversationSession>?> fetchRemoteSessions(String address);

  Future<ServerMeta?> fetchRemoteMeta(String address);

  Future<Map<String, ChatTurnStreamState>?> fetchRemoteStreams(String address);

  Future<ConversationSession?> fetchSessionDetail({
    required String address,
    required String sessionId,
  });

  Future<SessionStepsPageResult?> fetchSessionStepsPage({
    required String address,
    required String sessionId,
    int? beforeStepIndex,
    int limit = 30,
  });

  void requestSync();
}
