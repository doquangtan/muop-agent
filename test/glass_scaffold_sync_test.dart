import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:muop_agent/core/theme/app_theme.dart';
import 'package:muop_agent/core/theme/chat_theme_painter.dart';
import 'package:muop_agent/core/widgets/desktop_panel.dart';
import 'package:muop_agent/core/widgets/liquid_glass.dart';
import 'package:muop_agent/features/agent_map/presentation/agent_map_screen.dart';
import 'package:muop_agent/features/settings/presentation/settings_screen.dart';

void main() {
  testWidgets(
    'GlassScreenScaffold hiển thị nền ChatWallpaperSurface và thanh header dạng LiquidGlassPill',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: buildAppTheme(
              seedColor: const Color(0xFF4C8DFF),
              brightness: Brightness.dark,
            ),
            home: const SettingsScreen(),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(ChatWallpaperSurface), findsOneWidget);
      expect(find.byType(LiquidGlassPill), findsWidgets);
      expect(find.byType(TabBar), findsOneWidget);
      final titlePillWidth = tester
          .getSize(find.byKey(const Key('glass-header-title-pill')))
          .width;
      expect(titlePillWidth, greaterThan(400));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'GlassScreenScaffold hỗ trợ nút quay lại trong PanelScope trên Desktop cùng LiquidGlassPill',
    (tester) async {
      var closed = false;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(
            seedColor: const Color(0xFF4C8DFF),
            brightness: Brightness.light,
          ),
          home: PanelScope(
            open: (_) async {},
            close: () => closed = true,
            child: AgentMapScreen(sessionReader: () => null),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(ChatWallpaperSurface), findsOneWidget);
      expect(find.byType(LiquidGlassPill), findsWidgets);
      expect(find.text('Agent map'), findsOneWidget);

      await tester.tap(find.byTooltip('Quay lại'));
      await tester.pump();
      expect(closed, isTrue);
      expect(tester.takeException(), isNull);
    },
  );
}
