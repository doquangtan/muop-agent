import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'package:muop_agent/core/widgets/throttled_spinner.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:muop_agent/core/di/app_dependencies.dart';
import 'package:muop_agent/core/theme/app_theme.dart';
import 'package:muop_agent/features/accounts_common/presentation/account_widgets.dart';
import 'package:muop_agent/features/claude_auth/domain/claude_auth_entities.dart';
import 'package:muop_agent/features/claude_auth/domain/claude_auth_repository.dart';

/// Đăng nhập / đăng xuất tài khoản Claude Code CLI trên máy server. Là một section nhúng trong
/// màn hình Tài khoản (không có Scaffold riêng).
class ClaudeAuthSection extends StatefulWidget {
  const ClaudeAuthSection({
    super.key,
    required this.serverAddress,
    this.repository,
  });

  final String serverAddress;
  final ClaudeAuthRepository? repository;

  @override
  State<ClaudeAuthSection> createState() => ClaudeAuthSectionState();
}

class ClaudeAuthSectionState extends State<ClaudeAuthSection> {
  ClaudeAuthRepository get _repo =>
      widget.repository ?? AppDependencies.claudeAuth;

  final _codeController = TextEditingController();
  ClaudeAuthState? _state;
  bool _loading = true;
  bool _busy = false;
  String? _actionError;
  StreamSubscription<ClaudeAuthState>? _updatesSub;

  @override
  void initState() {
    super.initState();
    _updatesSub = _repo.updates.listen((s) => _onUpdate(s));
    _reload();
  }

  @override
  void dispose() {
    _updatesSub?.cancel();
    _codeController.dispose();
    super.dispose();
  }

  /// Tải lại trạng thái (nút làm mới của màn Tài khoản)
  Future<void> reload() => _reload();

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _actionError = null;
    });
    final res = await _repo.fetchStatus();
    if (!mounted) return;
    setState(() {
      _loading = false;
      _state = res;
    });
  }

  void _onUpdate(
    ClaudeAuthState res, {
    String fallbackError = 'Thao tác thất bại',
  }) {
    if (!mounted) return;
    final wasLoggedIn = _state?.loggedIn ?? false;
    setState(() {
      _loading = false;
      if (res.verifying) {
        _busy = true;
        _actionError = null;
        _state = ClaudeAuthState(
          ok: true,
          loggedIn: false,
          email: _state?.email ?? '',
          subscriptionType: _state?.subscriptionType ?? '',
          loginUrl: _state?.loginUrl ?? '',
          error: '',
          phase: 'verifying',
        );
        return;
      }
      _busy = false;
      if (res.ok) {
        _state = res;
        _actionError = null;
      } else {
        _state = ClaudeAuthState(
          ok: true,
          loggedIn: res.loggedIn,
          email: res.email,
          subscriptionType: res.subscriptionType,
          loginUrl: res.loginUrl,
          error: '',
          phase: res.phase,
        );
        _actionError = res.error.isEmpty ? fallbackError : res.error;
      }
    });
    if (!wasLoggedIn && (_state?.loggedIn ?? false)) {
      _codeController.clear();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Đã đăng nhập Claude Code CLI')),
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

  Future<void> _submitCode() async {
    final code = _codeController.text.trim();
    if (code.isEmpty) {
      setState(() => _actionError = 'Hãy dán mã xác thực vào ô bên dưới');
      return;
    }
    setState(() {
      _busy = true;
      _actionError = null;
    });
    final res = await _repo.submitCode(code);
    if (!mounted) return;
    _onUpdate(res, fallbackError: 'Mã xác thực không hợp lệ');
  }

  Future<void> _cancelLogin() async {
    setState(() {
      _busy = true;
      _actionError = null;
    });
    final res = await _repo.cancelLogin();
    if (!mounted) return;
    _codeController.clear();
    _onUpdate(res, fallbackError: 'Không hủy được phiên đăng nhập');
  }

  Future<void> _confirmLogout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Đăng xuất Claude CLI?'),
        content: const Text(
          'Claude Code CLI trên server sẽ mất đăng nhập. Các phiên chat dùng Claude sẽ thất bại cho tới khi đăng nhập lại.',
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

  Future<void> _openLink(String url) async {
    final uri = Uri.tryParse(url);
    final opened =
        uri != null &&
        await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!mounted || opened) return;
    setState(
      () => _actionError =
          'Không mở được trình duyệt. Hãy sao chép link rồi mở thủ công.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: ThrottledSpinner(size: 36, strokeWidth: 4)),
      );
    }
    if (_state == null || !_state!.ok) {
      return _ErrorView(
        message: _state?.error.isNotEmpty == true
            ? _state!.error
            : 'Không tải được trạng thái Claude CLI',
        onRetry: reload,
        textTheme: textTheme,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AccountStatusCard(
          loggedIn: _state!.loggedIn,
          email: _state!.email,
          badge: _state!.loggedIn ? _state!.subscriptionType : '',
          description: _state!.loggedIn
              ? 'Claude Code CLI trên server đang sẵn sàng phục vụ các phiên chat.'
              : 'Claude Code CLI chưa có tài khoản. Hãy đăng nhập để kích hoạt các model claude-cli.',
        ),
        const SizedBox(height: 12),
        if (_state!.loggedIn)
          AccountLogoutButton(busy: _busy, onLogout: _confirmLogout)
        else if (_state!.awaitingCode)
          _CodeSection(
            url: _state!.loginUrl,
            codeController: _codeController,
            busy: _busy,
            onOpen: () => _openLink(_state!.loginUrl),
            onSubmit: _submitCode,
            onCancel: _cancelLogin,
          )
        else
          _LoggedOutSection(busy: _busy, onStart: _startLogin),
        if (_actionError != null) ...[
          const SizedBox(height: 12),
          _ErrorBanner(message: _actionError!),
        ],
      ],
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
            ? const ThrottledSpinner(size: 16, strokeWidth: 2)
            : const Icon(Icons.login_rounded),
        label: const Text('Đăng nhập Claude CLI'),
      ),
    );
  }
}

class _CodeSection extends StatelessWidget {
  const _CodeSection({
    required this.url,
    required this.codeController,
    required this.busy,
    required this.onOpen,
    required this.onSubmit,
    required this.onCancel,
  });

  final String url;
  final TextEditingController codeController;
  final bool busy;
  final VoidCallback onOpen;
  final VoidCallback onSubmit;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final textTheme = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '1. Mở link và đăng nhập tài khoản Anthropic (Claude) của bạn.\n'
          '2. Sau khi xác thực, sao chép mã hiển thị (hoặc cả URL trang callback) và dán bên dưới.\n'
          '3. Mã hết hạn sau ít phút, vui lòng gửi sớm.',
          style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 10),
        Material(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SelectableText(
                  url,
                  maxLines: 3,
                  style: textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    FilledButton.tonalIcon(
                      onPressed: busy ? null : onOpen,
                      icon: const Icon(Icons.open_in_new_rounded, size: 18),
                      label: const Text('Mở link'),
                    ),
                    OutlinedButton.icon(
                      onPressed: busy
                          ? null
                          : () {
                              Clipboard.setData(ClipboardData(text: url));
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Đã sao chép link'),
                                ),
                              );
                            },
                      icon: const Icon(Icons.copy_rounded, size: 18),
                      label: const Text('Sao chép'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: codeController,
          enabled: !busy,
          minLines: 1,
          maxLines: 3,
          style: textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
          decoration: const InputDecoration(
            labelText: 'Mã xác thực hoặc URL trang callback',
            isDense: true,
          ),
          onSubmitted: busy ? null : (_) => onSubmit(),
        ),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: busy ? null : onCancel,
              child: const Text('Hủy đăng nhập'),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: busy ? null : onSubmit,
              child: busy
                  ? const ThrottledSpinner(size: 16, strokeWidth: 2)
                  : const Text('Gửi mã'),
            ),
          ],
        ),
      ],
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final textTheme = Theme.of(context).textTheme;

    return Material(
      color: scheme.errorContainer,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Icon(
              Icons.error_outline_rounded,
              color: scheme.onErrorContainer,
              size: 20,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: textTheme.bodySmall?.copyWith(
                  color: scheme.onErrorContainer,
                ),
              ),
            ),
          ],
        ),
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
            Icon(Icons.cloud_off_rounded, size: 48, color: scheme.error),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: textTheme.bodyMedium?.copyWith(color: scheme.error),
            ),
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Thử lại'),
            ),
          ],
        ),
      ),
    );
  }
}
