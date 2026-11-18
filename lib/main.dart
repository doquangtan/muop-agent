import 'package:material_ui/material_ui.dart';

import 'package:muop_agent/core/theme/app_theme.dart';
import 'package:muop_agent/features/dashboard/presentation/dashboard_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MuopAgentMonitorApp());
}

class MuopAgentMonitorApp extends StatefulWidget {
  const MuopAgentMonitorApp({super.key});

  @override
  State<MuopAgentMonitorApp> createState() => _MuopAgentMonitorAppState();
}

class _MuopAgentMonitorAppState extends State<MuopAgentMonitorApp> {
  ThemeMode _themeMode = ThemeMode.dark;
  Color _seedColor = kDefaultThemeSeed;

  void _toggleTheme() {
    setState(() {
      _themeMode =
          _themeMode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
    });
  }

  void _setSeedColor(Color color) {
    setState(() => _seedColor = color);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Mướp Agent Monitor — Parallel ERP Agents',
      debugShowCheckedModeBanner: false,
      themeMode: _themeMode,
      theme: buildAppTheme(
        seedColor: _seedColor,
        brightness: Brightness.light,
      ),
      darkTheme: buildAppTheme(
        seedColor: _seedColor,
        brightness: Brightness.dark,
      ),
      home: DashboardScreen(
        isDarkMode: _themeMode == ThemeMode.dark,
        onToggleTheme: _toggleTheme,
        seedColor: _seedColor,
        onSeedColorChanged: _setSeedColor,
      ),
    );
  }
}
