import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:muop_agent/core/config/server_config.dart';
import 'package:muop_agent/core/state/server_address_provider.dart';
import 'package:muop_agent/core/theme/app_theme.dart';
import 'package:muop_agent/features/agy_auth/domain/agy_auth_entities.dart';
import 'package:muop_agent/features/agy_auth/domain/agy_auth_repository.dart';
import 'package:muop_agent/features/agy_auth/presentation/accounts_screen.dart';
import 'package:muop_agent/features/claude_auth/domain/claude_auth_entities.dart';
import 'package:muop_agent/features/claude_auth/domain/claude_auth_repository.dart';

/// Repository giả đếm số lần màn tải trạng thái agy (mỗi lần dựng hoặc tải lại màn là một lần)
class _CountingAgyRepo implements AgyAuthRepository {
  int statusFetches = 0;

  @override
  Future<AgyAuthState> checkStatus() async {
    statusFetches++;
    return const AgyAuthState(ok: true, loggedIn: false, error: '');
  }

  @override
  Stream<AgyAuthState> get updates => const Stream.empty();

  @override
  Future<AgyAuthState> fetchStatus() async {
    statusFetches++;
    return const AgyAuthState(ok: true, loggedIn: false, error: '');
  }

  @override
  Future<AccountsStatus> fetchAccounts() async => AccountsStatus.empty;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ClaudeFake implements ClaudeAuthRepository {
  @override
  Stream<ClaudeAuthState> get updates => const Stream.empty();

  @override
  Future<ClaudeAuthState> fetchStatus() async => const ClaudeAuthState(
        ok: true,
        loggedIn: false,
        email: '',
        subscriptionType: '',
        loginUrl: '',
        error: '',
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('serverAddressProvider', () {
    test('mặc định là địa chỉ mặc định; đổi thì trim, chuỗi rỗng quay về mặc định', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(serverAddressProvider.notifier);
      expect(container.read(serverAddressProvider), defaultHostAddress);

      notifier.change('  10.0.0.2:8787 ');
      expect(container.read(serverAddressProvider), '10.0.0.2:8787');

      notifier.change('   ');
      expect(container.read(serverAddressProvider), defaultHostAddress);
    });
  });

  testWidgets('đổi địa chỉ toàn cục: màn đang mount tải lại dữ liệu từ server mới', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final repo = _CountingAgyRepo();

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildAppTheme(seedColor: const Color(0xFF00897B), brightness: Brightness.light),
        home: AccountsScreen(repository: repo, claudeRepository: _ClaudeFake()),
      ),
    ));
    await tester.pumpAndSettle();
    final before = repo.statusFetches;
    expect(before, greaterThan(0));
    expect(tester.widget<AccountsScreenView>(find.byType(AccountsScreenView)).serverAddress, defaultHostAddress);

    container.read(serverAddressProvider.notifier).change('10.0.0.2:8787');
    await tester.pumpAndSettle();
    expect(repo.statusFetches, greaterThan(before), reason: 'đổi địa chỉ phải tải lại');
    expect(tester.widget<AccountsScreenView>(find.byType(AccountsScreenView)).serverAddress, '10.0.0.2:8787');

    // cùng địa chỉ: không tải lại
    final after = repo.statusFetches;
    container.read(serverAddressProvider.notifier).change('10.0.0.2:8787');
    await tester.pumpAndSettle();
    expect(repo.statusFetches, after);
  });
}
