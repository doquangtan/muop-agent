import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'package:muop_agent/core/di/app_dependencies.dart';
import 'package:muop_agent/core/state/chat_theme_provider.dart';
import 'package:muop_agent/core/state/server_address_provider.dart';
import 'package:muop_agent/core/theme/app_theme.dart';
import 'package:muop_agent/core/widgets/throttled_ticker.dart';
import 'package:muop_agent/features/dashboard/presentation/dashboard_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Dừng các Timer animation khi app ra nền (không có khung nào được vẽ)
  WidgetsBinding.instance.addObserver(AppActivityObserver());
  // Địa chỉ server và cấu hình theme đã lưu được nạp trước khi dựng màn hình đầu tiên
  final container = ProviderContainer();
  container
      .read(serverAddressProvider.notifier)
      .change(await AppDependencies.connection.loadSavedServerAddress());
  container
      .read(chatThemeProvider.notifier)
      .hydrate(await ChatThemeNotifier.loadSavedConfig());
  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const MuopAgentMonitorApp(),
    ),
  );
}

class MuopAgentMonitorApp extends ConsumerWidget {
  const MuopAgentMonitorApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chatConfig = ref.watch(chatThemeProvider);
    final notifier = ref.read(chatThemeProvider.notifier);
    final seed = chatConfig.isDark
        ? chatConfig.preset.accentDark
        : chatConfig.preset.accentLight;

    return MaterialApp(
      title: 'Mướp Agents',
      debugShowCheckedModeBanner: false,
      themeMode: chatConfig.isDark ? ThemeMode.dark : ThemeMode.light,
      theme: buildAppTheme(
        seedColor: seed,
        brightness: Brightness.light,
        chatTheme: chatConfig,
      ),
      darkTheme: buildAppTheme(
        seedColor: seed,
        brightness: Brightness.dark,
        chatTheme: chatConfig,
      ),
      home: DashboardScreen(
        isDarkMode: chatConfig.isDark,
        onToggleTheme: notifier.toggleBrightness,
        seedColor: seed,
        onSeedColorChanged: (_) {},
      ),
    );
  }
}
