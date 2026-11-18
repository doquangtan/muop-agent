part of '../chat_canvas_view.dart';

/// Card nhóm các tệp đã tác động trong lượt chat và hiển thị số dòng +Added / -Removed + nút Xem Change
class _GroupedFilesChangedCard extends StatefulWidget {
  const _GroupedFilesChangedCard({
    required this.groupedFiles,
    required this.isMobile,
    required this.onInspectFileChange,
    required this.onDownloadFile,
  });

  final List<GroupedFileChange> groupedFiles;
  final bool isMobile;
  final void Function(String filePath, GroupedFileChange? change)
  onInspectFileChange;
  final ValueChanged<String> onDownloadFile;

  @override
  State<_GroupedFilesChangedCard> createState() =>
      _GroupedFilesChangedCardState();
}

class _GroupedFilesChangedCardState extends State<_GroupedFilesChangedCard> {
  bool _isExpanded = true;
  bool _showAllFiles = false;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    int totalAdded = 0;
    int totalRemoved = 0;
    int modifiedCount = 0;
    for (final f in widget.groupedFiles) {
      totalAdded += f.addedLines;
      totalRemoved += f.removedLines;
      if (f.hasChanges) modifiedCount++;
    }

    final int totalFilesCount = widget.groupedFiles.length;
    final bool hasOverflow = totalFilesCount > 5;
    final visibleFiles = (_showAllFiles || !hasOverflow)
        ? widget.groupedFiles
        : widget.groupedFiles.take(5).toList();
    final int hiddenCount = totalFilesCount - 5;

    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => setState(() => _isExpanded = !_isExpanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Icon(
                    Icons.folder_copy_outlined,
                    size: 15,
                    color: colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      modifiedCount > 0
                          ? 'Files Changed (${widget.groupedFiles.length} tệp • $modifiedCount sửa đổi)'
                          : 'Files Touched (${widget.groupedFiles.length} tệp)',
                      style: textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: colorScheme.onSurface,
                      ),
                    ),
                  ),
                  if (totalAdded > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 1.5,
                      ),
                      decoration: BoxDecoration(
                        color: context.status.success.withAlpha(30),
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: Text(
                        '+$totalAdded',
                        style: textTheme.labelSmall?.copyWith(
                          fontFamily: 'monospace',
                          fontSize: 10.5,
                          fontWeight: FontWeight.w800,
                          color: context.status.success,
                        ),
                      ),
                    ),
                  if (totalAdded > 0 && totalRemoved > 0)
                    const SizedBox(width: 4),
                  if (totalRemoved > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 1.5,
                      ),
                      decoration: BoxDecoration(
                        color: context.scheme.error.withAlpha(30),
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: Text(
                        '-$totalRemoved',
                        style: textTheme.labelSmall?.copyWith(
                          fontFamily: 'monospace',
                          fontSize: 10.5,
                          fontWeight: FontWeight.w800,
                          color: context.scheme.error,
                        ),
                      ),
                    ),
                  const SizedBox(width: 6),
                  Icon(
                    _isExpanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 18,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
          if (_isExpanded) ...[
            Divider(height: 1, color: colorScheme.outlineVariant),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                children: [
                  for (final f in visibleFiles)
                    RepaintBoundary(
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: () => widget.onInspectFileChange(f.path, f),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: colorScheme.surfaceContainer,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              children: [
                                _buildActionMiniBadge(f.action, textTheme),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        f.basename,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: textTheme.labelMedium?.copyWith(
                                          fontFamily: 'monospace',
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      if (!widget.isMobile)
                                        Text(
                                          f.path,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: textTheme.labelSmall?.copyWith(
                                            fontFamily: 'monospace',
                                            fontSize: 9.5,
                                            color: colorScheme.onSurfaceVariant,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                if (f.viaBash) ...[
                                  Text(
                                    'sửa bởi Bash',
                                    style: textTheme.labelSmall?.copyWith(
                                      fontStyle: FontStyle.italic,
                                      color: colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                ],
                                if (f.addedLines > 0) ...[
                                  Text(
                                    '+${f.addedLines}',
                                    style: textTheme.labelSmall?.copyWith(
                                      fontFamily: 'monospace',
                                      fontWeight: FontWeight.w800,
                                      color: context.status.success,
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                ],
                                if (f.removedLines > 0) ...[
                                  Text(
                                    '-${f.removedLines}',
                                    style: textTheme.labelSmall?.copyWith(
                                      fontFamily: 'monospace',
                                      fontWeight: FontWeight.w800,
                                      color: context.scheme.error,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                ],
                                Tooltip(
                                  message: 'Xem Change (Diff) & Nội dung',
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(6),
                                    onTap: () =>
                                        widget.onInspectFileChange(f.path, f),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 7,
                                        vertical: 3,
                                      ),
                                      decoration: BoxDecoration(
                                        color:
                                            colorScheme.surfaceContainerHighest,
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Text(
                                        'Diff',
                                        style: textTheme.labelSmall?.copyWith(
                                          fontSize: 10,
                                          fontWeight: FontWeight.w700,
                                          color: colorScheme.primary,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Tooltip(
                                  message: 'Tải tệp từ Server về máy',
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(6),
                                    onTap: () => widget.onDownloadFile(f.path),
                                    child: Padding(
                                      padding: const EdgeInsets.all(4),
                                      child: Icon(
                                        Icons.download_rounded,
                                        size: 15,
                                        color: colorScheme.primary,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (hasOverflow)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: () {
                          setState(() {
                            _showAllFiles = !_showAllFiles;
                          });
                        },
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                            vertical: 6,
                            horizontal: 10,
                          ),
                          decoration: BoxDecoration(
                            color: colorScheme.surfaceContainerHighest
                                .withAlpha(120),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: colorScheme.outlineVariant.withAlpha(80),
                            ),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                _showAllFiles
                                    ? Icons.keyboard_arrow_up_rounded
                                    : Icons.keyboard_arrow_down_rounded,
                                size: 16,
                                color: colorScheme.primary,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                _showAllFiles
                                    ? 'Thu gọn (chỉ hiện 5 tệp đầu)'
                                    : 'Xem tất cả $totalFilesCount tệp (còn +$hiddenCount tệp)',
                                style: textTheme.labelSmall?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  color: colorScheme.primary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildActionMiniBadge(String action, TextTheme textTheme) {
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
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: textTheme.labelSmall?.copyWith(
          fontSize: 9,
          fontWeight: FontWeight.w800,
          color: fg,
        ),
      ),
    );
  }
}
