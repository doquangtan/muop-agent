import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../models/agent_models.dart';
import '../../services/brain_scanner_service.dart';
import '../theme/app_theme.dart';

/// Modal / Bottom Sheet hiển thị trực quan Git Tree, Lịch sử Commit và Unified Diff của Dự án
class ProjectGitHistorySheet extends StatefulWidget {
  const ProjectGitHistorySheet({
    super.key,
    required this.scanner,
    required this.serverAddress,
    required this.projectPath,
    this.projectName,
    this.initialBranch,
  });

  final BrainScannerService scanner;
  final String serverAddress;
  final String projectPath;
  final String? projectName;
  final String? initialBranch;

  static Future<void> show(
    BuildContext context, {
    required BrainScannerService scanner,
    required String serverAddress,
    required String projectPath,
    String? projectName,
    String? initialBranch,
  }) {
    final isDesktop = MediaQuery.of(context).size.width >= 800;

    if (isDesktop) {
      return showDialog<void>(
        context: context,
        builder: (ctx) => Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: SizedBox(
              width: 1200,
              height: 850,
              child: ProjectGitHistorySheet(
                scanner: scanner,
                serverAddress: serverAddress,
                projectPath: projectPath,
                projectName: projectName,
                initialBranch: initialBranch,
              ),
            ),
          ),
        ),
      );
    }

    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.92,
        minChildSize: 0.5,
        maxChildSize: 0.98,
        builder: (ctx, scrollController) => ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          child: ProjectGitHistorySheet(
            scanner: scanner,
            serverAddress: serverAddress,
            projectPath: projectPath,
            projectName: projectName,
            initialBranch: initialBranch,
          ),
        ),
      ),
    );
  }

  @override
  State<ProjectGitHistorySheet> createState() => _ProjectGitHistorySheetState();
}

class _ProjectGitHistorySheetState extends State<ProjectGitHistorySheet> {
  bool _isLoading = true;
  String? _errorMessage;
  GitHistoryResponse? _history;
  String _selectedBranch = '';
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();

  GitCommitSummary? _selectedCommit;
  GitCommitDetailResponse? _selectedCommitDetail;
  bool _isLoadingDetail = false;
  String? _detailErrorMessage;
  bool _isPushing = false;

  @override
  void initState() {
    super.initState();
    _selectedBranch = widget.initialBranch ?? '';
    _loadHistory();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final res = await widget.scanner.fetchGitHistory(
      address: widget.serverAddress,
      projectPath: widget.projectPath,
      branch: _selectedBranch.isNotEmpty ? _selectedBranch : null,
      limit: 150,
    );

    if (!mounted) return;

    if (res.ok) {
      setState(() {
        _isLoading = false;
        _history = res;
        if (_selectedBranch.isEmpty) {
          _selectedBranch = res.currentBranch.isNotEmpty ? res.currentBranch : 'HEAD';
        }
        // Tự động chọn commit đầu tiên nếu chưa chọn
        if (_selectedCommit == null && res.commits.isNotEmpty) {
          _selectCommit(res.commits.first);
        }
      });
    } else {
      setState(() {
        _isLoading = false;
        _errorMessage = res.error ?? 'Không thể tải lịch sử Git';
      });
    }
  }

  Future<void> _selectCommit(GitCommitSummary commit) async {
    setState(() {
      _selectedCommit = commit;
      _isLoadingDetail = true;
      _selectedCommitDetail = null;
      _detailErrorMessage = null;
    });

    final res = await widget.scanner.fetchGitCommitDetail(
      address: widget.serverAddress,
      projectPath: widget.projectPath,
      hash: commit.hash,
    );

    if (!mounted) return;

    setState(() {
      _isLoadingDetail = false;
      if (res.ok) {
        _selectedCommitDetail = res;
      } else {
        _detailErrorMessage = res.error ?? 'Không thể tải chi tiết commit';
      }
    });
  }

  Future<void> _triggerPush() async {
    if (_isPushing) return;
    setState(() => _isPushing = true);

    final res = await widget.scanner.gitPush(
      address: widget.serverAddress,
      projectPath: widget.projectPath,
      branch: _selectedBranch != 'HEAD' ? _selectedBranch : '',
    );

    if (!mounted) return;
    setState(() => _isPushing = false);

    if (res.ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(res.message),
          backgroundColor: context.status.success,
          behavior: SnackBarBehavior.floating,
        ),
      );
      _loadHistory();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(res.message),
          backgroundColor: context.scheme.error,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  List<GitCommitSummary> _getFilteredCommits() {
    if (_history == null) return const [];
    if (_searchQuery.trim().isEmpty) return _history!.commits;

    final query = _searchQuery.trim().toLowerCase();
    return _history!.commits.where((c) {
      return c.subject.toLowerCase().contains(query) ||
          c.shortHash.toLowerCase().contains(query) ||
          c.authorName.toLowerCase().contains(query) ||
          c.authorEmail.toLowerCase().contains(query) ||
          c.body.toLowerCase().contains(query) ||
          c.refs.any((r) => r.toLowerCase().contains(query));
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final isDesktop = MediaQuery.of(context).size.width >= 900;
    final projectName = widget.projectName ??
        (_history?.projectName.isNotEmpty == true
            ? _history!.projectName
            : widget.projectPath.split('/').last);

    return Scaffold(
      backgroundColor: colorScheme.surface,
      appBar: AppBar(
        backgroundColor: colorScheme.surfaceContainerHigh,
        elevation: 0,
        titleSpacing: 0,
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: () => Navigator.of(context).pop(),
          tooltip: 'Đóng',
        ),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: context.scheme.tertiary.withAlpha(25),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                Icons.account_tree_rounded,
                size: 18,
                color: context.scheme.tertiary,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        'Git Tree & Commit History',
                        style: textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                        decoration: BoxDecoration(
                          color: colorScheme.primaryContainer,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          projectName,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: colorScheme.onPrimaryContainer,
                          ),
                        ),
                      ),
                    ],
                  ),
                  Text(
                    widget.projectPath,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 10.5,
                      color: colorScheme.onSurfaceVariant.withAlpha(180),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          // Nút Push to Remote nếu có
          IconButton(
            icon: _isPushing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.cloud_upload_outlined, size: 20),
            tooltip: 'Push lên Remote Git',
            onPressed: _isPushing ? null : _triggerPush,
          ),
          // Nút Refresh
          IconButton(
            icon: const Icon(Icons.refresh_rounded, size: 20),
            tooltip: 'Tải lại Git Tree',
            onPressed: _isLoading ? null : _loadHistory,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: _buildBody(context, isDesktop),
    );
  }

  Widget _buildBody(BuildContext context, bool isDesktop) {
    final colorScheme = Theme.of(context).colorScheme;

    if (_isLoading) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 14),
            Text('Đang nạp Git Tree & Commit History...'),
          ],
        ),
      );
    }

    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline_rounded, size: 48, color: context.scheme.error),
              const SizedBox(height: 12),
              Text(
                'Lỗi nạp kho lưu trữ Git',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
              const SizedBox(height: 8),
              Text(
                _errorMessage!,
                textAlign: TextAlign.center,
                style: TextStyle(color: colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: _loadHistory,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Thử lại'),
              ),
            ],
          ),
        ),
      );
    }

    final commits = _getFilteredCommits();

    if (isDesktop) {
      // Giao diện Desktop chia 2 cột: Cột trái (Git Tree List), Cột phải (Commit Detail & Diff)
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Cột 1: Danh sách Git Tree & Search/Branch Filter
          SizedBox(
            width: 480,
            child: Column(
              children: [
                _buildToolbar(context),
                Expanded(
                  child: commits.isEmpty
                      ? _buildEmptySearch(context)
                      : _buildCommitTreeList(context, commits, isDesktop: true),
                ),
              ],
            ),
          ),
          VerticalDivider(width: 1, color: colorScheme.outlineVariant.withAlpha(80)),
          // Cột 2: Chi tiết Commit đã chọn và Diff Inspector
          Expanded(
            child: _buildCommitDetailPanel(context, isDesktop: true),
          ),
        ],
      );
    }

    // Giao diện Mobile: 1 cột cuộn kèm mở sheet chi tiết
    return Column(
      children: [
        _buildToolbar(context),
        Expanded(
          child: commits.isEmpty
              ? _buildEmptySearch(context)
              : _buildCommitTreeList(context, commits, isDesktop: false),
        ),
      ],
    );
  }

  Widget _buildToolbar(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final branches = _history?.branches ?? const [];

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        border: Border(
          bottom: BorderSide(color: colorScheme.outlineVariant.withAlpha(60)),
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              // Dropdown Branch
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                  decoration: BoxDecoration(
                    color: colorScheme.surface,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: colorScheme.outlineVariant),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      isExpanded: true,
                      value: branches.contains(_selectedBranch) ? _selectedBranch : null,
                      hint: Row(
                        children: [
                          Icon(Icons.merge_type_rounded, size: 16, color: context.status.success),
                          const SizedBox(width: 6),
                          Text(
                            _selectedBranch.isNotEmpty ? _selectedBranch : 'Tất cả Branches',
                            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                      items: [
                        const DropdownMenuItem(
                          value: 'HEAD',
                          child: Text('HEAD (Mặc định)', style: TextStyle(fontSize: 12.5)),
                        ),
                        for (final b in branches)
                          DropdownMenuItem(
                            value: b,
                            child: Text(
                              b,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12.5),
                            ),
                          ),
                      ],
                      onChanged: (val) {
                        if (val != null && val != _selectedBranch) {
                          setState(() => _selectedBranch = val);
                          _loadHistory();
                        }
                      },
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // Badge đếm số lượng commits
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '${_history?.totalCommits ?? 0} commits',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Ô tìm kiếm Commit
          SizedBox(
            height: 36,
            child: TextField(
              controller: _searchController,
              onChanged: (v) => setState(() => _searchQuery = v),
              style: const TextStyle(fontSize: 12.5),
              decoration: InputDecoration(
                hintText: 'Tìm theo commit hash, thông điệp, tác giả...',
                prefixIcon: const Icon(Icons.search_rounded, size: 16),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear_rounded, size: 14),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _searchQuery = '');
                        },
                      )
                    : null,
                contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 10),
                filled: true,
                fillColor: colorScheme.surface,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: colorScheme.outlineVariant),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: colorScheme.outlineVariant.withAlpha(100)),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptySearch(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          'Không tìm thấy commit nào khớp với "$_searchQuery"',
          style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      ),
    );
  }

  Widget _buildCommitTreeList(
    BuildContext context,
    List<GitCommitSummary> commits, {
    required bool isDesktop,
  }) {
    return ListView.builder(
      itemCount: commits.length,
      padding: const EdgeInsets.symmetric(vertical: 6),
      itemBuilder: (ctx, i) {
        final commit = commits[i];
        final isSelected = _selectedCommit?.hash == commit.hash;
        final isFirst = i == 0;
        final isLast = i == commits.length - 1;

        return _buildCommitTreeItem(
          context,
          commit,
          isFirst: isFirst,
          isLast: isLast,
          isSelected: isSelected,
          isDesktop: isDesktop,
        );
      },
    );
  }

  Widget _buildCommitTreeItem(
    BuildContext context,
    GitCommitSummary commit, {
    required bool isFirst,
    required bool isLast,
    required bool isSelected,
    required bool isDesktop,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final isMerge = commit.parentHashes.length > 1;

    // Màu node dựa trên trạng thái (HEAD: xanh teal, merge: tím, commit thường: xanh dương/primary)
    final nodeColor = commit.isHead
        ? context.status.success
        : isMerge
            ? context.scheme.tertiary
            : colorScheme.primary;

    return InkWell(
      onTap: () {
        _selectCommit(commit);
        if (!isDesktop) {
          _showMobileCommitDetailSheet(context, commit);
        }
      },
      child: Container(
        color: isSelected ? colorScheme.primaryContainer.withAlpha(50) : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Cột đồ họa Git Tree Node
            SizedBox(
              width: 24,
              child: Column(
                children: [
                  Container(
                    width: 2,
                    height: 8,
                    color: isFirst ? Colors.transparent : colorScheme.outlineVariant,
                  ),
                  Container(
                    width: isMerge ? 14 : 11,
                    height: isMerge ? 14 : 11,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: nodeColor,
                      border: Border.all(
                        color: commit.isHead ? context.scheme.onPrimary : colorScheme.surface,
                        width: 2,
                      ),
                      boxShadow: commit.isHead
                          ? [
                              BoxShadow(
                                color: context.status.success.withAlpha(140),
                                blurRadius: 6,
                                spreadRadius: 1,
                              )
                            ]
                          : null,
                    ),
                    child: isMerge
                        ? Center(
                            child: Icon(
                              Icons.alt_route_rounded,
                              size: 8,
                              color: context.scheme.onPrimary,
                            ),
                          )
                        : null,
                  ),
                  Container(
                    width: 2,
                    height: 52,
                    color: isLast ? Colors.transparent : colorScheme.outlineVariant,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            // Nội dung Commit
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Dòng 1: Subject + Badges (HEAD, branch, tag)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          commit.subject.isNotEmpty ? commit.subject : 'No commit message',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.labelLarge?.copyWith(
                            fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
                            color: isSelected ? colorScheme.primary : colorScheme.onSurface,
                            fontSize: 12.5,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      // Short Hash chip có nút copy
                      InkWell(
                        borderRadius: BorderRadius.circular(4),
                        onTap: () {
                          Clipboard.setData(ClipboardData(text: commit.hash));
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('Đã sao chép hash: ${commit.shortHash}'),
                              duration: const Duration(seconds: 1),
                              behavior: SnackBarBehavior.floating,
                            ),
                          );
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                          decoration: BoxDecoration(
                            color: colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: colorScheme.outlineVariant.withAlpha(80)),
                          ),
                          child: Text(
                            commit.shortHash,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  // Dòng 2: Refs (tags, branches) nếu có
                  if (commit.refs.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: commit.refs.map((r) {
                        final isHeadRef = r.contains('HEAD');
                        final isTag = r.contains('tag:');
                        return Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: isHeadRef
                                ? context.status.success.withAlpha(35)
                                : isTag
                                    ? context.status.warning.withAlpha(35)
                                    : context.scheme.secondary.withAlpha(35),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                              color: isHeadRef
                                  ? context.status.success
                                  : isTag
                                      ? context.status.warning
                                      : context.scheme.secondary,
                              width: 0.8,
                            ),
                          ),
                          child: Text(
                            r,
                            style: TextStyle(
                              fontSize: 9.5,
                              fontWeight: FontWeight.w700,
                              color: isHeadRef
                                  ? context.status.success
                                  : isTag
                                      ? context.status.warning
                                      : context.scheme.secondary,
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ],
                  const SizedBox(height: 5),
                  // Dòng 3: Author avatar + Tên tác giả + Thời gian tương đối
                  Row(
                    children: [
                      CircleAvatar(
                        radius: 8,
                        backgroundColor: colorScheme.primary.withAlpha(35),
                        child: Text(
                          commit.authorName.isNotEmpty ? commit.authorName[0].toUpperCase() : 'A',
                          style: TextStyle(
                            fontSize: 8.5,
                            fontWeight: FontWeight.w800,
                            color: colorScheme.primary,
                          ),
                        ),
                      ),
                      const SizedBox(width: 5),
                      Text(
                        commit.authorName,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '•',
                        style: TextStyle(color: colorScheme.outlineVariant, fontSize: 10),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        commit.relativeTime,
                        style: TextStyle(
                          fontSize: 11,
                          color: colorScheme.onSurfaceVariant.withAlpha(160),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCommitDetailPanel(BuildContext context, {required bool isDesktop}) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    if (_selectedCommit == null) {
      return Center(
        child: Text(
          'Chọn một commit từ danh sách bên trái để xem chi tiết',
          style: TextStyle(color: colorScheme.onSurfaceVariant),
        ),
      );
    }

    if (_isLoadingDetail) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 12),
            Text('Đang nạp chi tiết commit và git diff...'),
          ],
        ),
      );
    }

    if (_detailErrorMessage != null) {
      return Center(
        child: Text(
          _detailErrorMessage!,
          style: TextStyle(color: context.scheme.error),
        ),
      );
    }

    final detail = _selectedCommitDetail;
    if (detail == null) {
      return const SizedBox.shrink();
    }

    return DefaultTabController(
      length: 2,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header chi tiết commit
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerLow,
              border: Border(
                bottom: BorderSide(color: colorScheme.outlineVariant.withAlpha(60)),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        detail.subject,
                        style: textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    // Nút Copy Full Hash
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: detail.hash));
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('Đã sao chép hash đầy đủ: ${detail.hash}'),
                            duration: const Duration(seconds: 2),
                            behavior: SnackBarBehavior.floating,
                          ),
                        );
                      },
                      icon: const Icon(Icons.copy_rounded, size: 13),
                      label: Text(detail.shortHash, style: const TextStyle(fontFamily: 'monospace')),
                    ),
                  ],
                ),
                if (detail.body.trim().isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: colorScheme.surface,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: colorScheme.outlineVariant.withAlpha(60)),
                    ),
                    child: SelectableText(
                      detail.body.trim(),
                      style: textTheme.bodySmall?.copyWith(height: 1.4),
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                Row(
                  children: [
                    Icon(Icons.person_outline_rounded, size: 14, color: colorScheme.primary),
                    const SizedBox(width: 4),
                    Text(
                      '${detail.authorName} <${detail.authorEmail}>',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const Spacer(),
                    Icon(Icons.access_time_rounded, size: 14, color: colorScheme.onSurfaceVariant),
                    const SizedBox(width: 4),
                    Text(
                      detail.committedAt.isNotEmpty
                          ? detail.committedAt.split('+').first.replaceAll('T', ' ')
                          : detail.relativeTime,
                      style: TextStyle(fontSize: 11.5, color: colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ],
            ),
          ),
          // Tab bar: Files changed vs Unified Diff
          TabBar(
            labelColor: colorScheme.primary,
            unselectedLabelColor: colorScheme.onSurfaceVariant,
            indicatorColor: colorScheme.primary,
            tabs: [
              Tab(
                text: 'Tệp thay đổi (${detail.files.length})',
                icon: const Icon(Icons.folder_open_outlined, size: 16),
              ),
              Tab(
                text: 'Unified Git Diff',
                icon: const Icon(Icons.difference_outlined, size: 16),
              ),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                _buildFilesListTab(context, detail),
                _buildDiffViewerTab(context, detail),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilesListTab(BuildContext context, GitCommitDetailResponse detail) {
    final colorScheme = Theme.of(context).colorScheme;

    if (detail.files.isEmpty) {
      return Center(
        child: Text(
          'Không có tệp tin nào thay đổi trong commit này',
          style: TextStyle(color: colorScheme.onSurfaceVariant),
        ),
      );
    }

    return ListView.builder(
      itemCount: detail.files.length,
      padding: const EdgeInsets.all(10),
      itemBuilder: (ctx, i) {
        final f = detail.files[i];
        Color statusColor;
        String statusLabel;
        switch (f.status) {
          case 'A':
            statusColor = context.status.success;
            statusLabel = 'A';
            break;
          case 'D':
            statusColor = context.scheme.error;
            statusLabel = 'D';
            break;
          case 'R':
            statusColor = context.scheme.tertiary;
            statusLabel = 'R';
            break;
          default:
            statusColor = context.status.warning;
            statusLabel = 'M';
        }

        return Container(
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: colorScheme.outlineVariant.withAlpha(60)),
          ),
          child: Row(
            children: [
              Container(
                width: 20,
                height: 20,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: statusColor.withAlpha(35),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: statusColor, width: 0.8),
                ),
                child: Text(
                  statusLabel,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    color: statusColor,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  f.path,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (f.additions > 0 || f.deletions > 0) ...[
                if (f.additions > 0)
                  Text(
                    '+${f.additions}',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: context.status.success,
                    ),
                  ),
                const SizedBox(width: 6),
                if (f.deletions > 0)
                  Text(
                    '-${f.deletions}',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: context.scheme.error,
                    ),
                  ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildDiffViewerTab(BuildContext context, GitCommitDetailResponse detail) {
    final colorScheme = Theme.of(context).colorScheme;

    if (detail.diff.trim().isEmpty) {
      return Center(
        child: Text(
          'Không có nội dung diff cho commit này',
          style: TextStyle(color: colorScheme.onSurfaceVariant),
        ),
      );
    }

    final diffLines = detail.diff.split('\n');

    return Column(
      children: [
        // Action bar: Copy toàn bộ diff
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          color: colorScheme.surfaceContainerLow,
          child: Row(
            children: [
              Text(
                '${diffLines.length} dòng diff',
                style: TextStyle(fontSize: 11, color: colorScheme.onSurfaceVariant),
              ),
              const Spacer(),
              TextButton.icon(
                style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: detail.diff));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Đã sao chép toàn bộ Git diff vào bộ nhớ tạm'),
                      duration: Duration(seconds: 1),
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                },
                icon: const Icon(Icons.copy_rounded, size: 14),
                label: const Text('Sao chép Diff', style: TextStyle(fontSize: 11.5)),
              ),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: 1000,
              child: ListView.builder(
                itemCount: diffLines.length,
                padding: const EdgeInsets.symmetric(vertical: 4),
                itemBuilder: (ctx, idx) {
                  final line = diffLines[idx];
                  Color? bgColor;
                  Color textColor = colorScheme.onSurface;

                  if (line.startsWith('+') && !line.startsWith('+++')) {
                    bgColor = context.status.success.withAlpha(35);
                    textColor = context.status.success;
                  } else if (line.startsWith('-') && !line.startsWith('---')) {
                    bgColor = context.scheme.error.withAlpha(35);
                    textColor = context.scheme.error;
                  } else if (line.startsWith('@@')) {
                    bgColor = context.scheme.secondary.withAlpha(30);
                    textColor = context.scheme.secondary;
                  } else if (line.startsWith('diff --git')) {
                    bgColor = colorScheme.surfaceContainerHighest;
                    textColor = colorScheme.primary;
                  }

                  return Container(
                    color: bgColor,
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1.5),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 38,
                          child: Text(
                            '${idx + 1}',
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 10,
                              color: colorScheme.outlineVariant,
                            ),
                          ),
                        ),
                        Expanded(
                          child: SelectableText(
                            line,
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 11.5,
                              color: textColor,
                              height: 1.3,
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _showMobileCommitDetailSheet(BuildContext context, GitCommitSummary commit) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _MobileCommitDetailSheet(
        commit: commit,
        scanner: widget.scanner,
        serverAddress: widget.serverAddress,
        projectPath: widget.projectPath,
      ),
    );
  }
}

/// Modal Bottom Sheet độc lập hiển thị chi tiết Commit & Unified Diff trên Mobile
/// Tự quản lý vòng đời tải chi tiết để tắt animation loading ngay lập tức khi API phản hồi.
class _MobileCommitDetailSheet extends StatefulWidget {
  const _MobileCommitDetailSheet({
    required this.commit,
    required this.scanner,
    required this.serverAddress,
    required this.projectPath,
  });

  final GitCommitSummary commit;
  final BrainScannerService scanner;
  final String serverAddress;
  final String projectPath;

  @override
  State<_MobileCommitDetailSheet> createState() =>
      _MobileCommitDetailSheetState();
}

class _MobileCommitDetailSheetState extends State<_MobileCommitDetailSheet> {
  bool _isLoading = true;
  GitCommitDetailResponse? _detail;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _fetchDetail();
  }

  Future<void> _fetchDetail() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final res = await widget.scanner.fetchGitCommitDetail(
      address: widget.serverAddress,
      projectPath: widget.projectPath,
      hash: widget.commit.hash,
    );

    if (!mounted) return;

    setState(() {
      _isLoading = false;
      if (res.ok) {
        _detail = res;
      } else {
        _errorMessage = res.error ?? 'Không thể tải chi tiết commit';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return DraggableScrollableSheet(
      initialChildSize: 0.88,
      minChildSize: 0.45,
      maxChildSize: 0.96,
      builder: (ctx, scroll) => ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        child: Scaffold(
          backgroundColor: colorScheme.surface,
          appBar: AppBar(
            backgroundColor: colorScheme.surfaceContainerHigh,
            elevation: 0,
            leading: IconButton(
              icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 28),
              onPressed: () => Navigator.of(context).pop(),
              tooltip: 'Đóng',
            ),
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Chi tiết Commit',
                  style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
                Text(
                  widget.commit.shortHash,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    color: colorScheme.primary,
                  ),
                ),
              ],
            ),
            actions: [
              IconButton(
                icon: const Icon(Icons.refresh_rounded, size: 20),
                tooltip: 'Tải lại',
                onPressed: _isLoading ? null : _fetchDetail,
              ),
              const SizedBox(width: 8),
            ],
          ),
          body: _buildBody(context),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    if (_isLoading) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 14),
            Text('Đang nạp chi tiết commit và git diff...'),
          ],
        ),
      );
    }

    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline_rounded, size: 40, color: context.scheme.error),
              const SizedBox(height: 10),
              Text(
                _errorMessage!,
                textAlign: TextAlign.center,
                style: TextStyle(color: context.scheme.error),
              ),
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: _fetchDetail,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Thử lại'),
              ),
            ],
          ),
        ),
      );
    }

    final detail = _detail;
    if (detail == null) {
      return const SizedBox.shrink();
    }

    final diffLines = detail.diff.isNotEmpty ? detail.diff.split('\n') : <String>[];

    return DefaultTabController(
      length: 2,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header chi tiết commit
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerLow,
              border: Border(
                bottom: BorderSide(color: colorScheme.outlineVariant.withAlpha(60)),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        detail.subject,
                        style: textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                          height: 1.3,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // Nút Copy Full Hash
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: detail.hash));
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('Đã sao chép hash: ${detail.hash}'),
                            duration: const Duration(seconds: 1),
                            behavior: SnackBarBehavior.floating,
                          ),
                        );
                      },
                      icon: const Icon(Icons.copy_rounded, size: 12),
                      label: Text(detail.shortHash, style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
                    ),
                  ],
                ),
                if (detail.body.trim().isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: colorScheme.surface,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: colorScheme.outlineVariant.withAlpha(60)),
                    ),
                    child: SelectableText(
                      detail.body.trim(),
                      style: textTheme.bodySmall?.copyWith(height: 1.35),
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(Icons.person_outline_rounded, size: 13, color: colorScheme.primary),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        '${detail.authorName} <${detail.authorEmail}>',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    Icon(Icons.access_time_rounded, size: 13, color: colorScheme.onSurfaceVariant),
                    const SizedBox(width: 4),
                    Text(
                      detail.committedAt.isNotEmpty
                          ? detail.committedAt.split('+').first.replaceAll('T', ' ')
                          : detail.relativeTime,
                      style: TextStyle(fontSize: 10.5, color: colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ],
            ),
          ),
          // Tab bar: Files changed vs Unified Diff
          TabBar(
            labelColor: colorScheme.primary,
            unselectedLabelColor: colorScheme.onSurfaceVariant,
            indicatorColor: colorScheme.primary,
            tabs: [
              Tab(
                text: 'Tệp thay đổi (${detail.files.length})',
                icon: const Icon(Icons.folder_open_outlined, size: 15),
              ),
              Tab(
                text: 'Unified Git Diff',
                icon: const Icon(Icons.difference_outlined, size: 15),
              ),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                // Tab 1: Danh sách Files
                detail.files.isEmpty
                    ? Center(
                        child: Text(
                          'Không có tệp nào thay đổi trong commit này',
                          style: TextStyle(color: colorScheme.onSurfaceVariant),
                        ),
                      )
                    : ListView.builder(
                        itemCount: detail.files.length,
                        padding: const EdgeInsets.all(10),
                        itemBuilder: (ctx, i) {
                          final f = detail.files[i];
                          Color statusColor;
                          String statusLabel;
                          switch (f.status) {
                            case 'A':
                              statusColor = context.status.success;
                              statusLabel = 'A';
                              break;
                            case 'D':
                              statusColor = context.scheme.error;
                              statusLabel = 'D';
                              break;
                            case 'R':
                              statusColor = context.scheme.tertiary;
                              statusLabel = 'R';
                              break;
                            default:
                              statusColor = context.status.warning;
                              statusLabel = 'M';
                          }

                          return Container(
                            margin: const EdgeInsets.only(bottom: 6),
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                            decoration: BoxDecoration(
                              color: colorScheme.surfaceContainerHigh,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: colorScheme.outlineVariant.withAlpha(60)),
                            ),
                            child: Row(
                              children: [
                                Container(
                                  width: 18,
                                  height: 18,
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    color: statusColor.withAlpha(35),
                                    borderRadius: BorderRadius.circular(4),
                                    border: Border.all(color: statusColor, width: 0.8),
                                  ),
                                  child: Text(
                                    statusLabel,
                                    style: TextStyle(
                                      fontSize: 9.5,
                                      fontWeight: FontWeight.w800,
                                      color: statusColor,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    f.path,
                                    style: const TextStyle(
                                      fontFamily: 'monospace',
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                if (f.additions > 0) ...[
                                  Text(
                                    '+${f.additions}',
                                    style: TextStyle(
                                      fontFamily: 'monospace',
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.bold,
                                      color: context.status.success,
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                ],
                                if (f.deletions > 0) ...[
                                  Text(
                                    '-${f.deletions}',
                                    style: TextStyle(
                                      fontFamily: 'monospace',
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.bold,
                                      color: context.scheme.error,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          );
                        },
                      ),

                // Tab 2: Unified Diff Viewer
                detail.diff.trim().isEmpty
                    ? Center(
                        child: Text(
                          'Không có nội dung diff cho commit này',
                          style: TextStyle(color: colorScheme.onSurfaceVariant),
                        ),
                      )
                    : Column(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            color: colorScheme.surfaceContainerLow,
                            child: Row(
                              children: [
                                Text(
                                  '${diffLines.length} dòng diff',
                                  style: TextStyle(fontSize: 11, color: colorScheme.onSurfaceVariant),
                                ),
                                const Spacer(),
                                TextButton.icon(
                                  style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                                  onPressed: () {
                                    Clipboard.setData(ClipboardData(text: detail.diff));
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text('Đã sao chép toàn bộ Git diff'),
                                        duration: Duration(seconds: 1),
                                        behavior: SnackBarBehavior.floating,
                                      ),
                                    );
                                  },
                                  icon: const Icon(Icons.copy_rounded, size: 13),
                                  label: const Text('Sao chép Diff', style: TextStyle(fontSize: 11)),
                                ),
                              ],
                            ),
                          ),
                          Expanded(
                            child: SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: SizedBox(
                                width: 900,
                                child: ListView.builder(
                                  itemCount: diffLines.length,
                                  padding: const EdgeInsets.symmetric(vertical: 4),
                                  itemBuilder: (ctx, idx) {
                                    final line = diffLines[idx];
                                    Color? bgColor;
                                    Color textColor = colorScheme.onSurface;

                                    if (line.startsWith('+') && !line.startsWith('+++')) {
                                      bgColor = context.status.success.withAlpha(35);
                                      textColor = context.status.success;
                                    } else if (line.startsWith('-') && !line.startsWith('---')) {
                                      bgColor = context.scheme.error.withAlpha(35);
                                      textColor = context.scheme.error;
                                    } else if (line.startsWith('@@')) {
                                      bgColor = context.scheme.secondary.withAlpha(30);
                                      textColor = context.scheme.secondary;
                                    } else if (line.startsWith('diff --git')) {
                                      bgColor = colorScheme.surfaceContainerHighest;
                                      textColor = colorScheme.primary;
                                    }

                                    return Container(
                                      color: bgColor,
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1.5),
                                      child: Row(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          SizedBox(
                                            width: 38,
                                            child: Text(
                                              '${idx + 1}',
                                              style: TextStyle(
                                                fontFamily: 'monospace',
                                                fontSize: 10,
                                                color: colorScheme.outlineVariant,
                                              ),
                                            ),
                                          ),
                                          Expanded(
                                            child: SelectableText(
                                              line,
                                              style: TextStyle(
                                                fontFamily: 'monospace',
                                                fontSize: 11,
                                                color: textColor,
                                                height: 1.3,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    );
                                  },
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
