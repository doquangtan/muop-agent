import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:muop_agent/core/theme/app_theme.dart';
import 'package:muop_agent/features/chat/domain/chat_entities.dart';
import 'package:muop_agent/features/chat/presentation/chat_canvas_view.dart';
import 'package:muop_agent/features/sessions/domain/session_entities.dart';
import 'package:muop_agent/features/projects/domain/project_entities.dart';

const _liveText = 'Sông Hồng bắt nguồn từ tỉnh Vân Nam, Trung Quốc.';

AgentStep _step({
  required int index,
  required String type,
  required String content,
  String status = 'DONE',
  String thinking = '',
}) {
  return AgentStep(
    stepIndex: index,
    source: type == 'USER_INPUT' ? 'USER_EXPLICIT' : 'MODEL',
    type: type,
    status: status,
    createdAt: DateTime(2026, 11, 19, 10, 0, index),
    content: content,
    thinking: thinking,
    toolCalls: const [],
    inputTokens: 0,
    outputTokens: 0,
    cacheReadTokens: 0,
    agentName: 'Coordinator',
    phase: AgentWorkflowPhase.contractDiscovery,
    vietnameseTitle: 'Trả lời',
    vietnameseDetail: '',
  );
}

ConversationSession _session({
  required AgentStatus status,
  required List<AgentStep> steps,
}) {
  return ConversationSession(
    id: 'cid-agy-1',
    title: 'Test agy',
    createdAt: DateTime(2026, 11, 19, 9),
    updatedAt: DateTime(2026, 11, 19, 10),
    status: status,
    currentPhase: AgentWorkflowPhase.contractDiscovery,
    steps: steps,
    subagentLanes: const [],
    filesTouched: const [],
    commandsRun: const [],
    totalInputTokens: 0,
    totalOutputTokens: 0,
    totalCacheTokens: 0,
    source: 'agy',
  );
}

Future<void> _pump(
  WidgetTester tester, {
  required ConversationSession session,
  required ChatTurnStreamState? stream,
}) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(
        seedColor: const Color(0xFF00897B),
        brightness: Brightness.light,
      ),
      home: Scaffold(
        body: ChatCanvasView(
          session: session,
          projects: const <ProjectWorkspace>[],
          selectedProject: null,
          availableAgents: const ['Coordinator'],
          availableModels: const ['agy:gemini-test'],
          modelQuotas: const <ModelQuotaGroup>[],
          selectedAgent: 'Coordinator',
          selectedModel: 'agy:gemini-test',
          isNewConversationMode: false,
          isSending: false,
          activeStream: stream,
          onSelectProject: (_) {},
          onSelectAgent: (_) {},
          onSelectModel: (_) {},
          onStartNewConversation: () {},
          onSendMessage: (_, _) {},
          onStopTurn: () {},
          onOpenFileBrowser: () {},
          onOpenChangesTab: () {},
          onInspectFileChange: (_, _) {},
          onDownloadFile: (_) {},
          onOpenDownloadedFile: (_) {},
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 300));
}

ChatTurnStreamState _stream({
  required String text,
  String step = 'agent_response',
  String thinking = '',
}) {
  return ChatTurnStreamState(
    conversationId: 'cid-agy-1',
    projectPath: '/tmp',
    userPrompt: 'Hỏi về sông Hồng',
    streamingText: text,
    isRunning: true,
    activeStepType: step,
    startedAt: DateTime(2026, 11, 19, 10, 0),
    thinkingText: thinking,
  );
}

void main() {
  final userStep = _step(
    index: 0,
    type: 'USER_INPUT',
    content: 'Hỏi về sông Hồng',
  );
  final doneStep = _step(
    index: 1,
    type: 'PLANNER_RESPONSE',
    content: 'Bước trước đã xong.',
    thinking: 'Suy nghĩ thử nghiệm',
  );

  testWidgets('A: session running, turn có bước đã xong, stream có text', (
    tester,
  ) async {
    await _pump(
      tester,
      session: _session(
        status: AgentStatus.running,
        steps: [userStep, doneStep],
      ),
      stream: _stream(text: _liveText),
    );
    expect(find.textContaining('bắt nguồn từ tỉnh Vân Nam'), findsWidgets);
  });

  testWidgets('B: session running, turn chỉ có user step, stream có text', (
    tester,
  ) async {
    await _pump(
      tester,
      session: _session(status: AgentStatus.running, steps: [userStep]),
      stream: _stream(text: _liveText),
    );
    expect(find.textContaining('bắt nguồn từ tỉnh Vân Nam'), findsWidgets);
  });

  testWidgets('C: session completed (transcript chưa cập nhật), stream vẫn chạy', (
    tester,
  ) async {
    await _pump(
      tester,
      session: _session(
        status: AgentStatus.completed,
        steps: [userStep, doneStep],
      ),
      stream: _stream(text: _liveText),
    );
    expect(find.textContaining('bắt nguồn từ tỉnh Vân Nam'), findsWidgets);
  });

  testWidgets('D: stream text tăng dần, session running', (tester) async {
    await _pump(
      tester,
      session: _session(
        status: AgentStatus.running,
        steps: [userStep, doneStep],
      ),
      stream: _stream(text: 'Sông Hồng bắt'),
    );
    await _pump(
      tester,
      session: _session(
        status: AgentStatus.running,
        steps: [userStep, doneStep],
      ),
      stream: _stream(text: _liveText),
    );
    expect(find.textContaining('bắt nguồn từ tỉnh Vân Nam'), findsWidgets);
  });
}
