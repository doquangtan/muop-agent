import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'package:muop_agent/core/theme/app_theme.dart';
import 'package:muop_agent/features/agy_auth/domain/agy_auth_entities.dart';
import 'package:muop_agent/features/agy_auth/presentation/agy_login_code_field.dart';
import 'package:muop_agent/features/agy_auth/presentation/agy_login_url_box.dart';
import 'package:muop_agent/features/ssh/presentation/ssh_terminal_panel.dart';

/// Khung đăng nhập agy. Dùng chung cho màn Tài khoản và wizard.
///
/// - Link đăng nhập do server đọc từ agy và gửi trong [AgyAuthState.loginUrl]. Client chỉ hiển thị link đó
///   (nút Mở link, Sao chép), ô nhập mã và nút Xác nhận. Client không tự phân tích đầu ra của terminal.
/// - Terminal SSH chỉ hiện khi người dùng mở ra, hoặc khi agy đang chờ đồng ý điều khoản (bước phải làm trong
///   terminal). Đây là trường hợp bất đắc dĩ, nên mặc định ẩn.
/// - Nút mở link, sao chép, ô mã và Xác nhận luôn bấm được khi link đang hiện. Agy báo lỗi thì
///   server chuyển sang `failed`, terminal đóng, màn hình quay về nút "Đăng nhập bằng Google".
/// - Trong lúc khung hiện, gọi `agy:auth:check` định kỳ để biết agy đã đăng nhập chưa.
class AgyLoginPanel extends StatefulWidget {
  const AgyLoginPanel({
    super.key,
    required this.state,
    required this.busy,
    required this.onSubmitCode,
    required this.onCancel,
    required this.onRestart,
    required this.onCheck,
    this.terminalHeight = 360,
  });

  final AgyAuthState state;

  /// Một thao tác đang chờ server (gửi mã, hủy...)
  final bool busy;
  final Future<AgyAuthState> Function(String code) onSubmitCode;
  final VoidCallback onCancel;

  /// Mở lại đăng nhập khi terminal SSH đã đóng (nút "Mở lại" trong khung terminal)
  final VoidCallback onRestart;

  /// Hỏi server đã đăng nhập chưa (`agy:auth:check`). Kết quả do màn hình cha áp dụng.
  final Future<void> Function() onCheck;

  final double terminalHeight;

  /// Khoảng cách kiểm tra trạng thái khi khung đang hiện
  static const checkEvery = Duration(seconds: 3);

  @override
  State<AgyLoginPanel> createState() => _AgyLoginPanelState();
}

class _AgyLoginPanelState extends State<AgyLoginPanel> {
  Timer? _timer;
  bool _checking = false;

  /// Người dùng đã mở terminal SSH (trường hợp bất đắc dĩ)
  bool _showTerminal = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(AgyLoginPanel.checkEvery, (_) => _check());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// Không chồng nhiều lần kiểm tra cùng lúc
  Future<void> _check() async {
    if (_checking || !mounted) return;
    _checking = true;
    try {
      await widget.onCheck();
    } finally {
      _checking = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final scheme = context.scheme;
    final state = widget.state;
    final stage = state.stage;
    final verifying = stage == 'verifying';
    // Agy chờ đồng ý điều khoản: phải làm trong terminal, nên tự mở
    final showTerminal = _showTerminal || stage == 'awaiting_terms';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (state.hasLoginUrl) ...[
          AgyLoginUrlBox(url: state.loginUrl),
          const SizedBox(height: 10),
          AgyLoginCodeField(onSubmit: widget.onSubmitCode),
        ] else ...[
          // Chờ server đọc link từ agy: chỉ hiện trạng thái tĩnh (không hoạt ảnh liên tục)
          Row(
            children: [
              Icon(Icons.hourglass_top_rounded, size: 18, color: scheme.onSurfaceVariant),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Đang lấy link đăng nhập Google từ máy chủ...',
                  style: textTheme.bodyMedium,
                ),
              ),
            ],
          ),
        ],
        if (verifying) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text('Đang xác nhận mã với agy...', style: textTheme.bodyMedium),
              ),
            ],
          ),
        ],
        if (stage == 'awaiting_terms') ...[
          const SizedBox(height: 10),
          Text(
            'Mã đã được chấp nhận. agy đang chờ bạn xác nhận điều khoản trong terminal bên dưới. '
            'Khi xong, đăng nhập sẽ tự hoàn tất.',
            style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
        const SizedBox(height: 8),
        if (showTerminal)
          SshTerminalPanel(
            key: ValueKey(state.sshSessionId),
            hostId: state.sshHostId,
            hostName: 'Máy này (muop-agent)',
            hostAddress: '127.0.0.1',
            sessionId: state.sshSessionId,
            height: widget.terminalHeight,
            hint: stage == 'awaiting_terms'
                ? 'agy đang hỏi điều khoản: đồng ý trong terminal này, đăng nhập sẽ tự hoàn tất.'
                : 'Chỉ dùng khi cần thao tác trực tiếp với agy (ví dụ điều khoản).',
            onRestart: widget.onRestart,
          )
        else
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => setState(() => _showTerminal = true),
              icon: const Icon(Icons.terminal_rounded, size: 18),
              label: const Text('Mở terminal (chỉ khi cần)'),
            ),
          ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: widget.busy ? null : widget.onCancel,
            child: const Text('Hủy đăng nhập'),
          ),
        ),
      ],
    );
  }
}
