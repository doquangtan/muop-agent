import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:muop_agent/core/widgets/spinning_icon.dart';
import 'package:muop_agent/core/widgets/throttled_linear_progress.dart';
import 'package:muop_agent/core/widgets/throttled_ticker.dart';

Widget _host({required bool tickerOn}) {
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: TickerMode(
          enabled: tickerOn,
          child: const SpinningIcon(icon: Icons.hourglass_top_rounded),
        ),
      ),
    ),
  );
}

/// Góc quay hiện tại (radian) đọc từ Transform.rotate bên trong SpinningIcon
double _angle(WidgetTester tester) {
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
  tearDown(() => AppActivity.foreground.value = true);

  testWidgets(
    'tạm dừng khi TickerMode tắt (chat nằm dưới panel), tiếp tục khi bật lại',
    (tester) async {
      await tester.pumpWidget(_host(tickerOn: true));
      await tester.pump(const Duration(milliseconds: 200));

      await tester.pumpWidget(_host(tickerOn: false));
      final paused = _angle(tester);
      await tester.pump(const Duration(milliseconds: 500));
      expect(_angle(tester), paused, reason: 'không được quay khi bị ẩn');

      await tester.pumpWidget(_host(tickerOn: true));
      await tester.pump(const Duration(milliseconds: 200));
      expect(_angle(tester), isNot(paused), reason: 'phải quay lại khi hiện');
    },
  );

  testWidgets('ticker dừng khi app ra nền, chạy lại khi quay lại foreground', (
    tester,
  ) async {
    final ticker = ThrottledTicker()..period = const Duration(seconds: 1);
    ticker.start(interval: const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 250));
    final before = ticker.phase.value;

    AppActivity.foreground.value = false;
    await tester.pump(const Duration(milliseconds: 500));
    expect(ticker.phase.value, before, reason: 'app ra nền thì không tick');
    expect(ticker.isRunning, isFalse);

    AppActivity.foreground.value = true;
    await tester.pump(const Duration(milliseconds: 250));
    expect(ticker.phase.value, isNot(before), reason: 'quay lại thì tick tiếp');
    ticker.dispose();
  });

  testWidgets('thanh tiến trình không xác định vẽ được và không lỗi layout', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(children: [ThrottledLinearProgress(minHeight: 2)]),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(ThrottledLinearProgress), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
