part of '../chat_canvas_view.dart';

extension _CanvasExtRunningModals on _ChatCanvasViewState {
  /// [1] TASK RUNNING PANEL — Nằm phía trên thanh % Model Usage và Khung Chat
  /// Hộp thoại chi tiết xem Agent đang chạy bên trong đang làm gì
  void _showRunningAgentDetailModal(BuildContext context, SubagentLane lane) {
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
          initialChildSize: 0.75,
          minChildSize: 0.45,
          maxChildSize: 0.95,
          expand: false,
          builder: (context, scrollController) {
            return Column(
              children: [
                Center(
                  child: Container(
                    margin: const EdgeInsets.only(top: 10, bottom: 6),
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: colorScheme.outlineVariant,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: context.status.warning.withAlpha(35),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: context.status.warning.withAlpha(120),
                          ),
                        ),
                        child: Icon(
                          Icons.hub_rounded,
                          size: 20,
                          color: context.status.warning,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Text(
                                  lane.name,
                                  style: textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: context.status.warning.withAlpha(30),
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(
                                      color: context.status.warning.withAlpha(
                                        100,
                                      ),
                                      width: 0.8,
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Container(
                                        width: 6,
                                        height: 6,
                                        decoration: BoxDecoration(
                                          color: context.status.warning,
                                          shape: BoxShape.circle,
                                        ),
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        'ĐANG CHẠY',
                                        style: textTheme.labelSmall?.copyWith(
                                          fontSize: 9,
                                          fontWeight: FontWeight.w800,
                                          color: context.status.warning,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 2),
                            Text(
                              lane.role.isNotEmpty
                                  ? lane.role
                                  : lane.targetRepo,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: textTheme.bodySmall?.copyWith(
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.of(ctx).pop(),
                        icon: const Icon(Icons.close_rounded),
                        tooltip: 'Đóng',
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView(
                    controller: scrollController,
                    padding: const EdgeInsets.all(16),
                    children: [
                      // Card Hành động đang xử lý
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: colorScheme.surfaceContainerHigh,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: colorScheme.outlineVariant.withAlpha(80),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  Icons.pending_actions_rounded,
                                  size: 16,
                                  color: context.status.warning,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  'Hành động hiện tại',
                                  style: textTheme.labelMedium?.copyWith(
                                    fontWeight: FontWeight.w700,
                                    color: colorScheme.onSurface,
                                  ),
                                ),
                                const Spacer(),
                                if (lane.currentToolName.isNotEmpty)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 7,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: colorScheme.primary.withAlpha(25),
                                      borderRadius: BorderRadius.circular(6),
                                      border: Border.all(
                                        color: colorScheme.primary.withAlpha(
                                          80,
                                        ),
                                      ),
                                    ),
                                    child: Text(
                                      lane.currentToolName,
                                      style: TextStyle(
                                        fontFamily: 'monospace',
                                        fontSize: 10,
                                        fontWeight: FontWeight.w700,
                                        color: colorScheme.primary,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            Text(
                              lane.currentActionText.isNotEmpty
                                  ? lane.currentActionText
                                  : 'Đang thực thi các tác vụ song song...',
                              style: textTheme.bodyMedium?.copyWith(
                                height: 1.45,
                              ),
                            ),
                            const SizedBox(height: 12),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: LinearProgressIndicator(
                                value: lane.progress > 0 ? lane.progress : null,
                                backgroundColor:
                                    colorScheme.surfaceContainerHighest,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  context.status.warning,
                                ),
                                minHeight: 4,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),

                      // Thông tin Repo & Workspace
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: colorScheme.surfaceContainerLow,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: colorScheme.outlineVariant.withAlpha(60),
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.folder_outlined,
                              size: 16,
                              color: context.status.success,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'Target Repo:',
                              style: textTheme.bodySmall?.copyWith(
                                fontWeight: FontWeight.w600,
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                lane.targetRepo,
                                style: const TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),

                      // Danh sách tệp đã chỉnh sửa bởi Agent này
                      if (lane.filesModified.isNotEmpty) ...[
                        const SizedBox(height: 14),
                        Text(
                          'Tệp đã chỉnh sửa (${lane.filesModified.length})',
                          style: textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (final path in lane.filesModified)
                              InkWell(
                                borderRadius: BorderRadius.circular(6),
                                onTap: () => widget.onInspectFileChange(
                                  path,
                                  GroupedFileChange(
                                    path: path,
                                    action: 'EDIT',
                                    repo: lane.targetRepo,
                                    agentNames: [lane.name],
                                    touchCount: 1,
                                    addedLines: 0,
                                    removedLines: 0,
                                    diffPreview: '',
                                    lastTimestamp: DateTime.now(),
                                  ),
                                ),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: colorScheme.surfaceContainerHighest,
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(
                                      color: colorScheme.outlineVariant
                                          .withAlpha(80),
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        Icons.description_outlined,
                                        size: 13,
                                        color: context.status.success,
                                      ),
                                      const SizedBox(width: 5),
                                      Text(
                                        path.split('/').last,
                                        style: TextStyle(
                                          fontFamily: 'monospace',
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600,
                                          color: colorScheme.onSurface,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ],

                      // Danh sách các bước gần nhất của Agent này
                      if (lane.steps.isNotEmpty) ...[
                        const SizedBox(height: 18),
                        Row(
                          children: [
                            Text(
                              'Nhật ký các bước xử lý gần nhất (${lane.steps.length})',
                              style: textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const Spacer(),
                            Text(
                              '(Chạm để xem chi tiết)',
                              style: textTheme.labelSmall?.copyWith(
                                fontSize: 10,
                                color: context.status.warning,
                                fontStyle: FontStyle.italic,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        ...lane.steps.reversed.take(15).map((st) {
                          return InkWell(
                            borderRadius: BorderRadius.circular(8),
                            onTap: () => _showStepDetailModal(context, st),
                            child: Container(
                              margin: const EdgeInsets.only(bottom: 6),
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: colorScheme.surfaceContainerHigh,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: colorScheme.outlineVariant.withAlpha(
                                    60,
                                  ),
                                ),
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.only(top: 2),
                                    child: Icon(
                                      st.toolCalls.isNotEmpty
                                          ? Icons.build_circle_outlined
                                          : Icons.chat_bubble_outline_rounded,
                                      size: 14,
                                      color: context.status.warning,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Expanded(
                                              child: Text(
                                                st.vietnameseTitle.isNotEmpty
                                                    ? st.vietnameseTitle
                                                    : (st.toolCalls.isNotEmpty
                                                          ? st
                                                                .toolCalls
                                                                .first
                                                                .name
                                                          : st.type),
                                                style: textTheme.labelMedium
                                                    ?.copyWith(
                                                      fontWeight:
                                                          FontWeight.w700,
                                                    ),
                                              ),
                                            ),
                                            Text(
                                              '#${st.stepIndex}',
                                              style: TextStyle(
                                                fontFamily: 'monospace',
                                                fontSize: 10,
                                                color: colorScheme
                                                    .onSurfaceVariant,
                                              ),
                                            ),
                                          ],
                                        ),
                                        if (st.vietnameseDetail.isNotEmpty) ...[
                                          const SizedBox(height: 3),
                                          Text(
                                            st.vietnameseDetail,
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                            style: textTheme.bodySmall
                                                ?.copyWith(
                                                  color: colorScheme
                                                      .onSurfaceVariant,
                                                ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Icon(
                                    Icons.chevron_right_rounded,
                                    size: 16,
                                    color: colorScheme.onSurfaceVariant
                                        .withAlpha(120),
                                  ),
                                ],
                              ),
                            ),
                          );
                        }),
                      ],

                      const SizedBox(height: 20),
                    ],
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// Hộp thoại chi tiết xem Coordinator đang chạy làm gì
  void _showRunningCoordinatorDetailModal(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final stream = widget.activeStream;
    final session = widget.session;
    final taskPath = (stream != null && stream.projectPath.isNotEmpty)
        ? stream.projectPath
        : (widget.selectedProject?.path.isNotEmpty == true)
        ? widget.selectedProject!.path
        : (session != null && session.projectPath.isNotEmpty)
        ? session.projectPath
        : '/home/john/Documents/muop-ecosystem/muop-erp-server';

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
          initialChildSize: 0.70,
          minChildSize: 0.40,
          maxChildSize: 0.95,
          expand: false,
          builder: (context, scrollController) {
            final isMobile = MediaQuery.sizeOf(context).width < 720;
            return Column(
              children: [
                Center(
                  child: Container(
                    margin: const EdgeInsets.only(top: 10, bottom: 6),
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: colorScheme.outlineVariant,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: colorScheme.primary.withAlpha(35),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: colorScheme.primary.withAlpha(120),
                          ),
                        ),
                        child: Icon(
                          Icons.psychology_rounded,
                          size: 20,
                          color: colorScheme.primary,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Text(
                                  'Coordinator (Antigravity)',
                                  style: textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: context.status.success.withAlpha(30),
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(
                                      color: context.status.success.withAlpha(
                                        100,
                                      ),
                                      width: 0.8,
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Container(
                                        width: 6,
                                        height: 6,
                                        decoration: BoxDecoration(
                                          color: context.status.success,
                                          shape: BoxShape.circle,
                                        ),
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        'ĐANG CHẠY',
                                        style: textTheme.labelSmall?.copyWith(
                                          fontSize: 9,
                                          fontWeight: FontWeight.w800,
                                          color: context.status.success,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 2),
                            Text(
                              taskPath,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: textTheme.bodySmall?.copyWith(
                                fontFamily: 'monospace',
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.of(ctx).pop(),
                        icon: const Icon(Icons.close_rounded),
                        tooltip: 'Đóng',
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView(
                    controller: scrollController,
                    padding: const EdgeInsets.all(16),
                    children: [
                      if (stream != null && stream.userPrompt.isNotEmpty) ...[
                        _ScrollablePromptBox(
                          prompt: stream.userPrompt,
                          maxHeight: isMobile ? 130 : 180,
                        ),
                        const SizedBox(height: 14),
                      ],
                      if (stream != null &&
                          stream.streamingText.isNotEmpty) ...[
                        Text(
                          'Nội dung đang phản hồi:',
                          style: textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: colorScheme.surfaceContainerLowest,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: colorScheme.outlineVariant.withAlpha(60),
                            ),
                          ),
                          child: Text(
                            stream.streamingText,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 12,
                              height: 1.4,
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],

                      // Danh sách các bước gần nhất của Coordinator
                      () {
                        final allSteps = session?.steps ?? const <AgentStep>[];
                        final coordSteps = allSteps
                            .where((s) => s.agentName == 'Coordinator')
                            .toList();
                        final displaySteps = coordSteps.isNotEmpty
                            ? coordSteps
                            : allSteps;

                        if (displaySteps.isEmpty) {
                          return const SizedBox.shrink();
                        }

                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Text(
                                  'Nhật ký các bước xử lý gần nhất (${displaySteps.length})',
                                  style: textTheme.titleSmall?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const Spacer(),
                                Text(
                                  '(Chạm để xem chi tiết)',
                                  style: textTheme.labelSmall?.copyWith(
                                    fontSize: 10,
                                    color: colorScheme.primary,
                                    fontStyle: FontStyle.italic,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            ...displaySteps.reversed.take(15).map((st) {
                              return InkWell(
                                borderRadius: BorderRadius.circular(8),
                                onTap: () => _showStepDetailModal(context, st),
                                child: Container(
                                  margin: const EdgeInsets.only(bottom: 6),
                                  padding: const EdgeInsets.all(10),
                                  decoration: BoxDecoration(
                                    color: colorScheme.surfaceContainerHigh,
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                      color: colorScheme.outlineVariant
                                          .withAlpha(60),
                                    ),
                                  ),
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Padding(
                                        padding: const EdgeInsets.only(top: 2),
                                        child: Icon(
                                          st.toolCalls.isNotEmpty
                                              ? Icons.build_circle_outlined
                                              : Icons
                                                    .chat_bubble_outline_rounded,
                                          size: 14,
                                          color: colorScheme.primary,
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Row(
                                              children: [
                                                Expanded(
                                                  child: Text(
                                                    st
                                                            .vietnameseTitle
                                                            .isNotEmpty
                                                        ? st.vietnameseTitle
                                                        : (st
                                                                  .toolCalls
                                                                  .isNotEmpty
                                                              ? st
                                                                    .toolCalls
                                                                    .first
                                                                    .name
                                                              : st.type),
                                                    style: textTheme.labelMedium
                                                        ?.copyWith(
                                                          fontWeight:
                                                              FontWeight.w700,
                                                        ),
                                                  ),
                                                ),
                                                Text(
                                                  '#${st.stepIndex}',
                                                  style: TextStyle(
                                                    fontFamily: 'monospace',
                                                    fontSize: 10,
                                                    color: colorScheme
                                                        .onSurfaceVariant,
                                                  ),
                                                ),
                                              ],
                                            ),
                                            if (st
                                                .vietnameseDetail
                                                .isNotEmpty) ...[
                                              const SizedBox(height: 3),
                                              Text(
                                                st.vietnameseDetail,
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                                style: textTheme.bodySmall
                                                    ?.copyWith(
                                                      color: colorScheme
                                                          .onSurfaceVariant,
                                                    ),
                                              ),
                                            ],
                                          ],
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      Icon(
                                        Icons.chevron_right_rounded,
                                        size: 16,
                                        color: colorScheme.onSurfaceVariant
                                            .withAlpha(120),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            }),
                            const SizedBox(height: 16),
                          ],
                        );
                      }(),

                      FilledButton.icon(
                        onPressed: () {
                          Navigator.of(ctx).pop();
                          widget.onStopTurn();
                        },
                        icon: const Icon(Icons.stop_circle_outlined, size: 18),
                        label: const Text('Dừng tác vụ (Stop Turn)'),
                        style: FilledButton.styleFrom(
                          backgroundColor: context.scheme.error,
                          foregroundColor: context.scheme.onPrimary,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}
