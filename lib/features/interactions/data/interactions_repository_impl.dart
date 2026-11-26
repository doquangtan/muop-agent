import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:muop_agent/core/config/server_config.dart';
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
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 4);
    try {
      final uri = Uri.parse('$baseUrl/api/chat/retry/cancel');
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

  /// Đọc cấu hình tự gửi lại (`GET /api/chat/retry/config?id=`)
  @override
  Future<ConversationRetryConfig?> fetchRetryConfig({
    required String address,
    required String conversationId,
  }) async {
    final baseUrl = normalizeBaseUrl(address);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 4);
    try {
      final uri = Uri.parse('$baseUrl/api/chat/retry/config').replace(
        queryParameters: {'id': conversationId},
      );
      final req = await client.getUrl(uri);
      final resp = await req.close().timeout(const Duration(seconds: 4));
      if (resp.statusCode != 200) return null;
      final body = await resp.transform(utf8.decoder).join();
      final data = jsonDecode(body);
      if (data is Map && data['config'] is Map) {
        return ConversationRetryConfig.fromJson(
          Map<String, dynamic>.from(data['config'] as Map),
        );
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// Lưu cấu hình tự gửi lại (`POST /api/chat/retry/config`)
  @override
  Future<({bool ok, String message})> saveRetryConfig({
    required String address,
    required ConversationRetryConfig config,
  }) async {
    final baseUrl = normalizeBaseUrl(address);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 4);
    try {
      final uri = Uri.parse('$baseUrl/api/chat/retry/config');
      final req = await client.postUrl(uri);
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(config.toJson()));
      final resp = await req.close().timeout(const Duration(seconds: 6));
      final body = await resp.transform(utf8.decoder).join();
      final data = jsonDecode(body);
      if (resp.statusCode == 200 && data is Map && data['ok'] == true) {
        return (ok: true, message: 'Đã lưu cấu hình tự gửi lại');
      }
      final err = (data is Map && data['error'] != null)
          ? data['error'].toString()
          : 'Không lưu được cấu hình (HTTP ${resp.statusCode})';
      return (ok: false, message: err);
    } catch (e) {
      return (ok: false, message: 'Không lưu được cấu hình: $e');
    } finally {
      client.close(force: true);
    }
  }

  /// Lấy danh sách kế hoạch đang chờ duyệt (`/api/plan/pending`)
  @override
  Future<List<PlanArtifactInfo>> fetchPendingPlans({
    required String address,
    required String conversationId,
  }) async {
    final baseUrl = normalizeBaseUrl(address);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 4);
    try {
      final uri = Uri.parse('$baseUrl/api/plan/pending').replace(
        queryParameters: {'conversationId': conversationId},
      );
      final req = await client.getUrl(uri);
      final resp = await req.close().timeout(const Duration(seconds: 4));
      if (resp.statusCode != 200) return const [];
      final body = await resp.transform(utf8.decoder).join();
      final data = jsonDecode(body);
      if (data is Map && data['plans'] is List) {
        return (data['plans'] as List)
            .whereType<Map>()
            .map((e) => PlanArtifactInfo.fromJson(Map<String, dynamic>.from(e)))
            .toList();
      }
      return const [];
    } catch (_) {
      return const [];
    } finally {
      client.close(force: true);
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
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 6);
    try {
      final uri = Uri.parse('$baseUrl/api/plan/action');
      final req = await client.postUrl(uri);
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({
        'conversationId': conversationId,
        'fileName': fileName,
        'action': action,
        'feedback': feedback,
        'model': model,
      }));
      final resp = await req.close().timeout(const Duration(seconds: 6));
      final body = await resp.transform(utf8.decoder).join();
      final data = jsonDecode(body);
      if (resp.statusCode == 200 && data is Map && data['ok'] == true) {
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
    } finally {
      client.close(force: true);
    }
  }

  /// Lấy danh sách câu hỏi từ AI cho conversation
  @override
  Future<List<AIQuestion>> fetchAIQuestions(String conversationId) async {
    final baseUrl = normalizeBaseUrl(_gateway.connectedBaseUrl);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 4);
    try {
      final uri = Uri.parse('$baseUrl/api/ai-questions?conversationId=$conversationId');
      final req = await client.getUrl(uri);
      final resp = await req.close().timeout(const Duration(seconds: 6));
      if (resp.statusCode == 200) {
        final body = await resp.transform(utf8.decoder).join();
        final json = jsonDecode(body);
        final questions = (json['questions'] as List?)?.map((q) => AIQuestion.fromJson(q)).toList() ?? [];
        return questions;
      }
    } catch (_) {
    } finally {
      client.close(force: true);
    }
    return [];
  }

  /// Gửi câu trả lời cho câu hỏi từ AI
  @override
  Future<bool> submitAIAnswer(String questionId, String answer) async {
    final baseUrl = normalizeBaseUrl(_gateway.connectedBaseUrl);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 4);
    try {
      final uri = Uri.parse('$baseUrl/api/ai-questions/answer');
      final req = await client.postUrl(uri);
      req.headers.contentType = ContentType.json;
      req.add(jsonEncode({
        'questionId': questionId,
        'answer': answer,
      }).codeUnits);
      final resp = await req.close().timeout(const Duration(seconds: 6));
      return resp.statusCode == 200;
    } catch (_) {
    } finally {
      client.close(force: true);
    }
    return false;
  }

  /// Tương tác Claude CLI đang chờ người dùng (câu hỏi hoặc kế hoạch cần duyệt); null nếu không có
  @override
  Future<PendingClaudeInteraction?> fetchPendingClaudeInteraction(String conversationId) async {
    final baseUrl = normalizeBaseUrl(_gateway.connectedBaseUrl);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 4);
    try {
      final uri = Uri.parse(
        '$baseUrl/api/claude/pending?id=${Uri.encodeQueryComponent(conversationId)}',
      );
      final req = await client.getUrl(uri);
      final resp = await req.close().timeout(const Duration(seconds: 6));
      if (resp.statusCode == 200) {
        final body = await resp.transform(utf8.decoder).join();
        final json = jsonDecode(body) as Map<String, dynamic>;
        final pending = json['pending'];
        if (pending is Map) {
          return PendingClaudeInteraction.fromJson(Map<String, dynamic>.from(pending));
        }
      }
    } catch (_) {
    } finally {
      client.close(force: true);
    }
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
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 6);
    try {
      final uri = Uri.parse('$baseUrl/api/claude/respond');
      final req = await client.postUrl(uri);
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({
        'conversationId': conversationId,
        'toolUseId': toolUseId,
        'projectPath': projectPath,
        'model': model,
        'answers': answers,
        'decision': decision,
        'feedback': feedback,
      }));
      final resp = await req.close().timeout(const Duration(seconds: 15));
      final body = await resp.transform(utf8.decoder).join();
      if (resp.statusCode == 200) return null;
      final map = jsonDecode(body) as Map<String, dynamic>;
      return '${map['error'] ?? 'HTTP ${resp.statusCode}'}';
    } catch (e) {
      return 'Không gửi được câu trả lời: $e';
    } finally {
      client.close(force: true);
    }
  }
}
