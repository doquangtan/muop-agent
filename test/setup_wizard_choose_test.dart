import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:muop_agent/features/setup/domain/setup_entities.dart';
import 'package:muop_agent/features/setup/domain/setup_repository.dart';
import 'package:muop_agent/features/setup/presentation/setup_wizard_screen.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Repository giả: trả về một trạng thái cố định, không gọi socket
class _FakeSetupRepository implements SetupRepository {
  _FakeSetupRepository(this._status);

  final SetupStatus _status;

  @override
  Stream<SetupStatus> get updates => const Stream.empty();

  @override
  Future<SetupStatus> fetchStatus() async => _status;

  @override
  Future<SetupStatus> install(String tool) async => _status;

  @override
  Future<SetupStatus> selectClis(List<String> clis) async => _status;

  @override
  Future<SetupStatus> complete() async => _status;

  @override
  Future<SetupStatus> setWorkspace(String path) async => _status;

  @override
  Future<SetupDirListing> browseDirectories(String path) async =>
      SetupDirListing.failure('không dùng trong test');

  @override
  Future<SetupStatus> setToolPath(String tool, String path) async => _status;

  @override
  Future<SetupStatus> configureSsh(String username) async => _status;

  @override
  Future<SetupStatus> autoSetupSsh() async => _status;

  @override
  Future<SetupStatus> verifySsh(String publicKey) async => _status;
}

SetupStatus _status({
  required List<String> selectedClis,
  required List<String> installed,
}) {
  return SetupStatus.fromJson({
    'ok': true,
    'error': '',
    'completed': false,
    'workspaceRoot': '/home/tester/project',
    'selectedClis': selectedClis,
    'tools': [
      for (final id in ['git', 'ssh', 'curl'])
        {'id': id, 'label': id, 'group': 'base', 'installed': true, 'path': '/usr/bin/$id', 'installable': false, 'hint': ''},
      for (final id in ['agy', 'claude'])
        {'id': id, 'label': id, 'group': 'cli', 'installed': installed.contains(id), 'path': '', 'installable': true, 'hint': ''},
    ],
    'job': null,
    'ssh': {
      'client': true,
      'sshdRunning': true,
      'username': 'john',
      'keyPath': '/home/john/.ssh/muop_agent_ed25519',
      'keyExists': true,
      'publicKey': 'ssh-ed25519 AAAA muop-agent',
      'keyAuthorized': true,
      'loginOk': true,
      'ready': true,
    },
  });
}

/// Mở wizard, bấm "Tiếp tục" ở bước kiểm tra để sang bước chọn CLI
Future<void> _gotoChooseStep(WidgetTester tester, SetupStatus status) async {
  await tester.pumpWidget(ProviderScope(child: MaterialApp(
      home: SetupWizardScreen(
        repository: _FakeSetupRepository(status),
      ),
    ),));
  await tester.pumpAndSettle();
  // Khối SSH đẩy nút xuống dưới: cuộn tới nút rồi mới bấm
  final next = find.widgetWithText(FilledButton, 'Tiếp tục');
  await tester.ensureVisible(next);
  await tester.pumpAndSettle();
  await tester.tap(next);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows only Tiếp tục when the selected CLI is already installed', (tester) async {
    await _gotoChooseStep(
      tester,
      _status(selectedClis: ['agy'], installed: ['agy', 'claude']),
    );
    expect(find.widgetWithText(OutlinedButton, 'Cài thêm phần đã chọn'), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Tiếp tục'), findsOneWidget);
  });

  testWidgets('một CLI đã cài là đi tiếp được, CLI còn lại chỉ là nút cài thêm', (tester) async {
    await _gotoChooseStep(
      tester,
      _status(selectedClis: ['claude'], installed: ['agy']),
    );
    expect(find.widgetWithText(FilledButton, 'Tiếp tục'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Cài thêm phần đã chọn'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Cài & tiếp tục'), findsNothing);
  });

  testWidgets('chưa có CLI nào cài: chỉ có Cài đã chọn, không có Tiếp tục', (tester) async {
    await _gotoChooseStep(
      tester,
      _status(selectedClis: ['agy'], installed: []),
    );
    expect(find.widgetWithText(FilledButton, 'Cài đã chọn'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Tiếp tục'), findsNothing);
  });
}
