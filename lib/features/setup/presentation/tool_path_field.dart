import 'package:material_ui/material_ui.dart';

import 'package:muop_agent/core/theme/app_theme.dart';
import 'package:muop_agent/features/setup/domain/setup_entities.dart';
import 'package:muop_agent/features/setup/domain/setup_repository.dart';

/// Ô nhập đường dẫn của một công cụ khi server không tìm thấy bằng `which`.
/// Server kiểm tra tệp thực thi rồi lưu. Để trống và lưu = bỏ lựa chọn, dò lại bằng `which`.
class ToolPathField extends StatefulWidget {
  const ToolPathField({
    super.key,
    required this.repository,
    required this.toolId,
    required this.current,
    required this.onSaved,
    this.enabled = true,
  });

  final SetupRepository repository;

  /// `id` của công cụ trong danh sách Khởi tạo (ví dụ `agy`)
  final String toolId;

  /// Đường dẫn đã lưu trên server (rỗng nếu chưa chọn)
  final String current;
  final bool enabled;

  /// Được gọi khi server đã lưu; nhận trạng thái mới
  final ValueChanged<SetupStatus> onSaved;

  @override
  State<ToolPathField> createState() => _ToolPathFieldState();
}

class _ToolPathFieldState extends State<ToolPathField> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.current);
  bool _busy = false;
  String _error = '';

  @override
  void didUpdateWidget(covariant ToolPathField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_busy && widget.current != oldWidget.current) {
      _controller.text = widget.current;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = '';
    });
    final res = await widget.repository
        .setToolPath(widget.toolId, _controller.text.trim());
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = res.ok
          ? ''
          : (res.error.isEmpty ? 'Không lưu được đường dẫn' : res.error);
    });
    if (res.ok) widget.onSaved(res);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final enabled = widget.enabled && !_busy;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _controller,
          enabled: enabled,
          decoration: InputDecoration(
            labelText: 'Đường dẫn tới ${widget.toolId}',
            hintText: 'Đường dẫn tuyệt đối tới tệp thực thi',
            border: const OutlineInputBorder(),
            isDense: true,
          ),
          onSubmitted: (_) => _save(),
        ),
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton(
            onPressed: enabled ? _save : null,
            child: Text(_busy ? 'Đang kiểm tra…' : 'Lưu đường dẫn'),
          ),
        ),
        if (_error.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(_error, style: TextStyle(color: scheme.error)),
        ],
      ],
    );
  }
}
