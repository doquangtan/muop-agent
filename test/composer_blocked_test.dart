import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:muop_agent/core/theme/app_theme.dart';
import 'package:muop_agent/features/chat/presentation/chat_canvas_view.dart';
import 'package:muop_agent/features/quota/domain/quota_entities.dart';
import 'package:muop_agent/features/projects/domain/project_entities.dart';

/// Khung chat khi model đang chọn chạy trên máy phụ đã mất kết nối: ô nhập bị khóa,
/// có lý do hiển thị, và không gửi được tin.
void main() {
  Future<List<String>> pumpCanvas(WidgetTester tester, {String? blockedReason}) async {
    final sent = <String>[];
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(
          seedColor: const Color(0xFF00897B),
          brightness: Brightness.light,
        ),
        home: Scaffold(
          body: ChatCanvasView(
            session: null,
            projects: const <ProjectWorkspace>[],
            selectedProject: null,
            availableAgents: const ['Coordinator'],
            availableModels: const ['peer:claude-cli:claude-haiku-5-5-low'],
            quotaScope: 'claude',
            quotaReports: const <String, QuotaReport>{},
            selectedAgent: 'Coordinator',
            selectedModel: 'peer:claude-cli:claude-haiku-5-5-low',
            isNewConversationMode: true,
            isSending: false,
            activeStream: null,
            blockedReason: blockedReason,
            onSelectProject: (_) {},
            onSelectAgent: (_) {},
            onSelectModel: (_) {},
            onStartNewConversation: () {},
            onSendMessage: (text, _) => sent.add(text),
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
    return sent;
  }

  Finder composerField() => find.byWidgetPredicate(
        (w) => w is TextField && (w.decoration?.hintText?.startsWith('Ask anything') ?? false),
      );

  testWidgets('a blocked chat disables the composer and shows the reason', (tester) async {
    await pumpCanvas(
      tester,
      blockedReason: 'Mất kết nối tới máy phụ Laptop. Khung chat bị khóa cho model này cho đến khi kết nối lại.',
    );

    expect(find.byKey(const Key('composer-blocked')), findsOneWidget);
    expect(find.textContaining('Mất kết nối tới máy phụ Laptop'), findsOneWidget);
    expect(tester.widget<TextField>(composerField()).enabled, isFalse);
  });

  testWidgets('without a block the composer is enabled and shows no reason', (tester) async {
    await pumpCanvas(tester);

    expect(find.byKey(const Key('composer-blocked')), findsNothing);
    expect(tester.widget<TextField>(composerField()).enabled, isTrue);
  });
}
