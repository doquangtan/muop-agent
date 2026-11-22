import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:muop_agent/core/di/app_dependencies.dart';
import 'package:muop_agent/main.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

void main() {
  testWidgets('MuopAgentMonitorApp renders title', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());

    await tester.pumpWidget(ProviderScope(child: const MuopAgentMonitorApp()));
    expect(find.byType(MaterialApp), findsOneWidget);
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.title, 'Mướp Agents');
    // Dashboard mở socket tới server thật: dựng lại cây (hủy timer) và ngắt socket trước khi kết thúc test
    await tester.pumpWidget(const SizedBox());
    AppDependencies.socket.disconnect();
    // Bơm thời gian ảo để timer kết nối còn lại (lookup/ping) kết thúc trước khi test đóng
    await tester.pump(const Duration(seconds: 1));
  });
}
