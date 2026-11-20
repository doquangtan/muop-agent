part of '../chat_canvas_view.dart';

extension _CanvasExtDock on _ChatCanvasViewState {
  /// Cụm Dock phía dưới sắp xếp theo đúng thứ tự:
  /// 0. Plan Approval Card (Nếu có kế hoạch đang chờ duyệt)
  /// 1. Task Running Panel (Phía trên)
  /// 2. % Model Usage Bar chuẩn Antigravity (Ở giữa Task Running và Khung Chat)
  /// 3. Khung nhập Chat (Phía dưới cùng)
  Widget _buildBottomDockStack(
    BuildContext context,
    bool isMobile,
    bool isTurnRunning,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final pendingPlans =
        widget.session?.pendingPlans.where((p) => p.requestFeedback).toList() ??
        const [];
    final claudeInteraction = widget.pendingClaudeInteraction;
    final showClaudeInteraction =
        claudeInteraction != null &&
        widget.onRespondClaudeInteraction != null &&
        claudeInteraction.conversationId == widget.session?.id &&
        !isTurnRunning;

    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    final retry = widget.pendingRetry;
    final retryCancel = widget.onCancelRetry;
    final showRetry =
        retry != null &&
        retryCancel != null &&
        retry.conversationId == widget.session?.id;

    return Container(
      padding: EdgeInsets.fromLTRB(
        isMobile ? 8 : 24,
        4,
        isMobile ? 8 : 24,
        isMobile ? 8 : 14,
      ),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        border: Border(
          top: BorderSide(
            color: colorScheme.outlineVariant.withAlpha(110),
            width: 0.8,
          ),
        ),
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 840),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // [0] KẾ HOẠCH ĐANG CHỜ PHÊ DUYỆT (PLAN APPROVAL CARD)
              if (pendingPlans.isNotEmpty) ...[
                for (final plan in pendingPlans)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: _buildPlanBanner(context, plan),
                  ),
              ],

              // [0.2] CÂU HỎI / KẾ HOẠCH ĐANG CHỜ CỦA CLAUDE CODE CLI (mở dialog khi bấm)
              if (showRetry)
                RetryBanner(
                  retry: retry,
                  onCancel: retryCancel,
                  isMobile: isMobile,
                ),
              if (showClaudeInteraction)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: _buildClaudeInteractionBanner(
                    context,
                    claudeInteraction,
                  ),
                ),

              // [0.3] CẢNH BÁO TIẾN TRÌNH AGY BỊ GIÁN ĐOẠN (SERVER RESTART / CRASH)
              if (widget.session != null &&
                  (widget.session!.isInterrupted ||
                      widget.session!.status == AgentStatus.interrupted))
                _buildInterruptedNoticeBanner(
                  context,
                  widget.session!,
                  isMobile,
                ),

              // [0.5] KHUNG XÁC NHẬN PUSH LÊN SERVER SAU KHI AGENT COMMIT XONG
              () {
                final gitSync =
                    widget.session?.gitSyncStatus ??
                    widget.selectedProject?.gitSyncStatus ??
                    widget.projects
                        .where(
                          (p) =>
                              p.name == widget.session?.projectName ||
                              p.path == widget.session?.projectPath,
                        )
                        .firstOrNull
                        ?.gitSyncStatus;
                final showGitPushPrompt =
                    gitSync != null &&
                    gitSync.isAhead &&
                    gitSync.aheadCount > 0 &&
                    _dismissedGitAheadHash != gitSync.lastCommitHash;
                if (!showGitPushPrompt) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: _buildGitPushPromptCard(context, gitSync, isMobile),
                );
              }(),

              // [1] PHẦN TRÊN: TASK RUNNING PANEL (+ Nút Mở tệp vừa tải về)
              _buildTaskRunningPanel(context, isMobile, isTurnRunning),
              const SizedBox(height: 5),

              // [2] PHẦN GIỮA: % USAGE CỦA MODEL AI (LIMIT TUẦN / LIMIT GIỜ ANTIGRAVITY)
              // Mobile: ẩn khi bàn phím mở để vùng chat có đủ chỗ
              if (!(isMobile && keyboardOpen)) ...[
                _buildModelUsageMiddleBar(context, isMobile),
                const SizedBox(height: 5),
              ],

              // [2.5] HÀNG CÔNG CỤ (Agent map, SFTP, Git Tree): luôn hiện, kể cả khi khung chat ẩn
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: _buildComposerToolRow(context, isMobile),
              ),

              // [3] PHẦN DƯỚI: KHUNG NHẬP CHAT (ẩn khi đang chạy, bấm để hiện)
              if (isTurnRunning && !_composerRevealed)
                _buildHiddenComposerBar(context)
              else ...[
                if (isTurnRunning)
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: () =>
                          _applyState(() => _composerRevealed = false),
                      icon: const Icon(
                        Icons.keyboard_arrow_down_rounded,
                        size: 18,
                      ),
                      label: const Text('Ẩn khung chat'),
                    ),
                  ),
                _buildAntigravityComposer(context, isMobile, isTurnRunning),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildClaudeInteractionBanner(
    BuildContext context,
    PendingClaudeInteraction interaction,
  ) {
    return InteractionBanner(
      icon: interaction.isPlan
          ? Icons.assignment_outlined
          : Icons.help_outline_rounded,
      title: interaction.isPlan
          ? 'Claude đã trình kế hoạch, chờ bạn duyệt'
          : 'Claude đang chờ bạn trả lời',
      subtitle: interaction.summary,
      actionLabel: interaction.isPlan ? 'Xem & duyệt' : 'Trả lời',
      onAction: () => _openClaudeInteraction(context, interaction),
    );
  }

  void _openClaudeInteraction(
    BuildContext context,
    PendingClaudeInteraction interaction,
  ) {
    final respond = widget.onRespondClaudeInteraction!;
    if (interaction.isPlan) {
      showPlanReviewDialog(
        context: context,
        title: 'Kế hoạch từ Claude',
        subtitle: 'Claude chưa thực hiện thay đổi nào cho đến khi bạn duyệt',
        markdown: interaction.plan,
        onDecision: (decision, feedback) =>
            respond(interaction, const [], decision.name, feedback),
      );
    } else {
      showQuestionDialog(
        context: context,
        questions: interaction.questions,
        onSubmit: (answers) => respond(interaction, answers, '', ''),
      );
    }
  }

  Widget _buildHiddenComposerBar(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colorScheme.outlineVariant, width: 1.1),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: colorScheme.primary,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Đang chạy...',
              overflow: TextOverflow.ellipsis,
              style: textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Dừng lượt chạy (Stop)',
            onPressed: widget.onStopTurn,
            icon: Icon(
              Icons.stop_rounded,
              size: 18,
              color: context.scheme.error,
            ),
          ),
          TextButton.icon(
            onPressed: () => _applyState(() => _composerRevealed = true),
            icon: const Icon(Icons.keyboard_arrow_up_rounded, size: 18),
            label: const Text('Hiện khung chat'),
          ),
        ],
      ),
    );
  }

  /// [0.3] Cảnh báo tiến trình Agent bị ngắt đột ngột (server restart / cli crash)
  Widget _buildInterruptedNoticeBanner(
    BuildContext context,
    ConversationSession session,
    bool isMobile,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: EdgeInsets.symmetric(
        horizontal: isMobile ? 12 : 14,
        vertical: 8,
      ),
      decoration: BoxDecoration(
        color: context.status.warning.withAlpha(25),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: context.status.warning.withAlpha(120),
          width: 1,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.warning_amber_rounded,
            size: 18,
            color: context.status.warning,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Tiến trình Agent trước đó đã bị gián đoạn',
                  style: textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: context.status.warning,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  session.interruptedReason ?? 'Lượt xử lý đã dừng do máy chủ khởi động lại hoặc agy CLI bị ngắt đột ngột. Bạn có thể gửi tin nhắn tiếp theo để tiếp tục bình thường.',
                  style: textTheme.bodySmall?.copyWith(
                    fontSize: 11.5,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// [0.5] GIT PUSH PROMPT CARD — Khung hỏi người dùng có cần push lên remote server sau khi Agent commit xong
  Widget _buildGitPushPromptCard(
    BuildContext context,
    GitSyncStatus gitSync,
    bool isMobile,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withAlpha(220),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: context.status.warning.withAlpha(160),
          width: 1.2,
        ),
      ),
      padding: EdgeInsets.symmetric(
        horizontal: isMobile ? 12 : 16,
        vertical: 10,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Row 1: Tiêu đề & nút đóng
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: context.status.warning.withAlpha(35),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.cloud_upload_outlined,
                  size: 16,
                  color: context.status.warning,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Agent đã commit mã nguồn (${gitSync.aheadCount} commit chưa push)',
                  style: textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: colorScheme.onSurface,
                  ),
                ),
              ),
              InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () {
                  _applyState(
                    () => _dismissedGitAheadHash = gitSync.lastCommitHash,
                  );
                },
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(
                    Icons.close_rounded,
                    size: 16,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),

          // Row 2: Chi tiết commit (branch, hash, message, tác giả)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: colorScheme.surface.withAlpha(180),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: colorScheme.outlineVariant.withAlpha(80),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 1.5,
                      ),
                      decoration: BoxDecoration(
                        color: colorScheme.primaryContainer.withAlpha(120),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.alt_route_rounded,
                            size: 11,
                            color: colorScheme.primary,
                          ),
                          const SizedBox(width: 3),
                          Text(
                            gitSync.branch.isNotEmpty ? gitSync.branch : 'main',
                            style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.bold,
                              color: colorScheme.primary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      gitSync.lastCommitHash.isNotEmpty
                          ? gitSync.lastCommitHash.substring(
                              0,
                              math.min(7, gitSync.lastCommitHash.length),
                            )
                          : '',
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (gitSync.lastCommitAuthor.isNotEmpty) ...[
                      const SizedBox(width: 6),
                      Text(
                        '• ${gitSync.lastCommitAuthor}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodySmall?.copyWith(fontSize: 11),
                      ),
                    ],
                  ],
                ),
                if (gitSync.lastCommitMessage.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    gitSync.lastCommitMessage,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.bodySmall?.copyWith(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: colorScheme.onSurface,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 8),

          // Row 3: Action Buttons
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  visualDensity: VisualDensity.compact,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                icon: const Icon(Icons.close_rounded, size: 14),
                label: const Text('Bỏ qua', style: TextStyle(fontSize: 12)),
                onPressed: () {
                  _applyState(
                    () => _dismissedGitAheadHash = gitSync.lastCommitHash,
                  );
                },
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: context.status.success,
                  foregroundColor: context.scheme.onPrimary,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  visualDensity: VisualDensity.compact,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                icon: _isPushingGit
                    ? SizedBox(
                        width: 13,
                        height: 13,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            context.scheme.onPrimary,
                          ),
                        ),
                      )
                    : const Icon(Icons.cloud_upload_rounded, size: 14),
                label: Text(
                  _isPushingGit ? 'Đang push...' : 'Push lên Server',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                onPressed: _isPushingGit
                    ? null
                    : () async {
                        _applyState(() => _isPushingGit = true);
                        try {
                          final res = await widget.onGitPush?.call(
                            gitSync.projectPath,
                            gitSync.branch,
                          );
                          if (!context.mounted) return;
                          if (res != null && res.ok) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Row(
                                  children: [
                                    Icon(
                                      Icons.check_circle_rounded,
                                      color: context.scheme.onPrimary,
                                      size: 18,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        res.message.isNotEmpty ? res.message : 'Đã push thành công lên máy chủ từ xa!',
                                      ),
                                    ),
                                  ],
                                ),
                                backgroundColor: context.status.success,
                                behavior: SnackBarBehavior.floating,
                              ),
                            );
                            _applyState(
                              () => _dismissedGitAheadHash =
                                  gitSync.lastCommitHash,
                            );
                          } else {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  res?.message ??
                                      'Lỗi khi push git lên remote server',
                                ),
                                backgroundColor: Theme.of(context)
                                    .colorScheme
                                    .error,
                                behavior: SnackBarBehavior.floating,
                              ),
                            );
                          }
                        } catch (e) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('Lỗi: $e'),
                                backgroundColor: Theme.of(context)
                                    .colorScheme
                                    .error,
                                behavior: SnackBarBehavior.floating,
                              ),
                            );
                          }
                        } finally {
                          if (mounted) {
                            _applyState(() => _isPushingGit = false);
                          }
                        }
                      },
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPlanBanner(BuildContext context, PlanArtifactInfo plan) {
    return InteractionBanner(
      icon: Icons.assignment_outlined,
      title: 'Agent đã trình kế hoạch, chờ bạn duyệt',
      subtitle: plan.fileName,
      actionLabel: 'Xem & duyệt',
      onAction: () => _showPlanReview(context, plan),
    );
  }
}
