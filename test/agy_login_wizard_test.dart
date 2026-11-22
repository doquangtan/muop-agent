import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:muop_agent/core/theme/app_theme.dart';
import 'package:muop_agent/features/agy_auth/domain/agy_auth_entities.dart';
import 'package:muop_agent/features/agy_auth/domain/agy_auth_repository.dart';
import 'package:muop_agent/features/claude_auth/domain/claude_auth_repository.dart';
import 'package:muop_agent/features/claude_auth/domain/claude_auth_entities.dart';
import 'package:muop_agent/features/setup/domain/setup_entities.dart';
import 'package:muop_agent/features/setup/domain/setup_repository.dart';
import 'package:muop_agent/features/setup/presentation/setup_wizard_screen.dart';
import 'package:muop_agent/features/ssh/presentation/ssh_terminal_panel.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

const _sid = 'sid-wizard-1';
const _link = 'https://accounts.google.com/o/oauth2/auth?state=wiz';

/// Setup đã xong, agy là CLI đã cài, SSH sẵn sàng: wizard vào thẳng bước đăng nhập agy
SetupStatus _setupDone() => SetupStatus.fromJson({
      'ok': true,
      'error': '',
      'completed': true,
      'workspaceRoot': '/home/tester/project',
      'selectedClis': ['agy'],
      'tools': [
        for (final id in ['git', 'ssh', 'curl'])
          {'id': id, 'label': id, 'group': 'base', 'installed': true, 'path': '/usr/bin/$id', 'installable': false, 'hint': ''},
        {'id': 'agy', 'label': 'agy', 'group': 'cli', 'installed': true, 'path': '/usr/bin/agy', 'installable': true, 'hint': ''},
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

AgyAuthState _terminal({String loginUrl = '', String stage = ''}) => AgyAuthState(
      ok: true,
      loggedIn: false,
      error: '',
      phase: 'login_terminal',
      sshSessionId: _sid,
      sshHostId: 6,
      loginUrl: loginUrl,
      loginStage: stage,
    );

class _FakeSetupRepository implements SetupRepository {
  @override
  Stream<SetupStatus> get updates => const Stream.empty();

  @override
  Future<SetupStatus> fetchStatus() async => _setupDone();

  @override
  Future<SetupStatus> install(String tool) async => _setupDone();

  @override
  Future<SetupStatus> selectClis(List<String> clis) async => _setupDone();

  @override
  Future<SetupStatus> complete() async => _setupDone();

  @override
  Future<SetupStatus> setWorkspace(String path) async => _setupDone();

  @override
  Future<SetupStatus> setToolPath(String tool, String path) async => _setupDone();

  @override
  Future<SetupStatus> configureSsh(String username) async => _setupDone();

  @override
  Future<SetupStatus> autoSetupSsh() async => _setupDone();

  @override
  Future<SetupStatus> verifySsh(String publicKey) async => _setupDone();
}

class _FakeAgyRepository implements AgyAuthRepository {
  _FakeAgyRepository({required this.status});

  AgyAuthState status;
  final _updates = StreamController<AgyAuthState>.broadcast();

  void emit(AgyAuthState s) => _updates.add(s);

  Future<void> dispose() => _updates.close();

  @override
  Stream<AgyAuthState> get updates => _updates.stream;

  @override
  Future<AgyAuthState> fetchStatus() async => status;

  @override
  Future<AccountsStatus> fetchAccounts() async => AccountsStatus.empty;

  @override
  Future<AgyAuthState> logout() async => AgyAuthState.failure('');

  @override
  Future<AgyAuthState> checkStatus() async => status;

  @override
  Future<AgyAuthState> startLogin() async {
    status = _terminal();
    return status;
  }

  @override
  Future<AgyAuthState> submitCode(String code) async => status;

  @override
  Future<AgyAuthState> cancelLogin() async => AgyAuthState.failure('');

}

/// Spinner của bước `verifying` không bao giờ "settle": màn đó dùng settle: false
Future<void> _pump(WidgetTester tester, _FakeAgyRepository agy, {bool settle = true}) async {
  addTearDown(agy.dispose);
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(800, 1400);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(ProviderScope(child: MaterialApp(
      theme: buildAppTheme(seedColor: const Color(0xFF00897B), brightness: Brightness.light),
      home: SetupWizardScreen(
        repository: _FakeSetupRepository(),
        agyRepository: agy,
        claudeRepository: _FakeClaudeRepo(),
      ),
    ),));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    // Các future giả (trạng thái, kiểm tra TUI) hoàn tất sau vài frame; spinner không settle
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('wizard: có link thì hiện link, ô mã, nút Xác nhận bên dưới terminal SSH', (tester) async {
    final agy = _FakeAgyRepository(status: _terminal(loginUrl: _link, stage: 'awaiting_token'));
    await _pump(tester, agy);

    expect(find.byType(SshTerminalPanel), findsOneWidget);
    expect(find.text('Mở link'), findsOneWidget);
    expect(find.text('Sao chép'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Mã xác thực'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Xác nhận'), findsOneWidget);
  });

  testWidgets('wizard: agy báo lỗi sau khi xác nhận: quay về nút Đăng nhập bằng Google', (tester) async {
    final agy = _FakeAgyRepository(status: _terminal(loginUrl: _link, stage: 'verifying'));
    await _pump(tester, agy, settle: false);

    expect(find.byType(SshTerminalPanel), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Mã xác thực'), findsOneWidget);

    agy.emit(const AgyAuthState(
      ok: false,
      loggedIn: false,
      error: 'Xác thực thất bại: Malformed auth code. Bấm Đăng nhập bằng Google để thử lại.',
      phase: 'failed',
    ));
    await tester.pump();
    await tester.pumpAndSettle();

    // Lỗi không bị hiểu thành "không lấy được trạng thái": vẫn có nút đăng nhập và thông báo lỗi
    expect(find.text('Đăng nhập bằng Google'), findsOneWidget);
    expect(find.textContaining('Malformed auth code'), findsOneWidget);
    expect(find.text('Thử lại'), findsNothing);
    expect(find.byType(SshTerminalPanel), findsNothing);
  });
}

class _FakeClaudeRepo implements ClaudeAuthRepository {
  final bool loggedIn = false;

  @override
  Stream<ClaudeAuthState> get updates => const Stream.empty();

  @override
  Future<ClaudeAuthState> fetchStatus() async => ClaudeAuthState(
        ok: true,
        loggedIn: loggedIn,
        email: loggedIn ? 'claude@example.com' : '',
        subscriptionType: loggedIn ? 'pro' : '',
        loginUrl: '',
        error: '',
      );

  @override
  Future<ClaudeAuthState> logout() async => fetchStatus();

  @override
  Future<ClaudeAuthState> startLogin() async => fetchStatus();

  @override
  Future<ClaudeAuthState> submitCode(String code) async => fetchStatus();

  @override
  Future<ClaudeAuthState> cancelLogin() async => fetchStatus();
}
