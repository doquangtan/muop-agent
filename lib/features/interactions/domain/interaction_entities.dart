
class PlanArtifactInfo {
  const PlanArtifactInfo({
    required this.fileName,
    required this.filePath,
    required this.title,
    required this.summary,
    required this.updatedAt,
    required this.requestFeedback,
    required this.content,
  });

  final String fileName;
  final String filePath;
  final String title;
  final String summary;
  final String updatedAt;
  final bool requestFeedback;
  final String content;

  factory PlanArtifactInfo.fromJson(Map<String, dynamic> json) {
    return PlanArtifactInfo(
      fileName: json['fileName']?.toString() ?? '',
      filePath: json['filePath']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      summary: json['summary']?.toString() ?? '',
      updatedAt: json['updatedAt']?.toString() ?? '',
      requestFeedback: json['requestFeedback'] == true,
      content: json['content']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'fileName': fileName,
        'filePath': filePath,
        'title': title,
        'summary': summary,
        'updatedAt': updatedAt,
        'requestFeedback': requestFeedback,
        'content': content,
      };
}

class ClaudeQuestionOption {
  final String label;
  final String description;

  const ClaudeQuestionOption({required this.label, required this.description});

  factory ClaudeQuestionOption.fromJson(Map<String, dynamic> json) {
    return ClaudeQuestionOption(
      label: '${json['label'] ?? ''}',
      description: '${json['description'] ?? ''}',
    );
  }
}

class ClaudeQuestionItem {
  final String question;
  final String header;
  final bool multiSelect;
  final List<ClaudeQuestionOption> options;

  const ClaudeQuestionItem({
    required this.question,
    required this.header,
    required this.multiSelect,
    required this.options,
  });

  factory ClaudeQuestionItem.fromJson(Map<String, dynamic> json) {
    final rawOptions = json['options'];
    return ClaudeQuestionItem(
      question: '${json['question'] ?? ''}',
      header: '${json['header'] ?? ''}',
      multiSelect: json['multiSelect'] == true,
      options: rawOptions is List
          ? rawOptions
              .whereType<Map>()
              .map((o) => ClaudeQuestionOption.fromJson(Map<String, dynamic>.from(o)))
              .toList()
          : const [],
    );
  }
}

class PendingClaudeInteraction {
  final String conversationId;
  final String toolUseId;
  final String kind;
  final String createdAt;
  final List<ClaudeQuestionItem> questions;
  final String plan;

  const PendingClaudeInteraction({
    required this.conversationId,
    required this.toolUseId,
    required this.kind,
    required this.createdAt,
    required this.questions,
    required this.plan,
  });

  bool get isPlan => kind == 'plan';

  String get summary {
    if (!isPlan) return questions.isEmpty ? '' : questions.first.question;
    for (final line in plan.split('\n')) {
      final text = line.replaceFirst(RegExp(r'^#+\s*'), '').trim();
      if (text.isNotEmpty) return text;
    }
    return '';
  }

  factory PendingClaudeInteraction.fromJson(Map<String, dynamic> json) {
    final rawQuestions = json['questions'];
    return PendingClaudeInteraction(
      conversationId: '${json['conversationId'] ?? ''}',
      toolUseId: '${json['toolUseId'] ?? ''}',
      kind: '${json['kind'] ?? 'question'}',
      createdAt: '${json['createdAt'] ?? ''}',
      questions: rawQuestions is List
          ? rawQuestions
              .whereType<Map>()
              .map((q) => ClaudeQuestionItem.fromJson(Map<String, dynamic>.from(q)))
              .toList()
          : const [],
      plan: '${json['plan'] ?? ''}',
    );
  }
}

class AIQuestion {
  final String id;
  final String conversationId;
  final int stepIndex;
  final String question;
  final String createdAt;
  final String? answeredAt;
  final String? answer;
  final bool isPending;

  AIQuestion({
    required this.id,
    required this.conversationId,
    required this.stepIndex,
    required this.question,
    required this.createdAt,
    this.answeredAt,
    this.answer,
    required this.isPending,
  });

  factory AIQuestion.fromJson(Map<String, dynamic> json) {
    return AIQuestion(
      id: '${json['id'] ?? ''}',
      conversationId: '${json['conversationId'] ?? ''}',
      stepIndex: (json['stepIndex'] as int?) ?? 0,
      question: '${json['question'] ?? ''}',
      createdAt: '${json['createdAt'] ?? ''}',
      answeredAt: json['answeredAt']?.toString(),
      answer: json['answer']?.toString(),
      isPending: json['isPending'] == true,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'conversationId': conversationId,
      'stepIndex': stepIndex,
      'question': question,
      'createdAt': createdAt,
      'answeredAt': answeredAt,
      'answer': answer,
      'isPending': isPending,
    };
  }

  AIQuestion copyWith({
    String? id,
    String? conversationId,
    int? stepIndex,
    String? question,
    String? createdAt,
    String? answeredAt,
    String? answer,
    bool? isPending,
  }) {
    return AIQuestion(
      id: id ?? this.id,
      conversationId: conversationId ?? this.conversationId,
      stepIndex: stepIndex ?? this.stepIndex,
      question: question ?? this.question,
      createdAt: createdAt ?? this.createdAt,
      answeredAt: answeredAt ?? this.answeredAt,
      answer: answer ?? this.answer,
      isPending: isPending ?? this.isPending,
    );
  }
}

/// Lượt chat đang chờ hệ thống tự gửi lại sau khi bị rate limit / hết quota
class PendingRetry {
  const PendingRetry({
    required this.conversationId,
    required this.provider,
    required this.reason,
    required this.retryAt,
    required this.attempt,
    required this.maxAttempts,
    this.waitSource = '',
    this.waitDetail = '',
    this.resetAt,
  });

  final String conversationId;
  final String provider;
  /// Thông điệp lỗi gốc từ CLI
  final String reason;
  final DateTime retryAt;
  /// Lần gửi lại thứ mấy (1 = lần đầu)
  final int attempt;
  final int maxAttempts;
  /// Căn cứ chọn giờ gửi lại: `quota` | `message` | `interval` (rỗng với server cũ)
  final String waitSource;
  /// Mô tả ngắn từ server, ví dụ `Chờ reset quota · Phiên 5 giờ`
  final String waitDetail;
  /// Thời điểm quota reset (chỉ có khi `waitSource == 'quota'`)
  final DateTime? resetAt;

  /// Key để nhận biết cùng một lịch (không đổi khi đếm ngược)
  String get key => '$conversationId#$attempt';

  factory PendingRetry.fromJson(Map<String, dynamic> json) {
    final resetRaw = '${json['resetAt'] ?? ''}';
    return PendingRetry(
      conversationId: '${json['conversationId'] ?? ''}',
      provider: '${json['provider'] ?? ''}',
      reason: '${json['reason'] ?? ''}',
      retryAt: DateTime.tryParse('${json['retryAt'] ?? ''}') ??
          DateTime.now().add(const Duration(minutes: 5)),
      attempt: (json['attempt'] as num?)?.toInt() ?? 1,
      maxAttempts: (json['maxAttempts'] as num?)?.toInt() ?? 8,
      waitSource: '${json['waitSource'] ?? ''}',
      waitDetail: '${json['waitDetail'] ?? ''}',
      resetAt: resetRaw.isEmpty ? null : DateTime.tryParse(resetRaw),
    );
  }
}

/// Cấu hình tự gửi lại của một conversation (`GET/POST /api/chat/retry/config`)
class ConversationRetryConfig {
  const ConversationRetryConfig({
    required this.conversationId,
    this.enabled = true,
    this.prompt = '',
    this.maxAttempts = 8,
    this.intervalMinutes = 5,
    this.useQuotaReset = true,
  });

  /// Giới hạn khớp với server (`models.rs`)
  static const int maxAttemptsLimit = 20;
  static const int intervalMinutesMin = 1;
  static const int intervalMinutesMax = 720;
  static const int promptMaxChars = 4000;

  final String conversationId;
  /// Tắt: lượt bị giới hạn không được gửi lại tự động
  final bool enabled;
  /// Nội dung gửi lại. Rỗng = gửi lại đúng nội dung của lượt bị giới hạn
  final String prompt;
  /// Số lần gửi lại tối đa cho một lượt (0 = không gửi lại)
  final int maxAttempts;
  /// Khoảng chờ dự phòng (phút), dùng khi không có thời điểm reset hoặc tắt chờ theo quota
  final int intervalMinutes;
  /// Chờ đến thời điểm quota reset, đọc từ dữ liệu quota của provider
  final bool useQuotaReset;

  ConversationRetryConfig copyWith({
    bool? enabled,
    String? prompt,
    int? maxAttempts,
    int? intervalMinutes,
    bool? useQuotaReset,
  }) {
    return ConversationRetryConfig(
      conversationId: conversationId,
      enabled: enabled ?? this.enabled,
      prompt: prompt ?? this.prompt,
      maxAttempts: maxAttempts ?? this.maxAttempts,
      intervalMinutes: intervalMinutes ?? this.intervalMinutes,
      useQuotaReset: useQuotaReset ?? this.useQuotaReset,
    );
  }

  factory ConversationRetryConfig.fromJson(Map<String, dynamic> json) {
    final defaults = ConversationRetryConfig(
      conversationId: '${json['conversationId'] ?? ''}',
    );
    return ConversationRetryConfig(
      conversationId: '${json['conversationId'] ?? ''}',
      enabled: json['enabled'] as bool? ?? defaults.enabled,
      prompt: '${json['prompt'] ?? ''}',
      maxAttempts:
          (json['maxAttempts'] as num?)?.toInt() ?? defaults.maxAttempts,
      intervalMinutes:
          (json['intervalMinutes'] as num?)?.toInt() ?? defaults.intervalMinutes,
      useQuotaReset: json['useQuotaReset'] as bool? ?? defaults.useQuotaReset,
    );
  }

  Map<String, dynamic> toJson() => {
        'conversationId': conversationId,
        'enabled': enabled,
        'prompt': prompt,
        'maxAttempts': maxAttempts,
        'intervalMinutes': intervalMinutes,
        'useQuotaReset': useQuotaReset,
      };
}
