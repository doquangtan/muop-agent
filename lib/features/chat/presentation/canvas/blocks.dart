part of '../chat_canvas_view.dart';

extension _CanvasExtBlocks on _ChatCanvasViewState {
  Widget _buildFlatBlockItem(
    BuildContext context,
    _ChatFlatBlock block, {
    required bool isMobile,
  }) {
    switch (block.kind) {
      case _ChatBlockKind.turnSpacing:
        return SizedBox(height: isMobile ? 14 : 20);

      case _ChatBlockKind.liveStreaming:
        // Dùng stream hiện tại, không dùng bản chụp lưu trong block (có thể đã cũ)
        final current = widget.activeStream;
        final liveNow =
            (current != null &&
                current.conversationId == block.stream!.conversationId)
            ? current
            : block.stream!;
        return _buildStandaloneLiveCard(context, liveNow);

      case _ChatBlockKind.userPromptBubble:
        final userStep = block.turn!.userStep!;
        final turnIndex = block.turn!.turnIndex;
        final isExpanded = _expandedPromptTurns.contains(turnIndex);
        final promptContent = userStep.content;
        final chatTheme = context.chatTheme;

        return Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              Align(
            alignment: Alignment.centerRight,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: isMobile ? 320 : 660),
              // Content Layer: dùng bề mặt đục/gradient nhẹ theo theme widget User, tránh hiệu ứng nặng trong ListView
              child: Container(
                key: const Key('chat-user-bubble'),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: chatTheme.userBubbleGradient,
                  ),
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(18),
                    topRight: Radius.circular(18),
                    bottomLeft: Radius.circular(18),
                    bottomRight: Radius.circular(4),
                  ),
                  border: Border.all(
                    color: chatTheme.userBubbleBorder,
                    width: 0.85,
                  ),
                ),
                padding: EdgeInsets.symmetric(
                  horizontal: isMobile ? 14 : 18,
                  vertical: isMobile ? 10 : 12,
                ),
                child: LayoutBuilder(
                  builder: (context, boxConstraints) {
                    final textStyle = TextStyle(
                      fontSize: isMobile ? 13.5 : 14,
                      height: 1.45,
                      color: chatTheme.userBubbleText,
                      fontWeight: FontWeight.w500,
                    );

                    final textDirection = Directionality.of(context);
                    final cacheKey = Object.hash(
                      promptContent,
                      boxConstraints.maxWidth.round(),
                      isMobile,
                      textDirection,
                    );
                    var layout = _promptLayoutCache[cacheKey];
                    if (layout == null) {
                      final textSpan = TextSpan(
                        text: promptContent,
                        style: textStyle,
                      );
                      final textPainter = TextPainter(
                        text: textSpan,
                        maxLines: 5,
                        textDirection: textDirection,
                      )..layout(maxWidth: boxConstraints.maxWidth);
                      final exceedsFiveLines = textPainter.didExceedMaxLines;
                      if (!exceedsFiveLines) {
                        layout = _CollapsedPromptLayout(
                          exceedsFiveLines: false,
                          hiddenLines: 0,
                          collapsedText: promptContent,
                        );
                      } else {
                        final fullPainter = TextPainter(
                          text: textSpan,
                          textDirection: textDirection,
                        )..layout(maxWidth: boxConstraints.maxWidth);
                        final totalLines =
                            fullPainter.computeLineMetrics().length;
                        final hiddenPromptLines = math.max(0, totalLines - 5);
                        layout = _CollapsedPromptLayout(
                          exceedsFiveLines: true,
                          hiddenLines: hiddenPromptLines,
                          collapsedText: textFromVisualLine(
                            fullPainter,
                            promptContent,
                            hiddenPromptLines,
                          ),
                        );
                      }
                      if (_promptLayoutCache.length > 200) {
                        _promptLayoutCache.clear();
                      }
                      _promptLayoutCache[cacheKey] = layout;
                    }
                    final exceedsFiveLines = layout.exceedsFiveLines;
                    final hiddenPromptLines = layout.hiddenLines;
                    final collapsedPrompt = layout.collapsedText;

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Nút xem toàn bộ nằm trên cùng, căn phải
                        if (exceedsFiveLines) ...[
                          Align(
                            alignment: Alignment.centerRight,
                            child: InkWell(
                              onTap: () {
                                _applyState(() {
                                  if (isExpanded) {
                                    _expandedPromptTurns.remove(turnIndex);
                                  } else {
                                    _expandedPromptTurns.add(turnIndex);
                                  }
                                });
                              },
                              borderRadius: BorderRadius.circular(4),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 3,
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      isExpanded
                                          ? 'Thu gọn'
                                          : 'Xem toàn bộ ($hiddenPromptLines dòng ẩn)',
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        color: chatTheme.userBubbleLink,
                                      ),
                                    ),
                                    const SizedBox(width: 2),
                                    Icon(
                                      isExpanded
                                          ? Icons.unfold_less_rounded
                                          : Icons.unfold_more_rounded,
                                      size: 16,
                                      color: chatTheme.userBubbleLink,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 4),
                        ],
                        if (userStep.imageUrls.isNotEmpty) ...[
                          Align(
                            alignment: Alignment.centerRight,
                            child: _UserAttachmentThumbs(
                              urls: userStep.imageUrls,
                              baseUrl: widget.serverBaseUrl,
                            ),
                          ),
                          const SizedBox(height: 8),
                        ] else if (userStep.imageCount > 0) ...[
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.image_outlined,
                                size: 14,
                                color: chatTheme.userBubbleText.withValues(
                                  alpha: 0.78,
                                ),
                              ),
                              const SizedBox(width: 4),
                              Text(
                                '${userStep.imageCount} ảnh đính kèm',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: chatTheme.userBubbleText.withValues(
                                    alpha: 0.78,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                        ],
                        // Thu gọn: hiện 5 dòng cuối; mở rộng: toàn bộ nội dung
                        Text(
                          (isExpanded || !exceedsFiveLines)
                              ? promptContent
                              : collapsedPrompt,
                          style: textStyle,
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
              _buildShareButton(context, userStep.stepIndex),
            ],
          ),
        );

      case _ChatBlockKind.aiTurnCard:
        final turn = block.turn!;
        // Lấy nội dung đang stream cho thẻ AI cuối khi lượt còn chạy. Không phụ thuộc
        // session.status: agy chỉ ghi transcript khi bước xong nên status có thể chưa
        // kịp là running, khi đó thẻ hiện trống dù streamingText đã có nội dung.
        final liveStream =
            (block.isLastTurn &&
                widget.activeStream != null &&
                widget.activeStream!.isRunning)
            ? widget.activeStream
            : null;
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: _buildAiTurnCard(
            context,
            turn,
            isMobile: isMobile,
            isLastTurn: block.isLastTurn,
            liveStream: liveStream,
          ),
        );

      case _ChatBlockKind.loadMoreBanner:
        return _buildLoadMoreOlderTurnsBanner(
          context,
          remainingCount: block.remainingCount,
          loadedCount: block.loadedCount,
          totalCount: block.totalTurnsCount,
        );
    }
  }

  Widget _buildGranularResponseSegmentWidget(
    BuildContext context,
    _ParsedResponseSegment block, {
    required int turnIndex,
    required bool isExpanded,
    required ColorScheme colorScheme,
    required TextTheme textTheme,
    required bool isMobile,
  }) {
    if (block.isCode) {
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(
          color: context.scheme.surfaceContainerLowest,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: context.scheme.outlineVariant, width: 0.8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
              decoration: BoxDecoration(
                color: context.scheme.surfaceContainerLow,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(8.2),
                ),
                border: Border(
                  bottom: BorderSide(
                    color: context.scheme.outlineVariant,
                    width: 0.8,
                  ),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.terminal_rounded,
                    size: 13,
                    color: colorScheme.primary,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    block.language.isEmpty ? 'bash' : block.language,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const Spacer(),
                  if (isRunnableShellBlock(block.language, block.text)) ...[
                    InkWell(
                      borderRadius: BorderRadius.circular(4),
                      onTap: () => showRunCommandDialog(
                        context,
                        serverAddress: widget.serverBaseUrl,
                        command: block.text,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.play_arrow_rounded,
                              size: 14,
                              color: colorScheme.primary,
                            ),
                            const SizedBox(width: 3),
                            Text(
                              'Run',
                              style: TextStyle(
                                fontSize: 11,
                                color: colorScheme.primary,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                  ],
                  InkWell(
                    borderRadius: BorderRadius.circular(4),
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: block.text));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Đã sao chép đoạn mã'),
                          duration: Duration(seconds: 1),
                        ),
                      );
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.copy_rounded,
                            size: 12.5,
                            color: colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            'Copy',
                            style: TextStyle(
                              fontSize: 11,
                              color: colorScheme.onSurfaceVariant,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Text(
                  block.text,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12.5,
                    height: 1.5,
                    color: context.scheme.onSurface,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2.5),
      child: _AntigravityMarkdownSegment(
        text: block.text,
        isExpanded: isExpanded,
        onExpand: !isExpanded
            ? () => _applyState(() => _expandedResponseTurns.add(turnIndex))
            : null,
        onLinkTap: (url, label) => _handleLinkTap(url, label),
        isMobile: isMobile,
      ),
    );
  }

  /// Thẻ AI đứng riêng khi stream đang chạy nhưng chưa gắn được vào lượt nào trong session
  Widget _buildStandaloneLiveCard(
    BuildContext context,
    ChatTurnStreamState stream,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final isMobile = MediaQuery.sizeOf(context).width < 760;
    final lastStep = widget.session?.steps.isNotEmpty == true
        ? widget.session!.steps.last
        : null;

    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: _buildAiCardShell(
        colorScheme: colorScheme,
        isMobile: isMobile,
        children: [
          if (stream.streamingText.trim().isNotEmpty) ...[
            _AiResponseTypewriter(
              text: stream.streamingText,
              builder: (ctx, visibleText) => _buildResponseSegmentsColumn(
                ctx,
                _lastLinesOf(
                  visibleText,
                  _ChatCanvasViewState._collapsedTailLines,
                ),
                turnIndex: -1,
                isExpanded: true,
                isMobile: isMobile,
              ),
            ),
            const SizedBox(height: 8),
          ],
          if (stream.isRunning)
            _buildRunningStatusRow(
              colorScheme,
              textTheme,
              _liveRunningTitle(stream, lastStep?.vietnameseTitle),
            ),
          if (stream.error.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              stream.error,
              style: textTheme.bodySmall?.copyWith(color: context.scheme.error),
            ),
          ],
        ],
      ),
    );
  }

  /// Khung chung của thẻ phản hồi AI: căn trái, bề rộng tối đa bằng bong bóng user
  /// (nên khoảng cách bên phải của thẻ AI bằng khoảng cách bên trái của bong bóng user)
  Widget _buildAiCardShell({
    required ColorScheme colorScheme,
    required bool isMobile,
    required List<Widget> children,
  }) {
    final chatTheme = context.chatTheme;
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: isMobile ? 320 : 660),
        // Content Layer: không dùng hiệu ứng nặng (blur, saveLayer) trên từng thẻ trong ListView để cuộn mượt 60/120fps
        child: Container(
          key: const Key('chat-ai-card'),
          decoration: BoxDecoration(
            color: chatTheme.aiBubbleBackground,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: chatTheme.aiBubbleBorder,
              width: 0.85,
            ),
          ),
          padding: EdgeInsets.fromLTRB(
            isMobile ? 12 : 16,
            10,
            isMobile ? 12 : 16,
            12,
          ),
          child: DefaultTextStyle.merge(
            style: TextStyle(color: chatTheme.aiBubbleText),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: children,
            ),
          ),
        ),
      ),
    );
  }

  /// Dòng trạng thái khi lượt đang chạy: chỉ có spinner nhỏ và tiêu đề, không có khung
  /// Tiêu đề dòng đang chạy. Khi đang ở block thinking và CLI báo số token suy nghĩ
  /// (Claude 5.x không gửi chữ thinking) thì hiện số token thay cho tên bước cuối.
  String _liveRunningTitle(ChatTurnStreamState stream, String? lastStepTitle) {
    if (stream.activeStepType == 'thinking' && stream.thinkingTokens > 0) {
      final tokens = _ChatCanvasViewState._formatTokensShort(
        stream.thinkingTokens,
      );
      return 'Đang suy nghĩ… ~$tokens token';
    }
    return lastStepTitle ?? 'Đang xử lý...';
  }

  Widget _buildRunningStatusRow(
    ColorScheme colorScheme,
    TextTheme textTheme,
    String title,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 13,
            height: 13,
            child: ThrottledSpinner(strokeWidth: 2, color: colorScheme.primary),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              title,
              style: textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResponseSegmentsColumn(
    BuildContext context,
    String text, {
    required int turnIndex,
    required bool isExpanded,
    required bool isMobile,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final seg in _parseResponseIntoGranularSegments(text))
          _buildGranularResponseSegmentWidget(
            context,
            seg,
            turnIndex: turnIndex,
            isExpanded: isExpanded,
            colorScheme: colorScheme,
            textTheme: textTheme,
            isMobile: isMobile,
          ),
      ],
    );
  }

  /// Thẻ phản hồi AI của một lượt:
  /// - Nút tool action ở giữa trên cùng (bấm để xem danh sách trong dialog)
  /// - Nội dung phản hồi căn trái (đang stream thì lấy nội dung live)
  /// - Thinking đang chạy nằm bên trong thẻ
  /// - Chip file thay đổi ở dưới cùng (bấm để xem trong dialog)
  Widget _buildAiTurnCard(
    BuildContext context,
    _ChatTurnGroup turn, {
    required bool isMobile,
    required bool isLastTurn,
    required ChatTurnStreamState? liveStream,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final liveText = liveStream?.streamingText ?? '';
    final responseText = liveText.trim().isNotEmpty
        ? liveText
        : turn.finalAgentResponse;
    final hasTools = turn.totalToolCount > 0 || turn.totalThoughtCount > 0;
    final isSessionRunning = widget.session?.status == AgentStatus.running;
    final lastStep = turn.agentSteps.isNotEmpty ? turn.agentSteps.last : null;

    final allLines = responseText.trimRight().split('\n');
    final canCollapse =
        responseText.isNotEmpty &&
        allLines.length > _ChatCanvasViewState._collapsedTailLines;
    final isExpanded = _expandedResponseTurns.contains(turn.turnIndex);
    final hiddenLines = canCollapse
        ? allLines.length - _ChatCanvasViewState._collapsedTailLines
        : 0;
    final responseModel = turn.agentSteps.reversed
        .map((s) => s.model)
        .firstWhere((m) => m.isNotEmpty, orElse: () => '');

    final card = _buildAiCardShell(
      colorScheme: colorScheme,
      isMobile: isMobile,
      children: [
        if (canCollapse)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () {
                _applyState(() {
                  if (isExpanded) {
                    _expandedResponseTurns.remove(turn.turnIndex);
                  } else {
                    _expandedResponseTurns.add(turn.turnIndex);
                  }
                });
              },
              icon: Icon(
                isExpanded
                    ? Icons.unfold_less_rounded
                    : Icons.unfold_more_rounded,
                size: 16,
              ),
              label: Text(
                isExpanded ? 'Thu gọn' : 'Xem toàn bộ ($hiddenLines dòng ẩn)',
                style: textTheme.labelSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        if (canCollapse) const SizedBox(height: 4),
        if (responseText.isNotEmpty)
          _AiResponseTypewriter(
            text: responseText,
            builder: (ctx, visibleText) => _buildResponseSegmentsColumn(
              ctx,
              canCollapse && !isExpanded
                  ? _lastLinesOf(
                      visibleText,
                      _ChatCanvasViewState._collapsedTailLines,
                    )
                  : visibleText.trimRight(),
              turnIndex: turn.turnIndex,
              isExpanded: isExpanded,
              isMobile: isMobile,
            ),
          ),
        if (liveStream != null) ...[
          const SizedBox(height: 8),
          _buildRunningStatusRow(
            colorScheme,
            textTheme,
            _liveRunningTitle(liveStream, lastStep?.vietnameseTitle),
          ),
        ] else if (isLastTurn && isSessionRunning && responseText.isEmpty)
          _buildRunningStatusRow(
            colorScheme,
            textTheme,
            lastStep?.vietnameseTitle ?? 'Đang xử lý...',
          ),
        if (hasTools || turn.groupedFiles.isNotEmpty) ...[
          const SizedBox(height: 10),
          // Wrap: trên màn hình hẹp nút tool action và chip file tự xuống dòng thay vì tràn
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (hasTools) _buildToolActionsButton(context, turn),
              if (turn.groupedFiles.isNotEmpty) _buildFilesChip(context, turn),
            ],
          ),
        ],
      ],
    );
    final shareFrom = turn.agentSteps.isNotEmpty
        ? turn.agentSteps.first.stepIndex
        : turn.userStep?.stepIndex;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        card,
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (responseModel.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4, left: 4),
                child: Tooltip(
                  message: responseModel,
                  child: Text(
                    _formatResponseModel(responseModel),
                    style: textTheme.labelSmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            if (shareFrom != null)
              _buildShareButton(context, shareFrom),
          ],
        ),
      ],
    );
  }

  /// Nút chia sẻ lịch sử từ bước [stepIndex] tới tin mới nhất; ẩn khi chưa có session
  Widget _buildShareButton(BuildContext context, int stepIndex) {
    final onShare = widget.onShareFromStep;
    if (onShare == null || widget.session == null) {
      return const SizedBox.shrink();
    }
    return IconButton(
      key: Key('chat-share-$stepIndex'),
      tooltip: 'Chia sẻ lịch sử từ đây',
      visualDensity: VisualDensity.compact,
      iconSize: 16,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 28),
      padding: EdgeInsets.zero,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
      icon: const Icon(Icons.ios_share_rounded),
      onPressed: () => onShare(stepIndex),
    );
  }

  /// Chip gọn ở dưới thẻ AI: bấm để mở dialog tool action
  Widget _buildToolActionsButton(BuildContext context, _ChatTurnGroup turn) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final parts = <String>[];
    if (turn.totalToolCount > 0) {
      final n = turn.totalToolCount;
      parts.add('$n tool ${n == 1 ? "action" : "actions"}');
    }
    if (turn.totalThoughtCount > 0) {
      parts.add('${turn.totalThoughtCount} thought');
    }
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => _showToolActionsDialog(context, turn),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: isDark
              ? Colors.white.withValues(alpha: 0.06)
              : Colors.black.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: colorScheme.outlineVariant.withAlpha(140),
            width: 0.8,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.build_circle_outlined,
              size: 14.5,
              color: colorScheme.primary,
            ),
            const SizedBox(width: 6),
            Text(
              parts.join(' • '),
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: colorScheme.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Chip gọn ở dưới cùng của thẻ AI: tóm tắt số file thay đổi, bấm để mở danh sách
  Widget _buildFilesChip(BuildContext context, _ChatTurnGroup turn) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final count = turn.groupedFiles.length;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => _showFilesChangedDialog(context, turn),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: isDark
              ? Colors.white.withValues(alpha: 0.06)
              : Colors.black.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: colorScheme.outlineVariant.withAlpha(140),
            width: 0.8,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.description_outlined,
              size: 14.5,
              color: colorScheme.primary,
            ),
            const SizedBox(width: 6),
            Text(
              '$count tệp thay đổi',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: colorScheme.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Ảnh đính kèm của một tin nhắn người dùng trong lịch sử. Bấm vào một ảnh để xem lớn.
class _UserAttachmentThumbs extends StatelessWidget {
  const _UserAttachmentThumbs({required this.urls, required this.baseUrl});

  final List<String> urls;
  final String baseUrl;

  static const double _size = 120;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return Wrap(
      alignment: WrapAlignment.end,
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final url in urls)
          GestureDetector(
            onTap: () => _showFullImage(context, url),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.network(
                '$baseUrl$url',
                width: _size,
                height: _size,
                fit: BoxFit.cover,
                cacheWidth: 240,
                loadingBuilder: (context, child, progress) {
                  if (progress == null) return child;
                  return SizedBox(
                    width: _size,
                    height: _size,
                    child: const Center(
                      child: ThrottledSpinner(strokeWidth: 2),
                    ),
                  );
                },
                errorBuilder: (context, error, stack) => Container(
                  width: _size,
                  height: _size,
                  alignment: Alignment.center,
                  color: scheme.surfaceContainerHighest,
                  child: Icon(
                    Icons.broken_image_outlined,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  void _showFullImage(BuildContext context, String url) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        child: InteractiveViewer(
          child: Image.network('$baseUrl$url', fit: BoxFit.contain),
        ),
      ),
    );
  }
}
