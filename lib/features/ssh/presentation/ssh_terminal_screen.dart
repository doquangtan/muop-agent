import 'package:material_ui/material_ui.dart';

import 'package:muop_agent/core/widgets/desktop_panel.dart';
import 'package:muop_agent/core/widgets/glass_scaffold.dart';
import 'package:muop_agent/core/theme/app_theme.dart';
import 'package:muop_agent/features/ssh/presentation/ssh_terminal_panel.dart';
import 'package:xterm/xterm.dart';

/// Màn hình terminal SSH đầy đủ (bọc `SshTerminalPanel`). Thoát màn chỉ tách khỏi phiên.
class SshTerminalScreen extends StatelessWidget {
  const SshTerminalScreen({
    super.key,
    required this.hostId,
    required this.hostName,
    required this.hostAddress,
    this.sessionId,
  });

  final int hostId;
  final String hostName;
  final String hostAddress;

  /// Phiên đang chạy trên server cần gắn lại. Null = mở phiên mới.
  final String? sessionId;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final textTheme = Theme.of(context).textTheme;

    return GlassScreenScaffold(
      bodyBackgroundColor: TerminalThemes.defaultTheme.background,
      titleWidget: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(hostName, style: textTheme.titleSmall),
          Text(
            hostAddress,
            style: textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
      body: SshTerminalPanel(
        hostId: hostId,
        hostName: hostName,
        hostAddress: hostAddress,
        sessionId: sessionId,
        onEnded: () => closePanelPage(context),
      ),
    );
  }
}
