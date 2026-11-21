import 'package:material_ui/material_ui.dart';
import 'package:muop_agent/core/di/app_dependencies.dart';
import 'package:muop_agent/core/theme/app_theme.dart';
import 'package:muop_agent/features/ssh/domain/ssh_entities.dart';
import 'package:muop_agent/features/ssh/presentation/ssh_terminal_panel.dart';

const _shellLanguages = {'', 'bash', 'sh', 'shell', 'zsh', 'console', 'terminal'};

/// Khối mã có thể chạy trong shell: ngôn ngữ là shell (hoặc không ghi) và có nội dung.
bool isRunnableShellBlock(String language, String text) {
  return _shellLanguages.contains(language.trim().toLowerCase()) &&
      text.trim().isNotEmpty;
}

/// Bỏ dấu nhắc `$ ` đầu dòng khi AI viết mẫu lệnh dạng console.
String _cleanCommand(String text) {
  return text
      .split('\n')
      .map((l) => l.startsWith(r'$ ') ? l.substring(2) : l)
      .join('\n')
      .trim();
}

/// Mở terminal của "Máy này" (shell local của server) trong dialog và chạy [command].
/// Người dùng theo dõi đầu ra và nhập mật khẩu sudo trực tiếp trong terminal.
Future<void> showRunCommandDialog(
  BuildContext context, {
  required String serverAddress,
  required String command,
}) async {
  final cmd = _cleanCommand(command);
  SshHost? local;
  String? error;
  try {
    final hosts = await AppDependencies.ssh.fetchSshHosts(serverAddress);
    for (final h in hosts) {
      if (h.builtin) local = h;
    }
    if (local == null) error = 'Server chưa có máy "Máy này"';
  } catch (e) {
    error = '$e';
  }
  if (!context.mounted) return;
  if (local == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(error ?? 'Không mở được terminal')),
    );
    return;
  }
  final host = local;
  await showDialog<void>(
    context: context,
    builder: (ctx) {
      final size = MediaQuery.sizeOf(ctx);
      return Dialog(
        insetPadding: const EdgeInsets.all(12),
        backgroundColor: ctx.scheme.surface,
        child: SizedBox(
          width: size.width < 760 ? size.width : 880,
          height: size.height * 0.8,
          child: SshTerminalPanel(
            hostId: host.id,
            hostName: host.name,
            hostAddress: host.address,
            initialCommand: cmd,
            hint: 'Đang chạy lệnh trên máy server. Nhập mật khẩu sudo ngay trong terminal nếu được hỏi.',
            onHide: () => Navigator.of(ctx).pop(),
            onEnded: () => Navigator.of(ctx).pop(),
          ),
        ),
      );
    },
  );
}
