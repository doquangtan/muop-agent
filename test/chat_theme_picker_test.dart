import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:muop_agent/core/state/chat_theme_provider.dart';
import 'package:muop_agent/core/theme/app_theme.dart';
import 'package:muop_agent/core/theme/chat_theme.dart';
import 'package:muop_agent/features/chat/presentation/chat_canvas_view.dart';
import 'package:muop_agent/features/dashboard/presentation/widgets/chat_theme_picker_sheet.dart';
import 'package:muop_agent/features/projects/domain/project_entities.dart';
import 'package:muop_agent/features/sessions/domain/session_entities.dart';

ConversationSession _sampleSession() {
  return ConversationSession(
    id: 'cid-theme-1',
    title: 'Theme Test',
    createdAt: DateTime(2026, 11, 23, 8),
    updatedAt: DateTime(2026, 11, 23, 9),
    status: AgentStatus.completed,
    currentPhase: AgentWorkflowPhase.completed,
    steps: [
      AgentStep(
        stepIndex: 0,
        source: 'USER_EXPLICIT',
        type: 'USER_INPUT',
        status: 'DONE',
        createdAt: DateTime(2026, 11, 23, 9, 0, 0),
        content: 'Kiểm tra đổi màu widget user',
        thinking: '',
        toolCalls: const [],
        inputTokens: 0,
        outputTokens: 0,
        cacheReadTokens: 0,
        agentName: 'Coordinator',
        phase: AgentWorkflowPhase.completed,
        vietnameseTitle: 'Yêu cầu',
        vietnameseDetail: '',
      ),
      AgentStep(
        stepIndex: 1,
        source: 'MODEL',
        type: 'PLANNER_RESPONSE',
        status: 'DONE',
        createdAt: DateTime(2026, 11, 23, 9, 0, 1),
        content: 'Đã cập nhật widget AI phản hồi và nền mới.',
        thinking: '',
        toolCalls: const [],
        inputTokens: 0,
        outputTokens: 0,
        cacheReadTokens: 0,
        agentName: 'Coordinator',
        phase: AgentWorkflowPhase.completed,
        vietnameseTitle: 'Hoàn tất',
        vietnameseDetail: '',
      ),
    ],
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
  test('có đúng 6 bộ theme và 6 kiểu hình nền hỗ trợ cả Dark và Light', () {
    expect(kChatThemePresets, hasLength(6));
    expect(kWallpaperPresets, hasLength(6));
    expect(
      kWallpaperPresets.map((w) => w.pattern).toSet(),
      hasLength(6),
    );

    for (final preset in kChatThemePresets) {
      final config = ChatThemeConfig(presetId: preset.id);
      final dark = ChatAppearanceColors.resolve(config, Brightness.dark);
      final light = ChatAppearanceColors.resolve(config, Brightness.light);

      expect(dark.wallpaperGradient, isNot(equals(light.wallpaperGradient)));
      expect(dark.aiBubbleBackground, isNot(equals(light.aiBubbleBackground)));
      expect(dark.userBubbleGradient, isNotEmpty);
      expect(light.userBubbleGradient, isNotEmpty);
    }
  });

  testWidgets(
    'ChatThemePickerSheet đổi được 6 preset, tùy chỉnh riêng User/AI/nền và Dark/Light',
    (tester) async {
      tester.view.physicalSize = const Size(430, 880);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        ProviderScope(
          child: Consumer(
            builder: (context, ref, _) {
              final cfg = ref.watch(chatThemeProvider);
              return MaterialApp(
                themeMode: cfg.isDark ? ThemeMode.dark : ThemeMode.light,
                theme: buildAppTheme(
                  seedColor: cfg.preset.accentLight,
                  brightness: Brightness.light,
                  chatTheme: cfg,
                ),
                darkTheme: buildAppTheme(
                  seedColor: cfg.preset.accentDark,
                  brightness: Brightness.dark,
                  chatTheme: cfg,
                ),
                home: const Scaffold(body: ChatThemePickerSheet()),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      for (final preset in kChatThemePresets) {
        expect(find.byKey(Key('theme-preset-${preset.id}')), findsOneWidget);
      }
      expect(find.byKey(const Key('theme-live-preview')), findsOneWidget);

      // Chọn preset Ngọc Lam
      await tester.tap(find.byKey(const Key('theme-preset-lagoon_diamond')));
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ChatThemePickerSheet)),
      );
      expect(container.read(chatThemeProvider).presetId, 'lagoon_diamond');

      // Tùy chỉnh riêng từng phần: nền Toán Học, User Hồng Đào, AI Trung Tính
      await tester.ensureVisible(
        find.byKey(const Key('wallpaper-option-math_emerald')),
      );
      await tester.tap(find.byKey(const Key('wallpaper-option-math_emerald')));
      await tester.pumpAndSettle();

      await tester.ensureVisible(
        find.byKey(const Key('user-bubble-option-sakura_rose')),
      );
      await tester.tap(find.byKey(const Key('user-bubble-option-sakura_rose')));
      await tester.pumpAndSettle();

      await tester.ensureVisible(
        find.byKey(const Key('ai-bubble-option-pure_neutral')),
      );
      await tester.tap(find.byKey(const Key('ai-bubble-option-pure_neutral')));
      await tester.pumpAndSettle();

      final customized = container.read(chatThemeProvider);
      expect(customized.effectiveWallpaperId, 'math_emerald');
      expect(customized.effectiveUserBubbleId, 'sakura_rose');
      expect(customized.effectiveAiBubbleId, 'pure_neutral');

      // Đổi Dark -> Light ngay trong sheet
      await tester.ensureVisible(
        find.byKey(const Key('theme-picker-brightness-toggle')),
      );
      await tester.tap(
        find.byKey(const Key('theme-picker-brightness-toggle')),
      );
      await tester.pumpAndSettle();
      expect(container.read(chatThemeProvider).isDark, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('widget user, AI card và nền chat áp dụng đúng ChatAppearanceColors', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(960, 760);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    const cfg = ChatThemeConfig(
      presetId: 'violet_dusk',
      customWallpaperId: 'math_emerald',
      customUserBubbleId: 'sunset_ember',
      customAiBubbleId: 'lagoon_ai',
      isDark: false,
    );
    final expected = ChatAppearanceColors.resolve(cfg, Brightness.light);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(
          seedColor: cfg.preset.accentLight,
          brightness: Brightness.light,
          chatTheme: cfg,
        ),
        home: Scaffold(
          body: ChatCanvasView(
            session: _sampleSession(),
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

    final userContainer = tester.widget<Container>(
      find.byKey(const Key('chat-user-bubble')),
    );
    final userDeco = userContainer.decoration! as BoxDecoration;
    expect(
      (userDeco.gradient! as LinearGradient).colors,
      expected.userBubbleGradient,
    );

    final aiContainer = tester.widget<Container>(
      find.byKey(const Key('chat-ai-card')),
    );
    final aiDeco = aiContainer.decoration! as BoxDecoration;
    expect(aiDeco.color, expected.aiBubbleBackground);
    expect(find.byKey(const Key('chat-telegram-wallpaper')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktopLeftInset dịch nội dung chat nhưng nền vẫn tràn full 0..width', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
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
            session: _sampleSession(),
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
            desktopLeftInset: 536,
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

    final wallpaperRect = tester.getRect(
      find.byKey(const Key('chat-telegram-wallpaper')),
    );
    expect(wallpaperRect.left, 0.0);
    expect(wallpaperRect.width, 1440.0);

    final dockRect = tester.getRect(find.byKey(const Key('chat-dock-island')));
    expect(dockRect.left, greaterThanOrEqualTo(536.0));
    expect(dockRect.width, closeTo(1440.0 - 536.0 - 32.0, 1.0));
    expect(tester.takeException(), isNull);
  });
}
