part of '../chat_canvas_view.dart';

extension _CanvasExtTaskPanel on _ChatCanvasViewState {
  Widget _buildTaskRunningPanel(
    BuildContext context,
    bool isMobile,
    bool isTurnRunning,
  ) {
    if (widget.isNewConversationMode && widget.activeStream == null) {
      return const SizedBox.shrink();
    }

    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final session = widget.session;
    final stream = widget.activeStream;
    final lastDownloaded = widget.lastDownloadedFilePath;

    final currentFilesCount = session?.filesTouched.length ?? 0;
    final currentSessId = session?.id;
    if (_lastGroupedFilesRecordCount != currentFilesCount ||
        _lastGroupedFilesSessionId != currentSessId) {
      _lastGroupedFilesRecordCount = currentFilesCount;
      _lastGroupedFilesSessionId = currentSessId;
      _cachedGroupedSessionFiles =
          (!widget.isNewConversationMode && session != null)
          ? GroupedFileChange.groupRecords(session.filesTouched)
          : const <GroupedFileChange>[];
      int added = 0;
      int removed = 0;
      for (final f in _cachedGroupedSessionFiles) {
        added += f.addedLines;
        removed += f.removedLines;
      }
      _cachedTotalAdded = added;
      _cachedTotalRemoved = removed;
    }

    final groupedSessionFiles = _cachedGroupedSessionFiles;
    final totalAdded = _cachedTotalAdded;
    final totalRemoved = _cachedTotalRemoved;

    final runningSubagents =
        (!widget.isNewConversationMode &&
            session != null &&
            !session.isInterrupted)
        ? session.subagentLanes
              .where(
                (lane) =>
                    lane.name != 'Coordinator' &&
                    lane.status == AgentStatus.running,
              )
              .toList()
        : const <SubagentLane>[];

    final isCoordinatorRunning = isTurnRunning;
    final int activeTaskCount =
        (isCoordinatorRunning ? 1 : 0) + runningSubagents.length;

    // Khi không có tác vụ nào đang chạy và không có file changed:
    // Ẩn hoàn toàn panel tasks running
    if (activeTaskCount == 0 &&
        groupedSessionFiles.isEmpty &&
        lastDownloaded == null) {
      return const SizedBox.shrink();
    }

    // Khi không có task nào đang chạy nhưng có file đã thay đổi:
    // Hiển thị thanh tóm tắt file changes gọn gàng, không hiện "0 tasks running"
    if (activeTaskCount == 0) {
      return Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHigh.withAlpha(240),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: colorScheme.outlineVariant.withAlpha(60),
            width: 0.8,
          ),
        ),
        child: Row(
          children: [
            Icon(
              Icons.check_circle_outline_rounded,
              size: 15,
              color: context.status.success,
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                '${groupedSessionFiles.length} tệp đã cập nhật',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.bodySmall?.copyWith(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            if (totalAdded > 0 || totalRemoved > 0) ...[
              const SizedBox(width: 6),
              Text(
                '+$totalAdded',
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: context.status.success,
                ),
              ),
              const SizedBox(width: 3),
              Text(
                '-$totalRemoved',
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: context.scheme.error,
                ),
              ),
            ],
            const Spacer(),
            InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: widget.onOpenChangesTab,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: colorScheme.primaryContainer.withAlpha(100),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: colorScheme.primary.withAlpha(80)),
                ),
                child: Text(
                  'Review',
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    color: colorScheme.primary,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
          ],
        ),
      );
    }

    final taskTitle = activeTaskCount > 0
        ? '$activeTaskCount task${activeTaskCount > 1 ? 's' : ''} running'
        : '0 tasks running';

    final lastStep =
        (!widget.isNewConversationMode &&
            session != null &&
            session.steps.isNotEmpty)
        ? session.steps.last
        : null;
    final bool isGitCommitTask =
        isCoordinatorRunning &&
        ((stream != null &&
                (stream.activeStepType == 'gitCommit' ||
                    stream.streamingText.toLowerCase().contains('git commit') ||
                    stream.userPrompt.toLowerCase().contains('commit'))) ||
            (lastStep != null &&
                (lastStep.phase.name == 'gitCommit' ||
                    lastStep.vietnameseTitle.contains('Git Commit') ||
                    lastStep.toolCalls.any((t) {
                      final cmd =
                          t.args['CommandLine']?.toString().toLowerCase() ?? '';
                      final sum =
                          t.args['toolSummary']?.toString().toLowerCase() ?? '';
                      return cmd.contains('git commit') ||
                          sum.contains('commit');
                    }))));
    String gitCommitDetail = '';
    if (isGitCommitTask &&
        lastStep != null &&
        lastStep.vietnameseDetail.isNotEmpty) {
      gitCommitDetail = lastStep.vietnameseDetail;
    }

    final int? currentStepIndex = lastStep?.stepIndex;
    final String stepBadgeLabel = currentStepIndex != null
        ? 'Bước #$currentStepIndex'
        : '';

    // Xác định trạng thái tác vụ cụ thể của Coordinator
    String coordinatorToolBadge = '';
    Color coordinatorBadgeColor = colorScheme.primary;
    IconData coordinatorActionIcon = Icons.smart_toy_rounded;
    String coordinatorActionTitle = currentStepIndex != null
        ? 'Bước #$currentStepIndex: Robot đang suy nghĩ & phân tích'
        : 'Robot đang suy nghĩ & phân tích';
    String coordinatorActionDetail = _extractSpecificThinkingDetail(
      stream?.streamingText ?? '',
      stream?.userPrompt ?? '',
      lastStep,
    );

    if (isGitCommitTask) {
      coordinatorToolBadge = 'git commit';
      coordinatorBadgeColor = context.status.success;
      coordinatorActionIcon = Icons.commit_rounded;
      coordinatorActionTitle = currentStepIndex != null
          ? 'Bước #$currentStepIndex: Đang tạo Git Commit'
          : 'Đang tạo Git Commit';
      coordinatorActionDetail = gitCommitDetail.isNotEmpty
          ? gitCommitDetail
          : 'Tạo git commit cho các thay đổi trong phiên làm việc';
    } else if (lastStep != null && lastStep.toolCalls.isNotEmpty) {
      final lastTool = lastStep.toolCalls.last;
      final toolName = lastTool.name;
      coordinatorToolBadge = toolName;
      switch (toolName) {
        case 'run_command':
          coordinatorBadgeColor = context.scheme.secondary;
          coordinatorActionIcon = Icons.terminal_rounded;
          final summary = lastTool.args['toolSummary']?.toString() ?? '';
          final cmd = lastTool.args['CommandLine']?.toString() ?? '';
          coordinatorActionTitle =
              'Bước #$currentStepIndex: ${summary.isNotEmpty ? summary : (lastStep.vietnameseTitle.isNotEmpty ? lastStep.vietnameseTitle : 'Thực thi lệnh terminal')}';
          coordinatorActionDetail = cmd.isNotEmpty
              ? cmd
              : lastStep.vietnameseDetail;
          break;
        case 'edit_file':
          coordinatorBadgeColor = context.status.warning;
          coordinatorActionIcon = Icons.edit_note_rounded;
          final path = lastTool.args['Path']?.toString() ?? '';
          coordinatorActionTitle =
              'Bước #$currentStepIndex: ${lastStep.vietnameseTitle.isNotEmpty ? lastStep.vietnameseTitle : 'Chỉnh sửa tệp nguồn'}';
          coordinatorActionDetail = path.isNotEmpty
              ? path.split('/').last
              : lastStep.vietnameseDetail;
          break;
        case 'write_file':
          coordinatorBadgeColor = context.status.success;
          coordinatorActionIcon = Icons.note_add_rounded;
          final path = lastTool.args['Path']?.toString() ?? '';
          coordinatorActionTitle =
              'Bước #$currentStepIndex: ${lastStep.vietnameseTitle.isNotEmpty ? lastStep.vietnameseTitle : 'Tạo mới tệp tin'}';
          coordinatorActionDetail = path.isNotEmpty
              ? path.split('/').last
              : lastStep.vietnameseDetail;
          break;
        case 'read_file':
          coordinatorBadgeColor = context.status.warning;
          coordinatorActionIcon = Icons.search_rounded;
          final path = lastTool.args['Path']?.toString() ?? '';
          coordinatorActionTitle =
              'Bước #$currentStepIndex: ${lastStep.vietnameseTitle.isNotEmpty ? lastStep.vietnameseTitle : 'Đọc nội dung tệp tin'}';
          coordinatorActionDetail = path.isNotEmpty
              ? path.split('/').last
              : lastStep.vietnameseDetail;
          break;
        case 'invoke_subagent':
          coordinatorBadgeColor = context.scheme.tertiary;
          coordinatorActionIcon = Icons.alt_route_rounded;
          final role = lastTool.args['Role']?.toString() ?? '';
          coordinatorActionTitle =
              'Bước #$currentStepIndex: ${role.isNotEmpty ? 'Phân quyền: $role' : 'Điều phối Subagent song song'}';
          coordinatorActionDetail =
              lastTool.args['Prompt']?.toString() ?? lastStep.vietnameseDetail;
          break;
        default:
          coordinatorBadgeColor = context.scheme.tertiary;
          coordinatorActionIcon = Icons.build_circle_outlined;
          coordinatorActionTitle =
              'Bước #$currentStepIndex: ${lastStep.vietnameseTitle.isNotEmpty ? lastStep.vietnameseTitle : 'Công cụ: $toolName'}';
          coordinatorActionDetail = lastStep.vietnameseDetail;
      }
    } else if (stream != null && stream.streamingText.isNotEmpty) {
      coordinatorToolBadge = 'Thinking';
      coordinatorBadgeColor = context.scheme.tertiary;
      coordinatorActionIcon = Icons.smart_toy_rounded;
      coordinatorActionTitle = currentStepIndex != null
          ? 'Bước #$currentStepIndex: Robot đang suy nghĩ & xử lý'
          : 'Robot đang suy nghĩ & xử lý';
      coordinatorActionDetail = _extractSpecificThinkingDetail(
        stream.streamingText,
        stream.userPrompt,
        lastStep,
      );
    } else if (lastStep != null) {
      final isPlanner = lastStep.type == 'PLANNER_RESPONSE';
      coordinatorToolBadge = isPlanner ? 'Thinking' : lastStep.type;
      coordinatorBadgeColor = isPlanner
          ? context.scheme.tertiary
          : colorScheme.primary;
      coordinatorActionIcon = isPlanner
          ? Icons.smart_toy_rounded
          : Icons.psychology_rounded;
      coordinatorActionTitle = currentStepIndex != null
          ? 'Bước #$currentStepIndex: ${isPlanner ? 'Robot đang suy nghĩ & phân tích' : (lastStep.vietnameseTitle.isNotEmpty ? lastStep.vietnameseTitle : 'Đang xử lý bước #$currentStepIndex')}'
          : (lastStep.vietnameseTitle.isNotEmpty
                ? lastStep.vietnameseTitle
                : 'Đang xử lý yêu cầu');
      coordinatorActionDetail = _extractSpecificThinkingDetail(
        stream?.streamingText ?? '',
        stream?.userPrompt ?? '',
        lastStep,
      );
    } else {
      coordinatorToolBadge = 'Thinking';
      coordinatorBadgeColor = context.scheme.tertiary;
      coordinatorActionIcon = Icons.smart_toy_rounded;
      coordinatorActionTitle = 'Robot đang suy nghĩ & phân tích';
      coordinatorActionDetail = _extractSpecificThinkingDetail(
        stream?.streamingText ?? '',
        stream?.userPrompt ?? '',
        null,
      );
    }

    final taskPath = (stream != null && stream.projectPath.isNotEmpty)
        ? stream.projectPath
        : (widget.selectedProject?.path.isNotEmpty == true)
        ? widget.selectedProject!.path
        : (session != null && session.projectPath.isNotEmpty)
        ? session.projectPath
        : '/home/john/Documents/muop-ecosystem/muop-erp-server';

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHigh.withAlpha(240),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: colorScheme.outlineVariant.withAlpha(60),
          width: 0.8,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // [Header Row] Giống hệt Antigravity: "1 task running" + chevron
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => _applyState(
              () => _isTaskRunningExpanded = !_isTaskRunningExpanded,
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 9, 14, 5),
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      taskTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodySmall?.copyWith(
                        fontSize: 13,
                        fontWeight: FontWeight.w400,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  // Nút Mở tệp vừa tải về (nếu có)
                  if (lastDownloaded != null &&
                      lastDownloaded.trim().isNotEmpty) ...[
                    InkWell(
                      borderRadius: BorderRadius.circular(6),
                      onTap: () => widget.onOpenDownloadedFile(lastDownloaded),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: context.status.success.withAlpha(35),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: context.status.success.withAlpha(100),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.open_in_new_rounded,
                              size: 11,
                              color: context.status.success,
                            ),
                            const SizedBox(width: 3),
                            Text(
                              isMobile
                                  ? 'Tệp'
                                  : 'Mở: ${lastDownloaded.split('/').last}',
                              style: textTheme.labelSmall?.copyWith(
                                fontSize: 9.5,
                                fontWeight: FontWeight.w700,
                                color: context.status.success,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                  // Nút Files Changed (nếu có)
                  if (groupedSessionFiles.isNotEmpty) ...[
                    InkWell(
                      borderRadius: BorderRadius.circular(6),
                      onTap: widget.onOpenChangesTab,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: colorScheme.primaryContainer.withAlpha(100),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: colorScheme.primary.withAlpha(80),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.difference_rounded,
                              size: 11,
                              color: colorScheme.primary,
                            ),
                            const SizedBox(width: 3),
                            Text(
                              isMobile
                                  ? '${groupedSessionFiles.length}'
                                  : '${groupedSessionFiles.length} tệp',
                              style: textTheme.labelSmall?.copyWith(
                                fontSize: 9.5,
                                fontWeight: FontWeight.w700,
                                color: colorScheme.onSurface,
                              ),
                            ),
                            if (totalAdded > 0 || totalRemoved > 0) ...[
                              const SizedBox(width: 2),
                              Text(
                                '+$totalAdded',
                                style: textTheme.labelSmall?.copyWith(
                                  fontFamily: 'monospace',
                                  fontSize: 8.5,
                                  fontWeight: FontWeight.w700,
                                  color: context.status.success,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                  Icon(
                    _isTaskRunningExpanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    size: 18,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),

          // [Coordinator Running Task Row] Khi Main Agent chạy: bấm vào để xem bên trong đang làm gì
          if (isCoordinatorRunning) ...[
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => _showRunningCoordinatorDetailModal(context),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 5, 14, 8),
                child: Row(
                  children: [
                    if (coordinatorToolBadge == 'Thinking')
                      _AnimatedThinkingRobotIcon(
                        size: 16,
                        color: context.scheme.tertiary,
                      )
                    else
                      SizedBox(
                        width: 15,
                        height: 15,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            coordinatorBadgeColor,
                          ),
                        ),
                      ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              Text(
                                'Coordinator',
                                style: textTheme.labelSmall?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  color: colorScheme.primary,
                                ),
                              ),
                              if (stepBadgeLabel.isNotEmpty) ...[
                                const SizedBox(width: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 5,
                                    vertical: 1,
                                  ),
                                  decoration: BoxDecoration(
                                    color: colorScheme.primaryContainer
                                        .withAlpha(140),
                                    borderRadius: BorderRadius.circular(4),
                                    border: Border.all(
                                      color: colorScheme.primary.withAlpha(140),
                                      width: 0.8,
                                    ),
                                  ),
                                  child: Text(
                                    stepBadgeLabel,
                                    style: TextStyle(
                                      fontFamily: 'monospace',
                                      fontSize: 9.5,
                                      fontWeight: FontWeight.w800,
                                      color: colorScheme.onPrimaryContainer,
                                    ),
                                  ),
                                ),
                              ],
                              if (coordinatorToolBadge.isNotEmpty) ...[
                                const SizedBox(width: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 5,
                                    vertical: 1,
                                  ),
                                  decoration: BoxDecoration(
                                    color: coordinatorBadgeColor.withAlpha(35),
                                    borderRadius: BorderRadius.circular(4),
                                    border: Border.all(
                                      color: coordinatorBadgeColor.withAlpha(
                                        120,
                                      ),
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        coordinatorActionIcon,
                                        size: 10,
                                        color: coordinatorBadgeColor,
                                      ),
                                      const SizedBox(width: 3),
                                      Text(
                                        coordinatorToolBadge,
                                        style: TextStyle(
                                          fontSize: 9.5,
                                          fontWeight: FontWeight.bold,
                                          color: coordinatorBadgeColor,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                              const SizedBox(width: 6),
                              Text(
                                '•',
                                style: TextStyle(
                                  color: colorScheme.outlineVariant,
                                  fontSize: 10,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  isMobile
                                      ? taskPath.split('/').last
                                      : taskPath,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 11,
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 3),
                          Row(
                            children: [
                              if (coordinatorToolBadge == 'Thinking')
                                _AnimatedThinkingRobotIcon(
                                  size: 12,
                                  color: context.scheme.tertiary,
                                )
                              else
                                Icon(
                                  coordinatorActionIcon,
                                  size: 12,
                                  color: coordinatorBadgeColor,
                                ),
                              const SizedBox(width: 5),
                              Expanded(
                                child: Text(
                                  coordinatorActionDetail.isNotEmpty
                                      ? '$coordinatorActionTitle — $coordinatorActionDetail'
                                      : coordinatorActionTitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: coordinatorBadgeColor,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 6),
                    Icon(
                      Icons.chevron_right_rounded,
                      size: 16,
                      color: colorScheme.onSurfaceVariant.withAlpha(140),
                    ),
                    const SizedBox(width: 8),
                    // Nút Stop hình tròn viền với ô vuông nhỏ bên trong [■]
                    InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: widget.onStopTurn,
                      child: Container(
                        width: 22,
                        height: 22,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: colorScheme.onSurfaceVariant.withAlpha(220),
                            width: 1.5,
                          ),
                        ),
                        child: Center(
                          child: Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: colorScheme.onSurfaceVariant.withAlpha(
                                220,
                              ),
                              borderRadius: BorderRadius.circular(1.5),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],

          // [Subagent Running Rows] CHỈ hiện Agent nào ĐANG CHẠY: bấm vào để xem chi tiết bên trong
          for (final lane in runningSubagents) ...[
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => _showRunningAgentDetailModal(context, lane),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 4, 14, 7),
                child: Row(
                  children: [
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.8,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          context.status.warning,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  lane.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: textTheme.labelSmall?.copyWith(
                                    fontWeight: FontWeight.w700,
                                    color: context.status.warning,
                                  ),
                                ),
                              ),
                              if (lane.targetRepo.isNotEmpty) ...[
                                const SizedBox(width: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 5,
                                    vertical: 1,
                                  ),
                                  decoration: BoxDecoration(
                                    color: colorScheme.surfaceContainer,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    lane.targetRepo.split('/').last,
                                    style: TextStyle(
                                      fontFamily: 'monospace',
                                      fontSize: 9.5,
                                      color: colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            lane.currentActionText.isNotEmpty
                                ? lane.currentActionText
                                : (lane.role.isNotEmpty
                                      ? lane.role
                                      : 'Đang xử lý tác vụ...'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              color: colorScheme.onSurface.withAlpha(200),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 6),
                    Icon(
                      Icons.chevron_right_rounded,
                      size: 16,
                      color: colorScheme.onSurfaceVariant.withAlpha(140),
                    ),
                  ],
                ),
              ),
            ),
          ],

          // [Expanded Content] Chi tiết tệp khi bấm chevron mở rộng
          if (_isTaskRunningExpanded) ...[
            Container(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(
                    color: colorScheme.outlineVariant.withAlpha(60),
                  ),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (groupedSessionFiles.isNotEmpty)
                    SizedBox(
                      height: 30,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: groupedSessionFiles.length,
                        separatorBuilder: (_, _) => const SizedBox(width: 6),
                        itemBuilder: (context, i) {
                          final gf = groupedSessionFiles[i];
                          return InkWell(
                            borderRadius: BorderRadius.circular(7),
                            onTap: () =>
                                widget.onInspectFileChange(gf.path, gf),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: colorScheme.surfaceContainer,
                                borderRadius: BorderRadius.circular(7),
                                border: Border.all(
                                  color: colorScheme.outlineVariant,
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    gf.action == 'WRITE'
                                        ? Icons.note_add_outlined
                                        : gf.action == 'EDIT'
                                        ? Icons.edit_note_rounded
                                        : Icons.description_outlined,
                                    size: 13,
                                    color: gf.action == 'WRITE'
                                        ? context.status.success
                                        : gf.action == 'EDIT'
                                        ? context.status.warning
                                        : colorScheme.onSurfaceVariant,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    gf.basename,
                                    style: textTheme.labelSmall?.copyWith(
                                      fontFamily: 'monospace',
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  if (gf.addedLines > 0 ||
                                      gf.removedLines > 0) ...[
                                    const SizedBox(width: 5),
                                    Text(
                                      '+${gf.addedLines}/-${gf.removedLines}',
                                      style: textTheme.labelSmall?.copyWith(
                                        fontFamily: 'monospace',
                                        fontSize: 9.5,
                                        fontWeight: FontWeight.w700,
                                        color: context.status.success,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    )
                  else
                    Text(
                      'Chưa có tệp nào bị thay đổi trong phiên này.',
                      style: textTheme.labelSmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                        fontSize: 11,
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
}
