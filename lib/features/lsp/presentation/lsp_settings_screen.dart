import 'package:material_ui/material_ui.dart';

import 'package:muop_agent/core/di/app_dependencies.dart';
import 'package:muop_agent/core/theme/app_theme.dart';
import 'package:muop_agent/features/lsp/domain/lsp_entities.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:muop_agent/core/state/server_address_provider.dart';

/// Cài đặt đường dẫn language server (gopls, dart, rust-analyzer) cho các máy có đường dẫn khác.
/// Đường dẫn được lưu trong SQLite trên server; để trống và lưu = dùng lại đường dẫn tự dò.
/// Màn gắn với server đang kết nối: đổi địa chỉ (provider toàn cục) thì dựng lại và tải lại dữ liệu
class LspSettingsScreen extends ConsumerWidget {
  const LspSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final serverAddress = ref.watch(serverAddressProvider);
    return LspSettingsScreenView(
      key: ValueKey(serverAddress),
      serverAddress: serverAddress,
    );
  }
}

class LspSettingsScreenView extends StatefulWidget {
  const LspSettingsScreenView({
    super.key,
    required this.serverAddress,
    this.embedded = false,
  });
  final String serverAddress;

  /// Trong màn Cài đặt (tab): không có Scaffold/AppBar riêng
  final bool embedded;

  @override
  State<LspSettingsScreenView> createState() => _LspSettingsScreenState();
}

class _LspSettingsScreenState extends State<LspSettingsScreenView> {
  List<LspLanguageStatus> _languages = const [];
  bool _loading = true;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    final res = await AppDependencies.lsp.fetchLspSettings(
      widget.serverAddress,
    );
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (res.ok) {
        _languages = res.languages;
      } else {
        _loadError = res.error.isEmpty
            ? 'Không tải được cài đặt LSP'
            : res.error;
      }
    });
  }

  /// Cập nhật danh sách trạng thái sau khi lưu
  void _applyResult(LspSettingsResult res) {
    if (res.languages.isNotEmpty) _languages = res.languages;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final textTheme = Theme.of(context).textTheme;

    final body = _loading
        ? const Center(child: CircularProgressIndicator())
        : _loadError != null
        ? Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.cloud_off_rounded, size: 40, color: scheme.error),
                  const SizedBox(height: 12),
                  Text(
                    _loadError!,
                    textAlign: TextAlign.center,
                    style: textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: _reload,
                    child: const Text('Thử lại'),
                  ),
                ],
              ),
            ),
          )
        : ListView(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
            children: [
              Text(
                'Đường dẫn LSP dùng để gấp code, danh sách hàm và Ctrl+click tới định nghĩa. '
                'Máy server chưa có LSP ở vị trí chuẩn thì nhập đường dẫn tuyệt đối tới tệp thực thi, rồi lưu. '
                'Để trống và lưu để dùng lại đường dẫn tự dò.',
                style: textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              for (final lang in _languages) ...[
                _LspLanguageCard(
                  key: ValueKey(lang.language),
                  serverAddress: widget.serverAddress,
                  status: lang,
                  onSaved: (res) => setState(() => _applyResult(res)),
                ),
                const SizedBox(height: 10),
              ],
            ],
          );

    if (widget.embedded) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: IconButton(
              tooltip: 'Kiểm tra lại',
              onPressed: _loading ? null : _reload,
              icon: const Icon(Icons.refresh_rounded),
            ),
          ),
          Expanded(child: body),
        ],
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Cài đặt LSP'),
        actions: [
          IconButton(
            tooltip: 'Kiểm tra lại',
            onPressed: _loading ? null : _reload,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: body,
    );
  }
}

class _LspLanguageCard extends StatefulWidget {
  const _LspLanguageCard({
    super.key,
    required this.serverAddress,
    required this.status,
    required this.onSaved,
  });
  final String serverAddress;
  final LspLanguageStatus status;
  final ValueChanged<LspSettingsResult> onSaved;

  @override
  State<_LspLanguageCard> createState() => _LspLanguageCardState();
}

class _LspLanguageCardState extends State<_LspLanguageCard> {
  late final TextEditingController _path;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _path = TextEditingController(text: widget.status.configuredPath);
  }

  @override
  void didUpdateWidget(covariant _LspLanguageCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Sau khi lưu, hiển thị đúng đường dẫn đã lưu từ server
    if (oldWidget.status.configuredPath != widget.status.configuredPath &&
        !_busy) {
      _path.text = widget.status.configuredPath;
    }
  }

  @override
  void dispose() {
    super.dispose();
  }

  Future<void> _save(String value) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final res = await AppDependencies.lsp.saveLspSetting(
      widget.serverAddress,
      language: widget.status.language,
      path: value,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (!res.ok) _error = res.error.isEmpty ? 'Không lưu được' : res.error;
    });
    if (res.ok) {
      _path.text = value;
      widget.onSaved(res);
    }
  }

  String get _sourceLabel {
    switch (widget.status.source) {
      case 'config':
        return 'Đã cài đặt';
      case 'auto':
        return 'Tự dò';
      default:
        return 'Chưa có';
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final status = context.status;
    final textTheme = Theme.of(context).textTheme;
    final st = widget.status;
    final ready = st.available;
    final chipColor = ready ? status.success : scheme.error;

    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    st.label,
                    style: textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: chipColor.withAlpha(36),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    _sourceLabel,
                    style: textTheme.labelSmall?.copyWith(
                      color: chipColor,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              ready
                  ? 'Đang dùng: ${st.effectivePath}'
                  : 'Chưa tìm thấy tệp thực thi',
              style: textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                color: scheme.onSurfaceVariant,
              ),
            ),
            if (st.note.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                st.note,
                style: textTheme.bodySmall?.copyWith(color: status.warning),
              ),
            ],
            const SizedBox(height: 10),
            TextField(
              controller: _path,
              enabled: !_busy,
              style: textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
              decoration: InputDecoration(
                labelText: 'Đường dẫn tệp thực thi (tuyệt đối)',
                hintText: _hintFor(st.language),
                isDense: true,
                errorText: _error,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (st.configuredPath.isNotEmpty)
                  TextButton(
                    onPressed: _busy ? null : () => _save(''),
                    child: const Text('Xóa cấu hình'),
                  ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _busy ? null : () => _save(_path.text.trim()),
                  child: _busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Lưu'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _hintFor(String language) {
    switch (language) {
      case 'go':
        return '/home/you/go/bin/gopls';
      case 'dart':
        return '/home/you/flutter/bin/dart';
      default:
        return '/home/you/.cargo/bin/rust-analyzer';
    }
  }
}
