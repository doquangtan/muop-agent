import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:muop_agent/features/setup/domain/setup_entities.dart';
import 'package:muop_agent/features/setup/domain/setup_repository.dart';
import 'package:muop_agent/features/setup/presentation/setup_wizard_screen.dart';

/// Repository giả: trạng thái cố định, không gọi socket
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
  Future<SetupStatus> setToolPath(String tool, String path) async => _status;

  @override
  Future<SetupStatus> configureSsh(String username) async => _status;

  @override
  Future<SetupStatus> autoSetupSsh() async => _status;

  @override
  Future<SetupStatus> verifySsh(String publicKey) async => _status;
}

/// Trạng thái có một tool bắt buộc (`fuse`) với [fuseInstalled] tùy chọn
SetupStatus _status({required bool fuseInstalled}) {
  return SetupStatus.fromJson({
    'ok': true,
    'error': '',
    'completed': false,
    'workspaceRoot': '/home/tester/project',
    'selectedClis': <String>[],
    'tools': [
      {'id': 'git', 'label': 'Git', 'group': 'base', 'installed': true, 'path': '/usr/bin/git', 'installable': false, 'hint': ''},
      {
        'id': 'fuse',
        'label': 'FUSE (fuse3, /dev/fuse)',
        'group': 'base',
        'installed': fuseInstalled,
        'path': fuseInstalled ? '/usr/bin/fusermount3' : '',
        'installable': false,
        'hint': 'sudo apt install fuse3',
      },
      {'id': 'agy', 'label': 'agy', 'group': 'cli', 'installed': false, 'path': '', 'installable': true, 'hint': ''},
    ],
    'aptPackages': [
      {'package': 'git', 'label': 'Git', 'note': 'quản lý mã nguồn', 'installed': true, 'required': true},
      {
        'package': 'fuse3',
        'label': 'FUSE (fusermount3, /dev/fuse)',
        'note': 'mount project của máy khác',
        'installed': fuseInstalled,
        'required': true,
      },
    ],
    'aptInstallCommand': fuseInstalled ? '' : 'sudo apt-get install -y fuse3',
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

Future<void> _pump(WidgetTester tester, SetupStatus status) async {
  tester.view.physicalSize = const Size(900, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: SetupWizardScreen(repository: _FakeSetupRepository(status)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('khi thiếu gói apt, danh sách hiện gói và nút chạy lệnh của server', (tester) async {
    await _pump(tester, _status(fuseInstalled: false));

    expect(find.text('Gói hệ thống (apt)'), findsOneWidget);
    expect(find.textContaining('fuse3'), findsWidgets);
    expect(find.text('Cài các gói còn thiếu bằng sudo'), findsOneWidget);
    // Lệnh lấy từ server, hiển thị để người dùng thấy sẽ chạy gì
    expect(find.text('sudo apt-get install -y fuse3'), findsOneWidget);
  });

  testWidgets('khi đủ gói apt, không có nút cài', (tester) async {
    await _pump(tester, _status(fuseInstalled: true));

    expect(find.text('Gói hệ thống (apt)'), findsOneWidget);
    expect(find.text('Cài các gói còn thiếu bằng sudo'), findsNothing);
  });

  testWidgets('thiếu gói bắt buộc thì ẩn Tiếp tục và báo lý do', (tester) async {
    await _pump(tester, _status(fuseInstalled: false));

    expect(find.widgetWithText(FilledButton, 'Tiếp tục'), findsNothing);
    expect(find.textContaining('Cần cài đủ gói bắt buộc'), findsOneWidget);
  });

  testWidgets('đủ gói bắt buộc thì có Tiếp tục', (tester) async {
    await _pump(tester, _status(fuseInstalled: true));

    expect(find.widgetWithText(FilledButton, 'Tiếp tục'), findsOneWidget);
  });

  testWidgets('không có nút back ở thanh tiêu đề', (tester) async {
    await _pump(tester, _status(fuseInstalled: true));

    expect(find.byType(BackButton), findsNothing);
    expect(find.byIcon(Icons.arrow_back), findsNothing);
    expect(find.byIcon(Icons.arrow_back_rounded), findsNothing);
  });
}
