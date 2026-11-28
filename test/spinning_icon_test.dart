import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:muop_agent/core/widgets/spinning_icon.dart';

Widget _host({required bool reduceMotion, required Widget child}) {
  return MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: reduceMotion),
      child: Scaffold(body: Center(child: child)),
    ),
  );
}

/// Góc quay hiện tại (radian) đọc từ ma trận của Transform.rotate bên trong icon
double _turns(WidgetTester tester) {
  final transform = tester.widget<Transform>(
    find.descendant(
      of: find.byType(SpinningIcon),
      matching: find.byType(Transform),
    ),
  );
  final m = transform.transform.storage;
  return math.atan2(m[1], m[0]);
}

void main() {
  testWidgets('icon quay khi spinning là true', (tester) async {
    await tester.pumpWidget(
      _host(
        reduceMotion: false,
        child: const SpinningIcon(icon: Icons.hourglass_top_rounded),
      ),
    );
    final before = _turns(tester);
    await tester.pump(const Duration(milliseconds: 350));
    expect(_turns(tester), isNot(before));
  });

  testWidgets('icon đứng yên khi spinning là false', (tester) async {
    await tester.pumpWidget(
      _host(
        reduceMotion: false,
        child: const SpinningIcon(
          icon: Icons.hourglass_top_rounded,
          spinning: false,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 350));
    expect(_turns(tester), 0);
  });

  testWidgets('icon không quay khi hệ thống giảm chuyển động', (tester) async {
    await tester.pumpWidget(
      _host(
        reduceMotion: true,
        child: const SpinningIcon(icon: Icons.hourglass_top_rounded),
      ),
    );
    await tester.pump(const Duration(milliseconds: 350));
    expect(_turns(tester), 0);
  });

  testWidgets('dừng quay khi spinning chuyển sang false', (tester) async {
    Widget build(bool spinning) => _host(
      reduceMotion: false,
      child: SpinningIcon(
        icon: Icons.hourglass_top_rounded,
        spinning: spinning,
      ),
    );
    await tester.pumpWidget(build(true));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpWidget(build(false));
    await tester.pump(const Duration(milliseconds: 200));
    expect(_turns(tester), 0);
  });
}
