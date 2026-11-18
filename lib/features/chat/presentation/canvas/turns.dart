part of '../chat_canvas_view.dart';

extension _CanvasExtTurns on _ChatCanvasViewState {
  List<_ParsedResponseSegment> _parseResponseIntoGranularSegments(String raw) {
    final cached = _segmentCache[raw];
    if (cached != null) return cached;

    final result = <_ParsedResponseSegment>[];
    final regex = RegExp(r'```([a-zA-Z0-9_-]*)\n([\s\S]*?)```');
    int lastEnd = 0;

    void addTextParagraphs(String textChunk) {
      final trimmed = textChunk.trim();
      if (trimmed.isEmpty) return;
      // Chia các đoạn văn dài theo dòng trống (\n\n) để ListView виртуал hóa từng đoạn mượt mà
      final paragraphs = trimmed.split(RegExp(r'\n\s*\n'));
      final buffer = StringBuffer();
      for (final p in paragraphs) {
        if (buffer.length + p.length > 420 && buffer.isNotEmpty) {
          result.add(
            _ParsedResponseSegment(
              isCode: false,
              language: '',
              text: buffer.toString().trim(),
            ),
          );
          buffer.clear();
        }
        if (buffer.isNotEmpty) buffer.write('\n\n');
        buffer.write(p.trim());
      }
      if (buffer.isNotEmpty) {
        result.add(
          _ParsedResponseSegment(
            isCode: false,
            language: '',
            text: buffer.toString().trim(),
          ),
        );
      }
    }

    for (final match in regex.allMatches(raw)) {
      if (match.start > lastEnd) {
        addTextParagraphs(raw.substring(lastEnd, match.start));
      }
      result.add(
        _ParsedResponseSegment(
          isCode: true,
          language: (match.group(1) ?? '').trim(),
          text: (match.group(2) ?? '').trimRight(),
        ),
      );
      lastEnd = match.end;
    }

    if (lastEnd < raw.length) {
      addTextParagraphs(raw.substring(lastEnd));
    }

    if (_segmentCache.length > 150) {
      _segmentCache.clear();
    }
    _segmentCache[raw] = result;
    return result;
  }

  List<_ChatTurnGroup> _buildTurnGroups(
    List<AgentStep> steps,
    List<FileTouchRecord> allFileTouches,
  ) {
    final groups = <_ChatTurnGroup>[];
    AgentStep? currentUser;
    var currentAgentSteps = <AgentStep>[];

    void flushGroup() {
      if (currentUser == null && currentAgentSteps.isEmpty) return;
      final stepIndices = currentAgentSteps.map((s) => s.stepIndex).toSet();
      final matchedTouches = allFileTouches
          .where((f) => stepIndices.contains(f.stepIndex))
          .toList();
      groups.add(
        _ChatTurnGroup(
          turnIndex: groups.length + 1,
          userStep: currentUser,
          agentSteps: currentAgentSteps,
          groupedFiles: GroupedFileChange.groupRecords(matchedTouches),
        ),
      );
    }

    for (final step in steps) {
      if (step.type == 'USER_INPUT') {
        flushGroup();
        currentUser = step;
        currentAgentSteps = <AgentStep>[];
      } else {
        currentAgentSteps.add(step);
      }
    }
    flushGroup();

    return groups;
  }

  /// Phân tách toàn bộ các lượt hội thoại thành danh sách phẳng (`List<_ChatFlatBlock>`)
  /// theo thứ tự từ dưới đáy đi lên (`reverse: true`) để ListView.builder chỉ render
  /// đúng những mảnh nhỏ đang nằm trong khung nhìn.
  List<_ChatFlatBlock> _buildFlatBlocks({
    required List<_ChatTurnGroup> visibleTurns,
    required int remainingOlderTurns,
    required int totalTurnsCount,
  }) {
    final blocks = <_ChatFlatBlock>[];
    final stream = widget.activeStream;
    final streamRunning = stream != null && stream.isRunning;
    // Khi session đang chạy, thinking của stream nằm bên trong thẻ AI của lượt mới nhất
    final liveAttached =
        streamRunning &&
        visibleTurns.isNotEmpty &&
        widget.session?.status == AgentStatus.running;

    // Stream chưa gắn được vào lượt nào (hoặc có lỗi): thẻ AI đứng riêng ở đáy danh sách
    if (stream != null &&
        (streamRunning || stream.error.isNotEmpty) &&
        !liveAttached) {
      blocks.add(
        _ChatFlatBlock(
          kind: _ChatBlockKind.liveStreaming,
          keyId: 'stream_${stream.conversationId}',
          stream: stream,
        ),
      );
    }

    // Duyệt từ mới nhất đến cũ nhất (ListView reverse: block push trước nằm dưới cùng)
    for (int i = visibleTurns.length - 1; i >= 0; i--) {
      final turn = visibleTurns[i];
      final isNewestTurn = i == visibleTurns.length - 1;

      blocks.add(
        _ChatFlatBlock(
          kind: _ChatBlockKind.turnSpacing,
          keyId: 'space_${turn.turnIndex}',
        ),
      );

      // Thẻ phản hồi AI của lượt: tool action (trên giữa), nội dung (trái), file thay đổi (dưới)
      final hasAiContent =
          turn.finalAgentResponse.isNotEmpty ||
          turn.agentSteps.isNotEmpty ||
          turn.groupedFiles.isNotEmpty ||
          (isNewestTurn && liveAttached);
      if (hasAiContent) {
        blocks.add(
          _ChatFlatBlock(
            kind: _ChatBlockKind.aiTurnCard,
            keyId: 'ai_${turn.turnIndex}',
            turn: turn,
            isLastTurn: isNewestTurn,
          ),
        );
      }

      // (Trên cùng của lượt): Bong bóng câu hỏi của User
      if (turn.userStep != null) {
        blocks.add(
          _ChatFlatBlock(
            kind: _ChatBlockKind.userPromptBubble,
            keyId: 'user_${turn.turnIndex}',
            turn: turn,
          ),
        );
      }
    }

    // 3. Banner phân trang tải thêm các lượt hội thoại cũ ở đỉnh danh sách
    final hasMoreLocal = remainingOlderTurns > 0;
    final canFetchServer =
        widget.onLoadOlderHistory != null && !_hasLoadedAllServerHistory;

    if (hasMoreLocal || canFetchServer || _isLoadingMoreTurns) {
      blocks.add(
        _ChatFlatBlock(
          kind: _ChatBlockKind.loadMoreBanner,
          keyId: 'load_more_banner',
          remainingCount: remainingOlderTurns,
          loadedCount: visibleTurns.length,
          totalTurnsCount: totalTurnsCount,
        ),
      );
    }

    return blocks;
  }

  /// Đổi id model thô thành nhãn ngắn, vd. `claude-haiku-5-5` → `Claude Haiku 5.5`,
  /// `claude-haiku-4-5-20251001` → `Claude Haiku 4.5`
  String _formatResponseModel(String raw) {
    final id = raw.trim();
    if (!id.startsWith('claude-')) return id;
    final parts = id.split('-');
    if (parts.length < 2) return id;
    final family = parts[1].isEmpty
        ? ''
        : parts[1][0].toUpperCase() + parts[1].substring(1);
    final version = parts
        .skip(2)
        .where((p) => p.isNotEmpty && p.length <= 2 && int.tryParse(p) != null)
        .join('.');
    return version.isEmpty ? 'Claude $family' : 'Claude $family $version';
  }

  String _lastLinesOf(String text, int count) {
    final trimmed = text.trimRight();
    final lines = trimmed.split('\n');
    if (lines.length <= count) return trimmed;
    return lines.sublist(lines.length - count).join('\n');
  }
}
