import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:muop_agent/core/theme/app_theme.dart';
import 'package:muop_agent/features/chat/presentation/chat_canvas_view.dart';
import 'package:muop_agent/features/projects/domain/project_entities.dart';
import 'package:muop_agent/features/sessions/domain/session_entities.dart';

AgentStep _step({
  required int index,
  required String type,
  required String content,
}) {
  return AgentStep(
    stepIndex: index,
    source: type == 'USER_INPUT' ? 'USER_EXPLICIT' : 'MODEL',
    type: type,
    status: 'DONE',
    createdAt: DateTime(2026, 11, 23, 9, 0, index),
    content: content,
    thinking: '',
    toolCalls: const [],
    inputTokens: 0,
    outputTokens: 0,
    cacheReadTokens: 0,
    agentName: 'Coordinator',
    phase: AgentWorkflowPhase.completed,
    vietnameseTitle: 'Hoàn tất',
    vietnameseDetail: '',
  );
}

ConversationSession _session(List<AgentStep> steps) {
  return ConversationSession(
    id: 'cid-scroll-1',
    title: 'Scroll Test',
    createdAt: DateTime(2026, 11, 23, 8),
    updatedAt: DateTime(2026, 11, 23, 9),
    status: AgentStatus.completed,
    currentPhase: AgentWorkflowPhase.completed,
    steps: steps,
    subagentLanes: const [],
    filesTouched: const [],
    commandsRun: const [],
    totalInputTokens: 0,
    totalOutputTokens: 0,
    totalCacheTokens: 0,
    source: 'claude-cli',
  );
}

void main() {
  testWidgets('không gọi onLoadOlderHistory khi session.steps còn rỗng', (
    tester,
  ) async {
    var loadCalls = 0;
    tester.view.physicalSize = const Size(420, 820);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(
          seedColor: const Color(0xFF4C8DFF),
          brightness: Brightness.dark,
        ),
        home: Scaffold(
          body: ChatCanvasView(
            session: _session(const []),
            projects: const <ProjectWorkspace>[],
            selectedProject: null,
            availableAgents: const ['Coordinator'],
            availableModels: const ['claude-cli:claude-haiku-5-5'],
            quotaScope: 'claude',
            quotaReports: const {},
            selectedAgent: 'Coordinator',
            selectedModel: 'claude-cli:claude-haiku-5-5',
            isNewConversationMode: false,
            isSending: false,
            activeStream: null,
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
            onLoadOlderHistory: () async {
              loadCalls++;
              return true;
            },
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));

    expect(loadCalls, 0);
  });

  testWidgets(
    'lỗi tạm thời khi tải lịch sử cũ giữ banner thử lại và tải tiếp được hết lên đầu',
    (tester) async {
      tester.view.physicalSize = const Size(420, 820);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      var currentSteps = <AgentStep>[
        for (int i = 10; i < 30; i++) ...[
          _step(index: i * 2, type: 'USER_INPUT', content: 'Câu hỏi $i'),
          _step(
            index: i * 2 + 1,
            type: 'PLANNER_RESPONSE',
            content: 'Trả lời chi tiết cho lượt $i\nDòng thứ 2 của lượt $i',
          ),
        ],
      ];

      var attempt = 0;
      late StateSetter outerSetState;

      Future<bool?> handleLoadOlder() async {
        attempt++;
        if (attempt == 1) {
          // Mô phỏng timeout/lỗi mạng tạm thời ở lần đầu
          return null;
        }
        // Lần thử lại nạp toàn bộ 10 lượt đầu tiên (step 0..19)
        outerSetState(() {
          currentSteps = [
            for (int i = 0; i < 10; i++) ...[
              _step(index: i * 2, type: 'USER_INPUT', content: 'Câu hỏi $i'),
              _step(
                index: i * 2 + 1,
                type: 'PLANNER_RESPONSE',
                content: 'Trả lời chi tiết cho lượt $i\nDòng thứ 2 của lượt $i',
              ),
            ],
            ...currentSteps,
          ];
        });
        return false;
      }

      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(
            seedColor: const Color(0xFF4C8DFF),
            brightness: Brightness.dark,
          ),
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                outerSetState = setState;
                return ChatCanvasView(
                  session: _session(currentSteps),
                  projects: const <ProjectWorkspace>[],
                  selectedProject: null,
                  availableAgents: const ['Coordinator'],
                  availableModels: const ['claude-cli:claude-haiku-5-5'],
                  quotaScope: 'claude',
                  quotaReports: const {},
                  selectedAgent: 'Coordinator',
                  selectedModel: 'claude-cli:claude-haiku-5-5',
                  isNewConversationMode: false,
                  isSending: false,
                  activeStream: null,
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
                  onLoadOlderHistory: handleLoadOlder,
                );
              },
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));

      // Cuộn lên đỉnh danh sách (với reverse: true, kéo xuống trên màn hình sẽ tăng offset)
      for (int i = 0; i < 15; i++) {
        await tester.dragFrom(
          const Offset(210, 200),
          const Offset(0, 450),
        );
        await tester.pump(const Duration(milliseconds: 100));
        if (find.textContaining('Không tải được lịch sử cũ').evaluate().isNotEmpty) {
          break;
        }
      }

      // Lần 1 gặp lỗi -> hiện banner thử lại, KHÔNG biến mất
      expect(attempt, 1);
      final retryFinder = find.textContaining('Không tải được lịch sử cũ');
      expect(retryFinder, findsOneWidget);

      // Kéo banner vào vùng hiển thị (có thể mới nằm trong scrollCacheExtent) rồi nhấn thử lại
      await tester.ensureVisible(retryFinder);
      await tester.pumpAndSettle();
      await tester.tap(retryFinder);
      await tester.pumpAndSettle();
      expect(attempt, 2);

      // Cuộn hết lên trên cùng để thấy Câu hỏi 0 (lượt đầu tiên của hội thoại)
      for (int i = 0; i < 20; i++) {
        await tester.dragFrom(
          const Offset(210, 200),
          const Offset(0, 450),
        );
        await tester.pump(const Duration(milliseconds: 100));
        if (find.text('Câu hỏi 0').evaluate().isNotEmpty) {
          break;
        }
      }
      await tester.pumpAndSettle();

      expect(find.text('Câu hỏi 0'), findsOneWidget);
      expect(find.textContaining('Không tải được lịch sử cũ'), findsNothing);
    },
  );

  testWidgets('cuộn xuống đáy hết cỡ thì thẻ tin nhắn cuối không bị dock che', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 820);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final steps = [
      for (int i = 0; i < 12; i++) ...[
        _step(index: i * 2, type: 'USER_INPUT', content: 'Câu hỏi $i'),
        _step(
          index: i * 2 + 1,
          type: 'PLANNER_RESPONSE',
          content: i == 11
              ? 'Tin nhắn cuối cùng hoàn chỉnh'
              : 'Trả lời lượt $i\nDòng phụ $i',
        ),
      ],
    ];

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(
          seedColor: const Color(0xFF4C8DFF),
          brightness: Brightness.dark,
        ),
        home: Scaffold(
          body: ChatCanvasView(
            session: _session(steps),
            projects: const <ProjectWorkspace>[],
            selectedProject: null,
            availableAgents: const ['Coordinator'],
            availableModels: const ['claude-cli:claude-haiku-5-5'],
            quotaScope: 'claude',
            quotaReports: const {},
            selectedAgent: 'Coordinator',
            selectedModel: 'claude-cli:claude-haiku-5-5',
            isNewConversationMode: false,
            isSending: false,
            activeStream: null,
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
    await tester.pumpAndSettle();

    final lastMsgRect = tester.getRect(
      find.text('Tin nhắn cuối cùng hoàn chỉnh'),
    );
    final dockRect = tester.getRect(find.byKey(const Key('chat-dock-island')));
    expect(lastMsgRect.bottom, lessThan(dockRect.top));
  });

  testWidgets('nền chat Telegram hiển thị mượt ở cả Dark và Light mode', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(420, 820);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    for (final brightness in [Brightness.dark, Brightness.light]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(
            seedColor: const Color(0xFF4C8DFF),
            brightness: brightness,
          ),
          home: Scaffold(
            body: ChatCanvasView(
              session: _session([
                _step(index: 0, type: 'USER_INPUT', content: 'Xin chào'),
                _step(
                  index: 1,
                  type: 'PLANNER_RESPONSE',
                  content: 'Chào bạn!',
                ),
              ]),
              projects: const <ProjectWorkspace>[],
              selectedProject: null,
              availableAgents: const ['Coordinator'],
              availableModels: const ['claude-cli:claude-haiku-5-5'],
              quotaScope: 'claude',
              quotaReports: const {},
              selectedAgent: 'Coordinator',
              selectedModel: 'claude-cli:claude-haiku-5-5',
              isNewConversationMode: false,
              isSending: false,
              activeStream: null,
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
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('chat-telegram-wallpaper')), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('các icon thao tác trong box chat nằm gọn bên trong TextField', (
    tester,
  ) async {
    for (final size in const [Size(420, 820), Size(1100, 820)]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(
            seedColor: const Color(0xFF4C8DFF),
            brightness: Brightness.dark,
          ),
          home: Scaffold(
            body: ChatCanvasView(
              session: _session([
                _step(index: 0, type: 'USER_INPUT', content: 'Hi'),
              ]),
              projects: const <ProjectWorkspace>[],
              selectedProject: null,
              availableAgents: const ['Coordinator'],
              availableModels: const ['claude-cli:claude-haiku-5-5'],
              quotaScope: 'claude',
              quotaReports: const {},
              selectedAgent: 'Coordinator',
              selectedModel: 'claude-cli:claude-haiku-5-5',
              isNewConversationMode: false,
              isSending: false,
              activeStream: null,
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
      await tester.pumpAndSettle();

      final fieldFinder = find.byKey(const Key('composer-text-field'));
      expect(fieldFinder, findsOneWidget);
      expect(
        find.descendant(
          of: fieldFinder,
          matching: find.byIcon(Icons.terminal_rounded),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: fieldFinder,
          matching: find.byIcon(Icons.attach_file_rounded),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: fieldFinder,
          matching: find.byIcon(Icons.arrow_upward_rounded),
        ),
        findsOneWidget,
      );
      if (size.width < 600) {
        expect(
          find.descendant(
            of: fieldFinder,
            matching: find.byIcon(Icons.tune_rounded),
          ),
          findsOneWidget,
        );
      }
      expect(tester.takeException(), isNull);
    }
  });
}
