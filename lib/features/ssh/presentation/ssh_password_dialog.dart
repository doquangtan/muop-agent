import 'package:material_ui/material_ui.dart';

import 'package:muop_agent/core/theme/app_theme.dart';
import 'package:muop_agent/features/ssh/domain/ssh_entities.dart';

/// Hộp thoại nhập mật khẩu khi `ssh` trên server hỏi, hoặc khi sudo hỏi trên máy này
/// ([kind] = `sudo`). Trả về null nếu người dùng hủy.
/// [hint] hiển thị phía trên ô nhập (ví dụ "Sai mật khẩu, vui lòng nhập lại").
Future<SshPasswordInput?> showSshPasswordDialog(
  BuildContext context, {
  required String hostName,
  required String address,
  String? hint,
  String kind = 'ssh',
}) {
  return showDialog<SshPasswordInput>(
    context: context,
    builder: (_) => _SshPasswordDialog(
      hostName: hostName,
      address: address,
      hint: hint,
      kind: kind,
    ),
  );
}

class _SshPasswordDialog extends StatefulWidget {
  const _SshPasswordDialog({
    required this.hostName,
    required this.address,
    this.hint,
    this.kind = 'ssh',
  });

  final String hostName;
  final String address;
  final String? hint;
  final String kind;

  @override
  State<_SshPasswordDialog> createState() => _SshPasswordDialogState();
}

class _SshPasswordDialogState extends State<_SshPasswordDialog> {
  final _controller = TextEditingController();
  bool _save = false;
  bool _obscure = true;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _canSubmit => _controller.text.isNotEmpty;

  void _submit() {
    if (!_canSubmit) return;
    Navigator.of(context).pop(
      SshPasswordInput(password: _controller.text, save: _save),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final textTheme = Theme.of(context).textTheme;
    final hint = widget.hint;

    return AlertDialog(
      title: Text(widget.kind == 'sudo' ? 'Nhập mật khẩu sudo' : 'Nhập mật khẩu SSH'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.hostName,
            style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
          ),
          Text(
            widget.address,
            style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          if (hint != null && hint.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              hint,
              style: textTheme.bodySmall?.copyWith(color: scheme.error),
            ),
          ],
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            autofocus: true,
            obscureText: _obscure,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              labelText: 'Mật khẩu',
              suffixIcon: IconButton(
                tooltip: _obscure ? 'Hiện mật khẩu' : 'Ẩn mật khẩu',
                icon: Icon(
                  _obscure
                      ? Icons.visibility_rounded
                      : Icons.visibility_off_rounded,
                ),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _save,
            onChanged: (v) => setState(() => _save = v ?? false),
            title: Text(
              widget.kind == 'sudo'
                  ? 'Lưu mật khẩu cho máy này (dùng cho sudo)'
                  : 'Lưu mật khẩu cho máy này',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Hủy'),
        ),
        FilledButton(
          onPressed: _canSubmit ? _submit : null,
          child: const Text('Kết nối'),
        ),
      ],
    );
  }
}
