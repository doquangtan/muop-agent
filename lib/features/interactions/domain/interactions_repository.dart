import 'dart:async';

import 'package:muop_agent/features/interactions/domain/interaction_entities.dart';

/// Interface (domain) của feature interactions. Presentation chỉ phụ thuộc interface này.
abstract class InteractionsRepository {
  Stream<List<PendingRetry>> get retryUpdateStream;

  Future<bool> cancelRetry({
    required String address,
    required String conversationId,
  });

  /// Cấu hình tự gửi lại của conversation; null nếu không đọc được
  Future<ConversationRetryConfig?> fetchRetryConfig({
    required String address,
    required String conversationId,
  });

  /// Lưu cấu hình tự gửi lại. `message` là lỗi từ server khi `ok` là false.
  Future<({bool ok, String message})> saveRetryConfig({
    required String address,
    required ConversationRetryConfig config,
  });

  Future<List<PlanArtifactInfo>> fetchPendingPlans({
    required String address,
    required String conversationId,
  });

  Future<({bool ok, String message})> submitPlanAction({
    required String address,
    required String conversationId,
    required String fileName,
    required String action, // 'approve' | 'reject' | 'cancel'
    String feedback = '',
    String model = '',
  });

  Future<List<AIQuestion>> fetchAIQuestions(String conversationId);

  Future<bool> submitAIAnswer(String questionId, String answer);

  Future<PendingClaudeInteraction?> fetchPendingClaudeInteraction(String conversationId);

  Future<String?> respondClaudeInteraction({
    required String conversationId,
    required String toolUseId,
    required String projectPath,
    required String model,
    required String decision,
    List<Map<String, String>> answers = const [],
    String feedback = '',
  });
}
