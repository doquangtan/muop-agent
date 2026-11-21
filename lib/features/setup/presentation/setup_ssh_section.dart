import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'package:muop_agent/core/theme/app_theme.dart';
import 'package:muop_agent/features/setup/domain/setup_entities.dart';

/// Khối SSH của máy này trong bước kiểm tra. Là điều kiện bắt buộc: server tự thiết lập khi làm được;
/// nếu không thì hiện các bước để người dùng copy lệnh vào terminal, rồi dán lại dòng khóa để xác nhận.
/// Mọi thao tác đi qua server (socket `setup:ssh:*`), app không chạy lệnh nào trên máy.
class SetupSshSection extends StatefulWidget {
  const SetupSshSection({
    super.key,
    required this.ssh,
    required this.busy,
    required this.onConfigure,
    required this.onAuto,
    required this.onVerify,
  });

  final SetupSsh ssh;
  final bool busy;
  final ValueChanged<String> onConfigure;
  final VoidCallback onAuto;
  final ValueChanged<String> onVerify;

  @override
  State<SetupSshSection> createState() => _SetupSshSectionState();
}

class _SetupSshSectionState extends State<SetupSshSection> {
  late final TextEditingController _user =
      TextEditingController(text: widget.ssh.username);
  final TextEditingController _paste = TextEditingController();

  @override
  void dispose() {
    _user.dispose();
    _paste.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ssh = widget.ssh;
    final scheme = context.scheme;
    final textTheme = Theme.of(context).textTheme;
    final checks = <(String, bool)>[
      ('OpenSSH client (lệnh ssh)', ssh.client),
      ('OpenSSH server (sshd) đang chạy', ssh.sshdRunning),
      ('Khóa SSH của server', ssh.keyExists),
      ('Khóa đã publish cho máy này', ssh.keyAuthorized),
      ('Đăng nhập SSH thử thành công', ssh.loginOk),
    ];
    // Số bước hướng dẫn đánh theo việc còn thiếu (sshd có thể đã có sẵn)
    final sshdStep = ssh.sshdRunning ? null : 1;
    final publishStep = ssh.sshdRunning ? 1 : 2;
    final pasteStep = publishStep + 1;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  ssh.ready
                      ? Icons.check_circle_rounded
                      : Icons.warning_amber_rounded,
                  color: ssh.ready ? context.status.success : context.status.warning,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('SSH của máy này (bắt buộc)', style: textTheme.titleMedium),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Server dùng SSH để mở terminal đồng ý điều khoản của agy trên máy này.',
              style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            for (final (label, ok) in checks)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    Icon(
                      ok ? Icons.check_rounded : Icons.close_rounded,
                      size: 18,
                      color: ok ? context.status.success : scheme.outline,
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: Text(label, style: textTheme.bodyMedium)),
                  ],
                ),
              ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _user,
                    enabled: !widget.busy,
                    decoration: const InputDecoration(
                      labelText: 'User SSH',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: widget.busy
                      ? null
                      : () => widget.onConfigure(_user.text.trim()),
                  child: const Text('Lưu user'),
                ),
              ],
            ),
            if (!ssh.ready) ...[
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: widget.busy ? null : widget.onAuto,
                icon: const Icon(Icons.auto_fix_high_rounded),
                label: const Text('Tự thiết lập SSH'),
              ),
              const SizedBox(height: 12),
              Text(
                'Nếu tự thiết lập không được, làm theo các bước sau trong terminal của máy này:',
                style: textTheme.bodySmall,
              ),
              if (sshdStep != null) ...[
                const SizedBox(height: 8),
                Text(
                  '$sshdStep. Cài và bật OpenSSH server (cần quyền sudo):',
                  style: textTheme.bodySmall,
                ),
                const _CommandBox(
                  command:
                      'sudo apt install -y openssh-server && sudo systemctl enable --now ssh',
                ),
              ],
              const SizedBox(height: 8),
              Text(
                '$publishStep. Publish khóa của server cho user ${ssh.username}:',
                style: textTheme.bodySmall,
              ),
              if (ssh.publicKey.isEmpty)
                Text(
                  'Chưa có khóa: bấm "Tự thiết lập SSH" để server tạo khóa trước.',
                  style: textTheme.bodySmall?.copyWith(color: scheme.error),
                )
              else
                _CommandBox(
                  command:
                      "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '${ssh.publicKey}' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys",
                ),
              const SizedBox(height: 8),
              Text(
                '$pasteStep. Dán lại dòng public key đã publish để server kiểm tra:',
                style: textTheme.bodySmall,
              ),
              const SizedBox(height: 6),
              TextField(
                controller: _paste,
                enabled: !widget.busy,
                minLines: 1,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Dòng public key (ssh-ed25519 ...)',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed: widget.busy
                      ? null
                      : () => widget.onVerify(_paste.text.trim()),
                  child: const Text('Xác nhận'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Một lệnh để copy vào terminal
class _CommandBox extends StatelessWidget {
  const _CommandBox({required this.command});

  final String command;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      decoration: BoxDecoration(
        color: context.scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: SelectableText(
              command,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
          IconButton(
            tooltip: 'Sao chép',
            icon: const Icon(Icons.copy_rounded, size: 18),
            onPressed: () => Clipboard.setData(ClipboardData(text: command)),
          ),
        ],
      ),
    );
  }
}
