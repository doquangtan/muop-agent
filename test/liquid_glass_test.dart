import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:muop_agent/core/widgets/glass_scaffold.dart';
import 'package:muop_agent/core/widgets/liquid_glass.dart';

void main() {
  testWidgets('kính không dùng BackdropFilter (không blur nền)', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: Column(
              children: [
                LiquidGlassPill(child: Text('kính')),
                GlassHeaderSurface(child: Text('header')),
              ],
            ),
          ),
        ),
      ),
    );
    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.text('kính'), findsOneWidget);
    expect(find.text('header'), findsOneWidget);
  });
}
