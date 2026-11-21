import 'package:material_ui/material_ui.dart';

import 'package:muop_agent/core/theme/app_theme.dart';
import 'package:muop_agent/features/agy_auth/domain/agy_auth_entities.dart';

/// Ô dán mã xác thực Google (trang callback hiện mã). Mã được gửi thẳng vào terminal đăng nhập trên server,
/// không cần dán trong khung terminal.
class AgyLoginCodeField extends StatefulWidget {
  const AgyLoginCodeField({super.key, required this.onSubmit});

  /// Gửi mã; kết quả trả về trạng thái server (lỗi nằm trong `error`)
  final Future<AgyAuthState> Function(String code) onSubmit;

  @override
  State<AgyLoginCodeField> createState() => _AgyLoginCodeFieldState();
}

class _AgyLoginCodeFieldState extends State<AgyLoginCodeField> {
  final _controller = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final code = _controller.text.trim();
    if (code.isEmpty || _busy) return;
    setState(() => _busy = true);
    final res = await widget.onSubmit(code);
    if (!mounted) return;
    setState(() => _busy = false);
    if (res.ok) _controller.clear();
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final scheme = context.scheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Trang Google đưa ra mã thì dán vào đây rồi bấm Xác nhận.',
          style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _controller,
                minLines: 1,
                maxLines: 3,
                style: textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
                decoration: const InputDecoration(
                  labelText: 'Mã xác thực',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _submit(),
              ),
            ),
            const SizedBox(width: 8),
            // Nút luôn bấm được; `_submit` bỏ qua lần bấm khi đang gửi mã
            FilledButton(
              onPressed: _submit,
              child: const Text('Xác nhận'),
            ),
          ],
        ),
      ],
    );
  }
}
