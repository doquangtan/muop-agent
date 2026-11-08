import 'package:flutter_test/flutter_test.dart';
import 'package:muop_agent/main.dart';

void main() {
  testWidgets('MuopAgentMonitorApp renders title', (WidgetTester tester) async {
    await tester.pumpWidget(const MuopAgentMonitorApp());
    expect(find.text('Mướp Agent Monitor'), findsOneWidget);
  });
}
