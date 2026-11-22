import 'package:material_ui/material_ui.dart';

import 'package:muop_agent/core/theme/app_theme.dart';
import 'package:muop_agent/features/setup/domain/setup_entities.dart';
import 'package:muop_agent/features/setup/domain/setup_repository.dart';

/// Ô chọn thư mục project: người dùng nhập đường dẫn tuyệt đối, server kiểm tra rồi lưu.
/// Dùng ở bước Khởi tạo và ở màn Cài đặt. Không có đường dẫn mặc định.
/// Việc quét project chỉ bắt đầu sau khi khởi tạo xong.
class WorkspaceRootField extends StatefulWidget {
  const WorkspaceRootField({
    super.key,
    required this.repository,
    required this.current,
    required this.onSaved,
    this.enabled = true,
  });

  final SetupRepository repository;

  /// Thư mục project đang lưu trên server (rỗng nếu chưa chọn)
  final String current;
  final bool enabled;

  /// Được gọi khi server đã lưu; nhận trạng thái mới
  final ValueChanged<SetupStatus> onSaved;

  @override
  State<WorkspaceRootField> createState() => _WorkspaceRootFieldState();
}

class _WorkspaceRootFieldState extends State<WorkspaceRootField> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.current);
  bool _busy = false;
  String _error = '';

  @override
  void didUpdateWidget(covariant WorkspaceRootField oldWidget) {
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
    final path = _controller.text.trim();
    if (path.isEmpty) {
      setState(() => _error = 'Hãy nhập đường dẫn thư mục project');
      return;
    }
    setState(() {
      _busy = true;
      _error = '';
    });
    final res = await widget.repository.setWorkspace(path);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (res.ok) {
        _error = '';
      } else {
        _error = res.error.isEmpty ? 'Không lưu được thư mục project' : res.error;
      }
    });
    if (res.ok) widget.onSaved(res);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final textTheme = Theme.of(context).textTheme;
    final enabled = widget.enabled && !_busy;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _controller,
          enabled: enabled,
          decoration: const InputDecoration(
            labelText: 'Đường dẫn thư mục project',
            hintText: 'Ví dụ: /home/ten-ban/projects',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (_) => _save(),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: Text(
                widget.current.isEmpty
                    ? 'Chưa chọn thư mục project'
                    : 'Đang dùng: ${widget.current}',
                style: textTheme.bodySmall?.copyWith(
                  color: widget.current.isEmpty
                      ? context.status.warning
                      : scheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: enabled ? _save : null,
              child: Text(_busy ? 'Đang lưu…' : 'Lưu thư mục'),
            ),
          ],
        ),
        if (_error.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(_error, style: TextStyle(color: scheme.error)),
        ],
      ],
    );
  }
}
