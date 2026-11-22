import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:muop_agent/core/theme/app_theme.dart';
import 'package:muop_agent/features/agy_auth/domain/agy_auth_entities.dart';
import 'package:muop_agent/features/agy_auth/domain/agy_auth_repository.dart';
import 'package:muop_agent/features/setup/presentation/setup_accounts_section.dart';
import 'package:muop_agent/features/agy_auth/presentation/agy_login_panel.dart';
import 'package:muop_agent/features/claude_auth/domain/claude_auth_entities.dart';
import 'package:muop_agent/features/claude_auth/domain/claude_auth_repository.dart';
import 'package:muop_agent/features/ssh/presentation/ssh_terminal_panel.dart';

const _sid = 'sid-accounts-1';
const _link = 'https://accounts.google.com/o/oauth2/auth?state=abc';
const _exitedError =
    'agy đã thoát trước khi đăng nhập. Chưa đăng nhập: bấm Đăng nhập bằng Google để thử lại.';

AgyAuthState _in() => const AgyAuthState(
      ok: true,
      loggedIn: true,
      error: '',
    );

AgyAuthState _out() => const AgyAuthState(
      ok: true,
      loggedIn: false,
      error: '',
    );

/// Terminal đăng nhập đang mở (server trả sau khi bấm đăng nhập)
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

/// Repository giả: trả về các kết quả đã định sẵn, ghi lại lời gọi, và cho phát event như socket
class _FakeAgyAuthRepository implements AgyAuthRepository {
  _FakeAgyAuthRepository({
    required this.status,
    this.logoutResult,
  });

  AgyAuthState status;
  AgyAuthState? logoutResult;
  /// Kết quả gửi mã (mặc định: terminal vẫn mở, không lỗi)
  AgyAuthState? submitResult;
  final calls = <String>[];

  /// Kết quả kiểm tra `agy:auth:check` (mặc định: trạng thái hiện tại)
  AgyAuthState? checkResult;

  final _updates = StreamController<AgyAuthState>.broadcast();

  /// Giả lập server đẩy `agy:auth:update`
  void emit(AgyAuthState state) => _updates.add(state);

  Future<void> dispose() => _updates.close();

  @override
  Stream<AgyAuthState> get updates => _updates.stream;

  @override
  Future<AgyAuthState> fetchStatus() async {
    calls.add('status');
    return status;
  }

  AccountsStatus accounts = AccountsStatus.empty;

  @override
  Future<AccountsStatus> fetchAccounts() async => accounts;

  @override
  Future<AgyAuthState> logout() async {
    calls.add('logout');
    return logoutResult ?? _out();
  }

  @override
  Future<AgyAuthState> checkStatus() async {
    calls.add('check');
    return checkResult ?? status;
  }

  @override
  Future<AgyAuthState> startLogin() async {
    calls.add('start');
    return _terminal();
  }

  @override
  Future<AgyAuthState> submitCode(String code) async {
    calls.add('submit');
    submittedCode = code;
    return submitResult ?? _terminal();
  }

  String? submittedCode;

  @override
  Future<AgyAuthState> cancelLogin() async {
    calls.add('cancel');
    return _out();
  }

}

/// Claude giả: mặc định chưa đăng nhập; [loggedIn] bật trạng thái đã đăng nhập gói pro
class _FakeClaudeRepo implements ClaudeAuthRepository {
  _FakeClaudeRepo({this.loggedIn = false});

  final bool loggedIn;

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

Future<void> _pump(
  WidgetTester tester,
  _FakeAgyAuthRepository repo, {
  bool claudeLoggedIn = false,
  // Spinner đang quay không bao giờ "settle": màn có spinner dùng settle: false
  bool settle = true,
  bool showAgy = true,
  bool showClaude = true,
}) async {
  addTearDown(repo.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(
        seedColor: const Color(0xFF00897B),
        brightness: Brightness.light,
      ),
      home: Scaffold(
        body: ListView(
          children: [
            SetupAccountsSection(
              serverAddress: 'http://127.0.0.1:8787',
              repository: repo,
              claudeRepository: _FakeClaudeRepo(loggedIn: claudeLoggedIn),
              showAgy: showAgy,
              showClaude: showClaude,
            ),
          ],
        ),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

void main() {
  testWidgets('chưa đăng nhập: bấm đăng nhập gọi start và hiện terminal đăng nhập', (tester) async {
    final repo = _FakeAgyAuthRepository(status: _out());
    await _pump(tester, repo);

    expect(find.text('Chưa đăng nhập'), findsWidgets);
    await tester.tap(find.text('Đăng nhập bằng Google'));
    await tester.pumpAndSettle();

    expect(repo.calls, containsAllInOrder(['check', 'start']));
    expect(find.text('Hủy đăng nhập'), findsOneWidget);
    // Lúc bắt đầu chỉ có terminal SSH: chưa có link, chưa có ô nhập mã
    expect(find.widgetWithText(TextField, 'Mã xác thực'), findsNothing);
    expect(find.text('Mở link'), findsNothing);
    expect(find.text('Sao chép'), findsNothing);
  });

  testWidgets('có link đăng nhập: hiện đủ link để sao chép', (tester) async {
    const url =
        'https://accounts.google.com/o/oauth2/auth?client_id=abc&access_type=offline&state=xyz';
    final repo = _FakeAgyAuthRepository(status: _terminal(loginUrl: url));
    await _pump(tester, repo);

    // Link đầy đủ nằm nguyên trong một SelectableText (không bị cắt như trong terminal)
    expect(find.byWidgetPredicate((w) => w is SelectableText && w.data == url), findsOneWidget);
    expect(find.text('Sao chép'), findsOneWidget);
    expect(find.text('Mở link'), findsOneWidget);
    // Terminal SSH vẫn hiện suốt quá trình đăng nhập; link và ô mã nằm bên dưới
    expect(find.byType(SshTerminalPanel), findsOneWidget);
  });

  testWidgets('màn không còn link: ẩn nút mở link, sao chép và ô mã; terminal vẫn hiện', (tester) async {
    final repo = _FakeAgyAuthRepository(status: _terminal(loginUrl: _link, stage: 'awaiting_token'));
    await _pump(tester, repo);
    expect(find.text('Mở link'), findsOneWidget);

    repo.emit(_terminal(stage: 'waiting_link'));
    await tester.pumpAndSettle();

    expect(find.text('Mở link'), findsNothing);
    expect(find.text('Sao chép'), findsNothing);
    expect(find.widgetWithText(TextField, 'Mã xác thực'), findsNothing);
    expect(find.byType(SshTerminalPanel), findsOneWidget);
  });

  testWidgets('đang đăng nhập: kiểm tra agy định kỳ bằng agy:auth:check, vào màn chat thì chuyển đã đăng nhập', (tester) async {
    final repo = _FakeAgyAuthRepository(status: _terminal())
      ..checkResult = _in();
    await _pump(tester, repo);

    await tester.pump(AgyLoginPanel.checkEvery);
    await tester.pumpAndSettle();

    expect(repo.calls.contains('check'), isTrue);
    expect(find.text('Đã đăng nhập'), findsOneWidget);
  });

  testWidgets('dán mã xác thực rồi gửi: mã được gửi tới server', (tester) async {
    final repo = _FakeAgyAuthRepository(status: _terminal(loginUrl: _link, stage: 'awaiting_token'));
    // Link + ô mã + nút Xác nhận (terminal đã ẩn): viewport đủ cao để thấy nút
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(800, 1200);
    addTearDown(tester.view.resetPhysicalSize);
    await _pump(tester, repo);

    await tester.enterText(find.widgetWithText(TextField, 'Mã xác thực'), '  4/0AbC-xyz  ');
    await tester.tap(find.widgetWithText(FilledButton, 'Xác nhận'));
    await tester.pumpAndSettle();

    expect(repo.calls.contains('submit'), isTrue);
    expect(repo.submittedCode, '4/0AbC-xyz');
  });

  testWidgets('đã gửi mã: terminal SSH vẫn hiện, nút mở link, sao chép, ô mã và Xác nhận vẫn bấm được', (tester) async {
    final repo = _FakeAgyAuthRepository(status: _terminal(loginUrl: _link, stage: 'verifying'));
    await _pump(tester, repo, settle: false);

    expect(find.text('Đang xác nhận mã với agy...'), findsOneWidget);
    expect(find.byType(SshTerminalPanel), findsOneWidget);
    final field = tester.widget<TextField>(find.widgetWithText(TextField, 'Mã xác thực'));
    expect(field.enabled, isNot(false));
    final confirm = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Xác nhận'));
    expect(confirm.onPressed, isNotNull);
    final open = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Mở link'));
    expect(open.onPressed, isNotNull);
    final copy = tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Sao chép'));
    expect(copy.onPressed, isNotNull);
  });

  testWidgets('mã bị từ chối khi nhập (lỗi nhập): vẫn giữ link và ô mã để nhập lại', (tester) async {
    final repo = _FakeAgyAuthRepository(status: _terminal(loginUrl: _link, stage: 'awaiting_token'))
      ..submitResult = const AgyAuthState(
        ok: false,
        loggedIn: false,
        error: 'Mã xác thực không được chứa khoảng trắng hoặc ký tự điều khoản.',
        phase: 'login_terminal',
        sshSessionId: _sid,
        sshHostId: 6,
        loginUrl: _link,
        loginStage: 'awaiting_token',
      );
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(800, 1200);
    addTearDown(tester.view.resetPhysicalSize);
    await _pump(tester, repo);

    await tester.enterText(find.widgetWithText(TextField, 'Mã xác thực'), 'abc');
    await tester.tap(find.widgetWithText(FilledButton, 'Xác nhận'));
    await tester.pumpAndSettle();

    expect(find.text('Mã xác thực không được chứa khoảng trắng hoặc ký tự điều khoản.'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Mã xác thực'), findsOneWidget);
    expect(find.text('Sao chép'), findsOneWidget);
  });

  testWidgets('agy báo lỗi sau khi xác nhận: quay về nút Google, không còn terminal', (tester) async {
    final repo = _FakeAgyAuthRepository(status: _terminal(loginUrl: _link, stage: 'verifying'));
    await _pump(tester, repo, settle: false);

    repo.emit(const AgyAuthState(
      ok: false,
      loggedIn: false,
      error: 'Xác thực thất bại: Malformed auth code. Bấm Đăng nhập bằng Google để thử lại.',
      phase: 'failed',
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('Xác thực thất bại: Malformed auth code'), findsOneWidget);
    expect(find.text('Đăng nhập bằng Google'), findsOneWidget);
    expect(find.byType(SshTerminalPanel), findsNothing);
    expect(find.text('Hủy đăng nhập'), findsNothing);
  });

  testWidgets('agy chờ điều khoản sau khi nhận mã: hướng dẫn xác nhận trong terminal', (tester) async {
    // Sang bước điều khoản thì link đã không còn trên màn hình
    final repo = _FakeAgyAuthRepository(status: _terminal(stage: 'awaiting_terms'));
    await _pump(tester, repo);

    expect(find.textContaining('chờ bạn xác nhận điều khoản trong terminal'), findsOneWidget);
    expect(find.byType(SshTerminalPanel), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Mã xác thực'), findsNothing);
  });

  testWidgets('hủy đăng nhập đang chờ: gọi cancel và đưa về nút đăng nhập', (tester) async {
    final repo = _FakeAgyAuthRepository(status: _terminal());
    await _pump(tester, repo);

    // Nút nằm dưới khung terminal (cao 360): viewport đủ cao để bấm được không cần cuộn
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(800, 1000);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hủy đăng nhập'));
    await tester.pumpAndSettle();

    expect(repo.calls.contains('cancel'), isTrue);
    expect(find.text('Đăng nhập bằng Google'), findsOneWidget);
    expect(find.text('Hủy đăng nhập'), findsNothing);
  });

  testWidgets('agy thoát khi chưa đăng nhập: server báo lỗi, không còn terminal', (tester) async {
    final repo = _FakeAgyAuthRepository(status: _terminal());
    await _pump(tester, repo);

    repo.emit(const AgyAuthState(
      ok: false,
      loggedIn: false,
      error: _exitedError,
      phase: 'failed',
    ));
    await tester.pumpAndSettle();

    expect(find.text(_exitedError), findsOneWidget);
    expect(find.text('Đăng nhập bằng Google'), findsOneWidget);
    expect(find.text('Hủy đăng nhập'), findsNothing);
    expect(find.text('Đã đăng nhập'), findsNothing);
  });

  testWidgets('đăng nhập xong trong terminal: server đẩy event, chuyển sang đã đăng nhập', (tester) async {
    final repo = _FakeAgyAuthRepository(status: _terminal());
    await _pump(tester, repo);

    repo.emit(_in());
    await tester.pumpAndSettle();

    expect(find.text('Đã đăng nhập'), findsOneWidget);
    expect(find.text('Đăng xuất'), findsOneWidget);
    expect(find.text('Đã đăng nhập agy'), findsOneWidget);
    expect(find.text('Hủy đăng nhập'), findsNothing);
  });

  testWidgets('đã đăng nhập: đăng xuất phải qua hộp xác nhận', (tester) async {
    final repo = _FakeAgyAuthRepository(status: _in());
    await _pump(tester, repo);

    expect(find.text('Đã đăng nhập'), findsOneWidget);
    await tester.tap(find.text('Đăng xuất'));
    await tester.pumpAndSettle();

    // Chưa xác nhận thì chưa gọi logout
    expect(find.text('Đăng xuất agy?'), findsOneWidget);
    expect(repo.calls.contains('logout'), isFalse);

    await tester.tap(find.widgetWithText(FilledButton, 'Đăng xuất'));
    await tester.pumpAndSettle();

    expect(repo.calls.contains('logout'), isTrue);
    expect(find.text('Chưa đăng nhập'), findsWidgets);
    expect(find.text('Đăng nhập bằng Google'), findsOneWidget);
  });

  testWidgets('đăng xuất thất bại: vẫn giữ trạng thái đã đăng nhập', (tester) async {
    final repo = _FakeAgyAuthRepository(
      status: _in(),
      logoutResult: const AgyAuthState(
        ok: false,
        loggedIn: true,
        error: 'Agy vẫn báo đang đăng nhập sau khi đăng xuất',
      ),
    );
    await _pump(tester, repo);

    await tester.tap(find.text('Đăng xuất'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Đăng xuất'));
    await tester.pumpAndSettle();

    expect(find.text('Đã đăng nhập'), findsOneWidget);
    expect(find.text('Agy vẫn báo đang đăng nhập sau khi đăng xuất'), findsOneWidget);
  });

  testWidgets('tài khoản: hiện email và gói agy, và trạng thái Claude Code CLI', (tester) async {
    final repo = _FakeAgyAuthRepository(status: _in());
    repo.accounts = const AccountsStatus(
      agyLoggedIn: true,
      agyEmail: 'a@example.com',
      agyPlan: 'Pro',
      claudeLoggedIn: true,
      claudePlan: 'pro',
    );
    await _pump(tester, repo, claudeLoggedIn: true);

    expect(find.text('Antigravity (agy)'), findsOneWidget);
    expect(find.text('Claude Code CLI'), findsOneWidget);
    expect(find.text('a@example.com · Gói Pro'), findsOneWidget);
    expect(find.text('PRO'), findsOneWidget);
  });

  testWidgets('agy chưa cài: không hiện khối agy, vẫn hiện Claude', (tester) async {
    await _pump(tester, _FakeAgyAuthRepository(status: _out()), showAgy: false);

    expect(find.text('Antigravity (agy)'), findsNothing);
    expect(find.text('Claude Code CLI'), findsOneWidget);
  });

  testWidgets('Claude chưa cài: không hiện khối Claude, vẫn hiện agy', (tester) async {
    await _pump(tester, _FakeAgyAuthRepository(status: _out()), showClaude: false);

    expect(find.text('Claude Code CLI'), findsNothing);
    expect(find.text('Antigravity (agy)'), findsOneWidget);
  });
}
