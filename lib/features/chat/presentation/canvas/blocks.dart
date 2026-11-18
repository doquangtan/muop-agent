part of '../chat_canvas_view.dart';

extension _CanvasExtBlocks on _ChatCanvasViewState {
  Widget _buildFlatBlockItem(
    BuildContext context,
    _ChatFlatBlock block, {
    required bool isMobile,
  }) {
    final colorScheme = Theme.of(context).colorScheme;

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

        return Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 14),
          child: Align(
            alignment: Alignment.centerRight,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: isMobile ? 320 : 660),
              child: Container(
                padding: EdgeInsets.symmetric(
                  horizontal: isMobile ? 14 : 18,
                  vertical: isMobile ? 10 : 12,
                ),
                decoration: BoxDecoration(
                  color: context.scheme.surfaceContainerHigh,
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(16),
                    topRight: Radius.circular(16),
                    bottomLeft: Radius.circular(16),
                    bottomRight: Radius.circular(4),
                  ),
                  border: Border.all(
                    color: context.scheme.outlineVariant.withAlpha(140),
                    width: 0.8,
                  ),
                ),
                child: LayoutBuilder(
                  builder: (context, boxConstraints) {
                    final textStyle = TextStyle(
                      fontSize: isMobile ? 13.5 : 14,
                      height: 1.45,
                      color: context.scheme.onSurface,
                      fontWeight: FontWeight.w500,
                    );

                    final textSpan = TextSpan(
                      text: promptContent,
                      style: textStyle,
                    );
                    final textPainter = TextPainter(
                      text: textSpan,
                      maxLines: 5,
                      textDirection: Directionality.of(context),
                    )..layout(maxWidth: boxConstraints.maxWidth);

                    final exceedsFiveLines = textPainter.didExceedMaxLines;

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          promptContent,
                          maxLines: (exceedsFiveLines && !isExpanded)
                              ? 5
                              : null,
                          overflow: (exceedsFiveLines && !isExpanded)
                              ? TextOverflow.ellipsis
                              : TextOverflow.visible,
                          style: textStyle,
                        ),
                        if (exceedsFiveLines) ...[
                          const SizedBox(height: 6),
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
                                      isExpanded ? 'Thu gọn' : '... More',
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        color: colorScheme.primary,
                                      ),
                                    ),
                                    const SizedBox(width: 2),
                                    Icon(
                                      isExpanded
                                          ? Icons.keyboard_arrow_up_rounded
                                          : Icons.keyboard_arrow_down_rounded,
                                      size: 16,
                                      color: colorScheme.primary,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    );
                  },
                ),
              ),
            ),
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
                child: SelectableText(
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
              lastStep?.vietnameseTitle ?? 'Đang xử lý...',
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
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: isMobile ? 320 : 660),
        child: Container(
          width: double.infinity,
          padding: EdgeInsets.fromLTRB(
            isMobile ? 12 : 16,
            10,
            isMobile ? 12 : 16,
            12,
          ),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: colorScheme.outlineVariant.withAlpha(150),
              width: 0.8,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: children,
          ),
        ),
      ),
    );
  }

  /// Dòng trạng thái khi lượt đang chạy: chỉ có spinner nhỏ và tiêu đề, không có khung
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
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: colorScheme.primary,
            ),
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
        if (liveStream != null) ...[
          const SizedBox(height: 8),
          _buildRunningStatusRow(
            colorScheme,
            textTheme,
            lastStep?.vietnameseTitle ?? 'Đang xử lý...',
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        card,
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
      ],
    );
  }

  /// Chip ở dưới thẻ AI (bên trái chip tệp thay đổi): bấm để mở dialog tool action
  Widget _buildToolActionsButton(BuildContext context, _ChatTurnGroup turn) {
    final colorScheme = Theme.of(context).colorScheme;
    final parts = <String>[];
    if (turn.totalToolCount > 0) {
      final n = turn.totalToolCount;
      parts.add('$n tool ${n == 1 ? "action" : "actions"}');
    }
    if (turn.totalThoughtCount > 0) {
      parts.add('${turn.totalThoughtCount} thought');
    }
    return ActionChip(
      avatar: Icon(
        Icons.build_circle_outlined,
        size: 16,
        color: colorScheme.primary,
      ),
      label: Text(parts.join(' • ')),
      onPressed: () => _showToolActionsDialog(context, turn),
    );
  }

  /// Chip ở dưới cùng của thẻ AI: tóm tắt số file thay đổi, bấm để mở danh sách
  Widget _buildFilesChip(BuildContext context, _ChatTurnGroup turn) {
    final colorScheme = Theme.of(context).colorScheme;
    final count = turn.groupedFiles.length;
    return ActionChip(
      avatar: Icon(
        Icons.description_outlined,
        size: 16,
        color: colorScheme.primary,
      ),
      label: Text('$count tệp thay đổi'),
      onPressed: () => _showFilesChangedDialog(context, turn),
    );
  }
}
