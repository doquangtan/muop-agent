import 'package:flutter/material.dart';

import 'ui/dashboard_screen.dart';

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

  void _toggleTheme() {
    setState(() {
      _themeMode =
          _themeMode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
    });
  }

  @override
  Widget build(BuildContext context) {
    const seedColor = Color(0xFF0B57D0);

    return MaterialApp(
      title: 'Mướp Agent Monitor — Parallel ERP Agents',
      debugShowCheckedModeBanner: false,
      themeMode: _themeMode,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: seedColor,
          brightness: Brightness.light,
        ),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: seedColor,
          brightness: Brightness.dark,
        ),
      ),
      home: DashboardScreen(
        isDarkMode: _themeMode == ThemeMode.dark,
        onToggleTheme: _toggleTheme,
      ),
    );
  }
}
