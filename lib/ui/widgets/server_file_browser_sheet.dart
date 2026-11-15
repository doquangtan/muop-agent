import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/agent_models.dart';
import '../../services/brain_scanner_service.dart';
import 'complete_markdown_doc_view.dart';
import 'project_git_history_sheet.dart';
import '../theme/app_theme.dart';

/// Đại diện cho 1 tệp đã được nhóm (deduplicated) từ danh sách FileTouchRecord
class GroupedFileChange {
  const GroupedFileChange({
    required this.path,
    required this.action,
    required this.repo,
    required this.agentNames,
    required this.touchCount,
    required this.addedLines,
    required this.removedLines,
    required this.diffPreview,
    required this.lastTimestamp,
    this.viaBash = false,
  });

  final String path;
  final String action; // WRITE, EDIT, READ
  final String repo;
  final List<String> agentNames;
  final int touchCount;
  final int addedLines;
  final int removedLines;
  final String diffPreview;
  final DateTime lastTimestamp;

  /// Thay đổi được suy ra từ lệnh Bash (không có số dòng +/-)
  final bool viaBash;

  String get basename {
    final parts = path.split('/');
    return parts.isNotEmpty ? parts.last : path;
  }

  String get directoryPath {
    final idx = path.lastIndexOf('/');
    if (idx <= 0) return '/';
    return path.substring(0, idx);
  }

  bool get hasChanges =>
      action == 'EDIT' ||
      action == 'WRITE' ||
      addedLines > 0 ||
      removedLines > 0 ||
      diffPreview.trim().isNotEmpty;

  static List<GroupedFileChange> groupRecords(List<FileTouchRecord> records) {
    final map = <String, _MutableFileGroup>{};
    for (final r in records) {
      final cleanPath = r.path.trim();
      if (cleanPath.isEmpty) continue;
      final group = map.putIfAbsent(
        cleanPath,
        () => _MutableFileGroup(
          path: cleanPath,
          action: r.action,
          repo: r.repo,
          lastTimestamp: r.timestamp,
        ),
      );
      group.touchCount += 1;
      if (r.source == 'bash') group.viaBash = true;
      group.addedLines += r.addedLines;
      group.removedLines += r.removedLines;
      if (!group.agentNames.contains(r.agentName) &&
          r.agentName.trim().isNotEmpty) {
        group.agentNames.add(r.agentName);
      }
      // Ưu tiên trạng thái WRITE / EDIT hơn READ
      if (r.action == 'WRITE') {
        group.action = 'WRITE';
      } else if (r.action == 'EDIT' && group.action != 'WRITE') {
        group.action = 'EDIT';
      }
      if (r.diffPreview.trim().isNotEmpty) {
        if (group.diffPreview.isEmpty) {
          group.diffPreview = r.diffPreview.trim();
        } else if (!group.diffPreview.contains(r.diffPreview.trim())) {
          group.diffPreview = '${group.diffPreview}\n@@ --- @@\n${r.diffPreview.trim()}';
        }
      }
      if (r.timestamp.isAfter(group.lastTimestamp)) {
        group.lastTimestamp = r.timestamp;
      }
    }

    final list = map.values
        .map(
          (g) => GroupedFileChange(
            path: g.path,
            action: g.action,
            repo: g.repo,
            agentNames: g.agentNames,
            touchCount: g.touchCount,
            addedLines: g.addedLines,
            removedLines: g.removedLines,
            diffPreview: g.diffPreview,
            lastTimestamp: g.lastTimestamp,
            viaBash: g.viaBash,
          ),
        )
        .toList();

    // Sắp xếp tệp có chỉnh sửa (WRITE/EDIT) lên đầu, sau đó tới READ
    list.sort((a, b) {
      if (a.hasChanges != b.hasChanges) {
        return a.hasChanges ? -1 : 1;
      }
      return b.lastTimestamp.compareTo(a.lastTimestamp);
    });
    return list;
  }
}

class _MutableFileGroup {
  _MutableFileGroup({
    required this.path,
    required this.action,
    required this.repo,
    required this.lastTimestamp,
  });

  final String path;
  String action;
  final String repo;
  final List<String> agentNames = [];
  int touchCount = 0;
  int addedLines = 0;
  int removedLines = 0;
  String diffPreview = '';
  bool viaBash = false;
  DateTime lastTimestamp;
}

enum _SftpSortMode { nameAsc, sizeDesc, dateDesc }

class ServerFileBrowserSheet extends StatefulWidget {
  const ServerFileBrowserSheet({
    super.key,
    required this.scanner,
    required this.serverAddress,
    required this.initialPath,
    required this.projects,
    required this.sessionFiles,
    this.initialTab = 0,
  });

  final BrainScannerService scanner;
  final String serverAddress;
  final String initialPath;
  final List<ProjectWorkspace> projects;
  final List<FileTouchRecord> sessionFiles;
  final int initialTab;

  static Future<void> show(
    BuildContext context, {
    required BrainScannerService scanner,
    required String serverAddress,
    required String initialPath,
    required List<ProjectWorkspace> projects,
    required List<FileTouchRecord> sessionFiles,
    int initialTab = 0,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: colorScheme.surfaceContainer,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => FractionallySizedBox(
        heightFactor: 0.90,
        child: ServerFileBrowserSheet(
          scanner: scanner,
          serverAddress: serverAddress,
          initialPath: initialPath,
          projects: projects,
          sessionFiles: sessionFiles,
          initialTab: initialTab,
        ),
      ),
    );
  }

  /// Mở hộp thoại xem chi tiết Change (Diff) & Nội dung tệp trên Server + Tải về
  static Future<void> showFilePreviewAndDiff(
    BuildContext context, {
    required BrainScannerService scanner,
    required String serverAddress,
    required String filePath,
    GroupedFileChange? groupedChange,
    required ValueChanged<String> onDownloadFile,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: colorScheme.surfaceContainer,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => FractionallySizedBox(
        heightFactor: 0.88,
        child: FileDiffAndContentPane(
          scanner: scanner,
          serverAddress: serverAddress,
          filePath: filePath,
          groupedChange: groupedChange,
          onDownloadFile: onDownloadFile,
        ),
      ),
    );
  }

  @override
  State<ServerFileBrowserSheet> createState() => _ServerFileBrowserSheetState();
}

class _ServerFileBrowserSheetState extends State<ServerFileBrowserSheet> {
  late String _currentPath;
  String _parentPath = '';
  List<ServerFileEntry> _entries = [];
  bool _isLoading = true;
  String _errorMessage = '';
  String _searchFilter = '';
  late int _activeTab; // 0 = SFTP Server Browser, 1 = Grouped Files Changed
  bool _showHidden = false;
  _SftpSortMode _sortMode = _SftpSortMode.nameAsc;
  bool _isEditingPath = false;
  late TextEditingController _pathEditController;

  final Set<String> _selectedFilePaths = {};
  bool _isBatchDownloading = false;

  String? _downloadingPath;
  int _receivedBytes = 0;
  int _totalBytes = 0;
  String? _lastSavedPath;
  String? _downloadError;

  @override
  void initState() {
    super.initState();
    _activeTab = widget.initialTab;
    _currentPath = widget.initialPath.trim().isNotEmpty
        ? widget.initialPath.trim()
        : '/home/john/Documents/muop-ecosystem';
    _pathEditController = TextEditingController(text: _currentPath);
    _loadDirectory(_currentPath);
  }

  @override
  void dispose() {
    _pathEditController.dispose();
    super.dispose();
  }

  Future<void> _loadDirectory(String path) async {
    setState(() {
      _isLoading = true;
      _errorMessage = '';
      _isEditingPath = false;
    });

    final res = await widget.scanner.fetchServerDirectory(
      address: widget.serverAddress,
      path: path,
      showHidden: _showHidden,
    );

    if (!mounted) return;
    setState(() {
      _isLoading = false;
      if (res.ok) {
        _currentPath = res.currentPath;
        _parentPath = res.parentPath;
        _entries = res.entries;
        _pathEditController.text = res.currentPath;
        _selectedFilePaths.clear();
      } else {
        _errorMessage = res.error.isNotEmpty
            ? res.error
            : 'Không thể đọc thư mục SFTP từ Rust Server';
      }
    });
  }

  Future<void> _downloadFile(String remotePath) async {
    if (_downloadingPath != null) return;
    setState(() {
      _downloadingPath = remotePath;
      _receivedBytes = 0;
      _totalBytes = 0;
      _lastSavedPath = null;
      _downloadError = null;
    });

    final res = await widget.scanner.downloadFileFromServer(
      address: widget.serverAddress,
      remotePath: remotePath,
      onProgress: (received, total) {
        if (!mounted) return;
        setState(() {
          _receivedBytes = received;
          _totalBytes = total;
        });
      },
    );

    if (!mounted) return;
    setState(() {
      _downloadingPath = null;
      if (res.ok) {
        _lastSavedPath = res.savedPath;
      } else {
        _downloadError = res.error;
      }
    });

    if (res.ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Đã tải file về máy: ${res.savedPath}'),
          duration: const Duration(seconds: 5),
          action: SnackBarAction(
            label: 'Mở tệp',
            onPressed: () {
              widget.scanner.openDownloadedFile(res.savedPath);
            },
          ),
        ),
      );
    }
  }

  Future<void> _downloadSelectedBatch() async {
    if (_selectedFilePaths.isEmpty || _isBatchDownloading) return;
    final targets = _selectedFilePaths.toList();
    setState(() {
      _isBatchDownloading = true;
      _downloadError = null;
    });

    int successCount = 0;
    String lastPath = '';
    for (final remotePath in targets) {
      if (!mounted) break;
      setState(() {
        _downloadingPath = remotePath;
        _receivedBytes = 0;
        _totalBytes = 0;
      });
      final res = await widget.scanner.downloadFileFromServer(
        address: widget.serverAddress,
        remotePath: remotePath,
        onProgress: (r, t) {
          if (!mounted) return;
          setState(() {
            _receivedBytes = r;
            _totalBytes = t;
          });
        },
      );
      if (res.ok) {
        successCount++;
        lastPath = res.savedPath;
      }
    }

    if (!mounted) return;
    setState(() {
      _isBatchDownloading = false;
      _downloadingPath = null;
      _selectedFilePaths.clear();
      if (lastPath.isNotEmpty) {
        _lastSavedPath = lastPath;
      }
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Đã tải hàng loạt $successCount/${targets.length} tệp về thiết bị!',
        ),
      ),
    );
  }

  List<GroupedFileChange> get _groupedSessionFiles =>
      GroupedFileChange.groupRecords(widget.sessionFiles);

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final isMobile = MediaQuery.sizeOf(context).width < 680;
    final groupedFiles = _groupedSessionFiles;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 1. Header SFTP & Chuyển Tab
        Padding(
          padding: EdgeInsets.fromLTRB(isMobile ? 14 : 20, 12, 10, 8),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(
                  color: colorScheme.primaryContainer.withAlpha(140),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  Icons.dns_rounded,
                  size: 18,
                  color: colorScheme.primary,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isMobile
                          ? 'SFTP & Tệp Thay Đổi'
                          : 'SFTP File Explorer & Changes — Rust Server',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      'sftp://${widget.serverAddress}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.labelSmall?.copyWith(
                        fontFamily: 'monospace',
                        fontSize: 10.5,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              SegmentedButton<int>(
                segments: [
                  ButtonSegment<int>(
                    value: 0,
                    icon: const Icon(Icons.folder_special_rounded, size: 15),
                    label: Text(isMobile ? 'SFTP' : 'Duyệt SFTP'),
                  ),
                  ButtonSegment<int>(
                    value: 1,
                    icon: const Icon(Icons.difference_rounded, size: 15),
                    label: Text('Changes (${groupedFiles.length})'),
                  ),
                ],
                selected: {_activeTab},
                onSelectionChanged: (s) => setState(() => _activeTab = s.first),
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.account_tree_outlined, size: 18),
                tooltip: 'Xem Git Tree & Commit History',
                onPressed: () {
                  ProjectGitHistorySheet.show(
                    context,
                    scanner: widget.scanner,
                    serverAddress: widget.serverAddress,
                    projectPath: _currentPath,
                  );
                },
              ),
              const SizedBox(width: 4),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close_rounded),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
        Divider(height: 1, color: colorScheme.outlineVariant),

        // 2. Thanh tiến trình tải file hoặc thao tác hàng loạt
        if (_selectedFilePaths.isNotEmpty && _activeTab == 0)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            color: colorScheme.secondaryContainer.withAlpha(140),
            child: Row(
              children: [
                Icon(
                  Icons.checklist_rounded,
                  size: 16,
                  color: colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Đã chọn ${_selectedFilePaths.length} tệp để tải về máy',
                    style: textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () => setState(() => _selectedFilePaths.clear()),
                  child: const Text('Bỏ chọn'),
                ),
                const SizedBox(width: 6),
                FilledButton.icon(
                  onPressed:
                      _isBatchDownloading ? null : _downloadSelectedBatch,
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  icon: const Icon(Icons.download_for_offline_rounded, size: 16),
                  label: Text('Tải ${_selectedFilePaths.length} tệp'),
                ),
              ],
            ),
          ),

        if (_downloadingPath != null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: colorScheme.primaryContainer.withAlpha(110),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const SizedBox(
                      width: 13,
                      height: 13,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Đang tải qua SFTP/HTTP: ${_downloadingPath!.split('/').last}...',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.labelSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Text(
                      _totalBytes > 0
                          ? '${(_receivedBytes / 1024).toStringAsFixed(0)} / ${(_totalBytes / 1024).toStringAsFixed(0)} KB'
                          : '${(_receivedBytes / 1024).toStringAsFixed(0)} KB',
                      style: textTheme.labelSmall?.copyWith(
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 5),
                LinearProgressIndicator(
                  value: _totalBytes > 0 ? _receivedBytes / _totalBytes : null,
                  borderRadius: BorderRadius.circular(4),
                ),
              ],
            ),
          ),

        if (_lastSavedPath != null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            color: context.status.success.withAlpha(30),
            child: Row(
              children: [
                Icon(
                  Icons.check_circle_rounded,
                  size: 15,
                  color: context.status.success,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: SelectableText(
                    'Đã lưu: $_lastSavedPath',
                    style: textTheme.labelSmall?.copyWith(
                      color: context.status.success,
                      fontWeight: FontWeight.w700,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                FilledButton.tonalIcon(
                  onPressed: () async {
                    final openRes = await widget.scanner
                        .openDownloadedFile(_lastSavedPath!);
                    if (!openRes.ok && context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            'Không thể mở bằng ứng dụng ngoài: ${openRes.error}',
                          ),
                        ),
                      );
                    }
                  },
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                  ),
                  icon: const Icon(Icons.open_in_new_rounded, size: 14),
                  label: const Text(
                    'Mở tệp',
                    style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton(
                  tooltip: 'Sao chép đường dẫn',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.copy_rounded, size: 14),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: _lastSavedPath!));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Đã sao chép đường dẫn tệp vừa tải'),
                        duration: Duration(seconds: 2),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),

        if (_downloadError != null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            color: context.scheme.error.withAlpha(30),
            child: Row(
              children: [
                Icon(
                  Icons.error_outline_rounded,
                  size: 15,
                  color: context.scheme.error,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Lỗi tải tệp: $_downloadError',
                    style: textTheme.labelSmall?.copyWith(
                      color: context.scheme.error,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),

        // 3. Nội dung chính theo Tab
        Expanded(
          child: _activeTab == 0
              ? _buildSftpExplorerTab(
                  context,
                  colorScheme,
                  textTheme,
                  isMobile,
                )
              : _buildGroupedChangesTab(
                  context,
                  groupedFiles,
                  colorScheme,
                  textTheme,
                  isMobile,
                ),
        ),
      ],
    );
  }

  Widget _buildSftpExplorerTab(
    BuildContext context,
    ColorScheme colorScheme,
    TextTheme textTheme,
    bool isMobile,
  ) {
    final filtered = _entries.where((e) {
      if (_searchFilter.isEmpty) return true;
      return e.name.toLowerCase().contains(_searchFilter.toLowerCase());
    }).toList();

    // Sắp xếp thư mục luôn ở trên, sau đó theo chế độ Sort
    filtered.sort((a, b) {
      if (a.isDir != b.isDir) {
        return a.isDir ? -1 : 1;
      }
      switch (_sortMode) {
        case _SftpSortMode.nameAsc:
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        case _SftpSortMode.sizeDesc:
          return b.size.compareTo(a.size);
        case _SftpSortMode.dateDesc:
          return b.modifiedAt.compareTo(a.modifiedAt);
      }
    });

    final dirCount = filtered.where((e) => e.isDir).length;
    final fileCount = filtered.length - dirCount;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 1. Bookmark nhảy nhanh tới các thư mục hệ thống & Project
        SizedBox(
          height: 38,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ActionChip(
                  visualDensity: VisualDensity.compact,
                  avatar: const Icon(Icons.home_outlined, size: 13.5),
                  label: const Text('/home/john', style: TextStyle(fontSize: 11.5)),
                  onPressed: () => _loadDirectory('/home/john'),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ActionChip(
                  visualDensity: VisualDensity.compact,
                  avatar: const Icon(Icons.workspaces_outlined, size: 13.5),
                  label: const Text(
                    'muop-ecosystem',
                    style: TextStyle(fontSize: 11.5),
                  ),
                  onPressed: () =>
                      _loadDirectory('/home/john/Documents/muop-ecosystem'),
                ),
              ),
              for (final p in widget.projects)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ActionChip(
                    visualDensity: VisualDensity.compact,
                    avatar: Icon(
                      Icons.folder_outlined,
                      size: 13.5,
                      color: _currentPath.startsWith(p.path)
                          ? colorScheme.primary
                          : null,
                    ),
                    label: Text(p.name, style: const TextStyle(fontSize: 11.5)),
                    onPressed: () => _loadDirectory(p.path),
                  ),
                ),
            ],
          ),
        ),

        // 2. Thanh Breadcrumb Path có thể bấm từng cấp hoặc nhập đường dẫn trực tiếp
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 2, 12, 6),
          child: Row(
            children: [
              IconButton.filledTonal(
                tooltip: 'Lên thư mục cha (..)',
                visualDensity: VisualDensity.compact,
                onPressed: _parentPath.isNotEmpty
                    ? () => _loadDirectory(_parentPath)
                    : null,
                icon: const Icon(Icons.arrow_upward_rounded, size: 16),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _isEditingPath
                    ? TextField(
                        controller: _pathEditController,
                        autofocus: true,
                        style: textTheme.labelSmall?.copyWith(
                          fontFamily: 'monospace',
                        ),
                        onSubmitted: (val) {
                          if (val.trim().isNotEmpty) {
                            _loadDirectory(val.trim());
                          }
                        },
                        decoration: InputDecoration(
                          hintText: 'Nhập đường dẫn trên Server...',
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          filled: true,
                          fillColor: colorScheme.surfaceContainerLowest,
                          suffixIcon: IconButton(
                            icon: const Icon(Icons.subdirectory_arrow_left_rounded, size: 15),
                            onPressed: () =>
                                _loadDirectory(_pathEditController.text.trim()),
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                      )
                    : _buildBreadcrumbBar(colorScheme, textTheme),
              ),
              const SizedBox(width: 4),
              IconButton(
                tooltip: _isEditingPath
                    ? 'Đóng nhập đường dẫn'
                    : 'Nhập đường dẫn trực tiếp',
                visualDensity: VisualDensity.compact,
                onPressed: () {
                  setState(() {
                    _isEditingPath = !_isEditingPath;
                    _pathEditController.text = _currentPath;
                  });
                },
                icon: Icon(
                  _isEditingPath ? Icons.close_rounded : Icons.edit_location_alt_outlined,
                  size: 17,
                ),
              ),
              IconButton(
                tooltip: 'Làm mới SFTP',
                visualDensity: VisualDensity.compact,
                onPressed: () => _loadDirectory(_currentPath),
                icon: const Icon(Icons.refresh_rounded, size: 17),
              ),
            ],
          ),
        ),

        // 3. Thanh công cụ lọc, hiện file ẩn (.env/.git), sắp xếp
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  onChanged: (v) => setState(() => _searchFilter = v.trim()),
                  style: textTheme.bodySmall,
                  decoration: InputDecoration(
                    hintText:
                        'Tìm tệp trong thư mục ($dirCount thư mục, $fileCount tệp)...',
                    prefixIcon: const Icon(Icons.search_rounded, size: 15),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 7),
                    filled: true,
                    fillColor: colorScheme.surfaceContainerHighest,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              FilterChip(
                visualDensity: VisualDensity.compact,
                label: const Text('.* Ẩn', style: TextStyle(fontSize: 11)),
                tooltip: 'Hiện/Ẩn các tệp bắt đầu bằng dấu chấm (.env, .git...)',
                selected: _showHidden,
                onSelected: (v) {
                  setState(() => _showHidden = v);
                  _loadDirectory(_currentPath);
                },
              ),
              const SizedBox(width: 4),
              PopupMenuButton<_SftpSortMode>(
                tooltip: 'Sắp xếp danh sách SFTP',
                onSelected: (m) => setState(() => _sortMode = m),
                itemBuilder: (ctx) => const [
                  PopupMenuItem(
                    value: _SftpSortMode.nameAsc,
                    child: Text('Sắp xếp: Tên (A → Z)'),
                  ),
                  PopupMenuItem(
                    value: _SftpSortMode.sizeDesc,
                    child: Text('Sắp xếp: Dung lượng giảm dần'),
                  ),
                  PopupMenuItem(
                    value: _SftpSortMode.dateDesc,
                    child: Text('Sắp xếp: Mới sửa gần nhất'),
                  ),
                ],
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.sort_rounded,
                        size: 15,
                        color: colorScheme.onSurfaceVariant,
                      ),
                      if (!isMobile) ...[
                        const SizedBox(width: 4),
                        Text(
                          _sortMode == _SftpSortMode.nameAsc
                              ? 'Tên'
                              : _sortMode == _SftpSortMode.sizeDesc
                                  ? 'Size'
                                  : 'Ngày',
                          style: textTheme.labelSmall,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),

        // 4. Danh sách tệp SFTP
        Expanded(
          child: _isLoading
              ? const Center(child: CircularProgressIndicator())
              : _errorMessage.isNotEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Text(
                          _errorMessage,
                          style: textTheme.bodyMedium?.copyWith(
                            color: context.scheme.error,
                          ),
                        ),
                      ),
                    )
                  : filtered.isEmpty
                      ? Center(
                          child: Text(
                            'Thư mục trống hoặc không khớp bộ lọc',
                            style: textTheme.bodySmall?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 4,
                          ),
                          itemCount: filtered.length,
                          separatorBuilder: (_, _) =>
                              const SizedBox(height: 4),
                          itemBuilder: (context, idx) {
                            final entry = filtered[idx];
                            final isDownloadingThis =
                                _downloadingPath == entry.path;
                            final isSelected =
                                _selectedFilePaths.contains(entry.path);

                            return InkWell(
                              borderRadius: BorderRadius.circular(10),
                              onTap: entry.isDir
                                  ? () => _loadDirectory(entry.path)
                                  : () => ServerFileBrowserSheet
                                          .showFilePreviewAndDiff(
                                        context,
                                        scanner: widget.scanner,
                                        serverAddress: widget.serverAddress,
                                        filePath: entry.path,
                                        onDownloadFile: _downloadFile,
                                      ),
                              child: Container(
                                padding: EdgeInsets.symmetric(
                                  horizontal: isMobile ? 8 : 12,
                                  vertical: 8,
                                ),
                                decoration: BoxDecoration(
                                  color: isSelected
                                      ? colorScheme.primaryContainer
                                          .withAlpha(70)
                                      : colorScheme.surfaceContainerLow,
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                    color: isSelected
                                        ? colorScheme.primary
                                        : colorScheme.outlineVariant,
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    if (!entry.isDir)
                                      SizedBox(
                                        width: 26,
                                        height: 24,
                                        child: Checkbox(
                                          value: isSelected,
                                          visualDensity: VisualDensity.compact,
                                          onChanged: (v) {
                                            setState(() {
                                              if (v == true) {
                                                _selectedFilePaths
                                                    .add(entry.path);
                                              } else {
                                                _selectedFilePaths
                                                    .remove(entry.path);
                                              }
                                            });
                                          },
                                        ),
                                      )
                                    else
                                      const SizedBox(width: 4),
                                    Icon(
                                      entry.isDir
                                          ? Icons.folder_rounded
                                          : _iconForFileName(entry.name),
                                      size: 20,
                                      color: entry.isDir
                                          ? context.status.warning
                                          : colorScheme.primary,
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            entry.name,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style:
                                                textTheme.bodySmall?.copyWith(
                                              fontWeight: entry.isDir
                                                  ? FontWeight.w700
                                                  : FontWeight.w600,
                                              color: colorScheme.onSurface,
                                            ),
                                          ),
                                          const SizedBox(height: 2),
                                          Row(
                                            children: [
                                              Text(
                                                entry.permissions,
                                                style: textTheme.labelSmall
                                                    ?.copyWith(
                                                  fontFamily: 'monospace',
                                                  fontSize: 10,
                                                  color: colorScheme
                                                      .onSurfaceVariant,
                                                ),
                                              ),
                                              const SizedBox(width: 8),
                                              Text(
                                                entry.formattedSize,
                                                style: textTheme.labelSmall
                                                    ?.copyWith(
                                                  fontFamily: 'monospace',
                                                  fontSize: 10,
                                                  fontWeight: FontWeight.w700,
                                                  color: colorScheme.primary,
                                                ),
                                              ),
                                              const SizedBox(width: 8),
                                              Flexible(
                                                child: Text(
                                                  _formatDateShort(
                                                    entry.modifiedAt,
                                                  ),
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: textTheme.labelSmall
                                                      ?.copyWith(
                                                    fontSize: 10,
                                                    color: colorScheme
                                                        .onSurfaceVariant,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
                                    if (entry.isDir)
                                      Icon(
                                        Icons.chevron_right_rounded,
                                        size: 18,
                                        color: colorScheme.onSurfaceVariant,
                                      )
                                    else ...[
                                      IconButton(
                                        tooltip: 'Xem nội dung & Git Diff',
                                        visualDensity: VisualDensity.compact,
                                        onPressed: () => ServerFileBrowserSheet
                                            .showFilePreviewAndDiff(
                                          context,
                                          scanner: widget.scanner,
                                          serverAddress: widget.serverAddress,
                                          filePath: entry.path,
                                          onDownloadFile: _downloadFile,
                                        ),
                                        icon: Icon(
                                          Icons.visibility_outlined,
                                          size: 16,
                                          color: colorScheme.onSurfaceVariant,
                                        ),
                                      ),
                                      FilledButton.tonalIcon(
                                        onPressed: isDownloadingThis
                                            ? null
                                            : () => _downloadFile(entry.path),
                                        style: FilledButton.styleFrom(
                                          visualDensity: VisualDensity.compact,
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 4,
                                          ),
                                        ),
                                        icon: isDownloadingThis
                                            ? const SizedBox(
                                                width: 12,
                                                height: 12,
                                                child:
                                                    CircularProgressIndicator(
                                                  strokeWidth: 2,
                                                ),
                                              )
                                            : const Icon(
                                                Icons.download_rounded,
                                                size: 14,
                                              ),
                                        label: Text(
                                          isMobile ? 'Tải' : 'Tải về',
                                          style: const TextStyle(fontSize: 11.5),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
        ),
      ],
    );
  }

  Widget _buildBreadcrumbBar(ColorScheme colorScheme, TextTheme textTheme) {
    final segments =
        _currentPath.split('/').where((s) => s.isNotEmpty).toList();
    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        reverse: true,
        child: Row(
          children: [
            InkWell(
              onTap: () => _loadDirectory('/'),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                child: Text(
                  '/',
                  style: textTheme.labelSmall?.copyWith(
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w800,
                    color: colorScheme.primary,
                  ),
                ),
              ),
            ),
            for (int i = 0; i < segments.length; i++) ...[
              Icon(
                Icons.chevron_right_rounded,
                size: 14,
                color: colorScheme.onSurfaceVariant,
              ),
              InkWell(
                borderRadius: BorderRadius.circular(4),
                onTap: () {
                  final target = '/${segments.sublist(0, i + 1).join('/')}';
                  _loadDirectory(target);
                },
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                  child: Text(
                    segments[i],
                    style: textTheme.labelSmall?.copyWith(
                      fontFamily: 'monospace',
                      fontWeight: i == segments.length - 1
                          ? FontWeight.w800
                          : FontWeight.w500,
                      color: i == segments.length - 1
                          ? colorScheme.onSurface
                          : colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Tab hiển thị các tệp đã nhóm theo Repo / Thư mục kèm số dòng +Added / -Removed và nút Xem Change
  Widget _buildGroupedChangesTab(
    BuildContext context,
    List<GroupedFileChange> groupedFiles,
    ColorScheme colorScheme,
    TextTheme textTheme,
    bool isMobile,
  ) {
    if (groupedFiles.isEmpty) {
      return Center(
        child: Text(
          'Phiên hội thoại này chưa có tệp nào được tác động.',
          style: textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    // Nhóm theo Repo (`muop-erp-server`, `muop-erp-app`, `muop-agent`, `system`)
    final byRepo = <String, List<GroupedFileChange>>{};
    for (final f in groupedFiles) {
      byRepo.putIfAbsent(f.repo, () => []).add(f);
    }

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        for (final entry in byRepo.entries) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 6, top: 4),
            child: Row(
              children: [
                Icon(
                  Icons.inventory_2_outlined,
                  size: 15,
                  color: colorScheme.primary,
                ),
                const SizedBox(width: 6),
                Text(
                  '${entry.key} (${entry.value.length} tệp)',
                  style: textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: colorScheme.primary,
                  ),
                ),
              ],
            ),
          ),
          for (final f in entry.value)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () => ServerFileBrowserSheet.showFilePreviewAndDiff(
                  context,
                  scanner: widget.scanner,
                  serverAddress: widget.serverAddress,
                  filePath: f.path,
                  groupedChange: f,
                  onDownloadFile: _downloadFile,
                ),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: colorScheme.outlineVariant),
                  ),
                  child: Row(
                    children: [
                      _buildActionBadge(f.action, textTheme),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    f.basename,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: textTheme.bodySmall?.copyWith(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                if (f.addedLines > 0 || f.removedLines > 0) ...[
                                  const SizedBox(width: 6),
                                  _buildDiffStatPill(
                                    f.addedLines,
                                    f.removedLines,
                                    textTheme,
                                  ),
                                ],
                              ],
                            ),
                            const SizedBox(height: 2),
                            Text(
                              f.path,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: textTheme.labelSmall?.copyWith(
                                fontFamily: 'monospace',
                                fontSize: 10,
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        onPressed: () =>
                            ServerFileBrowserSheet.showFilePreviewAndDiff(
                          context,
                          scanner: widget.scanner,
                          serverAddress: widget.serverAddress,
                          filePath: f.path,
                          groupedChange: f,
                          onDownloadFile: _downloadFile,
                        ),
                        style: OutlinedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                        ),
                        icon: const Icon(Icons.difference_outlined, size: 14),
                        label: Text(
                          isMobile ? 'Diff' : 'Xem Change',
                          style: const TextStyle(fontSize: 11.5),
                        ),
                      ),
                      const SizedBox(width: 4),
                      IconButton.filledTonal(
                        tooltip: 'Tải file về máy',
                        visualDensity: VisualDensity.compact,
                        onPressed: _downloadingPath == f.path
                            ? null
                            : () => _downloadFile(f.path),
                        icon: const Icon(Icons.download_rounded, size: 15),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          const SizedBox(height: 8),
        ],
      ],
    );
  }

  Widget _buildActionBadge(String action, TextTheme textTheme) {
    Color bg;
    Color fg;
    String label;
    if (action == 'WRITE') {
      bg = context.status.success.withAlpha(35);
      fg = context.status.success;
      label = 'NEW';
    } else if (action == 'EDIT') {
      bg = context.status.warning.withAlpha(35);
      fg = context.status.warning;
      label = 'MOD';
    } else {
      bg = context.scheme.onSurfaceVariant.withAlpha(30);
      fg = context.scheme.onSurfaceVariant;
      label = 'READ';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        label,
        style: textTheme.labelSmall?.copyWith(
          fontSize: 9.5,
          fontWeight: FontWeight.w800,
          color: fg,
        ),
      ),
    );
  }

  Widget _buildDiffStatPill(int added, int removed, TextTheme textTheme) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (added > 0)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              color: context.status.success.withAlpha(30),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              '+$added',
              style: textTheme.labelSmall?.copyWith(
                fontFamily: 'monospace',
                fontSize: 10,
                fontWeight: FontWeight.w800,
                color: context.status.success,
              ),
            ),
          ),
        if (added > 0 && removed > 0) const SizedBox(width: 3),
        if (removed > 0)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              color: context.scheme.error.withAlpha(30),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              '-$removed',
              style: textTheme.labelSmall?.copyWith(
                fontFamily: 'monospace',
                fontSize: 10,
                fontWeight: FontWeight.w800,
                color: context.scheme.error,
              ),
            ),
          ),
      ],
    );
  }

  String _formatDateShort(DateTime dt) {
    final local = dt.toLocal();
    final d = local.day.toString().padLeft(2, '0');
    final m = local.month.toString().padLeft(2, '0');
    final h = local.hour.toString().padLeft(2, '0');
    final min = local.minute.toString().padLeft(2, '0');
    return '$d/$m $h:$min';
  }

  IconData _iconForFileName(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.apk')) return Icons.android_rounded;
    if (lower.endsWith('.dart') ||
        lower.endsWith('.go') ||
        lower.endsWith('.rs') ||
        lower.endsWith('.py') ||
        lower.endsWith('.js') ||
        lower.endsWith('.ts')) {
      return Icons.code_rounded;
    }
    if (lower.endsWith('.json') ||
        lower.endsWith('.yaml') ||
        lower.endsWith('.toml')) {
      return Icons.data_object_rounded;
    }
    if (lower.endsWith('.md') || lower.endsWith('.txt')) {
      return Icons.description_outlined;
    }
    if (lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.webp')) {
      return Icons.image_outlined;
    }
    if (lower.endsWith('.zip') ||
        lower.endsWith('.tar') ||
        lower.endsWith('.gz')) {
      return Icons.folder_zip_outlined;
    }
    return Icons.insert_drive_file_outlined;
  }
}

/// Modal hiển thị trực quan Change (Diff xanh/đỏ) và Nội dung tệp từ Rust Server
class FileDiffAndContentPane extends StatefulWidget {
  const FileDiffAndContentPane({
    super.key,
    required this.scanner,
    required this.serverAddress,
    required this.filePath,
    this.groupedChange,
    required this.onDownloadFile,
    this.onClose,
  });

  final BrainScannerService scanner;
  final String serverAddress;
  final String filePath;
  final GroupedFileChange? groupedChange;
  final ValueChanged<String> onDownloadFile;
  /// Nếu null thì nút đóng tự pop modal; khi nhúng vào layout thì truyền callback riêng
  final VoidCallback? onClose;

  @override
  State<FileDiffAndContentPane> createState() =>
      _FileDiffAndContentPaneState();
}

class _FileDiffAndContentPaneState extends State<FileDiffAndContentPane> {
  bool _isLoading = true;
  ServerFileReadResponse? _readResponse;
  int _selectedTab = 0; // 0 = Changes (Diff), 1 = Full File Content
  int _markdownViewMode = 0; // 0 = Preview (Bản xem trước), 1 = Raw Source (Mã nguồn)
  bool _isDownloading = false;
  double _downloadProgress = 0.0;
  String? _downloadedLocalPath;
  final TransformationController _imageTransformController =
      TransformationController();
  double _currentImageScale = 1.0;

  @override
  void initState() {
    super.initState();
    _fetchFileDetail();
  }

  @override
  void didUpdateWidget(covariant FileDiffAndContentPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.filePath != widget.filePath) {
      _downloadedLocalPath = null;
      _fetchFileDetail();
    }
  }

  @override
  void dispose() {
    _imageTransformController.dispose();
    super.dispose();
  }

  bool _isImageFile(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.bmp') ||
        lower.endsWith('.ico') ||
        lower.endsWith('.svg');
  }

  bool _isMarkdownFile(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.md') ||
        lower.endsWith('.markdown') ||
        lower.endsWith('.mdown') ||
        lower.endsWith('.plan');
  }

  /// Ngưỡng dưới đó markdown được tải toàn bộ để render; file lớn hơn chỉ xem dạng dòng
  static const int _markdownFullLoadLimit = 300 * 1024;
  /// Số dòng mỗi trang khi tải theo đoạn
  static const int _linePageSize = 200;
  /// Số trang tối đa giữ trong bộ nhớ (cuộn xa thì trang xa nhất bị bỏ)
  static const int _maxCachedLinePages = 40;

  /// Các trang dòng đã tải, key là số trang (bắt đầu từ 0)
  final Map<int, List<String>> _linePages = {};
  final Set<int> _linePagesLoading = {};
  int _totalLines = 0;
  /// Tăng mỗi lần đổi file để bỏ kết quả của yêu cầu cũ
  int _generation = 0;

  Future<void> _fetchFileDetail() async {
    setState(() => _isLoading = true);
    final gen = ++_generation;
    _linePages.clear();
    _linePagesLoading.clear();
    _totalLines = 0;

    if (_isImageFile(widget.filePath)) {
      final res = await widget.scanner.readServerFile(
        address: widget.serverAddress,
        path: widget.filePath,
      );
      if (!mounted || gen != _generation) return;
      setState(() {
        _isLoading = false;
        _readResponse = res;
        _selectedTab = 1;
      });
      return;
    }

    final first = await widget.scanner.fetchServerFileLines(
      address: widget.serverAddress,
      path: widget.filePath,
      offset: 0,
      limit: _linePageSize,
    );
    if (!mounted || gen != _generation) return;

    ServerFileReadResponse resp = ServerFileReadResponse(
      ok: first.ok,
      path: first.path,
      name: first.name,
      size: first.size,
      isBinary: first.isBinary,
      content: '',
      gitDiff: first.gitDiff,
      error: first.error,
    );
    // Markdown nhỏ: tải toàn bộ để render như tài liệu. File lớn: chỉ xem dạng dòng.
    if (first.ok &&
        !first.isBinary &&
        _isMarkdownFile(widget.filePath) &&
        first.size <= _markdownFullLoadLimit) {
      final full = await widget.scanner.readServerFile(
        address: widget.serverAddress,
        path: widget.filePath,
      );
      if (!mounted || gen != _generation) return;
      if (full.ok) resp = full;
    }

    if (first.ok) {
      _linePages[0] = first.lines;
      _totalLines = first.totalLines;
    }
    final hasAnyDiff =
        (widget.groupedChange?.diffPreview.trim().isNotEmpty == true) ||
            resp.gitDiff.trim().isNotEmpty;
    setState(() {
      _isLoading = false;
      _readResponse = resp;
      _selectedTab = hasAnyDiff ? 0 : 1;
    });
  }

  /// Tải một trang dòng ở nền; khi xong thì vẽ lại phần đã có dữ liệu
  void _ensureLinePage(int page) {
    if (_linePages.containsKey(page) || _linePagesLoading.contains(page)) return;
    _linePagesLoading.add(page);
    final gen = _generation;
    widget.scanner
        .fetchServerFileLines(
      address: widget.serverAddress,
      path: widget.filePath,
      offset: page * _linePageSize,
      limit: _linePageSize,
    )
        .then((res) {
      if (!mounted || gen != _generation) return;
      setState(() {
        _linePagesLoading.remove(page);
        // Lỗi: trang rỗng để không lặp lại yêu cầu vô hạn khi cuộn
        _linePages[page] = res.ok ? res.lines : const <String>[];
        _evictLinePages(page);
      });
    });
  }

  /// Bỏ các trang xa vị trí đang xem nhất khi vượt quá giới hạn bộ nhớ
  void _evictLinePages(int nearPage) {
    if (_linePages.length <= _maxCachedLinePages) return;
    final pages = _linePages.keys.toList()
      ..sort((a, b) => (b - nearPage).abs().compareTo((a - nearPage).abs()));
    for (final page in pages.take(_linePages.length - _maxCachedLinePages)) {
      _linePages.remove(page);
    }
  }

  Future<void> _downloadAndTrack() async {
    if (_isDownloading) return;
    setState(() {
      _isDownloading = true;
      _downloadProgress = 0.0;
    });
    final res = await widget.scanner.downloadFileFromServer(
      address: widget.serverAddress,
      remotePath: widget.filePath,
      onProgress: (received, total) {
        if (!mounted) return;
        setState(() {
          if (total > 0) {
            _downloadProgress = (received / total).clamp(0.0, 1.0);
          } else {
            _downloadProgress = (_downloadProgress + 0.08).clamp(0.0, 0.95);
          }
        });
      },
    );
    if (!mounted) return;
    setState(() {
      _isDownloading = false;
      if (res.ok) {
        _downloadProgress = 1.0;
        _downloadedLocalPath = res.savedPath;
      }
    });
    if (res.ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Đã tải xong: ${res.savedPath}'),
          action: SnackBarAction(
            label: 'Mở tệp',
            onPressed: () => widget.scanner.openDownloadedFile(res.savedPath),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final filename = widget.filePath.split('/').last;
    final agentDiff = widget.groupedChange?.diffPreview.trim() ?? '';
    final gitDiff = _readResponse?.gitDiff.trim() ?? '';
    final combinedDiff = agentDiff.isNotEmpty
        ? (gitDiff.isNotEmpty
            ? '@@ Thay đổi bởi Agent trong hội thoại @@\n$agentDiff\n\n@@ Git Diff HEAD trên Server @@\n$gitDiff'
            : agentDiff)
        : gitDiff;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Header
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 10, 8),
          child: Row(
            children: [
              Icon(
                Icons.difference_rounded,
                size: 20,
                color: colorScheme.primary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      filename,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      widget.filePath,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.labelSmall?.copyWith(
                        fontFamily: 'monospace',
                        fontSize: 10.5,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              // Khi tải về xong: Thay thế hoàn toàn bằng nút Mở tệp
              if (_downloadedLocalPath != null) ...[
                FilledButton.icon(
                  onPressed: () =>
                      widget.scanner.openDownloadedFile(_downloadedLocalPath!),
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    backgroundColor: context.status.success,
                    foregroundColor: context.scheme.onPrimary,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  icon: const Icon(Icons.open_in_new_rounded, size: 15),
                  label: const Text(
                    'Mở tệp',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                  ),
                ),
                const SizedBox(width: 2),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Tải lại',
                  icon: const Icon(Icons.refresh_rounded, size: 16),
                  onPressed: _isDownloading ? null : _downloadAndTrack,
                ),
              ] else ...[
                // Lúc bấm tải về: Đổ màu từ trái qua phải theo % tải về
                _buildProgressDownloadButton(context),
              ],
              const SizedBox(width: 4),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close_rounded),
                onPressed: widget.onClose ?? () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: SegmentedButton<int>(
            segments: [
              ButtonSegment<int>(
                value: 0,
                icon: const Icon(Icons.compare_arrows_rounded, size: 15),
                label: Text(
                  widget.groupedChange != null &&
                          (widget.groupedChange!.addedLines > 0 ||
                              widget.groupedChange!.removedLines > 0)
                      ? 'Changes (+${widget.groupedChange!.addedLines} / -${widget.groupedChange!.removedLines})'
                      : 'Changes (Diff)',
                ),
              ),
              ButtonSegment<int>(
                value: 1,
                icon: Icon(
                  (_readResponse?.isImageFile == true || _isImageFile(widget.filePath))
                      ? Icons.image_outlined
                      : ((_readResponse?.isMarkdown == true || _isMarkdownFile(widget.filePath))
                          ? Icons.description_outlined
                          : Icons.article_outlined),
                  size: 15,
                ),
                label: Text(
                  (_readResponse?.isImageFile == true || _isImageFile(widget.filePath))
                      ? 'Hình ảnh (Image)'
                      : ((_readResponse?.isMarkdown == true || _isMarkdownFile(widget.filePath))
                          ? 'Tài liệu Markdown'
                          : 'Nội dung tệp'),
                ),
              ),
            ],
            selected: {_selectedTab},
            onSelectionChanged: (s) => setState(() => _selectedTab = s.first),
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
          ),
        ),
        const SizedBox(height: 4),
        Divider(height: 1, color: colorScheme.outlineVariant),
        Expanded(
          child: _isLoading
              ? const Center(child: CircularProgressIndicator())
              : _selectedTab == 0
                  ? _buildColoredDiffView(
                      context,
                      combinedDiff,
                      colorScheme,
                      textTheme,
                    )
                  : _buildFullFileContentView(
                      context,
                      _readResponse,
                      colorScheme,
                      textTheme,
                    ),
        ),
      ],
    );
  }

  Widget _buildColoredDiffView(
    BuildContext context,
    String diffText,
    ColorScheme colorScheme,
    TextTheme textTheme,
  ) {
    if (diffText.trim().isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.check_circle_outline_rounded,
                size: 36,
                color: colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 10),
              Text(
                'Tệp này chỉ được đọc (READ) hoặc không có khác biệt so với Git HEAD.',
                textAlign: TextAlign.center,
                style: textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () => setState(() => _selectedTab = 1),
                icon: const Icon(Icons.article_outlined, size: 16),
                label: const Text('Xem toàn bộ nội dung tệp'),
              ),
            ],
          ),
        ),
      );
    }

    final lines = diffText.split('\n');
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: lines.length,
      itemBuilder: (context, index) {
        final line = lines[index];
        Color? bgColor;
        Color textColor = colorScheme.onSurface;
        FontWeight weight = FontWeight.w400;

        if (line.startsWith('+') && !line.startsWith('+++')) {
          bgColor = context.status.success.withAlpha(38);
          textColor = context.status.success;
          weight = FontWeight.w600;
        } else if (line.startsWith('-') && !line.startsWith('---')) {
          bgColor = context.scheme.error.withAlpha(38);
          textColor = context.scheme.error.withAlpha(36);
          weight = FontWeight.w600;
        } else if (line.startsWith('@@')) {
          bgColor = colorScheme.primaryContainer.withAlpha(65);
          textColor = colorScheme.primary;
          weight = FontWeight.w700;
        }

        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          color: bgColor,
          child: SelectableText(
            line,
            style: textTheme.bodySmall?.copyWith(
              fontFamily: 'monospace',
              fontSize: 11.5,
              height: 1.35,
              color: textColor,
              fontWeight: weight,
            ),
          ),
        );
      },
    );
  }

  Widget _buildFullFileContentView(
    BuildContext context,
    ServerFileReadResponse? resp,
    ColorScheme colorScheme,
    TextTheme textTheme,
  ) {
    if (resp == null || !resp.ok) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.error_outline_rounded,
                size: 40,
                color: context.scheme.error,
              ),
              const SizedBox(height: 10),
              Text(
                resp?.error.isNotEmpty == true
                    ? resp!.error
                    : 'Không thể đọc tệp từ Server',
                textAlign: TextAlign.center,
                style: textTheme.bodySmall?.copyWith(color: context.scheme.error),
              ),
              const SizedBox(height: 14),
              FilledButton.tonalIcon(
                onPressed: _fetchFileDetail,
                icon: const Icon(Icons.refresh_rounded, size: 16),
                label: const Text('Thử lại'),
              ),
            ],
          ),
        ),
      );
    }

    final isImg = resp.isImageFile || _isImageFile(widget.filePath);
    if (isImg) {
      return _buildImageViewer(context, resp, colorScheme, textTheme);
    }

    final isMd = resp.isMarkdown || _isMarkdownFile(widget.filePath);
    final isMobile = MediaQuery.sizeOf(context).width < 600;

    if (isMd && resp.content.isNotEmpty) {
      return _buildMarkdownContentView(
        context,
        resp.content,
        colorScheme,
        textTheme,
        isMobile,
      );
    }

    if (resp.isBinary) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.memory_rounded,
              size: 40,
              color: colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 10),
            Text(
              'Đây là tệp nhị phân (${(resp.size / 1024).toStringAsFixed(1)} KB). Hãy tải về máy để mở.',
              style: textTheme.bodySmall,
            ),
            const SizedBox(height: 14),
            if (_downloadedLocalPath != null)
              FilledButton.icon(
                onPressed: () =>
                    widget.scanner.openDownloadedFile(_downloadedLocalPath!),
                style: FilledButton.styleFrom(
                  backgroundColor: context.status.success,
                  foregroundColor: context.scheme.onPrimary,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                icon: const Icon(Icons.open_in_new_rounded, size: 16),
                label: const Text(
                  'Mở tệp đã tải',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              )
            else
              _buildProgressDownloadButton(context),
          ],
        ),
      );
    }

    return _buildLazyTextView(context, resp, colorScheme, textTheme);
  }

  /// Trình xem văn bản theo đoạn: chỉ render các dòng đang nằm trong khung nhìn,
  /// các trang chưa có được tải khi cuộn tới. Không nạp cả file.
  Widget _buildLazyTextView(
    BuildContext context,
    ServerFileReadResponse resp,
    ColorScheme colorScheme,
    TextTheme textTheme,
  ) {
    final total = _totalLines;
    final digits = total.toString().length;
    final gutterWidth = (digits * 9.0 + 20.0).clamp(38.0, 80.0);
    const rowHeight = 18.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          color: colorScheme.surfaceContainerLow,
          child: Row(
            children: [
              Text(
                'Tổng: $total dòng • ${(resp.size / 1024).toStringAsFixed(1)} KB • cuộn để tải thêm',
                style: textTheme.labelSmall?.copyWith(
                  fontFamily: 'monospace',
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: total == 0
              ? Center(
                  child: Text(
                    'Tệp trống',
                    style: textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemExtent: rowHeight,
                  itemCount: total,
                  itemBuilder: (context, idx) {
                    final page = idx ~/ _linePageSize;
                    final inPage = idx % _linePageSize;
                    final lines = _linePages[page];
                    final lineNum = idx + 1;

                    final gutter = Container(
                      width: gutterWidth,
                      padding: const EdgeInsets.only(right: 10),
                      alignment: Alignment.centerRight,
                      child: Text(
                        '$lineNum',
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11.5,
                          color: colorScheme.onSurfaceVariant.withAlpha(120),
                          height: 1.45,
                        ),
                      ),
                    );

                    if (lines == null) {
                      _ensureLinePage(page);
                      return Row(
                        children: [
                          gutter,
                          Text(
                            '…',
                            style: textTheme.bodySmall?.copyWith(
                              fontFamily: 'monospace',
                              color: colorScheme.onSurfaceVariant.withAlpha(120),
                            ),
                          ),
                        ],
                      );
                    }
                    final text = inPage < lines.length ? lines[inPage] : '';
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        gutter,
                        Expanded(
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: SelectableText(
                              text.isEmpty ? ' ' : text,
                              maxLines: 1,
                              style: textTheme.bodySmall?.copyWith(
                                fontFamily: 'monospace',
                                fontSize: 11.5,
                                height: 1.45,
                              ),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
        ),
      ],
    );
  }

  /// Trình xem ảnh hoàn chỉnh với Zoom & Pan, Nền ca-rô trong suốt và Điều khiển
  Widget _buildImageViewer(
    BuildContext context,
    ServerFileReadResponse resp,
    ColorScheme colorScheme,
    TextTheme textTheme,
  ) {
    final imageUrl = widget.scanner.getFileDownloadUrl(
      address: widget.serverAddress,
      remotePath: widget.filePath,
    );
    final ext = widget.filePath.split('.').last.toUpperCase();
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Thanh công cụ ảnh
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          color: colorScheme.surfaceContainerLow,
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: context.scheme.tertiary.withAlpha(35),
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(
                    color: context.scheme.tertiary.withAlpha(100),
                    width: 0.8,
                  ),
                ),
                child: Text(
                  ext,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    color: context.scheme.tertiary,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${(resp.size / 1024).toStringAsFixed(1)} KB • Tỉ lệ: ${(_currentImageScale * 100).toInt()}%',
                style: textTheme.labelSmall?.copyWith(
                  fontFamily: 'monospace',
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const Spacer(),
              // Zoom Controls
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: 'Thu nhỏ (-)',
                icon: const Icon(Icons.remove_circle_outline_rounded, size: 18),
                onPressed: () {
                  setState(() {
                    _currentImageScale =
                        (_currentImageScale / 1.25).clamp(0.2, 8.0);
                    _imageTransformController.value =
                        Matrix4.diagonal3Values(_currentImageScale, _currentImageScale, 1.0);
                  });
                },
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: 'Phóng to (+)',
                icon: const Icon(Icons.add_circle_outline_rounded, size: 18),
                onPressed: () {
                  setState(() {
                    _currentImageScale =
                        (_currentImageScale * 1.25).clamp(0.2, 8.0);
                    _imageTransformController.value =
                        Matrix4.diagonal3Values(_currentImageScale, _currentImageScale, 1.0);
                  });
                },
              ),
              Tooltip(
                message: 'Vừa màn hình (100%)',
                child: TextButton.icon(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                  ),
                  icon: const Icon(Icons.aspect_ratio_rounded, size: 15),
                  label: const Text('100%'),
                  onPressed: () {
                    setState(() {
                      _currentImageScale = 1.0;
                      _imageTransformController.value = Matrix4.identity();
                    });
                  },
                ),
              ),
            ],
          ),
        ),
        // Image Canvas với hoa văn ca-rô
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: _CheckerboardPainter(
                    color1: isDark
                        ? context.scheme.surfaceContainerLowest
                        : context.scheme.surfaceContainerLow,
                    color2: isDark
                        ? context.scheme.surfaceContainerLow
                        : context.scheme.surfaceContainerHighest,
                  ),
                ),
              ),
              Positioned.fill(
                child: InteractiveViewer(
                  transformationController: _imageTransformController,
                  minScale: 0.2,
                  maxScale: 8.0,
                  onInteractionUpdate: (details) {
                    final scale =
                        _imageTransformController.value.getMaxScaleOnAxis();
                    if ((scale - _currentImageScale).abs() > 0.05) {
                      setState(() => _currentImageScale = scale);
                    }
                  },
                  child: Center(
                    child: Image.network(
                      imageUrl,
                      fit: BoxFit.contain,
                      loadingBuilder: (context, child, loadingProgress) {
                        if (loadingProgress == null) return child;
                        final total = loadingProgress.expectedTotalBytes;
                        final loaded = loadingProgress.cumulativeBytesLoaded;
                        final progress =
                            total != null && total > 0 ? loaded / total : null;

                        return Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              CircularProgressIndicator(value: progress),
                              const SizedBox(height: 10),
                              Text(
                                progress != null
                                    ? 'Đang tải ảnh: ${(progress * 100).toInt()}%'
                                    : 'Đang tải ảnh...',
                                style: textTheme.bodySmall,
                              ),
                            ],
                          ),
                        );
                      },
                      errorBuilder: (context, error, stackTrace) {
                        return Center(
                          child: Padding(
                            padding: const EdgeInsets.all(20),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.broken_image_rounded,
                                  size: 48,
                                  color: context.scheme.error,
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  'Không thể hiển thị hình ảnh từ máy chủ',
                                  style: textTheme.bodyMedium?.copyWith(
                                    fontWeight: FontWeight.w700,
                                    color: context.scheme.error,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '$error',
                                  textAlign: TextAlign.center,
                                  style: textTheme.bodySmall?.copyWith(
                                    fontSize: 11,
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                FilledButton.tonalIcon(
                                  onPressed: () => setState(() {}),
                                  icon: const Icon(
                                    Icons.refresh_rounded,
                                    size: 16,
                                  ),
                                  label: const Text('Thử lại'),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Trình xem tài liệu Markdown hoàn chỉnh với 2 chế độ:
  /// - 👁️ Xem tài liệu (Formatted Markdown Document)
  /// - 💻 Mã nguồn (Raw Markdown Source với đánh số dòng)
  Widget _buildMarkdownContentView(
    BuildContext context,
    String content,
    ColorScheme colorScheme,
    TextTheme textTheme,
    bool isMobile,
  ) {
    final lineCount = content.split('\n').length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Thanh chuyển đổi chế độ xem tài liệu
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          color: colorScheme.surfaceContainerLow,
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: context.scheme.tertiary.withAlpha(35),
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(
                    color: context.scheme.tertiary.withAlpha(100),
                    width: 0.8,
                  ),
                ),
                child: Text(
                  'MARKDOWN',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    color: context.scheme.tertiary,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '$lineCount dòng • ${((_readResponse?.size ?? 0) / 1024).toStringAsFixed(1)} KB',
                style: textTheme.labelSmall?.copyWith(
                  fontFamily: 'monospace',
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const Spacer(),
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment<int>(
                    value: 0,
                    icon: Icon(Icons.visibility_outlined, size: 14),
                    label: Text('Tài liệu'),
                  ),
                  ButtonSegment<int>(
                    value: 1,
                    icon: Icon(Icons.code_rounded, size: 14),
                    label: Text('Mã nguồn'),
                  ),
                ],
                selected: {_markdownViewMode},
                onSelectionChanged: (s) =>
                    setState(() => _markdownViewMode = s.first),
                style: const ButtonStyle(visualDensity: VisualDensity.compact),
              ),
            ],
          ),
        ),
        // Nội dung
        Expanded(
          child: _markdownViewMode == 0
              ? SingleChildScrollView(
                  padding: EdgeInsets.symmetric(
                    horizontal: isMobile ? 12 : 20,
                    vertical: 14,
                  ),
                  child: CompleteMarkdownDocView(
                    markdown: content,
                    isMobile: isMobile,
                    onLinkTap: (url, label) {
                      final cleanUrl = url.replaceFirst('file://', '');
                      if (cleanUrl.contains('/') || cleanUrl.endsWith('.md')) {
                        ServerFileBrowserSheet.showFilePreviewAndDiff(
                          context,
                          scanner: widget.scanner,
                          serverAddress: widget.serverAddress,
                          filePath: cleanUrl,
                          onDownloadFile: widget.onDownloadFile,
                        );
                      }
                    },
                  ),
                )
              : _buildCodeWithLineNumbers(
                  context,
                  content,
                  colorScheme,
                  textTheme,
                ),
        ),
      ],
    );
  }

  /// Trình xem mã nguồn / tệp văn bản có ĐÁNH SỐ DÒNG và CUỘN NGANG
  Widget _buildCodeWithLineNumbers(
    BuildContext context,
    String content,
    ColorScheme colorScheme,
    TextTheme textTheme,
  ) {
    final lines = content.split('\n');
    final lineCount = lines.length;
    final digits = lineCount.toString().length;
    final gutterWidth = (digits * 9.0 + 20.0).clamp(38.0, 72.0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Top stats bar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          color: colorScheme.surfaceContainerLow,
          child: Row(
            children: [
              Text(
                'Tổng: $lineCount dòng • ${((_readResponse?.size ?? 0) / 1024).toStringAsFixed(1)} KB',
                style: textTheme.labelSmall?.copyWith(
                  fontFamily: 'monospace',
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: content));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Đã sao chép toàn bộ nội dung tệp!'),
                      duration: Duration(seconds: 2),
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                },
                icon: const Icon(Icons.copy_rounded, size: 14),
                label: const Text('Sao chép'),
              ),
            ],
          ),
        ),
        // Code view with line numbers
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: lines.length,
            itemBuilder: (context, idx) {
              final lineNum = idx + 1;
              final lineText = lines[idx];

              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: gutterWidth,
                    padding: const EdgeInsets.only(right: 10),
                    alignment: Alignment.centerRight,
                    child: Text(
                      '$lineNum',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11.5,
                        color: colorScheme.onSurfaceVariant.withAlpha(120),
                        height: 1.45,
                      ),
                    ),
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: SelectableText(
                        lineText.isEmpty ? ' ' : lineText,
                        style: textTheme.bodySmall?.copyWith(
                          fontFamily: 'monospace',
                          fontSize: 11.5,
                          height: 1.45,
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  /// Nút tải về có hiệu ứng đổ màu từ trái sang phải theo % tiến độ tải về
  Widget _buildProgressDownloadButton(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final int percent = (_downloadProgress * 100).toInt().clamp(0, 100);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: _isDownloading ? null : _downloadAndTrack,
        child: Container(
          height: 32,
          constraints: const BoxConstraints(minWidth: 86),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: _isDownloading
                  ? colorScheme.primary
                  : colorScheme.outlineVariant.withAlpha(140),
              width: 1,
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(9),
            child: Stack(
              children: [
                // Layer 1: Đổ màu từ trái qua phải theo % tiến độ tải về
                if (_isDownloading)
                  Positioned.fill(
                    child: FractionallySizedBox(
                      alignment: Alignment.centerLeft,
                      widthFactor: _downloadProgress > 0
                          ? _downloadProgress.clamp(0.06, 1.0)
                          : 0.06,
                      child: Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.centerLeft,
                            end: Alignment.centerRight,
                            colors: [
                              colorScheme.primary.withAlpha(150),
                              colorScheme.primary,
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),

                // Layer 2: Icon và nhãn hiển thị bên trên lớp đổ màu
                Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_isDownloading) ...[
                          Text(
                            '$percent%',
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              color: _downloadProgress > 0.45
                                  ? colorScheme.onPrimary
                                  : colorScheme.primary,
                            ),
                          ),
                          const SizedBox(width: 4),
                          SizedBox(
                            width: 10,
                            height: 10,
                            child: CircularProgressIndicator(
                              strokeWidth: 1.6,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                _downloadProgress > 0.45
                                    ? colorScheme.onPrimary
                                    : colorScheme.primary,
                              ),
                            ),
                          ),
                        ] else ...[
                          Icon(
                            Icons.download_rounded,
                            size: 15,
                            color: colorScheme.primary,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            'Tải về',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: colorScheme.primary,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Vẽ hoa văn ca-rô (checkerboard) cho vùng hiển thị hình ảnh trong suốt
class _CheckerboardPainter extends CustomPainter {
  const _CheckerboardPainter({required this.color1, required this.color2});
  final Color color1;
  final Color color2;

  @override
  void paint(Canvas canvas, Size size) {
    final paint1 = Paint()..color = color1;
    final paint2 = Paint()..color = color2;
    const double squareSize = 16.0;

    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), paint1);
    for (double y = 0; y < size.height; y += squareSize) {
      for (double x = 0; x < size.width; x += squareSize) {
        if (((x / squareSize).floor() + (y / squareSize).floor()) % 2 == 0) {
          canvas.drawRect(Rect.fromLTWH(x, y, squareSize, squareSize), paint2);
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant _CheckerboardPainter oldDelegate) =>
      oldDelegate.color1 != color1 || oldDelegate.color2 != color2;
}
