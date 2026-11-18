
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
    );
  }
}
