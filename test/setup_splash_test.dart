import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:muop_agent/features/agy_auth/domain/agy_auth_entities.dart';
import 'package:muop_agent/features/agy_auth/domain/agy_auth_repository.dart';
import 'package:muop_agent/features/setup/domain/setup_entities.dart';
import 'package:muop_agent/features/setup/domain/setup_repository.dart';
import 'package:muop_agent/features/setup/presentation/setup_splash_screen.dart';

/// Repository agy giả: chỉ trả kết quả kiểm tra TUI đã cho
class _FakeAgy implements AgyAuthRepository {
  _FakeAgy({required this.loginRequired});

  final bool loginRequired;

  @override
  Stream<AgyAuthState> get updates => const Stream.empty();

  @override
  Future<AgyAuthState> fetchStatus() async => loginRequired
      ? const AgyAuthState(ok: true, loggedIn: false, error: '', phase: 'logged_out')
      : const AgyAuthState(ok: true, loggedIn: true, error: '', phase: 'logged_in');

  @override
  Future<AccountsStatus> fetchAccounts() async => AccountsStatus.empty;

  @override
  Future<AgyAuthState> logout() async => AgyAuthState.failure('');

  @override
  Future<AgyAuthState> checkStatus() async => AgyAuthState.failure('');

  @override
  Future<AgyAuthState> startLogin() async => AgyAuthState.failure('');

  @override
  Future<AgyAuthState> submitCode(String code) async => AgyAuthState.failure('');

  @override
  Future<AgyAuthState> cancelLogin() async => AgyAuthState.failure('');
}

/// Trả lần lượt các trạng thái đã cho; lần cuối được lặp lại
class _FakeSetupRepository implements SetupRepository {
  _FakeSetupRepository(this._responses);

  final List<SetupStatus> _responses;
  int calls = 0;

  @override
  Stream<SetupStatus> get updates => const Stream.empty();

  @override
  Future<SetupStatus> fetchStatus() async {
    final i = calls < _responses.length ? calls : _responses.length - 1;
    calls++;
    return _responses[i];
  }

  @override
  Future<SetupStatus> install(String tool) async => SetupStatus.empty;

  @override
  Future<SetupStatus> selectClis(List<String> clis) async => SetupStatus.empty;

  @override
  Future<SetupStatus> complete() async => SetupStatus.empty;

  @override
  Future<SetupStatus> configureSsh(String username) async => SetupStatus.empty;

  @override
  Future<SetupStatus> autoSetupSsh() async => SetupStatus.empty;

  @override
  Future<SetupStatus> verifySsh(String publicKey) async => SetupStatus.empty;
}

SetupStatus _status({
  required bool completed,
  required List<String> clis,
  required List<String> installed,
}) {
  const baseIds = ['git', 'ssh', 'curl'];
  return SetupStatus.fromJson({
    'ok': true,
    'error': '',
    'completed': completed,
    'selectedClis': clis,
    'tools': [
      for (final id in baseIds)
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

/// Mở splash như dashboard làm, trả về danh sách kết quả khi splash đóng
Future<List<bool?>> _openSplash(
  WidgetTester tester,
  SetupRepository repo, {
  bool agyLoginRequired = false,
}) async {
  final results = <bool?>[];
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async {
              results.add(
                await Navigator.of(context).push<bool>(
                  MaterialPageRoute<bool>(
                    builder: (_) => SetupSplashScreen(
                      serverAddress: '192.168.31.216:8787',
                      repository: repo,
                      agyRepository: _FakeAgy(loginRequired: agyLoginRequired),
                    ),
                  ),
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pump();
  return results;
}

void main() {
  test('needsSetup is false only when completed, CLIs chosen and installed, base tools present', () {
    expect(_status(completed: true, clis: ['agy'], installed: ['agy']).needsSetup, isFalse);
    expect(_status(completed: false, clis: ['agy'], installed: ['agy']).needsSetup, isTrue);
    expect(_status(completed: true, clis: [], installed: []).needsSetup, isTrue);
    expect(_status(completed: true, clis: ['agy', 'claude'], installed: ['agy']).needsSetup, isTrue);
  });

  testWidgets('splash closes with false when setup is complete', (tester) async {
    final repo = _FakeSetupRepository([
      _status(completed: true, clis: ['agy'], installed: ['agy']),
    ]);
    final results = await _openSplash(tester, repo);
    await tester.pumpAndSettle();
    expect(results, [false]);
  });

  testWidgets('splash closes with true when a CLI is missing', (tester) async {
    final repo = _FakeSetupRepository([
      _status(completed: true, clis: ['claude'], installed: []),
    ]);
    final results = await _openSplash(tester, repo);
    await tester.pumpAndSettle();
    expect(results, [true]);
  });

  testWidgets('setup complete but agy not logged in opens the wizard', (tester) async {
    final repo = _FakeSetupRepository([
      _status(completed: true, clis: ['agy'], installed: ['agy']),
    ]);
    final results = await _openSplash(tester, repo, agyLoginRequired: true);
    await tester.pumpAndSettle();
    expect(results, [true]);
  });

  testWidgets('setup complete and agy logged in goes straight to the app', (tester) async {
    final repo = _FakeSetupRepository([
      _status(completed: true, clis: ['agy'], installed: ['agy']),
    ]);
    final results = await _openSplash(tester, repo, agyLoginRequired: false);
    await tester.pumpAndSettle();
    expect(results, [false]);
  });

  testWidgets('splash shows retry and skip when server stays unreachable', (tester) async {
    final repo = _FakeSetupRepository([SetupStatus.failure('Chưa kết nối tới server')]);
    final results = await _openSplash(tester, repo);
    for (var i = 0; i < SetupSplashScreen.maxAttempts + 2; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    await tester.pumpAndSettle();
    expect(find.text('Thử lại'), findsOneWidget);
    expect(repo.calls, SetupSplashScreen.maxAttempts);

    await tester.tap(find.text('Bỏ qua'));
    await tester.pumpAndSettle();
    expect(results, [null]);
  });
}
