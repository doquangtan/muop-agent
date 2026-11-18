import 'package:material_ui/material_ui.dart';

import 'package:muop_agent/core/di/app_dependencies.dart';
import 'package:muop_agent/core/theme/app_theme.dart';
import 'package:muop_agent/features/server_files/domain/server_file_entities.dart';

/// Thư mục và file không cần hiển thị trong explorer (build, cache, phụ thuộc)
const Set<String> _hiddenNames = {
  '.git',
  '.dart_tool',
  '.idea',
  '.vscode',
  'build',
  'node_modules',
  'target',
  'Pods',
  '.gradle',
};

/// Trạng thái thay đổi của một file trong phiên làm việc hiện tại
enum ExplorerChangeStatus { created, modified }

/// Số file mới / đã sửa nằm bên trong một thư mục
class _FolderCounts {
  int created = 0;
  int modified = 0;
}

class _TreeNode {
  _TreeNode(this.entry, this.depth);

  final ServerFileEntry entry;
  final int depth;
  bool expanded = false;
  bool loading = false;
  String? error;
  List<_TreeNode>? children;
}

/// Cây thư mục của project trên server. Thư mục được tải khi mở; bấm file để mở ở vùng xem file.
/// File và thư mục có thay đổi được tô màu: mới = xanh (success), đã sửa = vàng (warning).
/// Thư mục hiển thị chữ N (có file mới bên trong, ưu tiên hơn) hoặc M (có file đã sửa).
class ProjectTreeExplorer extends StatefulWidget {
  const ProjectTreeExplorer({
    super.key,
    required this.serverAddress,
    required this.rootPath,
    required this.selectedFilePath,
    required this.onOpenFile,
    this.fileStatuses = const {},
    this.onCollapse,
  });
  final String serverAddress;
  final String rootPath;
  final String? selectedFilePath;
  final ValueChanged<String> onOpenFile;
  /// Thay đổi do agent ghi trong conversation (đường dẫn tuyệt đối). Chỉ dùng khi project không phải git repo.
  final Map<String, ExplorerChangeStatus> fileStatuses;
  final VoidCallback? onCollapse;

  @override
  State<ProjectTreeExplorer> createState() => _ProjectTreeExplorerState();
}

class _ProjectTreeExplorerState extends State<ProjectTreeExplorer> {
  List<_TreeNode> _roots = const [];
  bool _loadingRoot = false;
  String? _rootError;
  bool _showHidden = false;
  /// Các thư mục đang mở, để giữ lại khi làm mới hoặc đổi chế độ hiện file ẩn
  final Set<String> _expandedPaths = {};
  /// Trạng thái theo git (so với HEAD). Chỉ dùng khi project là git repository.
  Map<String, ExplorerChangeStatus> _gitStatuses = {};
  bool _gitLoaded = false;
  bool _isGitRepo = false;
  int _gitRequest = 0;

  /// Màu theo git nếu project là repo; không có git thì dựa vào thay đổi do agent ghi
  Map<String, ExplorerChangeStatus> get _statuses =>
      _gitLoaded && _isGitRepo ? _gitStatuses : widget.fileStatuses;

  @override
  void initState() {
    super.initState();
    _loadRoot();
  }

  @override
  void didUpdateWidget(covariant ProjectTreeExplorer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.rootPath != widget.rootPath ||
        oldWidget.serverAddress != widget.serverAddress) {
      _expandedPaths.clear();
      _loadRoot();
    } else if (_agentStatusChanged(oldWidget.fileStatuses, widget.fileStatuses)) {
      // Agent vừa sửa file: cập nhật lại màu theo git
      _loadGitStatus();
    }
  }

  bool _agentStatusChanged(
    Map<String, ExplorerChangeStatus> before,
    Map<String, ExplorerChangeStatus> after,
  ) {
    if (before.length != after.length) return true;
    for (final entry in before.entries) {
      if (after[entry.key] != entry.value) return true;
    }
    return false;
  }

  /// Lấy trạng thái git của project. Bỏ kết quả của yêu cầu cũ nếu đã có yêu cầu mới hơn.
  Future<void> _loadGitStatus() async {
    final request = ++_gitRequest;
    final res = await AppDependencies.serverFiles.fetchGitStatus(
      address: widget.serverAddress,
      projectPath: widget.rootPath,
    );
    if (!mounted || request != _gitRequest) return;
    final statuses = <String, ExplorerChangeStatus>{};
    if (res.ok && res.isRepo) {
      res.kinds.forEach((path, kind) {
        if (kind == 'created') {
          statuses[path] = ExplorerChangeStatus.created;
        } else if (kind == 'modified') {
          statuses[path] = ExplorerChangeStatus.modified;
        }
      });
    }
    setState(() {
      _gitStatuses = statuses;
      _isGitRepo = res.ok && res.isRepo;
      _gitLoaded = true;
    });
  }

  /// Lấy danh sách con của một thư mục, sắp thư mục trước rồi theo tên
  Future<List<_TreeNode>> _fetchChildren(String path, int depth) async {
    final res = await AppDependencies.serverFiles.fetchServerDirectory(
      address: widget.serverAddress,
      path: path,
      showHidden: _showHidden,
    );
    if (!res.ok) {
      throw res.error.isEmpty ? 'Không đọc được thư mục' : res.error;
    }
    final entries = res.entries.where((e) {
      if (_hiddenNames.contains(e.name)) return false;
      if (!_showHidden && e.name.startsWith('.')) return false;
      return true;
    }).toList()
      ..sort((a, b) {
        if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    return entries.map((e) => _TreeNode(e, depth)).toList();
  }

  Future<void> _loadRoot() async {
    _loadGitStatus();
    setState(() {
      _loadingRoot = true;
      _rootError = null;
    });
    try {
      final nodes = await _fetchChildren(widget.rootPath, 0);
      if (!mounted) return;
      setState(() {
        _roots = nodes;
        _loadingRoot = false;
      });
      await _restoreExpanded(_roots);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _roots = const [];
        _loadingRoot = false;
        _rootError = '$e';
      });
    }
  }

  /// Mở lại các thư mục đã mở trước đó (sau khi làm mới hoặc đổi chế độ file ẩn)
  Future<void> _restoreExpanded(List<_TreeNode> nodes) async {
    for (final node in nodes) {
      if (node.entry.isDir && _expandedPaths.contains(node.entry.path)) {
        await _expand(node);
      }
    }
  }

  Future<void> _expand(_TreeNode node) async {
    if (!mounted) return;
    setState(() {
      node.expanded = true;
      node.loading = true;
      node.error = null;
    });
    _expandedPaths.add(node.entry.path);
    try {
      final children = await _fetchChildren(node.entry.path, node.depth + 1);
      if (!mounted) return;
      setState(() {
        node.children = children;
        node.loading = false;
      });
      await _restoreExpanded(children);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        node.loading = false;
        node.error = '$e';
      });
    }
  }

  Future<void> _toggle(_TreeNode node) async {
    if (!node.entry.isDir) {
      widget.onOpenFile(node.entry.path);
      return;
    }
    if (node.expanded) {
      setState(() {
        node.expanded = false;
        _expandedPaths.remove(node.entry.path);
      });
      return;
    }
    if (node.children != null) {
      setState(() {
        node.expanded = true;
        _expandedPaths.add(node.entry.path);
      });
      return;
    }
    await _expand(node);
  }

  void _toggleHidden() {
    setState(() => _showHidden = !_showHidden);
    _loadRoot();
  }

  /// Đếm số file mới / đã sửa bên trong mỗi thư mục nằm trong project
  Map<String, _FolderCounts> _folderCounts() {
    final counts = <String, _FolderCounts>{};
    final root = widget.rootPath.endsWith('/')
        ? widget.rootPath.substring(0, widget.rootPath.length - 1)
        : widget.rootPath;
    _statuses.forEach((filePath, status) {
      if (!filePath.startsWith('$root/')) return;
      var dir = filePath.substring(0, filePath.lastIndexOf('/'));
      while (dir.length > root.length && dir.startsWith(root)) {
        final c = counts.putIfAbsent(dir, _FolderCounts.new);
        if (status == ExplorerChangeStatus.created) {
          c.created++;
        } else {
          c.modified++;
        }
        final slash = dir.lastIndexOf('/');
        if (slash <= 0) break;
        dir = dir.substring(0, slash);
      }
    });
    return counts;
  }

  /// Duỗi cây thành danh sách dòng hiển thị theo thứ tự từ trên xuống
  List<_TreeNode> _visibleRows() {
    final rows = <_TreeNode>[];
    void walk(List<_TreeNode> nodes) {
      for (final node in nodes) {
        rows.add(node);
        if (node.entry.isDir && node.expanded && node.children != null) {
          walk(node.children!);
        }
      }
    }

    walk(_roots);
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final rootName = widget.rootPath.split('/').where((s) => s.isNotEmpty).lastOrNull ?? '/';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 40,
          padding: const EdgeInsets.only(left: 12, right: 4),
          child: Row(
            children: [
              Icon(Icons.folder_open_rounded, size: 16, color: colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Tooltip(
                  message: widget.rootPath,
                  child: Text(
                    rootName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w800),
                  ),
                ),
              ),
              IconButton(
                tooltip: _showHidden ? 'Ẩn file ẩn (.*)' : 'Hiện file ẩn (.*)',
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  _showHidden ? Icons.visibility_rounded : Icons.visibility_off_outlined,
                  size: 18,
                ),
                onPressed: _loadingRoot ? null : _toggleHidden,
              ),
              IconButton(
                tooltip: 'Làm mới',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                onPressed: _loadingRoot ? null : _loadRoot,
              ),
              if (widget.onCollapse != null)
                IconButton(
                  tooltip: 'Thu gọn explorer',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.chevron_left_rounded, size: 18),
                  onPressed: widget.onCollapse,
                ),
            ],
          ),
        ),
        Divider(height: 1, color: colorScheme.outlineVariant),
        Expanded(child: _buildBody(context)),
      ],
    );
  }

  Widget _buildBody(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    if (_loadingRoot && _roots.isEmpty) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_rootError != null) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
          'Không tải được thư mục:\n$_rootError',
          style: textTheme.bodySmall?.copyWith(color: colorScheme.error),
        ),
      );
    }
    final rows = _visibleRows();
    if (rows.isEmpty) {
      return Center(
        child: Text(
          'Thư mục trống',
          style: textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
        ),
      );
    }
    final counts = _folderCounts();
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemExtent: 26,
      itemCount: rows.length,
      itemBuilder: (context, index) => _buildRow(context, rows[index], counts),
    );
  }

  Widget _buildRow(BuildContext context, _TreeNode node, Map<String, _FolderCounts> counts) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final path = node.entry.path;
    final isSelected = !node.entry.isDir && path == widget.selectedFilePath;
    final indent = 8.0 + node.depth * 14.0;

    // Màu và nhãn theo trạng thái thay đổi
    Color? changeColor;
    String? badge;
    String? badgeTooltip;
    if (node.entry.isDir) {
      final c = counts[path];
      // Ưu tiên file đã sửa (M) hơn file mới (N) khi cả hai cùng nằm bên trong
      if (c != null && c.modified > 0) {
        changeColor = context.status.warning;
        badge = 'M';
        badgeTooltip = '${c.modified} file đã sửa bên trong';
      } else if (c != null && c.created > 0) {
        changeColor = context.status.success;
        badge = 'N';
        badgeTooltip = '${c.created} file mới bên trong';
      }
    } else {
      final status = _statuses[path];
      if (status == ExplorerChangeStatus.created) {
        changeColor = context.status.success;
      } else if (status == ExplorerChangeStatus.modified) {
        changeColor = context.status.warning;
      }
    }

    final IconData icon;
    final Color iconColor;
    if (node.entry.isDir) {
      icon = node.expanded ? Icons.folder_open_rounded : Icons.folder_rounded;
      iconColor = changeColor ?? colorScheme.primary;
    } else {
      icon = Icons.insert_drive_file_outlined;
      iconColor = changeColor ?? colorScheme.onSurfaceVariant;
    }

    final nameColor = node.error != null
        ? colorScheme.error
        : (changeColor ?? colorScheme.onSurface);

    return Material(
      color: isSelected ? colorScheme.primary.withAlpha(28) : Colors.transparent,
      child: InkWell(
        onTap: () => _toggle(node),
        child: Padding(
          padding: EdgeInsets.only(left: indent, right: 8),
          child: Row(
            children: [
              if (node.entry.isDir)
                Icon(
                  node.expanded ? Icons.expand_more_rounded : Icons.chevron_right_rounded,
                  size: 16,
                  color: colorScheme.onSurfaceVariant,
                )
              else
                const SizedBox(width: 16),
              const SizedBox(width: 2),
              Icon(icon, size: 16, color: iconColor),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  node.loading ? '${node.entry.name} …' : node.entry.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.bodySmall?.copyWith(
                    fontWeight: isSelected || changeColor != null ? FontWeight.w700 : FontWeight.w500,
                    color: nameColor,
                  ),
                ),
              ),
              if (badge != null)
                Tooltip(
                  message: badgeTooltip ?? '',
                  child: Container(
                    width: 18,
                    height: 16,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: changeColor!.withAlpha(40),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      badge,
                      style: textTheme.labelSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: changeColor,
                        fontSize: 10,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
