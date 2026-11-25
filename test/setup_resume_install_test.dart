import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:muop_agent/features/setup/domain/setup_entities.dart';
import 'package:muop_agent/features/setup/domain/setup_repository.dart';
import 'package:muop_agent/features/setup/presentation/setup_wizard_screen.dart';

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

/// Đã hoàn tất khởi tạo (completed), agy đã cài xong, claude đang được cài trên server (app bị thoát giữa chừng)
SetupStatus _resumedInstall() {
  return SetupStatus.fromJson({
    'ok': true,
    'error': '',
    'completed': true,
    'workspaceRoot': '/home/tester/project',
    'selectedClis': ['agy', 'claude'],
    'tools': [
      for (final id in ['git', 'ssh', 'curl'])
        {'id': id, 'label': id, 'group': 'base', 'installed': true, 'path': '/usr/bin/$id', 'installable': false, 'hint': ''},
      {'id': 'agy', 'label': 'agy', 'group': 'cli', 'installed': true, 'path': '/home/tester/.local/bin/agy', 'installable': true, 'hint': ''},
      {'id': 'claude', 'label': 'claude', 'group': 'cli', 'installed': false, 'path': '', 'installable': true, 'hint': ''},
    ],
    'job': {
      'tool': 'claude',
      'state': 'running',
      'log': ['Downloading claude…'],
      'error': '',
      'startedAt': '2026-11-23T16:00:00Z',
      'finishedAt': '',
    },
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

void main() {
  test('đang cài dở thì vẫn coi là chưa khởi tạo xong (splash mở wizard)', () {
    final status = _resumedInstall();
    expect(status.installing, isTrue);
    expect(status.needsSetup, isTrue);
  });

  testWidgets('mở lại app lúc đang cài: wizard ở bước Chọn CLI và hiện tiến trình, không nhảy sang Đăng nhập',
      (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: SetupWizardScreen(repository: _FakeSetupRepository(_resumedInstall())),
        ),
      ),
    );
    // Không dùng pumpAndSettle: thanh tiến trình đang cài chạy hoạt ảnh liên tục
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.text('Chọn CLI'), findsOneWidget);
    expect(find.text('Đang cài Claude Code CLI…'), findsOneWidget);
    expect(find.text('Downloading claude…'), findsOneWidget);
    // Đang cài thì không cho bấm cài/đi tiếp
    final installButton = tester.widgetList<FilledButton>(find.byType(FilledButton));
    expect(installButton.every((b) => b.onPressed == null), isTrue);
  });
}
