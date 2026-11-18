part of '../chat_canvas_view.dart';

extension _CanvasExtDialogs on _ChatCanvasViewState {
  void _handleLinkTap(String url, String label) {
    final cleanUrl = url.trim();
    if (cleanUrl.startsWith('file://')) {
      final path = cleanUrl.replaceFirst('file://', '');
      widget.onInspectFileChange(path, null);
    } else if (cleanUrl.startsWith('http://') ||
        cleanUrl.startsWith('https://')) {
      Clipboard.setData(ClipboardData(text: cleanUrl));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Đã sao chép liên kết: $cleanUrl'),
          duration: const Duration(seconds: 2),
        ),
      );
    } else if (cleanUrl.contains('/') ||
        cleanUrl.endsWith('.apk') ||
        cleanUrl.endsWith('.dart') ||
        cleanUrl.endsWith('.go') ||
        cleanUrl.endsWith('.rs') ||
        cleanUrl.endsWith('.md')) {
      widget.onInspectFileChange(cleanUrl, null);
    } else {
      Clipboard.setData(ClipboardData(text: cleanUrl));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Đã sao chép: $cleanUrl'),
          duration: const Duration(seconds: 1),
        ),
      );
    }
  }

  void _showPlanReview(BuildContext context, PlanArtifactInfo plan) {
    showPlanReviewDialog(
      context: context,
      title: plan.fileName,
      subtitle: plan.summary,
      markdown: plan.content,
      onDecision: (decision, feedback) async {
        switch (decision) {
          case PlanDecision.approve:
            widget.onApprovePlan?.call(plan);
          case PlanDecision.cancel:
            widget.onCancelPlan?.call(plan);
          case PlanDecision.feedback:
            widget.onRejectPlan?.call(plan, feedback);
        }
        return null;
      },
    );
  }

  void _showToolActionsDialog(BuildContext context, _ChatTurnGroup turn) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        final colorScheme = Theme.of(dialogContext).colorScheme;
        final textTheme = Theme.of(dialogContext).textTheme;
        return Dialog(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720, maxHeight: 620),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 12, 8, 4),
                  child: Row(
                    children: [
                      Icon(
                        Icons.build_circle_outlined,
                        size: 18,
                        color: colorScheme.primary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Tool actions của phản hồi',
                          style: textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () => Navigator.of(dialogContext).pop(),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    child: _AntigravityTrajectorySection(
                      steps: turn.trajectorySteps,
                      thoughtCount: turn.totalThoughtCount,
                      toolCount: turn.totalToolCount,
                      initiallyExpanded: true,
                      onTapStep: (step) => _showStepDetailModal(context, step),
                      onDownloadFile: widget.onDownloadFile,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showFilesChangedDialog(BuildContext context, _ChatTurnGroup turn) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        final colorScheme = Theme.of(dialogContext).colorScheme;
        final textTheme = Theme.of(dialogContext).textTheme;
        final isMobile = MediaQuery.sizeOf(dialogContext).width < 760;
        return Dialog(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720, maxHeight: 620),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 12, 8, 4),
                  child: Row(
                    children: [
                      Icon(
                        Icons.description_outlined,
                        size: 18,
                        color: colorScheme.primary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Tệp thay đổi',
                          style: textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () => Navigator.of(dialogContext).pop(),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    child: _GroupedFilesChangedCard(
                      groupedFiles: turn.groupedFiles,
                      isMobile: isMobile,
                      onInspectFileChange: widget.onInspectFileChange,
                      onDownloadFile: widget.onDownloadFile,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showStepDetailModal(BuildContext context, AgentStep step) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: colorScheme.surfaceContainer,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.65,
          minChildSize: 0.4,
          maxChildSize: 0.92,
          builder: (context, scrollController) {
            return ListView(
              controller: scrollController,
              padding: const EdgeInsets.all(20),
              children: [
                Row(
                  children: [
                    Icon(step.icon, size: 20, color: colorScheme.primary),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Step #${step.stepIndex} • ${step.vietnameseTitle}',
                        style: textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () => Navigator.of(ctx).pop(),
                    ),
                  ],
                ),
                const Divider(height: 20),
                if (step.thinking.trim().isNotEmpty) ...[
                  Text(
                    'Thought Process',
                    style: textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: colorScheme.outlineVariant),
                    ),
                    child: SelectableText(
                      step.thinking.trim(),
                      style: textTheme.bodySmall?.copyWith(height: 1.45),
                    ),
                  ),
                  const SizedBox(height: 14),
                ],
                if (step.toolCalls.isNotEmpty) ...[
                  Text(
                    'Tool Calls (${step.toolCalls.length})',
                    style: textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  for (final tc in step.toolCalls)
                    Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: colorScheme.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: colorScheme.outlineVariant),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  '${tc.name} — ${tc.summaryLabel}',
                                  style: textTheme.labelMedium?.copyWith(
                                    fontFamily: 'monospace',
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              if ((tc.targetPath ?? '${tc.args['Path'] ?? ''}')
                                  .trim()
                                  .startsWith('/'))
                                FilledButton.tonalIcon(
                                  onPressed: () {
                                    final p =
                                        (tc.targetPath ??
                                                '${tc.args['Path'] ?? ''}')
                                            .trim();
                                    Navigator.of(ctx).pop();
                                    widget.onInspectFileChange(p, null);
                                  },
                                  style: FilledButton.styleFrom(
                                    visualDensity: VisualDensity.compact,
                                  ),
                                  icon: const Icon(
                                    Icons.difference_outlined,
                                    size: 14,
                                  ),
                                  label: const Text(
                                    'Xem Change',
                                    style: TextStyle(fontSize: 11.5),
                                  ),
                                ),
                            ],
                          ),
                          if (tc.args.isNotEmpty) ...[
                            const SizedBox(height: 6),
                            for (final e in tc.args.entries)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 3),
                                child: SelectableText(
                                  '${e.key}: ${e.value}',
                                  style: textTheme.labelSmall?.copyWith(
                                    fontFamily: 'monospace',
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                          ],
                        ],
                      ),
                    ),
                ],
                if (step.content.trim().isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Output / Content',
                    style: textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: colorScheme.outlineVariant),
                    ),
                    child: SelectableText(
                      step.content.trim(),
                      style: textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ],
            );
          },
        );
      },
    );
  }
}
