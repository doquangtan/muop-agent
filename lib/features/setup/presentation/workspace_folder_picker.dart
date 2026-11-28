import 'package:material_ui/material_ui.dart';

import 'package:muop_agent/core/widgets/throttled_spinner.dart';

import 'package:muop_agent/core/theme/app_theme.dart';
import 'package:muop_agent/features/setup/domain/setup_entities.dart';
import 'package:muop_agent/features/setup/domain/setup_repository.dart';

/// Mở hộp thoại duyệt cây thư mục trên máy server. Bấm thư mục để đi vào, breadcrumb để quay lại,
/// "Chọn thư mục này" trả về đường dẫn đang xem. Hủy trả về null.
Future<String?> showWorkspaceFolderPicker(
  BuildContext context, {
  required SetupRepository repository,
  String start = '',
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => WorkspaceFolderPicker(repository: repository, start: start),
  );
}

class WorkspaceFolderPicker extends StatefulWidget {
  const WorkspaceFolderPicker({
    super.key,
    required this.repository,
    this.start = '',
  });

  final SetupRepository repository;

  /// Thư mục mở đầu tiên (rỗng = home của server)
  final String start;

  @override
  State<WorkspaceFolderPicker> createState() => _WorkspaceFolderPickerState();
}

class _WorkspaceFolderPickerState extends State<WorkspaceFolderPicker> {
  SetupDirListing? _listing;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _open(widget.start);
  }

  Future<void> _open(String path) async {
    setState(() => _loading = true);
    final res = await widget.repository.browseDirectories(path);
    if (!mounted) return;
    setState(() {
      _listing = res;
      _loading = false;
    });
  }

  /// Các thư mục từ gốc tới thư mục đang xem, để bấm quay lại từng cấp
  List<(String label, String path)> _crumbs(String path) {
    final parts = path.split('/').where((p) => p.isNotEmpty).toList();
    final crumbs = <(String, String)>[('/', '/')];
    var acc = '';
    for (final part in parts) {
      acc = '$acc/$part';
      crumbs.add((part, acc));
    }
    return crumbs;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final textTheme = Theme.of(context).textTheme;
    final listing = _listing;
    final ready = !_loading && listing != null && listing.ok;
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 520),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Chọn thư mục project', style: textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(
                'Trên máy đang chạy server. Bấm thư mục để mở, rồi chọn thư mục này.',
                style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  IconButton(
                    tooltip: 'Thư mục cha',
                    icon: const Icon(Icons.arrow_upward_rounded),
                    onPressed: ready && listing.parent.isNotEmpty
                        ? () => _open(listing.parent)
                        : null,
                  ),
                  IconButton(
                    tooltip: 'Thư mục home',
                    icon: const Icon(Icons.home_rounded),
                    onPressed: _loading || listing == null || listing.home.isEmpty
                        ? null
                        : () => _open(listing.home),
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (final (label, path) in _crumbs(listing?.path ?? ''))
                            TextButton(
                              onPressed: _loading ? null : () => _open(path),
                              child: Text(label),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              const Divider(height: 16),
              Expanded(child: _buildBody(listing, scheme, textTheme)),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Hủy'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: ready
                        ? () => Navigator.of(context).pop(listing.path)
                        : null,
                    child: const Text('Chọn thư mục này'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody(SetupDirListing? listing, ColorScheme scheme, TextTheme textTheme) {
    if (_loading || listing == null) {
      return const Center(child: ThrottledSpinner(size: 36, strokeWidth: 4));
    }
    if (!listing.ok) {
      return Center(
        child: Text(
          listing.error.isEmpty ? 'Không đọc được thư mục' : listing.error,
          style: TextStyle(color: scheme.error),
          textAlign: TextAlign.center,
        ),
      );
    }
    if (listing.dirs.isEmpty) {
      return Center(
        child: Text(
          'Thư mục này không có thư mục con',
          style: textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
        ),
      );
    }
    return ListView.builder(
      itemCount: listing.dirs.length,
      itemBuilder: (context, i) {
        final dir = listing.dirs[i];
        return ListTile(
          dense: true,
          leading: Icon(Icons.folder_rounded, color: context.status.warning),
          title: Text(dir.name),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => _open(dir.path),
        );
      },
    );
  }
}
