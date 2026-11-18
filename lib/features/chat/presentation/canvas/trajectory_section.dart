part of '../chat_canvas_view.dart';

/// Khối hiển thị tiến trình suy luận & gọi công cụ thu gọn kiểu Antigravity
class _AntigravityTrajectorySection extends StatefulWidget {
  const _AntigravityTrajectorySection({
    required this.steps,
    required this.thoughtCount,
    required this.toolCount,
    required this.initiallyExpanded,
    required this.onTapStep,
    required this.onDownloadFile,
  });

  final List<AgentStep> steps;
  final int thoughtCount;
  final int toolCount;
  final bool initiallyExpanded;
  final ValueChanged<AgentStep> onTapStep;
  final ValueChanged<String> onDownloadFile;

  @override
  State<_AntigravityTrajectorySection> createState() =>
      _AntigravityTrajectorySectionState();
}

class _AntigravityTrajectorySectionState
    extends State<_AntigravityTrajectorySection> {
  late bool _expanded;

  @override
  void initState() {
    super.initState();
    _expanded = widget.initiallyExpanded;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final summaryParts = <String>[];
    if (widget.thoughtCount > 0) {
      summaryParts.add('Thought (${widget.thoughtCount})');
    }
    if (widget.toolCount > 0) {
      summaryParts.add(
        '${widget.toolCount} tool ${widget.toolCount == 1 ? "action" : "actions"}',
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _expanded
                      ? Icons.keyboard_arrow_down_rounded
                      : Icons.keyboard_arrow_right_rounded,
                  size: 18,
                  color: colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 4),
                Icon(
                  Icons.auto_awesome_outlined,
                  size: 14,
                  color: colorScheme.primary,
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    summaryParts.join(' • '),
                    style: textTheme.labelMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_expanded)
          Container(
            margin: const EdgeInsets.only(left: 9, top: 4, bottom: 4),
            padding: const EdgeInsets.only(left: 12),
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(color: colorScheme.outlineVariant, width: 1.5),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final step in widget.steps) ...[
                  if (step.thinking.trim().isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(6),
                        onTap: () => widget.onTapStep(step),
                        child: Text(
                          step.thinking.trim(),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                            fontStyle: FontStyle.italic,
                            height: 1.4,
                          ),
                        ),
                      ),
                    ),
                  for (final tc in step.toolCalls)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 5),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(6),
                        onTap: () => widget.onTapStep(step),
                        child: _buildToolActionRow(
                          context,
                          tc,
                          colorScheme,
                          textTheme,
                        ),
                      ),
                    ),
                ],
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildToolActionRow(
    BuildContext context,
    ToolCallInfo tc,
    ColorScheme colorScheme,
    TextTheme textTheme,
  ) {
    IconData icon = Icons.build_outlined;
    String actionVerb = tc.name;
    String targetBadge = tc.summaryLabel;

    final path = (tc.targetPath ?? '${tc.args['Path'] ?? ''}').trim();
    final basename = path.isNotEmpty ? path.split('/').last : '';

    switch (tc.name) {
      case 'read_file':
      case 'view_file_outline':
        icon = Icons.description_outlined;
        actionVerb = 'Read';
        targetBadge = basename.isNotEmpty ? basename : tc.summaryLabel;
        break;
      case 'edit_file':
        icon = Icons.edit_outlined;
        actionVerb = 'Edited';
        targetBadge = basename.isNotEmpty ? basename : tc.summaryLabel;
        break;
      case 'write_file':
        icon = Icons.note_add_outlined;
        actionVerb = 'Created';
        targetBadge = basename.isNotEmpty ? basename : tc.summaryLabel;
        break;
      case 'run_command':
        icon = Icons.terminal_rounded;
        actionVerb = 'Ran command';
        final cmd = '${tc.args['CommandLine'] ?? ''}'.trim();
        targetBadge = cmd.isNotEmpty ? cmd : tc.summaryLabel;
        break;
      case 'invoke_subagent':
        icon = Icons.call_split_rounded;
        actionVerb = 'Subagent';
        targetBadge =
            '${tc.args['TypeName'] ?? tc.args['Role'] ?? tc.summaryLabel}';
        break;
      case 'grep_search':
      case 'find_by_name':
        icon = Icons.search_rounded;
        actionVerb = 'Searched';
        targetBadge = '${tc.args['Query'] ?? tc.args['Pattern'] ?? ''}';
        break;
    }

    return Row(
      children: [
        Icon(icon, size: 14, color: colorScheme.onSurfaceVariant),
        const SizedBox(width: 6),
        Text(
          actionVerb,
          style: textTheme.labelSmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(5),
            ),
            child: Text(
              targetBadge,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: textTheme.labelSmall?.copyWith(
                fontFamily: 'monospace',
                fontSize: 11,
                color: colorScheme.onSurface,
              ),
            ),
          ),
        ),
        if (path.startsWith('/')) ...[
          const SizedBox(width: 6),
          Tooltip(
            message: 'Tải file $basename về máy',
            child: InkWell(
              borderRadius: BorderRadius.circular(4),
              onTap: () => widget.onDownloadFile(path),
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: Icon(
                  Icons.download_rounded,
                  size: 14,
                  color: colorScheme.primary,
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}
