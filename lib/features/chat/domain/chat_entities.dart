
import 'dart:convert';
import 'dart:typed_data';

/// Ảnh người dùng chọn để đính kèm vào tin nhắn (chưa gửi). Server kiểm tra lại nội dung thật của ảnh.
class ChatImageAttachment {
  const ChatImageAttachment({
    required this.name,
    required this.mimeType,
    required this.bytes,
  });

  final String name;
  final String mimeType;
  final Uint8List bytes;

  Map<String, dynamic> toJson() => {
        'name': name,
        'mimeType': mimeType,
        'dataBase64': base64Encode(bytes),
      };
}

class ChatSendResult {
  const ChatSendResult({
    required this.ok,
    required this.conversationId,
    required this.projectPath,
    this.error = '',
    this.source = '',
  });

  final bool ok;
  final String conversationId;
  final String projectPath;
  final String error;

  /// Provider đã xử lý lượt chat: `claude-cli` hoặc `agy`
  final String source;
}

class ChatTurnStreamState {
  const ChatTurnStreamState({
    required this.conversationId,
    required this.projectPath,
    required this.userPrompt,
    required this.streamingText,
    required this.isRunning,
    required this.activeStepType,
    required this.startedAt,
    this.error = '',
    this.thinkingText = '',
    this.thinkingTokens = 0,
  });

  final String conversationId;
  final String projectPath;
  final String userPrompt;
  final String streamingText;
  final bool isRunning;
  final String activeStepType;
  final DateTime startedAt;
  final String error;
  final String thinkingText;

  /// Số token suy nghĩ ước lượng của block thinking đang chạy (Claude 5.x không gửi chữ thinking)
  final int thinkingTokens;

  ChatTurnStreamState copyWith({
    String? conversationId,
    String? projectPath,
    String? userPrompt,
    String? streamingText,
    bool? isRunning,
    String? activeStepType,
    DateTime? startedAt,
    String? error,
    String? thinkingText,
    int? thinkingTokens,
  }) {
    return ChatTurnStreamState(
      conversationId: conversationId ?? this.conversationId,
      projectPath: projectPath ?? this.projectPath,
      userPrompt: userPrompt ?? this.userPrompt,
      streamingText: streamingText ?? this.streamingText,
      isRunning: isRunning ?? this.isRunning,
      activeStepType: activeStepType ?? this.activeStepType,
      startedAt: startedAt ?? this.startedAt,
      error: error ?? this.error,
      thinkingText: thinkingText ?? this.thinkingText,
      thinkingTokens: thinkingTokens ?? this.thinkingTokens,
    );
  }

  Map<String, dynamic> toJson() => {
        'conversationId': conversationId,
        'projectPath': projectPath,
        'userPrompt': userPrompt,
        'streamingText': streamingText,
        'isRunning': isRunning,
        'activeStepType': activeStepType,
        'startedAt': startedAt.toIso8601String(),
        'error': error,
        'thinkingText': thinkingText,
        'thinkingTokens': thinkingTokens,
      };

  factory ChatTurnStreamState.fromJson(Map<String, dynamic> json) {
    return ChatTurnStreamState(
      conversationId: '${json['conversationId'] ?? ''}',
      projectPath: '${json['projectPath'] ?? ''}',
      userPrompt: '${json['userPrompt'] ?? ''}',
      streamingText: '${json['streamingText'] ?? ''}',
      isRunning: json['isRunning'] == true,
      activeStepType: '${json['activeStepType'] ?? 'thinking'}',
      startedAt:
          DateTime.tryParse('${json['startedAt'] ?? ''}') ?? DateTime.now(),
      error: '${json['error'] ?? ''}',
      thinkingText: '${json['thinkingText'] ?? ''}',
      thinkingTokens: (json['thinkingTokens'] as num?)?.toInt() ?? 0,
    );
  }
}
