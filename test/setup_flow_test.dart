import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:muop_agent/core/state/setup_check_provider.dart';
import 'package:muop_agent/core/theme/app_theme.dart';
import 'package:muop_agent/features/setup/domain/setup_entities.dart';
import 'package:muop_agent/features/setup/domain/setup_repository.dart';
import 'package:muop_agent/features/setup/presentation/setup_flow.dart';
import 'package:muop_agent/features/setup/presentation/setup_splash_screen.dart';

/// Repository giả: `fetchStatus` trả về khi test hoàn tất [pending]
class _FakeSetupRepo implements SetupRepository {
  _FakeSetupRepo(this.pending);

  final Completer<SetupStatus> pending;

  @override
  Stream<SetupStatus> get updates => const Stream.empty();

  @override
  Future<SetupStatus> fetchStatus() => pending.future;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Trạng thái đã đủ: đã khởi tạo, có thư mục project, CLI đã chọn đã cài, không thiếu tool bắt buộc
const _readyStatus = SetupStatus(
  ok: true,
  error: '',
  completed: true,
  selectedClis: ['claude'],
  tools: [
    SetupTool(
      id: 'claude',
      label: 'Claude Code',
      group: 'cli',
      installed: true,
      path: '/usr/bin/claude',
      installable: true,
      hint: '',
    ),
  ],
  job: null,
  ssh: SetupSsh.empty,
  workspaceRoot: '/workspace',
  workspaceReady: true,
);

void main() {
  group('setupCheckedAddressProvider', () {
    test('claim chỉ đúng một lần cho mỗi địa chỉ; mark đánh dấu mà không cần claim', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(setupCheckedAddressProvider.notifier);

      expect(notifier.claim('10.0.0.2:8787'), isTrue);
      expect(notifier.claim('10.0.0.2:8787'), isFalse, reason: 'cùng địa chỉ đã được kiểm tra');

      notifier.mark('10.0.0.3:8787');
      expect(notifier.claim('10.0.0.3:8787'), isFalse, reason: 'đã mark thì không mở lại');
      expect(notifier.claim('10.0.0.2:8787'), isTrue, reason: 'địa chỉ khác thì được mở');
    });
  });

  testWidgets('runSetupFlow: splash hiện trong lúc chờ máy trả lời, tự đóng khi đã đủ mục', (tester) async {
    final pending = Completer<SetupStatus>();
    final repo = _FakeSetupRepo(pending);
    bool? finished;

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(seedColor: const Color(0xFF00897B), brightness: Brightness.light),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                finished = await runSetupFlow(
                  Navigator.of(context),
                  '10.0.0.2:8787',
                  setupRepository: repo,
                );
              },
              child: const Text('kết nối'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('kết nối'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(SetupSplashScreen), findsOneWidget, reason: 'splash phải hiện ngay khi bắt đầu');

    pending.complete(_readyStatus);
    await tester.pumpAndSettle();

    expect(find.byType(SetupSplashScreen), findsNothing, reason: 'máy đã đủ mục thì splash tự đóng');
    expect(finished, isTrue);
  });

  testWidgets('đổi IP làm dựng lại Navigator lồng: splash vẫn mở qua Navigator gốc đã chụp', (tester) async {
    final pending = Completer<SetupStatus>();
    final repo = _FakeSetupRepo(pending);
    NavigatorState? rootCaptured;

    // Mô phỏng vùng panel desktop: Navigator lồng trong widget được dựng lại theo key (địa chỉ máy chủ)
    Widget host(String address) => MaterialApp(
          theme: buildAppTheme(seedColor: const Color(0xFF00897B), brightness: Brightness.light),
          home: Scaffold(
            body: KeyedSubtree(
              key: ValueKey(address),
              child: Navigator(
                onGenerateRoute: (_) => MaterialPageRoute<void>(
                  builder: (ctx) => Center(
                    child: TextButton(
                      onPressed: () => rootCaptured = Navigator.of(ctx, rootNavigator: true),
                      child: const Text('chụp'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );

    await tester.pumpWidget(host('10.0.0.2:8787'));
    await tester.tap(find.text('chụp'));
    await tester.pump();
    expect(rootCaptured, isNotNull);

    // Đổi địa chỉ: Navigator lồng bị hủy và dựng lại
    await tester.pumpWidget(host('10.0.0.3:8787'));
    await tester.pump();

    final flow = runSetupFlow(rootCaptured!, '10.0.0.3:8787', setupRepository: repo);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(SetupSplashScreen), findsOneWidget, reason: 'splash phải hiện dù Navigator lồng đã bị hủy');
    pending.complete(_readyStatus);
    await tester.pumpAndSettle();
    expect(find.byType(SetupSplashScreen), findsNothing);
    expect(await flow, isTrue);
  });
}
