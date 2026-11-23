import 'dart:async';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'package:muop_agent/core/di/app_dependencies.dart';
import 'package:muop_agent/core/theme/app_theme.dart';
import 'package:muop_agent/core/theme/chat_theme_painter.dart';
import 'package:muop_agent/core/widgets/complete_markdown_doc_view.dart';
import 'package:muop_agent/core/widgets/desktop_panel.dart';
import 'package:muop_agent/core/widgets/glass_scaffold.dart';
import 'package:muop_agent/features/lsp/domain/lsp_entities.dart';
import 'package:muop_agent/features/lsp/presentation/lsp_settings_screen.dart';
import 'package:muop_agent/features/projects/domain/project_entities.dart';
import 'package:muop_agent/features/projects/presentation/project_git_history_sheet.dart';
import 'package:muop_agent/features/server_files/domain/server_file_entities.dart';
import 'package:muop_agent/features/sessions/domain/session_entities.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:muop_agent/core/state/server_address_provider.dart';

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

/// Màn gắn với server đang kết nối: đổi địa chỉ (provider toàn cục) thì dựng lại và tải lại dữ liệu
class ServerFileBrowserSheet extends ConsumerWidget {
  const ServerFileBrowserSheet({
    super.key,
    required this.initialPath,
    required this.projects,
    required this.sessionFiles,
    this.initialTab = 0,
    this.workspaceRoot = '',
    this.homeDir = '',
  });

  final String initialPath;
  final List<ProjectWorkspace> projects;
  final List<FileTouchRecord> sessionFiles;
  final int initialTab;
  /// Thư mục project gốc và home của server (lấy từ `meta`, không đoán trên client)
  final String workspaceRoot;
  final String homeDir;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final serverAddress = ref.watch(serverAddressProvider);
    return ServerFileBrowserSheetView(
      key: ValueKey(serverAddress),
      serverAddress: serverAddress,
      initialPath: initialPath,
      projects: projects,
      sessionFiles: sessionFiles,
      initialTab: initialTab,
      workspaceRoot: workspaceRoot,
      homeDir: homeDir,
    );
  }
  static Future<void> show(
    BuildContext context, {
    required String initialPath,
    required List<ProjectWorkspace> projects,
    required List<FileTouchRecord> sessionFiles,
    int initialTab = 0,
    String workspaceRoot = '',
    String homeDir = '',
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => FractionallySizedBox(
        heightFactor: 0.90,
        child: ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          child: ChatWallpaperSurface(
            child: ServerFileBrowserSheet(
              initialPath: initialPath,
              projects: projects,
              sessionFiles: sessionFiles,
              initialTab: initialTab,
              workspaceRoot: workspaceRoot,
              homeDir: homeDir,
            ),
          ),
        ),
      ),
    );
  }

  /// Mở hộp thoại xem chi tiết Change (Diff) & Nội dung tệp trên Server + Tải về
  static Future<void> showFilePreviewAndDiff(
    BuildContext context, {
    required String filePath,
    GroupedFileChange? groupedChange,
    required ValueChanged<String> onDownloadFile,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => FractionallySizedBox(
        heightFactor: 0.88,
        child: ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          child: ChatWallpaperSurface(
            child: Consumer(
              builder: (_, ref, _) {
                final serverAddress = ref.watch(serverAddressProvider);
                return FileDiffAndContentPane(
                  key: ValueKey(serverAddress),
                  serverAddress: serverAddress,
                  filePath: filePath,
                  groupedChange: groupedChange,
                  onDownloadFile: onDownloadFile,
                );
              },
            ),
          ),
        ),
      ),
    );
  }

}

class ServerFileBrowserSheetView extends StatefulWidget {
  const ServerFileBrowserSheetView({
    super.key,
    required this.serverAddress,
    required this.initialPath,
    required this.projects,
    required this.sessionFiles,
    this.initialTab = 0,
    this.workspaceRoot = '',
    this.homeDir = '',
  });
  final String serverAddress;
  final String initialPath;
  final List<ProjectWorkspace> projects;
  final List<FileTouchRecord> sessionFiles;
  final int initialTab;
  final String workspaceRoot;
  final String homeDir;

  @override
  State<ServerFileBrowserSheetView> createState() => _ServerFileBrowserSheetState();
}

class _ServerFileBrowserSheetState extends State<ServerFileBrowserSheetView> {
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
  /// Thư mục đang hiển thị và đang được server theo dõi (`explore:`)
  String? _watchedDir;
  StreamSubscription<String>? _changedSub;

  @override
  void initState() {
    super.initState();
    _activeTab = widget.initialTab;
    _currentPath = widget.initialPath.trim().isNotEmpty
        ? widget.initialPath.trim()
        : (widget.workspaceRoot.isNotEmpty ? widget.workspaceRoot : widget.homeDir);
    _pathEditController = TextEditingController(text: _currentPath);
    _changedSub = AppDependencies.explore.changedRooms.listen(_onRoomChanged);
    _loadDirectory(_currentPath);
  }

  @override
  void dispose() {
    _changedSub?.cancel();
    final watched = _watchedDir;
    if (watched != null) AppDependencies.explore.unwatch(watched);
    _watchedDir = null;
    super.dispose();
  }

  /// Chuyển theo dõi sang thư mục đang hiển thị (bỏ thư mục cũ)
  void _setWatch(String dir) {
    if (dir == _watchedDir) return;
    final previous = _watchedDir;
    if (previous != null) AppDependencies.explore.unwatch(previous);
    AppDependencies.explore.watch(dir);
    _watchedDir = dir;
  }

  /// Server báo thư mục đang xem đã đổi: nạp lại danh sách, không hiện trạng thái đang tải
  void _onRoomChanged(String room) {
    final dir = _watchedDir;
    if (dir == null || !mounted) return;
    if (AppDependencies.explore.roomOf(dir) != room) return;
    _loadDirectory(_currentPath, silent: true);
  }

  Future<void> _loadDirectory(String path, {bool silent = false}) async {
    if (!silent) {
      setState(() {
        _isLoading = true;
        _errorMessage = '';
        _isEditingPath = false;
      });
    }

    final res = await AppDependencies.serverFiles.fetchServerDirectory(
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
    if (res.ok) _setWatch(res.currentPath);
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

    final res = await AppDependencies.serverFiles.downloadFileFromServer(
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
              AppDependencies.serverFiles.openDownloadedFile(res.savedPath);
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
      final res = await AppDependencies.serverFiles.downloadFileFromServer(
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
        // 1. Header SFTP & Chuyển Tab (tách pill nổi đồng bộ thanh header khung chat)
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
          child: Row(
            children: [
              Expanded(
                child: GlassHeaderSurface(
                  borderRadius: 22,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: SizedBox(
                    width: double.infinity,
                    height: 44,
                    child: Row(
                      children: [
                        Icon(
                          Icons.dns_rounded,
                          size: 17,
                          color: colorScheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                isMobile
                                    ? 'SFTP & Tệp Thay Đổi'
                                    : 'SFTP File Explorer & Changes',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: textTheme.titleSmall?.copyWith(
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w700,
                                  height: 1.15,
                                ),
                              ),
                              Text(
                                'sftp://${widget.serverAddress}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: textTheme.labelSmall?.copyWith(
                                  fontFamily: 'monospace',
                                  fontSize: 10,
                                  color: colorScheme.onSurfaceVariant,
                                  height: 1.15,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              GlassHeaderSurface(
                borderRadius: 21,
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: SizedBox(
                  height: 42,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SegmentedButton<int>(
                        showSelectedIcon: !isMobile,
                        segments: [
                          ButtonSegment<int>(
                            value: 0,
                            icon: const Icon(
                              Icons.folder_special_rounded,
                              size: 15,
                            ),
                            label: Text(isMobile ? 'SFTP' : 'Duyệt SFTP'),
                          ),
                          ButtonSegment<int>(
                            value: 1,
                            icon: const Icon(
                              Icons.difference_rounded,
                              size: 15,
                            ),
                            label: Text(
                              isMobile
                                  ? '${groupedFiles.length}'
                                  : 'Changes (${groupedFiles.length})',
                            ),
                          ),
                        ],
                        selected: {_activeTab},
                        onSelectionChanged: (s) =>
                            setState(() => _activeTab = s.first),
                        style: const ButtonStyle(
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.account_tree_outlined, size: 18),
                        tooltip: 'Xem Git Tree & Commit History',
                        onPressed: () {
                          ProjectGitHistorySheet.show(
                            context,
                            projectPath: _currentPath,
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              GlassHeaderSurface(
                borderRadius: 21,
                child: SizedBox(
                  width: 42,
                  height: 42,
                  child: IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close_rounded, size: 20),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ),
              ),
            ],
          ),
        ),

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
                    final openRes = await AppDependencies.serverFiles.openDownloadedFile(_lastSavedPath!);
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
              if (widget.homeDir.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ActionChip(
                    visualDensity: VisualDensity.compact,
                    avatar: const Icon(Icons.home_outlined, size: 13.5),
                    label: Text(widget.homeDir, style: const TextStyle(fontSize: 11.5)),
                    onPressed: () => _loadDirectory(widget.homeDir),
                  ),
                ),
              if (widget.workspaceRoot.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ActionChip(
                    visualDensity: VisualDensity.compact,
                    avatar: const Icon(Icons.workspaces_outlined, size: 13.5),
                    label: Text(
                      widget.workspaceRoot.split('/').last,
                      style: const TextStyle(fontSize: 11.5),
                    ),
                    onPressed: () => _loadDirectory(widget.workspaceRoot),
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
    required this.serverAddress,
    required this.filePath,
    this.groupedChange,
    required this.onDownloadFile,
    this.onClose,
  });
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

/// Một token ngữ nghĩa trên dòng: [start, end) và loại (keyword, function...)
class _Tok {
  const _Tok(this.start, this.end, this.kind);

  final int start;
  final int end;
  final String kind;
}

/// Thẻ hiện nội dung hover, đặt gần con trỏ và không vượt khỏi cửa sổ
class _HoverCard extends StatelessWidget {
  const _HoverCard({required this.position, required this.text});

  final Offset position;
  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final size = MediaQuery.sizeOf(context);
    const width = 460.0;
    final left = (position.dx + 12).clamp(8.0, (size.width - width - 8).clamp(8.0, double.infinity));
    final top = (position.dy + 18).clamp(8.0, (size.height - 120).clamp(8.0, double.infinity));
    final plain = text.replaceAll(RegExp(r'```[a-zA-Z]*\n?'), '').trim();
    return Positioned(
      left: left,
      top: top,
      width: width,
      child: IgnorePointer(
        child: Material(
          elevation: 6,
          color: cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(10),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 260),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: SingleChildScrollView(
                child: Text(
                  plain,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11.5,
                    height: 1.4,
                    color: cs.onSurface,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Điểm quay lại khi nhảy sang file định nghĩa
class _NavEntry {
  const _NavEntry(this.path, this.line);

  final String path;
  final int line;
}

final RegExp _identifierPattern = RegExp(r'[A-Za-z_][A-Za-z0-9_]*');

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

  // ---- Gấp code, danh sách hàm, Ctrl+click tới định nghĩa (LSP) ----
  static const double _codeRowHeight = 18.0;
  static const int _spanCacheLimit = 2000;
  static const _codeExts = ['.go', '.dart', '.rs'];
  /// Đường dẫn đang xem khi đã nhảy sang file định nghĩa (null = file gốc của widget)
  String? _currentPath;
  String get _currentFilePath => _currentPath ?? widget.filePath;
  final List<_NavEntry> _navStack = [];
  /// Dòng cần nhảy tới sau khi tải file (khi vừa nhảy sang file khác)
  int? _pendingJump;
  /// Dòng vừa nhảy tới, được tô nền một lúc
  int? _highlightLine;
  Timer? _highlightTimer;
  final ScrollController _lazyScroll = ScrollController();
  /// Ngôn ngữ LSP đang phục vụ tệp (null = không phải tệp code hoặc chưa có LSP)
  String? _codeLanguage;
  /// Lý do chưa có LSP (lấy từ server), để gợi ý người dùng mở Cài đặt LSP
  String? _lspHint;
  final Map<int, CodeFoldRange> _foldAt = {};
  final Set<int> _collapsed = {};
  /// Tăng khi danh sách dòng ẩn thay đổi, để tính lại các dòng hiển thị
  int _foldVersion = 0;
  List<int>? _visibleCache;
  int _visibleCacheVersion = -1;
  int _visibleCacheTotal = -1;
  /// Span của từng dòng (đã gắn recognizer cho từng từ), để không tạo lại mỗi lần vẽ
  final Map<int, TextSpan> _spanCache = {};
  /// Token ngữ nghĩa theo dòng (LSP)
  final Map<int, List<_Tok>> _tokensByLine = {};
  final Map<String, String> _hoverCache = {};
  Brightness? _spanBrightness;
  Timer? _hoverTimer;
  String? _hoverKey;
  OverlayEntry? _hoverEntry;
  final List<TapGestureRecognizer> _recognizers = [];

  bool get _isCodeFile {
    final lower = _currentFilePath.toLowerCase();
    return _codeExts.any(lower.endsWith);
  }

  void _resetCodeState() {
    _removeHover();
    _tokensByLine.clear();
    _hoverCache.clear();
    _foldAt.clear();
    _collapsed.clear();
    _codeLanguage = null;
    _lspHint = null;
    _highlightLine = null;
    _foldVersion++;
    _clearSpanCache();
  }

  void _clearSpanCache() {
    _spanCache.clear();
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  void _applyFolds(List<CodeFoldRange> folds) {
    _foldAt.clear();
    for (final f in folds) {
      final cur = _foldAt[f.startLine];
      if (cur == null || cur.endLine < f.endLine) _foldAt[f.startLine] = f;
    }
    _collapsed.clear();
    _foldVersion++;
  }

  /// Nạp vùng gấp và danh sách hàm từ LSP (chạy nền, không chặn xem file)
  Future<void> _loadCode(int gen) async {
    if (!_isCodeFile) return;
    final res = await AppDependencies.lsp.fetchCodeFold(widget.serverAddress, _currentFilePath);
    if (!mounted || gen != _generation) return;
    setState(() {
      if (res.ok) {
        _codeLanguage = res.language.isEmpty ? 'code' : res.language;
        _lspHint = null;
        _applyFolds(res.folds);
      } else {
        _codeLanguage = null;
        _lspHint = res.error;
        _applyFolds(const []);
      }
    });
    if (!res.ok) return;
    final tokens = await AppDependencies.lsp.fetchCodeTokens(widget.serverAddress, _currentFilePath);
    if (!mounted || gen != _generation || !tokens.ok) return;
    setState(() => _applyTokens(tokens));
  }

  /// Đổ token ngữ nghĩa vào từng dòng (dữ liệu LSP đã sắp theo vị trí)
  void _applyTokens(CodeTokens tokens) {
    _tokensByLine.clear();
    final d = tokens.data;
    for (var i = 0; i + 3 < d.length; i += 4) {
      final line = d[i];
      final start = d[i + 1];
      final kindIdx = d[i + 3];
      if (kindIdx < 0 || kindIdx >= tokens.kinds.length) continue;
      _tokensByLine
          .putIfAbsent(line, () => <_Tok>[])
          .add(_Tok(start, start + d[i + 2], tokens.kinds[kindIdx]));
    }
    _clearSpanCache();
  }

  /// Hover: chờ người dùng dừng chuột một lúc rồi mới hỏi LSP
  void _onTokenEnter(PointerEnterEvent e, int line, int character, String token) {
    _hoverTimer?.cancel();
    _hoverKey = '$_currentFilePath:$line:$character';
    final key = _hoverKey;
    _hoverTimer = Timer(const Duration(milliseconds: 350), () => _showHover(e.position, key!, line, character));
  }

  void _onTokenExit(PointerExitEvent e) {
    _hoverTimer?.cancel();
    _hoverKey = null;
    _removeHover();
  }

  Future<void> _showHover(Offset global, String key, int line, int character) async {
    if (!mounted || _codeLanguage == null) return;
    var text = _hoverCache[key];
    if (text == null) {
      final res = await AppDependencies.lsp.fetchCodeHover(
        widget.serverAddress,
        path: _currentFilePath,
        line: line,
        character: character,
      );
      if (!mounted || !res.ok) return;
      text = res.contents;
      if (_hoverCache.length > 300) _hoverCache.clear();
      _hoverCache[key] = text;
    }
    // Chuột đã rời đi trong lúc chờ thì không hiện nữa
    if (_hoverKey != key || text.trim().isEmpty) return;
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) return;
    _removeHover();
    _hoverEntry = OverlayEntry(
      builder: (_) => _HoverCard(position: global, text: text!),
    );
    overlay.insert(_hoverEntry!);
  }

  void _removeHover() {
    _hoverEntry?.remove();
    _hoverEntry = null;
  }

  /// Alt+click: tìm mọi chỗ tham chiếu tới ký hiệu
  Future<void> _findReferences(int line, int character, String token) async {
    if (_codeLanguage == null) {
      _showLspHint();
      return;
    }
    final res = await AppDependencies.lsp.fetchCodeReferences(
      widget.serverAddress,
      path: _currentFilePath,
      line: line,
      character: character,
    );
    if (!mounted) return;
    if (!res.ok) {
      _showLspHint(res.error);
      return;
    }
    if (res.locations.isEmpty) {
      _snack("Không tìm thấy tham chiếu tới '$token'");
      return;
    }
    var target = res.locations.first;
    if (res.locations.length > 1) {
      final picked = await _pickLocation(res.locations, "Tham chiếu tới '$token' (${res.locations.length})");
      if (picked == null || !mounted) return;
      target = picked;
    }
    await _openLocation(target, fromLine: line);
  }

  /// Màu cho từng loại token (chỉ dùng token của theme)
  TextStyle? _kindStyle(String kind, ColorScheme cs, AppStatusColors st) {
    switch (kind) {
      case 'keyword':
      case 'modifier':
        return TextStyle(color: cs.primary, fontWeight: FontWeight.w600);
      case 'string':
      case 'regexp':
        return TextStyle(color: st.success);
      case 'comment':
        return TextStyle(color: cs.onSurfaceVariant, fontStyle: FontStyle.italic);
      case 'number':
        return TextStyle(color: st.warning);
      case 'type':
      case 'class':
      case 'struct':
      case 'interface':
      case 'enum':
      case 'typeParameter':
      case 'namespace':
        return TextStyle(color: cs.tertiary);
      case 'function':
      case 'method':
      case 'macro':
      case 'decorator':
      case 'annotation':
        return TextStyle(color: cs.secondary);
      default:
        return null;
    }
  }

  /// Vùng bị gấp ẩn các dòng bên trong; trả về danh sách chỉ số dòng đang hiển thị (cache theo phiên bản)
  List<int> _visibleLines(int total) {
    if (_visibleCache != null &&
        _visibleCacheVersion == _foldVersion &&
        _visibleCacheTotal == total) {
      return _visibleCache!;
    }
    final hide = List<bool>.filled(total, false);
    for (final s in _collapsed) {
      final f = _foldAt[s];
      if (f == null || total == 0) continue;
      final end = f.endLine.clamp(0, total - 1);
      for (var i = s + 1; i <= end; i++) {
        hide[i] = true;
      }
    }
    final out = <int>[];
    for (var i = 0; i < total; i++) {
      if (!hide[i]) out.add(i);
    }
    _visibleCache = out;
    _visibleCacheVersion = _foldVersion;
    _visibleCacheTotal = total;
    return out;
  }

  void _toggleFold(int line) {
    setState(() {
      if (!_collapsed.remove(line)) _collapsed.add(line);
      _foldVersion++;
    });
  }

  void _collapseAll() {
    setState(() {
      _collapsed
        ..clear()
        ..addAll(_foldAt.keys);
      _foldVersion++;
    });
  }

  void _expandAll() {
    setState(() {
      _collapsed.clear();
      _foldVersion++;
    });
  }

  /// Nhảy tới một dòng: mở các vùng gấp đang che dòng đó, cuộn tới và tô nền tạm
  void _jumpTo(int line) {
    if (!mounted) return;
    var changed = false;
    _collapsed.removeWhere((s) {
      final f = _foldAt[s];
      final hides = f != null && line > s && line <= f.endLine;
      if (hides) changed = true;
      return hides;
    });
    if (changed) _foldVersion++;
    _ensureLinePage(line ~/ _linePageSize);
    setState(() => _highlightLine = line);
    _highlightTimer?.cancel();
    _highlightTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _highlightLine = null);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_lazyScroll.hasClients) return;
      final idx = _visibleLines(_totalLines).indexOf(line);
      if (idx < 0) return;
      final pos = _lazyScroll.position;
      final target = (idx * _codeRowHeight - pos.viewportDimension / 3)
          .clamp(0.0, pos.maxScrollExtent);
      _lazyScroll.jumpTo(target);
    });
  }

  /// Mở vị trí định nghĩa: cùng file thì nhảy tại chỗ, file khác thì mở file đó và lưu vị trí để quay lại
  Future<void> _openLocation(CodeLocation loc, {required int fromLine}) async {
    if (loc.path == _currentFilePath) {
      _jumpTo(loc.line);
      return;
    }
    _navStack.add(_NavEntry(_currentFilePath, fromLine));
    _currentPath = loc.path == widget.filePath ? null : loc.path;
    _pendingJump = loc.line;
    await _fetchFileDetail();
  }

  Future<void> _goBack() async {
    if (_navStack.isEmpty) return;
    final entry = _navStack.removeLast();
    _currentPath = entry.path == widget.filePath ? null : entry.path;
    _pendingJump = entry.line;
    await _fetchFileDetail();
  }

  void _onTokenTap(int line, int character, String token) {
    if (!mounted) return;
    final kb = HardwareKeyboard.instance;
    final ctrl = kb.isControlPressed || kb.isMetaPressed;
    // Không có Ctrl (điện thoại): chạm một lần để tới định nghĩa
    final mobile = MediaQuery.sizeOf(context).width < 760;
    if (kb.isAltPressed) {
      _findReferences(line, character, token);
      return;
    }
    if (!ctrl && !mobile) return;
    _goToDefinition(line, character, token);
  }

  Future<void> _goToDefinition(int line, int character, String token) async {
    if (_codeLanguage == null) {
      _showLspHint();
      return;
    }
    final res = await AppDependencies.lsp.fetchCodeDefinition(
      widget.serverAddress,
      path: _currentFilePath,
      line: line,
      character: character,
    );
    if (!mounted) return;
    if (!res.ok) {
      _showLspHint(res.error);
      return;
    }
    if (res.locations.isEmpty) {
      _snack("Không tìm thấy định nghĩa của '$token'");
      return;
    }
    var target = res.locations.first;
    if (res.locations.length > 1) {
      final picked = await _pickLocation(res.locations, "Định nghĩa của '$token'");
      if (picked == null || !mounted) return;
      target = picked;
    }
    await _openLocation(target, fromLine: line);
  }

  Future<CodeLocation?> _pickLocation(List<CodeLocation> locs, String title) {
    return showDialog<CodeLocation>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(title),
        children: [
          for (final l in locs)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, l),
              child: Text(
                '${l.path.split('/').last}:${l.line + 1}  ${l.path}',
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }

  void _snack(String text, {bool openSettings = false}) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(
      content: Text(text),
      action: openSettings
          ? SnackBarAction(label: 'Cài đặt LSP', onPressed: _openLspSettings)
          : null,
    ));
  }

  void _showLspHint([String? detail]) {
    final base = (detail == null || detail.isEmpty)
        ? 'Chưa có LSP cho tệp này.'
        : detail;
    _snack(base, openSettings: true);
  }

  void _openLspSettings() {
    openPanelPage(
      context,
      LspSettingsScreen(),
    );
  }

  Future<void> _showSymbols() async {
    final res = await AppDependencies.lsp.fetchCodeSymbols(widget.serverAddress, _currentFilePath);
    if (!mounted) return;
    if (!res.ok) {
      _showLspHint(res.error);
      return;
    }
    if (res.symbols.isEmpty) {
      _snack('Không có hàm hay kiểu nào trong tệp');
      return;
    }
    final picked = await showModalBottomSheet<CodeSymbol>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: res.symbols.length,
          itemBuilder: (ctx, i) {
            final sym = res.symbols[i];
            return ListTile(
              dense: true,
              contentPadding: EdgeInsets.only(left: 16.0 + sym.depth * 14, right: 16),
              title: Text(sym.name, style: const TextStyle(fontFamily: 'monospace')),
              subtitle: Text('${sym.kindLabel} · dòng ${sym.line + 1}'),
              onTap: () => Navigator.pop(ctx, sym),
            );
          },
        ),
      ),
    );
    if (picked != null) _jumpTo(picked.line);
  }

  /// Nút điều khiển gấp code và điều hướng, hiển thị trên thanh tiêu đề
  List<Widget> _buildCodeToolButtons(BuildContext context) {
    final hasCode = _codeLanguage != null;
    return [
      if (_navStack.isNotEmpty)
        IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: 'Quay lại vị trí trước',
          icon: const Icon(Icons.arrow_back_rounded, size: 16),
          onPressed: _goBack,
        ),
      if (hasCode)
        IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: 'Danh sách hàm',
          icon: const Icon(Icons.list_alt_rounded, size: 16),
          onPressed: _showSymbols,
        ),
      if (hasCode && _foldAt.isNotEmpty)
        IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: _collapsed.isEmpty ? 'Gấp tất cả' : 'Mở tất cả',
          icon: Icon(
            _collapsed.isEmpty ? Icons.unfold_less_rounded : Icons.unfold_more_rounded,
            size: 16,
          ),
          onPressed: _collapsed.isEmpty ? _collapseAll : _expandAll,
        ),
      if (!hasCode && _isCodeFile)
        IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: _lspHint == null || _lspHint!.isEmpty
              ? 'Cài đặt LSP'
              : 'Chưa có LSP: $_lspHint',
          icon: Icon(
            Icons.settings_suggest_rounded,
            size: 16,
            color: context.status.warning,
          ),
          onPressed: _openLspSettings,
        ),
    ];
  }

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
      _currentPath = null;
      _navStack.clear();
      _fetchFileDetail();
    }
  }

  @override
  void dispose() {
    _highlightTimer?.cancel();
    _hoverTimer?.cancel();
    _removeHover();
    _clearSpanCache();
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
    _resetCodeState();

    if (_isImageFile(_currentFilePath)) {
      final res = await AppDependencies.serverFiles.readServerFile(
        address: widget.serverAddress,
        path: _currentFilePath,
      );
      if (!mounted || gen != _generation) return;
      setState(() {
        _isLoading = false;
        _readResponse = res;
        _selectedTab = 1;
      });
      return;
    }

    final first = await AppDependencies.serverFiles.fetchServerFileLines(
      address: widget.serverAddress,
      path: _currentFilePath,
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
        _isMarkdownFile(_currentFilePath) &&
        first.size <= _markdownFullLoadLimit) {
      final full = await AppDependencies.serverFiles.readServerFile(
        address: widget.serverAddress,
        path: _currentFilePath,
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
    if (first.ok && !first.isBinary) {
      unawaited(_loadCode(gen));
    }
    final jump = _pendingJump;
    if (jump != null) {
      _pendingJump = null;
      WidgetsBinding.instance.addPostFrameCallback((_) => _jumpTo(jump));
    }
  }

  /// Tải một trang dòng ở nền; khi xong thì vẽ lại phần đã có dữ liệu
  void _ensureLinePage(int page) {
    if (_linePages.containsKey(page) || _linePagesLoading.contains(page)) return;
    _linePagesLoading.add(page);
    final gen = _generation;
    AppDependencies.serverFiles.fetchServerFileLines(
      address: widget.serverAddress,
      path: _currentFilePath,
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
    final res = await AppDependencies.serverFiles.downloadFileFromServer(
      address: widget.serverAddress,
      remotePath: _currentFilePath,
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
            onPressed: () => AppDependencies.serverFiles.openDownloadedFile(res.savedPath),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final filename = _currentFilePath.split('/').last;
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
                      _currentFilePath,
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
              ..._buildCodeToolButtons(context),
              // Khi tải về xong: Thay thế hoàn toàn bằng nút Mở tệp
              if (_downloadedLocalPath != null) ...[
                FilledButton.icon(
                  onPressed: () =>
                      AppDependencies.serverFiles.openDownloadedFile(_downloadedLocalPath!),
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
                  (_readResponse?.isImageFile == true || _isImageFile(_currentFilePath))
                      ? Icons.image_outlined
                      : ((_readResponse?.isMarkdown == true || _isMarkdownFile(_currentFilePath))
                          ? Icons.description_outlined
                          : Icons.article_outlined),
                  size: 15,
                ),
                label: Text(
                  (_readResponse?.isImageFile == true || _isImageFile(_currentFilePath))
                      ? 'Hình ảnh (Image)'
                      : ((_readResponse?.isMarkdown == true || _isMarkdownFile(_currentFilePath))
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

    final isImg = resp.isImageFile || _isImageFile(_currentFilePath);
    if (isImg) {
      return _buildImageViewer(context, resp, colorScheme, textTheme);
    }

    final isMd = resp.isMarkdown || _isMarkdownFile(_currentFilePath);
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
                    AppDependencies.serverFiles.openDownloadedFile(_downloadedLocalPath!),
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

  /// Danh sách dòng của tệp code: có chevron gấp ở lề, token có thể Ctrl+click (LSP)
  Widget _buildCodeListView(
    BuildContext context,
    int total,
    double rowHeight,
    double gutterWidth,
    ColorScheme colorScheme,
    TextTheme textTheme,
  ) {
    // Màu token phụ thuộc theme: đổi sáng/tối thì bỏ cache span (không dispose recognizer đang hiển thị)
    if (_spanBrightness != colorScheme.brightness) {
      _spanBrightness = colorScheme.brightness;
      _spanCache.clear();
    }
    final visible = _visibleLines(total);
    final mono = textTheme.bodySmall?.copyWith(
      fontFamily: 'monospace',
      fontSize: 11.5,
      height: 1.45,
      color: colorScheme.onSurface,
    );
    final dim = colorScheme.onSurfaceVariant;

    return ListView.builder(
      controller: _lazyScroll,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemExtent: rowHeight,
      itemCount: visible.length,
      itemBuilder: (context, idx) {
        final lineIdx = visible[idx];
        final page = lineIdx ~/ _linePageSize;
        final inPage = lineIdx % _linePageSize;
        final fold = _foldAt[lineIdx];
        final collapsed = fold != null && _collapsed.contains(lineIdx);

        final gutter = SizedBox(
          width: gutterWidth,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (fold != null)
                InkWell(
                  onTap: () => _toggleFold(lineIdx),
                  child: Icon(
                    collapsed ? Icons.chevron_right_rounded : Icons.expand_more_rounded,
                    size: 14,
                    color: dim,
                  ),
                )
              else
                const SizedBox(width: 14),
              const SizedBox(width: 2),
              Text(
                '${lineIdx + 1}',
                style: mono?.copyWith(color: dim.withAlpha(120)),
              ),
              const SizedBox(width: 6),
            ],
          ),
        );

        final lines = _linePages[page];
        if (lines == null) {
          _ensureLinePage(page);
          return Row(
            children: [
              gutter,
              Text('…', style: mono?.copyWith(color: dim.withAlpha(120))),
            ],
          );
        }
        final text = inPage < lines.length ? lines[inPage] : '';
        final suffix = collapsed
            ? '  ⋯ ${fold.endLine - fold.startLine} dòng'
            : '';

        return Container(
          color: _highlightLine == lineIdx
              ? colorScheme.primary.withAlpha(44)
              : null,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              gutter,
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SelectableText.rich(
                    TextSpan(
                      style: mono,
                      children: [
                        _lineSpan(lineIdx, text, colorScheme, context.status),
                        if (suffix.isNotEmpty)
                          TextSpan(text: suffix, style: mono?.copyWith(color: dim)),
                      ],
                    ),
                    maxLines: 1,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Span của một dòng: màu theo token LSP; các từ (định danh) có thể chạm để tới định nghĩa / hover / tham chiếu
  TextSpan _lineSpan(int lineIdx, String text, ColorScheme cs, AppStatusColors st) {
    if (_codeLanguage == null) {
      return TextSpan(text: text.isEmpty ? ' ' : text);
    }
    final cached = _spanCache[lineIdx];
    if (cached != null) return cached;

    final toks = _tokensByLine[lineIdx] ?? const <_Tok>[];
    final children = <TextSpan>[];
    var pos = 0;
    for (final t in toks) {
      final start = t.start.clamp(0, text.length);
      final end = t.end.clamp(0, text.length);
      if (start < pos || end <= start) continue;
      if (start > pos) children.addAll(_identSpans(lineIdx, text, pos, start, null));
      final style = _kindStyle(t.kind, cs, st);
      final tappable = t.kind != 'comment' && t.kind != 'string';
      if (tappable) {
        children.addAll(_identSpans(lineIdx, text, start, end, style));
      } else {
        children.add(TextSpan(text: text.substring(start, end), style: style));
      }
      pos = end;
    }
    if (pos < text.length) children.addAll(_identSpans(lineIdx, text, pos, text.length, null));

    final span = TextSpan(children: children.isEmpty ? [const TextSpan(text: ' ')] : children);
    if (_spanCache.length >= _spanCacheLimit) {
      // Bỏ cache (không dispose recognizer đang hiển thị); recognizer được giải phóng khi đổi tệp
      _spanCache.clear();
    }
    _spanCache[lineIdx] = span;
    return span;
  }

  /// Tách đoạn [from, to) của dòng thành span thường và span định danh (có recognizer chạm/hover)
  List<TextSpan> _identSpans(int lineIdx, String text, int from, int to, TextStyle? style) {
    final out = <TextSpan>[];
    final seg = text.substring(from, to);
    var last = 0;
    for (final m in _identifierPattern.allMatches(seg)) {
      if (m.start > last) {
        out.add(TextSpan(text: seg.substring(last, m.start), style: style));
      }
      final token = m.group(0)!;
      final character = from + m.start;
      final rec = TapGestureRecognizer()
        ..onTap = () => _onTokenTap(lineIdx, character, token);
      _recognizers.add(rec);
      out.add(TextSpan(
        text: token,
        style: style,
        recognizer: rec,
        onEnter: (e) => _onTokenEnter(e, lineIdx, character, token),
        onExit: _onTokenExit,
      ));
      last = m.end;
    }
    if (last < seg.length) {
      out.add(TextSpan(text: seg.substring(last), style: style));
    }
    return out;
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
              : _buildCodeListView(context, total, rowHeight, gutterWidth, colorScheme, textTheme),
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
    final imageUrl = AppDependencies.serverFiles.getFileDownloadUrl(
      address: widget.serverAddress,
      remotePath: _currentFilePath,
    );
    final ext = _currentFilePath.split('.').last.toUpperCase();
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
