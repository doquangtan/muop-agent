import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'package:muop_agent/core/di/app_dependencies.dart';
import 'package:muop_agent/core/theme/app_theme.dart';
import 'package:muop_agent/features/agy_auth/domain/agy_auth_entities.dart';
import 'package:muop_agent/features/agy_auth/domain/agy_auth_repository.dart';
import 'package:muop_agent/features/agy_auth/presentation/agy_login_panel.dart';
import 'package:muop_agent/features/claude_auth/domain/claude_auth_repository.dart';
import 'package:muop_agent/features/claude_auth/presentation/claude_auth_section.dart';

/// Nội dung màn Tài khoản (bản sao) dùng cho bước Đăng nhập của wizard Khởi tạo: đăng nhập / đăng xuất agy
/// trên máy server, và trạng thái Claude Code CLI. Không có Scaffold: nhúng vào trang khác.
/// Đăng nhập: server mở terminal SSH chạy agy, người dùng tự đăng nhập trong terminal đó
/// (khung đăng nhập dùng chung với wizard: [AgyLoginPanel]).
class SetupAccountsSection extends StatefulWidget {
  const SetupAccountsSection({
    super.key,
    required this.serverAddress,
    this.repository,
    this.claudeRepository,
  });

  final String serverAddress;

  /// Mặc định dùng repository của app; test có thể truyền bản giả
  final AgyAuthRepository? repository;

  /// Repository đăng nhập Claude (mặc định của app; test có thể truyền bản giả)
  final ClaudeAuthRepository? claudeRepository;

  @override
  State<SetupAccountsSection> createState() => _SetupAccountsSectionState();
}

class _SetupAccountsSectionState extends State<SetupAccountsSection> {
  AgyAuthRepository get _repo => widget.repository ?? AppDependencies.agyAuth;

  AgyAuthState? _state;
  bool _loading = true;
  bool _busy = false;
  AccountsStatus _accounts = AccountsStatus.empty;
  final _claudeKey = GlobalKey<ClaudeAuthSectionState>();

  /// Lỗi của thao tác vừa làm (đăng nhập, đăng xuất)
  String? _actionError;

  /// Nhận trạng thái do server đẩy qua socket (khi đăng nhập xong, bị hủy, hết hạn...)
  StreamSubscription<AgyAuthState>? _updatesSub;

  @override
  void initState() {
    super.initState();
    _updatesSub = _repo.updates.listen((s) => _onUpdate(s));
    _reload();
  }

  @override
  void dispose() {
    _updatesSub?.cancel();
    super.dispose();
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _actionError = null;
    });
    // Hiện ngay trạng thái nhanh (agy:auth:status), không chờ check
    var res = await _repo.fetchStatus();
    if (!res.ok) res = await _repo.checkStatus();
    if (!mounted) return;
    setState(() {
      _loading = false;
      _state = res;
    });
    await _refreshAccounts();
    // Kiểm tra login bằng agy:auth:check (mở SSH chạy agy, ~10 giây) chạy nền, cập nhật khi xong
    if (res.ok) {
      final checked = await _repo.checkStatus();
      if (!mounted || _busy || !checked.ok) return;
      _onUpdate(checked);
    }
  }

  Future<void> _refreshAccounts() async {
    final accounts = await _repo.fetchAccounts();
    if (!mounted) return;
    setState(() => _accounts = accounts);
  }

  /// Áp dụng trạng thái từ server: ack của một lệnh hoặc event `agy:auth:update`.
  /// Khi thất bại, giữ trạng thái đăng nhập theo server và hiện lỗi.
  void _onUpdate(AgyAuthState res, {String fallbackError = 'Thao tác thất bại'}) {
    if (!mounted) return;
    final wasLoggedIn = _state?.loggedIn ?? false;
    setState(() {
      _loading = false;
      _busy = false;
      if (res.ok) {
        _state = res;
        _actionError = null;
      } else {
        // Giữ bước và link đang có: lỗi (ví dụ mã sai) không được làm màn hình rơi khỏi bước nhập mã
        _state = res.displayed;
        _actionError = res.error.isEmpty ? fallbackError : res.error;
      }
    });
    if (wasLoggedIn != (_state?.loggedIn ?? false)) {
      // Đổi trạng thái đăng nhập agy thì gói và email cũng đổi theo
      _refreshAccounts();
    }
    if (!wasLoggedIn && (_state?.loggedIn ?? false)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Đã đăng nhập agy')),
      );
    }
  }

  Future<void> _startLogin() async {
    setState(() {
      _busy = true;
      _actionError = null;
    });
    final res = await _repo.startLogin();
    if (!mounted) return;
    _onUpdate(res, fallbackError: 'Không bắt đầu được đăng nhập');
  }

  Future<AgyAuthState> _submitCode(String code) async {
    setState(() {
      _busy = true;
      _actionError = null;
    });
    final res = await _repo.submitCode(code);
    if (!mounted) return res;
    _onUpdate(res, fallbackError: 'Mã xác thực không hợp lệ');
    return res;
  }

  /// Kiểm tra định kỳ khi khung đăng nhập hiện (`agy:auth:check`). Bỏ qua khi đang có thao tác (gửi mã...)
  /// để không làm mở lại ô mã; lỗi kiểm tra không thay màn hình đăng nhập.
  Future<void> _checkStatus() async {
    final res = await _repo.checkStatus();
    if (!mounted || _busy || !res.ok) return;
    _onUpdate(res);
  }

  Future<void> _cancelLogin() async {
    setState(() {
      _busy = true;
      _actionError = null;
    });
    final res = await _repo.cancelLogin();
    if (!mounted) return;
    _onUpdate(res, fallbackError: 'Không hủy được phiên đăng nhập');
  }

  Future<void> _confirmLogout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Đăng xuất agy?'),
        content: const Text(
          'Agy trên server sẽ mất đăng nhập. Antigravity IDE dùng chung tài khoản này cũng sẽ bị đăng xuất.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Hủy'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Đăng xuất'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() {
      _busy = true;
      _actionError = null;
    });
    final res = await _repo.logout();
    if (!mounted) return;
    _onUpdate(res, fallbackError: 'Không đăng xuất được');
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_state == null || !_state!.ok) {
      return _ErrorView(
        message: _state?.error.isNotEmpty == true
            ? _state!.error
            : 'Không tải được trạng thái agy',
        onRetry: _reload,
        textTheme: textTheme,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: IconButton(
            tooltip: 'Kiểm tra lại',
            onPressed: _busy
                ? null
                : () {
                    _claudeKey.currentState?.reload();
                    _reload();
                  },
            icon: const Icon(Icons.refresh_rounded),
          ),
        ),
        _SectionTitle(text: 'Antigravity (agy)', textTheme: textTheme),
        const SizedBox(height: 8),
        _StatusCard(
          state: _state!,
          email: _accounts.agyEmail,
          plan: _accounts.agyPlan,
        ),
        const SizedBox(height: 12),
        if (_state!.loggedIn)
          _LoggedInSection(busy: _busy, onLogout: _confirmLogout)
        else if (_state!.terminalOpen)
          AgyLoginPanel(
            state: _state!,
            busy: _busy,
            onRestart: _startLogin,
            onCancel: _cancelLogin,
            onSubmitCode: _submitCode,
            onCheck: _checkStatus,
            terminalHeight: 320,
          )
        else
          _LoggedOutSection(busy: _busy, onStart: _startLogin),
        if (_actionError != null) ...[
          const SizedBox(height: 12),
          _ErrorBanner(message: _actionError!),
        ],
        const SizedBox(height: 28),
        _SectionTitle(text: 'Claude Code CLI', textTheme: textTheme),
        const SizedBox(height: 8),
        ClaudeAuthSection(
          key: _claudeKey,
          serverAddress: widget.serverAddress,
          repository: widget.claudeRepository,
        ),
      ],
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.state, this.email = '', this.plan = ''});
  final AgyAuthState state;
  final String email;
  final String plan;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final status = context.status;
    final textTheme = Theme.of(context).textTheme;
    final loggedIn = state.loggedIn;
    final color = loggedIn ? status.success : status.warning;

    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Icon(
              loggedIn ? Icons.verified_user_rounded : Icons.lock_open_rounded,
              color: color,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    loggedIn ? 'Đã đăng nhập' : 'Chưa đăng nhập',
                    style: textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: color,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    loggedIn
                        ? (email.isEmpty ? 'Agy trên server đang dùng tài khoản Google đã đăng nhập.' : '$email${plan.isEmpty ? '' : ' · Gói $plan'}')
                        : 'Agy chưa có tài khoản. Chat với agy sẽ thất bại cho tới khi đăng nhập.',
                    style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LoggedInSection extends StatelessWidget {
  const _LoggedInSection({required this.busy, required this.onLogout});
  final bool busy;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return Align(
      alignment: Alignment.centerLeft,
      child: OutlinedButton.icon(
        style: OutlinedButton.styleFrom(foregroundColor: scheme.error),
        onPressed: busy ? null : onLogout,
        icon: busy
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.logout_rounded),
        label: const Text('Đăng xuất'),
      ),
    );
  }
}

class _LoggedOutSection extends StatelessWidget {
  const _LoggedOutSection({required this.busy, required this.onStart});
  final bool busy;
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: FilledButton.icon(
        onPressed: busy ? null : onStart,
        icon: busy
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.login_rounded),
        label: const Text('Đăng nhập bằng Google'),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline_rounded, size: 18, color: scheme.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onErrorContainer,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({
    required this.message,
    required this.onRetry,
    required this.textTheme,
  });
  final String message;
  final VoidCallback onRetry;
  final TextTheme textTheme;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_rounded, size: 40, color: scheme.error),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center, style: textTheme.bodyMedium),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: onRetry, child: const Text('Thử lại')),
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.text, required this.textTheme});
  final String text;
  final TextTheme textTheme;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: textTheme.titleSmall?.copyWith(
        fontWeight: FontWeight.w700,
        color: context.scheme.primary,
      ),
    );
  }
}
