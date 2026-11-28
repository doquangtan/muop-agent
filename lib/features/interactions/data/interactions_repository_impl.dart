import 'dart:async';
import 'dart:convert';

import 'package:muop_agent/core/config/server_config.dart';
import 'package:muop_agent/core/network/rest_client.dart';
import 'package:muop_agent/core/network/socket_gateway.dart';
import 'package:muop_agent/features/interactions/domain/interaction_entities.dart';
import 'package:muop_agent/features/interactions/domain/interactions_repository.dart';

class InteractionsRepositoryImpl implements InteractionsRepository {
  final SocketGateway _gateway;
  InteractionsRepositoryImpl(this._gateway) {
    _gateway.on('retry:update').listen((data) {
      if (_retryUpdateController.isClosed || data == null) return;
      try {
        List? list;
        if (data is List) {
          list = data;
        } else if (data is String) {
          list = jsonDecode(data) as List?;
        }
        if (list != null) {
          final retries = list
              .whereType<Map>()
              .map((item) => PendingRetry.fromJson(
                    Map<String, dynamic>.from(item),
                  ))
              .toList();
          _retryUpdateController.add(retries);
        }
      } catch (_) {}
    });
  }

  final StreamController<List<PendingRetry>> _retryUpdateController =
      StreamController<List<PendingRetry>>.broadcast();

  /// Danh sách lượt đang chờ tự gửi lại (toàn bộ, mỗi lần thay đổi)
  @override
  Stream<List<PendingRetry>> get retryUpdateStream =>
      _retryUpdateController.stream;

  /// Hủy lịch tự gửi lại sau rate limit (`/api/chat/retry/cancel`)
  @override
  Future<bool> cancelRetry({
    required String address,
    required String conversationId,
  }) async {
    final baseUrl = normalizeBaseUrl(address);
    try {
      final reply = await httpRequest(
        'POST',
        Uri.parse('$baseUrl/api/chat/retry/cancel'),
        json: {'conversationId': conversationId},
        timeout: const Duration(seconds: 4),
      );
      return reply.status == 200;
    } catch (_) {
      return false;
    }
  }

  /// Đọc cấu hình tự gửi lại (`GET /api/chat/retry/config?id=`)
  @override
  Future<ConversationRetryConfig?> fetchRetryConfig({
    required String address,
    required String conversationId,
  }) async {
    final baseUrl = normalizeBaseUrl(address);
    try {
      final uri = Uri.parse('$baseUrl/api/chat/retry/config').replace(
        queryParameters: {'id': conversationId},
      );
      final reply = await httpRequest('GET', uri, timeout: const Duration(seconds: 4));
      if (reply.status != 200) return null;
      final data = jsonDecode(reply.text);
      if (data is Map && data['config'] is Map) {
        return ConversationRetryConfig.fromJson(
          Map<String, dynamic>.from(data['config'] as Map),
        );
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Lưu cấu hình tự gửi lại (`POST /api/chat/retry/config`)
  @override
  Future<({bool ok, String message})> saveRetryConfig({
    required String address,
    required ConversationRetryConfig config,
  }) async {
    final baseUrl = normalizeBaseUrl(address);
    try {
      final reply = await httpRequest(
        'POST',
        Uri.parse('$baseUrl/api/chat/retry/config'),
        json: config.toJson(),
        timeout: const Duration(seconds: 6),
      );
      final data = jsonDecode(reply.text);
      if (reply.status == 200 && data is Map && data['ok'] == true) {
        return (ok: true, message: 'Đã lưu cấu hình tự gửi lại');
      }
      final err = (data is Map && data['error'] != null)
          ? data['error'].toString()
          : 'Không lưu được cấu hình (HTTP ${reply.status})';
      return (ok: false, message: err);
    } catch (e) {
      return (ok: false, message: 'Không lưu được cấu hình: $e');
    }
  }

  /// Lấy danh sách kế hoạch đang chờ duyệt (`/api/plan/pending`)
  @override
  Future<List<PlanArtifactInfo>> fetchPendingPlans({
    required String address,
    required String conversationId,
  }) async {
    final baseUrl = normalizeBaseUrl(address);
    try {
      final uri = Uri.parse('$baseUrl/api/plan/pending').replace(
        queryParameters: {'conversationId': conversationId},
      );
      final reply = await httpRequest('GET', uri, timeout: const Duration(seconds: 4));
      if (reply.status != 200) return const [];
      final data = jsonDecode(reply.text);
      if (data is Map && data['plans'] is List) {
        return (data['plans'] as List)
            .whereType<Map>()
            .map((e) => PlanArtifactInfo.fromJson(Map<String, dynamic>.from(e)))
            .toList();
      }
      return const [];
    } catch (_) {
      return const [];
    }
  }

  /// Gửi quyết định phê duyệt hoặc yêu cầu chỉnh sửa Kế hoạch (`/api/plan/action`)
  @override
  Future<({bool ok, String message})> submitPlanAction({
    required String address,
    required String conversationId,
    required String fileName,
    required String action, // 'approve' | 'reject' | 'cancel'
    String feedback = '',
    String model = '',
  }) async {
    final baseUrl = normalizeBaseUrl(address);
    try {
      final reply = await httpRequest(
        'POST',
        Uri.parse('$baseUrl/api/plan/action'),
        json: {
          'conversationId': conversationId,
          'fileName': fileName,
          'action': action,
          'feedback': feedback,
          'model': model,
        },
        timeout: const Duration(seconds: 6),
      );
      final data = jsonDecode(reply.text);
      if (reply.status == 200 && data is Map && data['ok'] == true) {
        return (
          ok: true,
          message: data['message']?.toString() ?? 'Thành công',
        );
      }
      final err = (data is Map && data['error'] != null)
          ? data['error'].toString()
          : 'Không thể xử lý kế hoạch';
      return (ok: false, message: err);
    } catch (e) {
      return (ok: false, message: e.toString());
    }
  }

  /// Lấy danh sách câu hỏi từ AI cho conversation (socket `request-ai-questions`, không polling)
  @override
  Future<List<AIQuestion>> fetchAIQuestions(String conversationId) async {
    try {
      final body = await _requestConversation('request-ai-questions', conversationId);
      final questions = (body['questions'] as List?)?.map((q) => AIQuestion.fromJson(q)).toList() ?? [];
      return questions;
    } catch (_) {}
    return [];
  }

  /// Gửi một `request-*` theo conversation và nhận ack (`{ok, conversationId, ...}`)
  Future<Map<String, dynamic>> _requestConversation(String event, String conversationId) async {
    final ack = await _gateway
        .emitWithAck(event, {'conversationId': conversationId})
        .timeout(const Duration(seconds: 6));
    return Map<String, dynamic>.from(ack as Map);
  }

  /// Gửi câu trả lời cho câu hỏi từ AI
  @override
  Future<bool> submitAIAnswer(String questionId, String answer) async {
    final baseUrl = normalizeBaseUrl(_gateway.connectedBaseUrl);
    try {
      final reply = await httpRequest(
        'POST',
        Uri.parse('$baseUrl/api/ai-questions/answer'),
        json: {'questionId': questionId, 'answer': answer},
        timeout: const Duration(seconds: 6),
      );
      return reply.status == 200;
    } catch (_) {}
    return false;
  }

  /// Tương tác Claude CLI đang chờ người dùng (câu hỏi hoặc kế hoạch cần duyệt); null nếu không có
  @override
  Future<PendingClaudeInteraction?> fetchPendingClaudeInteraction(String conversationId) async {
    try {
      final body = await _requestConversation('request-claude-pending', conversationId);
      final pending = body['pending'];
      if (pending is Map) {
        return PendingClaudeInteraction.fromJson(Map<String, dynamic>.from(pending));
      }
    } catch (_) {}
    return null;
  }

  /// Phản hồi tương tác Claude đang chờ (trả lời câu hỏi hoặc duyệt/góp ý kế hoạch).
  /// Trả về null nếu thành công, ngược lại là thông báo lỗi.
  @override
  Future<String?> respondClaudeInteraction({
    required String conversationId,
    required String toolUseId,
    required String projectPath,
    required String model,
    required String decision,
    List<Map<String, String>> answers = const [],
    String feedback = '',
  }) async {
    final baseUrl = normalizeBaseUrl(_gateway.connectedBaseUrl);
    try {
      final reply = await httpRequest(
        'POST',
        Uri.parse('$baseUrl/api/claude/respond'),
        json: {
          'conversationId': conversationId,
          'toolUseId': toolUseId,
          'projectPath': projectPath,
          'model': model,
          'answers': answers,
          'decision': decision,
          'feedback': feedback,
        },
        timeout: const Duration(seconds: 15),
      );
      if (reply.status == 200) return null;
      final map = jsonDecode(reply.text) as Map<String, dynamic>;
      return '${map['error'] ?? 'HTTP ${reply.status}'}';
    } catch (e) {
      return 'Không gửi được câu trả lời: $e';
    }
  }
}
