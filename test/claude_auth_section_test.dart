import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:muop_agent/core/theme/app_theme.dart';
import 'package:muop_agent/features/claude_auth/domain/claude_auth_entities.dart';
import 'package:muop_agent/features/claude_auth/domain/claude_auth_repository.dart';
import 'package:muop_agent/features/claude_auth/presentation/claude_auth_section.dart';

const _link =
    'https://claude.com/cai/oauth/authorize?code=true&client_id=12345';

ClaudeAuthState _in({String email = 'user@example.com', String plan = 'pro'}) =>
    ClaudeAuthState(
      ok: true,
      loggedIn: true,
      email: email,
      subscriptionType: plan,
      loginUrl: '',
      error: '',
    );

ClaudeAuthState _out({String loginUrl = ''}) => ClaudeAuthState(
      ok: true,
      loggedIn: false,
      email: '',
      subscriptionType: '',
      loginUrl: loginUrl,
      error: '',
    );

class _FakeClaudeAuthRepository implements ClaudeAuthRepository {
  _FakeClaudeAuthRepository({
    required this.status,
    this.submitResult,
  });

  ClaudeAuthState status;
  ClaudeAuthState? submitResult;
  final calls = <String>[];
  String? submittedCode;

  final _updates = StreamController<ClaudeAuthState>.broadcast();

  void emit(ClaudeAuthState state) => _updates.add(state);

  @override
  Stream<ClaudeAuthState> get updates => _updates.stream;

  @override
  Future<ClaudeAuthState> fetchStatus() async {
    calls.add('status');
    return status;
  }

  @override
  Future<ClaudeAuthState> logout() async {
    calls.add('logout');
    return _out();
  }

  @override
  Future<ClaudeAuthState> startLogin() async {
    calls.add('start');
    return _out(loginUrl: _link);
  }

  @override
  Future<ClaudeAuthState> submitCode(String code) async {
    calls.add('submit');
    submittedCode = code;
    return submitResult ??
        const ClaudeAuthState(
          ok: true,
          loggedIn: false,
          loginUrl: '',
          error: '',
          phase: 'verifying',
        );
  }

  @override
  Future<ClaudeAuthState> cancelLogin() async {
    calls.add('cancel');
    return _out();
  }
}

Future<void> _pump(WidgetTester tester, ClaudeAuthRepository repo) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(
        seedColor: const Color(0xFF00897B),
        brightness: Brightness.light,
      ),
      home: Scaffold(
        body: ListView(
          children: [
            ClaudeAuthSection(
                serverAddress: 'http://127.0.0.1:8787', repository: repo),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('chưa đăng nhập: bấm đăng nhập hiện link và ô nhập mã',
      (tester) async {
    final repo = _FakeClaudeAuthRepository(status: _out());
    await _pump(tester, repo);

    expect(find.text('Chưa đăng nhập'), findsOneWidget);
    await tester.tap(find.text('Đăng nhập Claude CLI'));
    await tester.pumpAndSettle();

    expect(repo.calls, containsAllInOrder(['status', 'start']));
    expect(find.text(_link), findsOneWidget);
    expect(find.text('Mở link'), findsOneWidget);
    expect(find.text('Gửi mã'), findsOneWidget);
  });

  testWidgets('gửi mã trống thì báo lỗi và không gọi server', (tester) async {
    final repo = _FakeClaudeAuthRepository(status: _out(loginUrl: _link));
    await _pump(tester, repo);

    await tester.tap(find.text('Gửi mã'));
    await tester.pumpAndSettle();

    expect(find.text('Hãy dán mã xác thực vào ô bên dưới'), findsOneWidget);
    expect(repo.calls.contains('submit'), isFalse);
  });

  testWidgets('gửi mã sai: hiện lỗi', (tester) async {
    final repo = _FakeClaudeAuthRepository(
      status: _out(loginUrl: _link),
      submitResult: const ClaudeAuthState(
        ok: false,
        loggedIn: false,
        loginUrl: '',
        error: 'Mã xác thực không hợp lệ.',
      ),
    );
    await _pump(tester, repo);

    await tester.enterText(find.byType(TextField), '  bad-code  ');
    await tester.tap(find.text('Gửi mã'));
    await tester.pumpAndSettle();

    expect(repo.submittedCode, 'bad-code');
    expect(find.text('Mã xác thực không hợp lệ.'), findsOneWidget);
  });

  testWidgets('gửi mã đúng: chuyển sang đã đăng nhập kèm email và gói',
      (tester) async {
    final repo = _FakeClaudeAuthRepository(status: _out(loginUrl: _link));
    await _pump(tester, repo);

    await tester.enterText(find.byType(TextField), 'good-code');
    await tester.tap(find.text('Gửi mã'));
    await tester.pump();

    expect(repo.calls, contains('submit'));

    repo.emit(_in(email: 'test@claude.ai', plan: 'pro'));
    await tester.pumpAndSettle();

    expect(find.text('Đã đăng nhập'), findsOneWidget);
    expect(find.text('test@claude.ai'), findsOneWidget);
    expect(find.text('PRO'), findsOneWidget);
    expect(find.text('Đăng xuất'), findsOneWidget);
  });

  testWidgets('đã đăng nhập: bấm đăng xuất có popup xác nhận', (tester) async {
    final repo = _FakeClaudeAuthRepository(
        status: _in(email: 'alice@example.com', plan: 'team'));
    await _pump(tester, repo);

    expect(find.text('Đã đăng nhập'), findsOneWidget);
    expect(find.text('alice@example.com'), findsOneWidget);
    expect(find.text('TEAM'), findsOneWidget);

    await tester.tap(find.text('Đăng xuất'));
    await tester.pumpAndSettle();

    expect(find.text('Đăng xuất Claude CLI?'), findsOneWidget);

    // Bấm Hủy
    await tester.tap(find.text('Hủy'));
    await tester.pumpAndSettle();
    expect(repo.calls.contains('logout'), isFalse);

    // Mở lại và bấm Đăng xuất
    await tester.tap(find.text('Đăng xuất'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Đăng xuất'));
    await tester.pumpAndSettle();

    expect(repo.calls.contains('logout'), isTrue);
    expect(find.text('Chưa đăng nhập'), findsOneWidget);
  });
}
