part of '../chat_canvas_view.dart';

class _ChatTurnGroup {
  _ChatTurnGroup({
    required this.turnIndex,
    this.userStep,
    required this.agentSteps,
    required this.groupedFiles,
  });

  final int turnIndex;
  final AgentStep? userStep;
  final List<AgentStep> agentSteps;
  final List<GroupedFileChange> groupedFiles;

  String get finalAgentResponse {
    for (int i = agentSteps.length - 1; i >= 0; i--) {
      final s = agentSteps[i];
      if (s.type == 'PLANNER_RESPONSE' && s.content.trim().isNotEmpty) {
        return s.content.trim();
      }
    }
    return '';
  }

  List<AgentStep> get trajectorySteps {
    return agentSteps
        .where((s) => s.thinking.trim().isNotEmpty || s.toolCalls.isNotEmpty)
        .toList();
  }

  int get totalToolCount {
    var count = 0;
    for (final s in agentSteps) {
      count += s.toolCalls.length;
    }
    return count;
  }

  int get totalThoughtCount {
    var count = 0;
    for (final s in agentSteps) {
      if (s.thinking.trim().isNotEmpty) count++;
    }
    return count;
  }
}

enum _ChatBlockKind {
  turnSpacing,
  liveStreaming,
  aiTurnCard,
  userPromptBubble,
  loadMoreBanner,
}

class _ParsedResponseSegment {
  const _ParsedResponseSegment({
    required this.isCode,
    required this.language,
    required this.text,
  });

  final bool isCode;
  final String language;
  final String text;
}

/// Đại diện cho 1 phần tử phẳng (flat item) được render trực tiếp bởi ListView.builder
/// giúp danh sách cuộn mượt 60/120fps mà không phải dựng các Widget cây khổng lồ.
class _ChatFlatBlock {
  const _ChatFlatBlock({
    required this.kind,
    required this.keyId,
    this.turn,
    this.stream,
    this.isLastTurn = false,
    this.remainingCount = 0,
    this.loadedCount = 0,
    this.totalTurnsCount = 0,
  });

  final _ChatBlockKind kind;
  final String keyId;
  final _ChatTurnGroup? turn;
  final ChatTurnStreamState? stream;
  final bool isLastTurn;
  final int remainingCount;
  final int loadedCount;
  final int totalTurnsCount;
}
