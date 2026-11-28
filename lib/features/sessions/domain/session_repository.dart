import 'dart:async';

import 'package:muop_agent/features/chat/domain/chat_entities.dart';
import 'package:muop_agent/features/sessions/domain/session_entities.dart';
import 'package:muop_agent/features/sessions/domain/session_share.dart';

/// Interface (domain) của feature sessions. Presentation chỉ phụ thuộc interface này.
abstract class SessionRepository {
  Stream<List<ConversationSession>> get sessionsListStream;

  Stream<ServerMeta> get metaStream;

  Stream<Map<String, ChatTurnStreamState>> get activeStreamsStream;

  Stream<String> get sessionRemovedStream;

  Stream<ConversationSession> get sessionUpdateStream;

  /// Có thay đổi quota trên server (`quotas:update`). Dữ liệu quota lấy qua REST theo màn hình.
  Stream<void> get quotasChangedStream;

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

  /// Trang đầu của link chia sẻ (để biết tổng số trang và kiểm tra link dùng được)
  Future<SessionSharePage?> fetchSessionSharePage({
    required String address,
    required String sessionId,
    required int fromStep,
    int page = 0,
    int limit = kSharePageSize,
  });

  void requestSync();
}
