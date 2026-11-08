import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/agent_models.dart';
import 'server_file_browser_sheet.dart';

class ChatCanvasView extends StatefulWidget {
  const ChatCanvasView({
    super.key,
    required this.session,
    required this.projects,
    required this.selectedProject,
    required this.availableAgents,
    required this.availableModels,
    required this.modelQuotas,
    required this.selectedAgent,
    required this.selectedModel,
    required this.isNewConversationMode,
    required this.isSending,
    required this.activeStream,
    this.lastDownloadedFilePath,
    required this.onSelectProject,
    required this.onSelectAgent,
    required this.onSelectModel,
    required this.onStartNewConversation,
    required this.onSendMessage,
    required this.onStopTurn,
    required this.onOpenFileBrowser,
    required this.onOpenChangesTab,
    required this.onInspectFileChange,
    required this.onDownloadFile,
    required this.onOpenDownloadedFile,
    this.onApprovePlan,
    this.onRejectPlan,
    this.onLoadOlderHistory,
    this.onOpenParallelFlow,
    this.onOpenCreateProject,
    this.onGitPush,
    this.onOpenGitHistory,
  });

  final ConversationSession? session;
  final List<ProjectWorkspace> projects;
  final ProjectWorkspace? selectedProject;
  final List<String> availableAgents;
  final List<String> availableModels;
  final List<ModelQuotaGroup> modelQuotas;
  final String selectedAgent;
  final String selectedModel;
  final bool isNewConversationMode;
  final bool isSending;
  final ChatTurnStreamState? activeStream;
  final String? lastDownloadedFilePath;
  final ValueChanged<ProjectWorkspace> onSelectProject;
  final ValueChanged<String> onSelectAgent;
  final ValueChanged<String> onSelectModel;
  final VoidCallback onStartNewConversation;
  final ValueChanged<String> onSendMessage;
  final VoidCallback onStopTurn;
  final VoidCallback onOpenFileBrowser;
  final VoidCallback onOpenChangesTab;
  final void Function(String filePath, GroupedFileChange? change)
      onInspectFileChange;
  final ValueChanged<String> onDownloadFile;
  final ValueChanged<String> onOpenDownloadedFile;
  final ValueChanged<PlanArtifactInfo>? onApprovePlan;
  final void Function(PlanArtifactInfo plan, String feedback)? onRejectPlan;
  final Future<bool> Function()? onLoadOlderHistory;
  final VoidCallback? onOpenParallelFlow;
  final VoidCallback? onOpenCreateProject;
  final Future<GitPushResponse> Function(String projectPath, String branch)?
      onGitPush;
  final VoidCallback? onOpenGitHistory;

  @override
  State<ChatCanvasView> createState() => _ChatCanvasViewState();
}

class _ChatTurnGroup {
  _ChatTurnGroup({
    required this.turnIndex,
    this.userStep,
    required this.agentSteps,
    required this.groupedFiles,
  });

  final int turnIndex;
  final AgentStep? userStep;
  final List<AgentStep> agentSteps;
  final List<GroupedFileChange> groupedFiles;

  String get finalAgentResponse {
    for (int i = agentSteps.length - 1; i >= 0; i--) {
      final s = agentSteps[i];
      if (s.type == 'PLANNER_RESPONSE' && s.content.trim().isNotEmpty) {
        return s.content.trim();
      }
    }
    return '';
  }

  List<AgentStep> get trajectorySteps {
    return agentSteps
        .where(
          (s) => s.thinking.trim().isNotEmpty || s.toolCalls.isNotEmpty,
        )
        .toList();
  }

  int get totalToolCount {
    var count = 0;
    for (final s in agentSteps) {
      count += s.toolCalls.length;
    }
    return count;
  }

  int get totalThoughtCount {
    var count = 0;
    for (final s in agentSteps) {
      if (s.thinking.trim().isNotEmpty) count++;
    }
    return count;
  }
}

enum _ChatBlockKind {
  turnSpacing,
  liveStreaming,
  filesChangedCard,
  aiRunningIndicator,
  aiResponseSegment,
  aiCollapseBanner,
  trajectorySection,
  userPromptBubble,
  loadMoreBanner,
}

class _ParsedResponseSegment {
  const _ParsedResponseSegment({
    required this.isCode,
    required this.language,
    required this.text,
  });

  final bool isCode;
  final String language;
  final String text;
}

/// Đại diện cho 1 phần tử phẳng (flat item) được render trực tiếp bởi ListView.builder
/// giúp danh sách cuộn mượt 60/120fps mà không phải dựng các Widget cây khổng lồ.
class _ChatFlatBlock {
  const _ChatFlatBlock({
    required this.kind,
    required this.keyId,
    this.turn,
    this.segment,
    this.stream,
    this.hiddenLineCount = 0,
    this.totalLineCount = 0,
    this.isExpanded = false,
    this.isLastTurn = false,
    this.remainingCount = 0,
    this.loadedCount = 0,
    this.totalTurnsCount = 0,
  });

  final _ChatBlockKind kind;
  final String keyId;
  final _ChatTurnGroup? turn;
  final _ParsedResponseSegment? segment;
  final ChatTurnStreamState? stream;
  final int hiddenLineCount;
  final int totalLineCount;
  final bool isExpanded;
  final bool isLastTurn;
  final int remainingCount;
  final int loadedCount;
  final int totalTurnsCount;
}

class _ChatCanvasViewState extends State<ChatCanvasView> {
  static const int _pageSize = 20;
  static const int _collapsedTailLines = 10;

  final TextEditingController _promptController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _inputFocusNode = FocusNode();

  int _loadedTurnCount = _pageSize;
  bool _isLoadingMoreTurns = false;
  bool _hasLoadedAllServerHistory = false;
  bool _showScrollToBottomBtn = false;
  bool _isTaskRunningExpanded = false;
  String? _dismissedGitAheadHash;
  bool _isPushingGit = false;

  /// Lưu trạng thái mở rộng (show full) của từng đoạn response theo turnIndex
  final Set<int> _expandedResponseTurns = {};

  /// Cache danh sách các đoạn văn/code đã tách để không phải regex lại khi cuộn
  final Map<String, List<_ParsedResponseSegment>> _segmentCache = {};

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToBottom(animated: false);
    });
  }

  @override
  void didUpdateWidget(covariant ChatCanvasView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldId = oldWidget.session?.id;
    final newId = widget.session?.id;
    if (oldId != newId ||
        oldWidget.isNewConversationMode != widget.isNewConversationMode) {
      _loadedTurnCount = _pageSize;
      _isLoadingMoreTurns = false;
      _hasLoadedAllServerHistory = false;
      _expandedResponseTurns.clear();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToBottom(animated: false);
      });
    } else {
      // Khi đang ở trong cùng phiên hội thoại mà có thêm bước/tin nhắn mới:
      final oldStepsCount = oldWidget.session?.steps.length ?? 0;
      final newStepsCount = widget.session?.steps.length ?? 0;
      if (newStepsCount > oldStepsCount && !_isLoadingMoreTurns) {
        // Chỉ tự động cuộn xuống đáy nếu người dùng đang ở gần đáy (pixels < 120) hoặc đang gửi prompt
        if (_scrollController.hasClients &&
            _scrollController.position.pixels < 120) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_scrollController.hasClients) {
              _scrollToBottom(animated: true);
            }
          });
        }
      }
    }
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _promptController.dispose();
    _scrollController.dispose();
    _inputFocusNode.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;

    // Với ListView(reverse: true), pixels = 0.0 là đáy (đoạn chat mới nhất).
    final shouldShowBtn = pos.pixels > 240;
    if (shouldShowBtn != _showScrollToBottomBtn) {
      setState(() => _showScrollToBottomBtn = shouldShowBtn);
    }

    // Khi người dùng cuộn lên trên (gần chạm đỉnh maxScrollExtent): Tự động nạp thêm dữ liệu cũ
    if (pos.pixels >= pos.maxScrollExtent - 240 && !_isLoadingMoreTurns) {
      _loadOlderTurnsPage();
    }
  }

  Future<void> _loadOlderTurnsPage() async {
    final session = widget.session;
    if (session == null || widget.isNewConversationMode || _isLoadingMoreTurns) {
      return;
    }

    final totalTurns =
        _buildTurnGroups(session.steps, session.filesTouched).length;

    // 1. Nếu còn turn cũ trong bộ nhớ cục bộ, nạp thêm 20 turn nữa
    if (_loadedTurnCount < totalTurns) {
      setState(() => _isLoadingMoreTurns = true);
      await Future.delayed(const Duration(milliseconds: 100));
      if (!mounted) return;
      setState(() {
        _loadedTurnCount = math.min(totalTurns, _loadedTurnCount + _pageSize);
        _isLoadingMoreTurns = false;
      });
      return;
    }

    // 2. Nếu đã hiển thị hết turn cục bộ, gọi server nạp thêm một trang (30 steps cũ hơn)
    if (widget.onLoadOlderHistory != null && !_hasLoadedAllServerHistory) {
      setState(() => _isLoadingMoreTurns = true);
      try {
        final hasMore = await widget.onLoadOlderHistory!();
        if (mounted) {
          final updatedTotalTurns = _buildTurnGroups(
            widget.session?.steps ?? const [],
            widget.session?.filesTouched ?? const [],
          ).length;

          setState(() {
            if (updatedTotalTurns > totalTurns) {
              _loadedTurnCount = math.min(
                updatedTotalTurns,
                _loadedTurnCount + _pageSize,
              );
            }
            if (!hasMore) {
              _hasLoadedAllServerHistory = true;
            }
            _isLoadingMoreTurns = false;
          });
        }
      } catch (_) {
        if (mounted) {
          setState(() => _isLoadingMoreTurns = false);
        }
      }
    }
  }

  void _scrollToBottom({bool animated = true}) {
    if (!_scrollController.hasClients) return;
    if (animated) {
      _scrollController.animateTo(
        0.0,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
      );
    } else {
      _scrollController.jumpTo(0.0);
    }
  }

  void _handleSend() {
    final text = _promptController.text.trim();
    if (text.isEmpty || widget.isSending) return;
    _promptController.clear();
    widget.onSendMessage(text);
    Future.delayed(const Duration(milliseconds: 100), () {
      _scrollToBottom(animated: true);
    });
  }

  String _formatModelLabel(String modelId) {
    switch (modelId) {
      case 'default':
      case 'gemini-3.8-flash-high':
        return 'Gemini 3.8 Flash (High)';
      case 'gemini-3.8-flash-medium':
        return 'Gemini 3.8 Flash (Medium)';
      case 'claude-opus-5-5-high':
        return 'Claude Opus 5.5 (High)';
      case 'claude-sonnet-5-5-high':
        return 'Claude Sonnet 5.5 (High)';
      case 'claude-sonnet-5-5-medium':
        return 'Claude Sonnet 5.5 (Medium)';
      default:
        return modelId;
    }
  }

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

    // 1. Luồng đang stream trực tiếp ở sát đáy
    if (widget.activeStream != null) {
      blocks.add(
        _ChatFlatBlock(
          kind: _ChatBlockKind.liveStreaming,
          keyId: 'stream_${widget.activeStream!.conversationId}',
          stream: widget.activeStream,
        ),
      );
    }

    // 2. Duyệt từng lượt hội thoại từ mới nhất đến cũ nhất
    // Vì ListView có `reverse: true`, phần tử push trước sẽ nằm ở dưới, phần tử push sau nằm ở trên.
    for (int i = visibleTurns.length - 1; i >= 0; i--) {
      final turn = visibleTurns[i];
      final isNewestTurn =
          (i == visibleTurns.length - 1) && widget.activeStream == null;

      blocks.add(
        _ChatFlatBlock(
          kind: _ChatBlockKind.turnSpacing,
          keyId: 'space_${turn.turnIndex}',
        ),
      );

      // (Dưới cùng của Turn): Card nhóm các tệp thay đổi (Files Changed)
      if (turn.groupedFiles.isNotEmpty) {
        blocks.add(
          _ChatFlatBlock(
            kind: _ChatBlockKind.filesChangedCard,
            keyId: 'files_${turn.turnIndex}',
            turn: turn,
          ),
        );
      }

      // (Giữa của Turn): Nội dung phản hồi AI được chia nhỏ thành từng đoạn văn / khối code
      final finalResponse = turn.finalAgentResponse;
      if (finalResponse.isNotEmpty) {
        final allLines = finalResponse.trimRight().split('\n');
        final canCollapse = allLines.length > _collapsedTailLines;
        final isExpanded = _expandedResponseTurns.contains(turn.turnIndex);
        final hiddenLines =
            canCollapse ? allLines.length - _collapsedTailLines : 0;

        final displayedText = (canCollapse && !isExpanded)
            ? allLines
                .sublist(allLines.length - _collapsedTailLines)
                .join('\n')
            : finalResponse;

        final segments = _parseResponseIntoGranularSegments(displayedText);

        // Push các segment theo thứ tự ngược để khi reverse: true sẽ hiển thị đúng từ trên xuống dưới
        for (int sIdx = segments.length - 1; sIdx >= 0; sIdx--) {
          blocks.add(
            _ChatFlatBlock(
              kind: _ChatBlockKind.aiResponseSegment,
              keyId: 'seg_${turn.turnIndex}_${isExpanded ? "full" : "tail"}_$sIdx',
              turn: turn,
              segment: segments[sIdx],
              isExpanded: isExpanded,
            ),
          );
        }

        if (canCollapse) {
          blocks.add(
            _ChatFlatBlock(
              kind: _ChatBlockKind.aiCollapseBanner,
              keyId: 'collapse_${turn.turnIndex}',
              turn: turn,
              hiddenLineCount: hiddenLines,
              totalLineCount: allLines.length,
              isExpanded: isExpanded,
            ),
          );
        }
      } else if (isNewestTurn &&
          widget.session?.status == AgentStatus.running &&
          turn.agentSteps.isNotEmpty) {
        blocks.add(
          _ChatFlatBlock(
            kind: _ChatBlockKind.aiRunningIndicator,
            keyId: 'running_${turn.turnIndex}',
            turn: turn,
          ),
        );
      }

      // (Phía trên phản hồi AI): Khối tiến trình suy luận & công cụ (Trajectory)
      if (turn.trajectorySteps.isNotEmpty) {
        blocks.add(
          _ChatFlatBlock(
            kind: _ChatBlockKind.trajectorySection,
            keyId: 'traj_${turn.turnIndex}',
            turn: turn,
            isLastTurn: isNewestTurn,
          ),
        );
      }

      // (Trên cùng của Turn): Bong bóng câu hỏi của User
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
    } else if (totalTurnsCount > _pageSize) {
      blocks.add(
        _ChatFlatBlock(
          kind: _ChatBlockKind.loadMoreBanner,
          keyId: 'load_more_banner_done',
          remainingCount: 0,
          loadedCount: visibleTurns.length,
          totalTurnsCount: totalTurnsCount,
        ),
      );
    }

    return blocks;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isMobile = MediaQuery.sizeOf(context).width < 760;
    final session = widget.session;
    final isTurnRunning = !widget.isNewConversationMode &&
        (session?.isInterrupted != true) &&
        (widget.isSending ||
            (widget.activeStream != null &&
                widget.activeStream!.isRunning &&
                widget.activeStream!.activeStepType != 'interrupted') ||
            (session != null && session.status == AgentStatus.running));

    final allTurns = (!widget.isNewConversationMode && session != null)
        ? _buildTurnGroups(session.steps, session.filesTouched)
        : const <_ChatTurnGroup>[];

    final int startIdx = math.max(0, allTurns.length - _loadedTurnCount);
    final visibleTurns = allTurns.sublist(startIdx);
    final int remainingOlderTurns = startIdx;

    final flatBlocks = _buildFlatBlocks(
      visibleTurns: visibleTurns,
      remainingOlderTurns: remainingOlderTurns,
      totalTurnsCount: allTurns.length,
    );

    return Column(
      children: [
        // 1. Luồng tin nhắn đã được làm phẳng (flattened) & ảo hóa bằng ListView.builder
        Expanded(
          child: flatBlocks.isEmpty
              ? _buildEmptyAntigravityWelcome(context, isMobile)
              : Stack(
                  children: [
                    SelectionArea(
                      child: ListView.builder(
                        controller: _scrollController,
                        reverse: true,
                        addAutomaticKeepAlives: false,
                        padding: EdgeInsets.fromLTRB(
                          isMobile ? 10 : 28,
                          16,
                          isMobile ? 10 : 28,
                          12,
                        ),
                        itemCount: flatBlocks.length,
                        itemBuilder: (context, index) {
                          final block = flatBlocks[index];
                          return RepaintBoundary(
                            key: ValueKey(block.keyId),
                            child: Center(
                              child: ConstrainedBox(
                                constraints:
                                    const BoxConstraints(maxWidth: 840),
                                child: _buildFlatBlockItem(
                                  context,
                                  block,
                                  isMobile: isMobile,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),

                    if (_showScrollToBottomBtn)
                      Positioned(
                        right: isMobile ? 14 : 28,
                        bottom: 10,
                        child: FloatingActionButton.small(
                          tooltip: 'Cuộn xuống đoạn chat mới nhất',
                          backgroundColor: colorScheme.primaryContainer,
                          foregroundColor: colorScheme.onPrimaryContainer,
                          onPressed: () => _scrollToBottom(animated: true),
                          child: const Icon(
                            Icons.arrow_downward_rounded,
                            size: 18,
                          ),
                        ),
                      ),
                  ],
                ),
        ),

        // 2. BOTTOM DOCK:
        //    [Trên]   Task Running Panel (nằm phía trên khung chat)
        //    [Giữa]   Thanh % Usage (Limit Tuần / Limit Giờ chuẩn Antigravity)
        //    [Dưới]   Khung nhập Chat (Composer Box)
        _buildBottomDockStack(context, isMobile, isTurnRunning),
      ],
    );
  }

  Widget _buildFlatBlockItem(
    BuildContext context,
    _ChatFlatBlock block, {
    required bool isMobile,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    switch (block.kind) {
      case _ChatBlockKind.turnSpacing:
        return SizedBox(height: isMobile ? 14 : 20);

      case _ChatBlockKind.liveStreaming:
        return _buildLiveStreamingBlock(context, block.stream!);

      case _ChatBlockKind.userPromptBubble:
        final userStep = block.turn!.userStep!;
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
                  color: const Color(0xFF27272A),
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(16),
                    topRight: Radius.circular(16),
                    bottomLeft: Radius.circular(16),
                    bottomRight: Radius.circular(4),
                  ),
                  border: Border.all(
                    color: const Color(0xFF3F3F46).withAlpha(140),
                    width: 0.8,
                  ),
                ),
                child: Text(
                  userStep.content,
                  style: TextStyle(
                    fontSize: isMobile ? 13.5 : 14,
                    height: 1.45,
                    color: const Color(0xFFF4F4F5),
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
          ),
        );

      case _ChatBlockKind.trajectorySection:
        final turn = block.turn!;
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: _AntigravityTrajectorySection(
            steps: turn.trajectorySteps,
            thoughtCount: turn.totalThoughtCount,
            toolCount: turn.totalToolCount,
            initiallyExpanded:
                block.isLastTurn && turn.finalAgentResponse.isEmpty,
            onTapStep: (step) => _showStepDetailModal(context, step),
            onDownloadFile: widget.onDownloadFile,
          ),
        );

      case _ChatBlockKind.aiCollapseBanner:
        final turnIndex = block.turn!.turnIndex;
        final isExpanded = block.isExpanded;
        return Padding(
          padding: const EdgeInsets.only(top: 6, bottom: 8),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () {
              setState(() {
                if (isExpanded) {
                  _expandedResponseTurns.remove(turnIndex);
                } else {
                  _expandedResponseTurns.add(turnIndex);
                }
              });
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8.5),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: isExpanded
                      ? [
                          colorScheme.surfaceContainerLow,
                          colorScheme.surfaceContainer,
                        ]
                      : [
                          colorScheme.primaryContainer.withAlpha(90),
                          colorScheme.surfaceContainerHigh,
                        ],
                ),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: isExpanded
                      ? colorScheme.outlineVariant
                      : colorScheme.primary.withAlpha(130),
                  width: 0.9,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    isExpanded
                        ? Icons.unfold_less_rounded
                        : Icons.unfold_more_rounded,
                    size: 16.5,
                    color: colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      isExpanded
                          ? 'Đang xem toàn bộ phản hồi (${block.totalLineCount} dòng) • Chạm để thu gọn'
                          : 'Đã thu gọn (${block.hiddenLineCount} dòng phía trên) • Chạm để xem toàn bộ • Đang hiện $_collapsedTailLines dòng cuối',
                      style: textTheme.labelSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: colorScheme.primary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );

      case _ChatBlockKind.aiResponseSegment:
        final seg = block.segment!;
        final turnIndex = block.turn!.turnIndex;
        return _buildGranularResponseSegmentWidget(
          context,
          seg,
          turnIndex: turnIndex,
          isExpanded: block.isExpanded,
          colorScheme: colorScheme,
          textTheme: textTheme,
          isMobile: isMobile,
        );

      case _ChatBlockKind.aiRunningIndicator:
        final turn = block.turn!;
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
                  turn.agentSteps.last.vietnameseTitle,
                  style: textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        );

      case _ChatBlockKind.filesChangedCard:
        final turn = block.turn!;
        return Padding(
          padding: const EdgeInsets.only(top: 6),
          child: _GroupedFilesChangedCard(
            groupedFiles: turn.groupedFiles,
            isMobile: isMobile,
            onInspectFileChange: widget.onInspectFileChange,
            onDownloadFile: widget.onDownloadFile,
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
          color: const Color(0xFF141416),
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: const Color(0xFF2E2E34), width: 0.8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
              decoration: BoxDecoration(
                color: const Color(0xFF1F1F24),
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(8.2),
                ),
                border: const Border(
                  bottom: BorderSide(color: Color(0xFF2E2E34), width: 0.8),
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
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12.5,
                    height: 1.5,
                    color: Color(0xFFE4E4E7),
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
            ? () => setState(() => _expandedResponseTurns.add(turnIndex))
            : null,
        onLinkTap: (url, label) => _handleLinkTap(url, label),
        isMobile: isMobile,
      ),
    );
  }

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
    final pendingPlans = widget.session?.pendingPlans
            .where((p) => p.requestFeedback)
            .toList() ??
        const [];

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
                    child: _buildPlanApprovalCard(context, plan, isMobile),
                  ),
              ],

              // [0.3] CẢNH BÁO TIẾN TRÌNH AGY BỊ GIÁN ĐOẠN (SERVER RESTART / CRASH)
              if (widget.session != null &&
                  (widget.session!.isInterrupted ||
                      widget.session!.status == AgentStatus.interrupted))
                _buildInterruptedNoticeBanner(context, widget.session!, isMobile),

              // [0.5] KHUNG XÁC NHẬN PUSH LÊN SERVER SAU KHI AGENT COMMIT XONG
              () {
                final gitSync = widget.session?.gitSyncStatus ??
                    widget.selectedProject?.gitSyncStatus ??
                    widget.projects
                        .where((p) =>
                            p.name == widget.session?.projectName ||
                            p.path == widget.session?.projectPath)
                        .firstOrNull
                        ?.gitSyncStatus;
                final showGitPushPrompt = gitSync != null &&
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
              _buildModelUsageMiddleBar(context, isMobile),
              const SizedBox(height: 5),

              // [3] PHẦN DƯỚI: KHUNG NHẬP CHAT (CHAT COMPOSER)
              _buildAntigravityComposer(context, isMobile, isTurnRunning),
            ],
          ),
        ),
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
        color: Colors.amber.withAlpha(25),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: Colors.amber.shade700.withAlpha(120),
          width: 1,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.warning_amber_rounded,
            size: 18,
            color: Colors.amber.shade700,
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
                    color: Colors.amber.shade900,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  session.interruptedReason ??
                      'Lượt xử lý đã dừng do máy chủ khởi động lại hoặc agy CLI bị ngắt đột ngột. Bạn có thể gửi tin nhắn tiếp theo để tiếp tục bình thường.',
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
          color: Colors.amber.shade700.withAlpha(160),
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
                  color: Colors.amber.shade700.withAlpha(35),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.cloud_upload_outlined,
                  size: 16,
                  color: Colors.amber.shade700,
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
                  setState(
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
                            gitSync.branch.isNotEmpty
                                ? gitSync.branch
                                : 'main',
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
                  setState(
                    () => _dismissedGitAheadHash = gitSync.lastCommitHash,
                  );
                },
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.teal.shade700,
                  foregroundColor: Colors.white,
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
                    ? const SizedBox(
                        width: 13,
                        height: 13,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            Colors.white,
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
                        setState(() => _isPushingGit = true);
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
                                    const Icon(
                                      Icons.check_circle_rounded,
                                      color: Colors.white,
                                      size: 18,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        res.message.isNotEmpty
                                            ? res.message
                                            : 'Đã push thành công lên máy chủ từ xa!',
                                      ),
                                    ),
                                  ],
                                ),
                                backgroundColor: Colors.teal.shade700,
                                behavior: SnackBarBehavior.floating,
                              ),
                            );
                            setState(
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
                                backgroundColor:
                                    Theme.of(context).colorScheme.error,
                                behavior: SnackBarBehavior.floating,
                              ),
                            );
                          }
                        } catch (e) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('Lỗi: $e'),
                                backgroundColor:
                                    Theme.of(context).colorScheme.error,
                                behavior: SnackBarBehavior.floating,
                              ),
                            );
                          }
                        } finally {
                          if (mounted) {
                            setState(() => _isPushingGit = false);
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

  /// [0] PLAN APPROVAL CARD — Hiển thị kế hoạch cần duyệt với 3 hành động:
  /// 👁️ Xem chi tiết | ✏️ Góp ý / Sửa | ✅ Duyệt Kế Hoạch (Proceed)
  Widget _buildPlanApprovalCard(
    BuildContext context,
    PlanArtifactInfo plan,
    bool isMobile,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withAlpha(220),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Colors.amber.shade700.withAlpha(210),
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.amber.shade900.withAlpha(25),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Row 1: Status Icon + Title + Chip
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(5),
                decoration: BoxDecoration(
                  color: Colors.amber.withAlpha(40),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Icon(
                  Icons.assignment_outlined,
                  size: 16,
                  color: Colors.amber.shade700,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Kế hoạch đang chờ duyệt: ${plan.fileName}',
                  style: textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: colorScheme.onSurface,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.amber.withAlpha(35),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: Colors.amber.shade700.withAlpha(120),
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
                        color: Colors.amber.shade700,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      'Chờ duyệt',
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w600,
                        color: Colors.amber.shade700,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),

          // Row 2: Summary description
          if (plan.summary.isNotEmpty) ...[
            const SizedBox(height: 5),
            Padding(
              padding: const EdgeInsets.only(left: 29),
              child: Text(
                plan.summary,
                style: textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                  fontSize: 12,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
          const SizedBox(height: 8),

          // Row 3: Action Buttons
          isMobile
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 6,
                              ),
                              visualDensity: VisualDensity.compact,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                            icon:
                                const Icon(Icons.visibility_outlined, size: 14),
                            label: const Text(
                              'Xem chi tiết',
                              style: TextStyle(fontSize: 12),
                            ),
                            onPressed: () =>
                                _showPlanDetailModal(context, plan, isMobile),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 6,
                              ),
                              visualDensity: VisualDensity.compact,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                            icon:
                                const Icon(Icons.edit_note_outlined, size: 14),
                            label: const Text(
                              'Góp ý / Sửa',
                              style: TextStyle(fontSize: 12),
                            ),
                            onPressed: () =>
                                _showPlanFeedbackDialog(context, plan),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.green.shade700,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        visualDensity: VisualDensity.compact,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      icon: const Icon(Icons.check_circle_outline, size: 15),
                      label: const Text(
                        'Duyệt Kế Hoạch (Proceed)',
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      onPressed: () => widget.onApprovePlan?.call(plan),
                    ),
                  ],
                )
              : Row(
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
                      icon: const Icon(Icons.visibility_outlined, size: 14),
                      label: const Text(
                        'Xem chi tiết',
                        style: TextStyle(fontSize: 12),
                      ),
                      onPressed: () =>
                          _showPlanDetailModal(context, plan, isMobile),
                    ),
                    const SizedBox(width: 8),
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
                      icon: const Icon(Icons.edit_note_outlined, size: 14),
                      label: const Text(
                        'Góp ý / Sửa',
                        style: TextStyle(fontSize: 12),
                      ),
                      onPressed: () => _showPlanFeedbackDialog(context, plan),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.green.shade700,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        visualDensity: VisualDensity.compact,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      icon: const Icon(Icons.check_circle_outline, size: 15),
                      label: const Text(
                        'Duyệt Kế Hoạch (Proceed)',
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      onPressed: () => widget.onApprovePlan?.call(plan),
                    ),
                  ],
                ),
        ],
      ),
    );
  }

  void _showPlanDetailModal(
    BuildContext context,
    PlanArtifactInfo plan,
    bool isMobile,
  ) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        final colorScheme = Theme.of(ctx).colorScheme;
        return DraggableScrollableSheet(
          initialChildSize: 0.85,
          minChildSize: 0.45,
          maxChildSize: 0.95,
          expand: false,
          builder: (sheetContext, scrollController) {
            return Column(
              children: [
                Center(
                  child: Container(
                    margin: const EdgeInsets.only(top: 10, bottom: 6),
                    width: 40,
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
                          color: colorScheme.primaryContainer,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(
                          Icons.assignment_outlined,
                          size: 20,
                          color: colorScheme.onPrimaryContainer,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              plan.fileName,
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.bold,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              plan.summary.isNotEmpty
                                  ? plan.summary
                                  : 'Kế hoạch triển khai kiến trúc',
                              style: TextStyle(
                                fontSize: 11.5,
                                color: colorScheme.onSurfaceVariant,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () => Navigator.of(ctx).pop(),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: SelectionArea(
                    child: SingleChildScrollView(
                      controller: scrollController,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      child: _AntigravityMarkdownSegment(
                        text: plan.content.isNotEmpty
                            ? plan.content
                            : '# ${plan.fileName}\n\n*Không có nội dung chi tiết.*',
                        isExpanded: true,
                        isMobile: isMobile,
                        onLinkTap: (url, label) => _handleLinkTap(url, label),
                      ),
                    ),
                  ),
                ),
                const Divider(height: 1),
                Container(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
                  color: colorScheme.surfaceContainerLow,
                  child: SafeArea(
                    top: false,
                    child: Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              side: BorderSide(color: colorScheme.outline),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                            icon: const Icon(Icons.edit_note_rounded, size: 18),
                            label: const Text('Góp ý / Sửa'),
                            onPressed: () {
                              Navigator.of(ctx).pop();
                              _showPlanFeedbackDialog(context, plan);
                            },
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 2,
                          child: FilledButton.icon(
                            style: FilledButton.styleFrom(
                              backgroundColor: Colors.green.shade700,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                            icon: const Icon(
                              Icons.check_circle_outline,
                              size: 18,
                            ),
                            label: const Text(
                              'Duyệt Kế Hoạch (Proceed)',
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                            onPressed: () {
                              Navigator.of(ctx).pop();
                              widget.onApprovePlan?.call(plan);
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showPlanFeedbackDialog(
    BuildContext context,
    PlanArtifactInfo plan,
  ) {
    final textController = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (ctx) {
        final colorScheme = Theme.of(ctx).colorScheme;
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Row(
            children: [
              Icon(Icons.edit_note_rounded, color: colorScheme.primary),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Yêu cầu sửa đổi Kế hoạch',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Nhập các điểm bạn muốn AI điều chỉnh trong kế hoạch [${plan.fileName}]:',
                style: TextStyle(
                  fontSize: 12.5,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: textController,
                maxLines: 4,
                autofocus: true,
                decoration: InputDecoration(
                  hintText:
                      'Ví dụ: Cần bổ sung kiểm tra tồn kho hoặc cấu trúc outbox...',
                  hintStyle: TextStyle(
                    fontSize: 12,
                    color: colorScheme.outline,
                  ),
                  filled: true,
                  fillColor:
                      colorScheme.surfaceContainerHighest.withAlpha(120),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: colorScheme.outlineVariant),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide:
                        BorderSide(color: colorScheme.primary, width: 1.5),
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Hủy'),
            ),
            FilledButton.icon(
              icon: const Icon(Icons.send_rounded, size: 16),
              label: const Text('Gửi phản hồi'),
              onPressed: () {
                final feedback = textController.text.trim();
                Navigator.of(ctx).pop();
                widget.onRejectPlan?.call(plan, feedback);
              },
            ),
          ],
        );
      },
    );
  }

  /// [1] TASK RUNNING PANEL — Nằm phía trên thanh % Model Usage và Khung Chat
  /// Hộp thoại chi tiết xem Agent đang chạy bên trong đang làm gì
  void _showRunningAgentDetailModal(
    BuildContext context,
    SubagentLane lane,
  ) {
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
                          color: Colors.orange.withAlpha(35),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: Colors.orange.withAlpha(120),
                          ),
                        ),
                        child: const Icon(
                          Icons.hub_rounded,
                          size: 20,
                          color: Colors.orange,
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
                                    color: Colors.orange.withAlpha(30),
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(
                                      color: Colors.orange.withAlpha(100),
                                      width: 0.8,
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Container(
                                        width: 6,
                                        height: 6,
                                        decoration: const BoxDecoration(
                                          color: Colors.orange,
                                          shape: BoxShape.circle,
                                        ),
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        'ĐANG CHẠY',
                                        style: textTheme.labelSmall?.copyWith(
                                          fontSize: 9,
                                          fontWeight: FontWeight.w800,
                                          color: Colors.orange,
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
                                const Icon(
                                  Icons.pending_actions_rounded,
                                  size: 16,
                                  color: Colors.orange,
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
                                        color:
                                            colorScheme.primary.withAlpha(80),
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
                                valueColor:
                                    const AlwaysStoppedAnimation<Color>(
                                  Colors.orange,
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
                            const Icon(
                              Icons.folder_outlined,
                              size: 16,
                              color: Colors.teal,
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
                                      const Icon(
                                        Icons.description_outlined,
                                        size: 13,
                                        color: Colors.teal,
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
                                color: Colors.orange,
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
                                  color: colorScheme.outlineVariant.withAlpha(60),
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
                                      color: Colors.orange,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Expanded(
                                              child: Text(
                                                st.vietnameseTitle.isNotEmpty
                                                    ? st.vietnameseTitle
                                                    : (st.toolCalls.isNotEmpty
                                                        ? st.toolCalls.first.name
                                                        : st.type),
                                                style: textTheme.labelMedium?.copyWith(
                                                  fontWeight: FontWeight.w700,
                                                ),
                                              ),
                                            ),
                                            Text(
                                              '#${st.stepIndex}',
                                              style: TextStyle(
                                                fontFamily: 'monospace',
                                                fontSize: 10,
                                                color: colorScheme.onSurfaceVariant,
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
                                            style: textTheme.bodySmall?.copyWith(
                                              color: colorScheme.onSurfaceVariant,
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
                                    color: colorScheme.onSurfaceVariant.withAlpha(120),
                                  ),
                                ],
                              ),
                            ),
                          );
                        }),
                      ],

                      const SizedBox(height: 20),
                      if (widget.onOpenParallelFlow != null &&
                          (widget.session?.hasParallelFlow == true ||
                              ((widget.session?.projectName == 'muop-erp-server' ||
                                      widget.session?.projectName == 'muop-erp-app') &&
                                  (widget.session?.subagentLanes.length ?? 0) > 1)))
                        OutlinedButton.icon(
                          onPressed: () {
                            Navigator.of(ctx).pop();
                            widget.onOpenParallelFlow!();
                          },
                          icon: const Icon(
                            Icons.alt_route_rounded,
                            size: 16,
                            color: Colors.deepPurpleAccent,
                          ),
                          label: const Text(
                            'Xem toàn bộ Sơ đồ Luồng Parallel Agent',
                            style: TextStyle(color: Colors.deepPurpleAccent),
                          ),
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(
                              color: Colors.deepPurpleAccent,
                            ),
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

  /// Hộp thoại chi tiết xem Coordinator đang chạy làm gì
  void _showRunningCoordinatorDetailModal(
    BuildContext context,
  ) {
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
                                    color: Colors.green.withAlpha(30),
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(
                                      color: Colors.green.withAlpha(100),
                                      width: 0.8,
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Container(
                                        width: 6,
                                        height: 6,
                                        decoration: const BoxDecoration(
                                          color: Colors.green,
                                          shape: BoxShape.circle,
                                        ),
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        'ĐANG CHẠY',
                                        style: textTheme.labelSmall?.copyWith(
                                          fontSize: 9,
                                          fontWeight: FontWeight.w800,
                                          color: Colors.green,
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
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: colorScheme.surfaceContainerHigh,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: colorScheme.outlineVariant.withAlpha(60),
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Yêu cầu của bạn (Prompt):',
                                style: textTheme.labelSmall?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                stream.userPrompt,
                                style: textTheme.bodyMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
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
                        final coordSteps = allSteps.where((s) => s.agentName == 'Coordinator').toList();
                        final displaySteps = coordSteps.isNotEmpty ? coordSteps : allSteps;

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
                                      color: colorScheme.outlineVariant.withAlpha(60),
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
                                          color: colorScheme.primary,
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Row(
                                              children: [
                                                Expanded(
                                                  child: Text(
                                                    st.vietnameseTitle.isNotEmpty
                                                        ? st.vietnameseTitle
                                                        : (st.toolCalls.isNotEmpty
                                                            ? st.toolCalls.first.name
                                                            : st.type),
                                                    style: textTheme.labelMedium?.copyWith(
                                                      fontWeight: FontWeight.w700,
                                                    ),
                                                  ),
                                                ),
                                                Text(
                                                  '#${st.stepIndex}',
                                                  style: TextStyle(
                                                    fontFamily: 'monospace',
                                                    fontSize: 10,
                                                    color: colorScheme.onSurfaceVariant,
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
                                                style: textTheme.bodySmall?.copyWith(
                                                  color: colorScheme.onSurfaceVariant,
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
                                        color: colorScheme.onSurfaceVariant.withAlpha(120),
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
                          backgroundColor: Colors.redAccent,
                          foregroundColor: Colors.white,
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

    final groupedSessionFiles =
        (!widget.isNewConversationMode && session != null)
            ? GroupedFileChange.groupRecords(session.filesTouched)
            : const <GroupedFileChange>[];

    int totalAdded = 0;
    int totalRemoved = 0;
    for (final f in groupedSessionFiles) {
      totalAdded += f.addedLines;
      totalRemoved += f.removedLines;
    }

    final runningSubagents = (!widget.isNewConversationMode && session != null && !session.isInterrupted)
        ? session.subagentLanes
            .where((lane) =>
                lane.name != 'Coordinator' &&
                lane.status == AgentStatus.running)
            .toList()
        : const <SubagentLane>[];

    final isCoordinatorRunning = isTurnRunning;
    final int activeTaskCount =
        (isCoordinatorRunning ? 1 : 0) + runningSubagents.length;

    final bool canShowParallelFlow = session?.hasParallelFlow == true ||
        ((session?.projectName == 'muop-erp-server' ||
                session?.projectName == 'muop-erp-app') &&
            session != null &&
            session.subagentLanes.length > 1);

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
            const Icon(
              Icons.check_circle_outline_rounded,
              size: 15,
              color: Colors.teal,
            ),
            const SizedBox(width: 8),
            Text(
              '${groupedSessionFiles.length} tệp đã cập nhật',
              style: textTheme.bodySmall?.copyWith(
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            if (totalAdded > 0 || totalRemoved > 0) ...[
              const SizedBox(width: 6),
              Text(
                '+$totalAdded',
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: Colors.teal,
                ),
              ),
              const SizedBox(width: 3),
              Text(
                '-$totalRemoved',
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: Colors.redAccent,
                ),
              ),
            ],
            const Spacer(),
            InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: widget.onOpenChangesTab,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
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
            if (widget.onOpenParallelFlow != null && canShowParallelFlow) ...[
              InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: widget.onOpenParallelFlow,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.deepPurple.withAlpha(35),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: Colors.deepPurpleAccent.withAlpha(120),
                    ),
                  ),
                  child: const Text(
                    'Parallel Flow',
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      color: Colors.deepPurpleAccent,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      );
    }

    final taskTitle = activeTaskCount > 0
        ? '$activeTaskCount task${activeTaskCount > 1 ? 's' : ''} running'
        : '0 tasks running';

    final lastStep = (!widget.isNewConversationMode &&
            session != null &&
            session.steps.isNotEmpty)
        ? session.steps.last
        : null;
    final bool isGitCommitTask = isCoordinatorRunning &&
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
    if (isGitCommitTask && lastStep != null && lastStep.vietnameseDetail.isNotEmpty) {
      gitCommitDetail = lastStep.vietnameseDetail;
    }

    final int? currentStepIndex = lastStep?.stepIndex;
    final String stepBadgeLabel = currentStepIndex != null ? 'Bước #$currentStepIndex' : '';

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
      coordinatorBadgeColor = Colors.teal;
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
          coordinatorBadgeColor = Colors.blueAccent;
          coordinatorActionIcon = Icons.terminal_rounded;
          final summary = lastTool.args['toolSummary']?.toString() ?? '';
          final cmd = lastTool.args['CommandLine']?.toString() ?? '';
          coordinatorActionTitle = 'Bước #$currentStepIndex: ${summary.isNotEmpty ? summary : (lastStep.vietnameseTitle.isNotEmpty ? lastStep.vietnameseTitle : 'Thực thi lệnh terminal')}';
          coordinatorActionDetail = cmd.isNotEmpty ? cmd : lastStep.vietnameseDetail;
          break;
        case 'edit_file':
          coordinatorBadgeColor = Colors.orange;
          coordinatorActionIcon = Icons.edit_note_rounded;
          final path = lastTool.args['Path']?.toString() ?? '';
          coordinatorActionTitle = 'Bước #$currentStepIndex: ${lastStep.vietnameseTitle.isNotEmpty ? lastStep.vietnameseTitle : 'Chỉnh sửa tệp nguồn'}';
          coordinatorActionDetail = path.isNotEmpty ? path.split('/').last : lastStep.vietnameseDetail;
          break;
        case 'write_file':
          coordinatorBadgeColor = Colors.teal;
          coordinatorActionIcon = Icons.note_add_rounded;
          final path = lastTool.args['Path']?.toString() ?? '';
          coordinatorActionTitle = 'Bước #$currentStepIndex: ${lastStep.vietnameseTitle.isNotEmpty ? lastStep.vietnameseTitle : 'Tạo mới tệp tin'}';
          coordinatorActionDetail = path.isNotEmpty ? path.split('/').last : lastStep.vietnameseDetail;
          break;
        case 'read_file':
          coordinatorBadgeColor = Colors.amber.shade700;
          coordinatorActionIcon = Icons.search_rounded;
          final path = lastTool.args['Path']?.toString() ?? '';
          coordinatorActionTitle = 'Bước #$currentStepIndex: ${lastStep.vietnameseTitle.isNotEmpty ? lastStep.vietnameseTitle : 'Đọc nội dung tệp tin'}';
          coordinatorActionDetail = path.isNotEmpty ? path.split('/').last : lastStep.vietnameseDetail;
          break;
        case 'invoke_subagent':
          coordinatorBadgeColor = Colors.purpleAccent;
          coordinatorActionIcon = Icons.alt_route_rounded;
          final role = lastTool.args['Role']?.toString() ?? '';
          coordinatorActionTitle = 'Bước #$currentStepIndex: ${role.isNotEmpty ? 'Phân quyền: $role' : 'Điều phối Subagent song song'}';
          coordinatorActionDetail = lastTool.args['Prompt']?.toString() ?? lastStep.vietnameseDetail;
          break;
        default:
          coordinatorBadgeColor = Colors.deepPurpleAccent;
          coordinatorActionIcon = Icons.build_circle_outlined;
          coordinatorActionTitle = 'Bước #$currentStepIndex: ${lastStep.vietnameseTitle.isNotEmpty ? lastStep.vietnameseTitle : 'Công cụ: $toolName'}';
          coordinatorActionDetail = lastStep.vietnameseDetail;
      }
    } else if (stream != null && stream.streamingText.isNotEmpty) {
      coordinatorToolBadge = 'Thinking';
      coordinatorBadgeColor = Colors.purpleAccent;
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
      coordinatorBadgeColor = isPlanner ? Colors.purpleAccent : colorScheme.primary;
      coordinatorActionIcon = isPlanner ? Icons.smart_toy_rounded : Icons.psychology_rounded;
      coordinatorActionTitle = currentStepIndex != null
          ? 'Bước #$currentStepIndex: ${isPlanner ? 'Robot đang suy nghĩ & phân tích' : (lastStep.vietnameseTitle.isNotEmpty ? lastStep.vietnameseTitle : 'Đang xử lý bước #$currentStepIndex')}'
          : (lastStep.vietnameseTitle.isNotEmpty ? lastStep.vietnameseTitle : 'Đang xử lý yêu cầu');
      coordinatorActionDetail = _extractSpecificThinkingDetail(
        stream?.streamingText ?? '',
        stream?.userPrompt ?? '',
        lastStep,
      );
    } else {
      coordinatorToolBadge = 'Thinking';
      coordinatorBadgeColor = Colors.purpleAccent;
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
            onTap: () => setState(
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
                          color: Colors.teal.withAlpha(35),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: Colors.teal.withAlpha(100)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.open_in_new_rounded,
                              size: 11,
                              color: Colors.teal,
                            ),
                            const SizedBox(width: 3),
                            Text(
                              isMobile
                                  ? 'Tệp'
                                  : 'Mở: ${lastDownloaded.split('/').last}',
                              style: textTheme.labelSmall?.copyWith(
                                fontSize: 9.5,
                                fontWeight: FontWeight.w700,
                                color: Colors.teal,
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
                                  color: Colors.teal,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                  // Nút chuyển nhanh sang màn hình trực quan Luồng chạy Parallel Agent
                  if (widget.onOpenParallelFlow != null && canShowParallelFlow) ...[
                    InkWell(
                      borderRadius: BorderRadius.circular(6),
                      onTap: widget.onOpenParallelFlow,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.deepPurple.withAlpha(35),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: Colors.deepPurpleAccent.withAlpha(120),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.alt_route_rounded,
                              size: 11,
                              color: Colors.deepPurpleAccent,
                            ),
                            const SizedBox(width: 3),
                            Text(
                              'Flow',
                              style: textTheme.labelSmall?.copyWith(
                                fontSize: 9.5,
                                fontWeight: FontWeight.w800,
                                color: Colors.deepPurpleAccent,
                              ),
                            ),
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
                      const _AnimatedThinkingRobotIcon(
                        size: 16,
                        color: Colors.purpleAccent,
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
                                    color: colorScheme.primaryContainer.withAlpha(140),
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
                                      color: coordinatorBadgeColor.withAlpha(120),
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
                                const _AnimatedThinkingRobotIcon(
                                  size: 12,
                                  color: Colors.purpleAccent,
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
                              color:
                                  colorScheme.onSurfaceVariant.withAlpha(220),
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
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.8,
                        valueColor:
                            AlwaysStoppedAnimation<Color>(Colors.orange),
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
                                    color: Colors.orange,
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
                                        ? Colors.teal
                                        : gf.action == 'EDIT'
                                            ? Colors.amber
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
                                        color: Colors.teal,
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

                  if (widget.onOpenParallelFlow != null && canShowParallelFlow) ...[
                    const SizedBox(height: 8),
                    InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: widget.onOpenParallelFlow,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.deepPurple.withAlpha(25),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: Colors.deepPurpleAccent.withAlpha(90),
                          ),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(
                              Icons.account_tree_outlined,
                              size: 14,
                              color: Colors.deepPurpleAccent,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              'Xem biểu đồ trực quan Luồng chạy Parallel Agent (Swimlanes & Checklist)',
                              style: textTheme.labelSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                                color: Colors.deepPurpleAccent,
                              ),
                            ),
                            const SizedBox(width: 4),
                            const Icon(
                              Icons.arrow_forward_rounded,
                              size: 13,
                              color: Colors.deepPurpleAccent,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Tìm nhóm Quota Antigravity khớp với Model đang chọn
  ({
    ModelQuotaGroup? primaryGroup,
    ModelQuotaGroup? geminiGroup,
  }) _resolveQuotaForSelectedModel() {
    ModelQuotaGroup? gemini;
    ModelQuotaGroup? claudeGpt;
    ModelQuotaGroup? argon;

    for (final g in widget.modelQuotas) {
      final lower = g.displayName.toLowerCase();
      if (lower.contains('argon')) {
        argon = g;
      } else if (lower.contains('claude') || lower.contains('gpt')) {
        claudeGpt = g;
      } else if (lower.contains('gemini')) {
        gemini = g;
      }
    }

    final m = widget.selectedModel.toLowerCase();
    if (m.contains('claude') || m.contains('gpt')) {
      return (primaryGroup: claudeGpt ?? gemini, geminiGroup: gemini);
    }
    if (m.contains('argon')) {
      return (primaryGroup: argon ?? gemini, geminiGroup: gemini);
    }
    return (primaryGroup: gemini ?? argon ?? claudeGpt, geminiGroup: gemini);
  }

  Color _quotaStatusColor(double remainingPct) {
    if (remainingPct <= 15) return Colors.redAccent;
    if (remainingPct <= 45) return Colors.amber;
    return Colors.teal;
  }

  /// [2] THANH % USAGE CỦA MODEL AI — Nằm ở giữa phần Task Running và Khung Chat
  /// Hiển thị chính xác Limit Tuần (Weekly Limit Remaining) & Limit Giờ / 5h (Five Hour Limit Remaining)
  /// lấy trực tiếp từ Antigravity LanguageServer (`RetrieveUserQuotaSummary`).
  Widget _buildModelUsageMiddleBar(BuildContext context, bool isMobile) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final resolved = _resolveQuotaForSelectedModel();
    final primaryGroup = resolved.primaryGroup;
    final geminiGroup = resolved.geminiGroup;

    final weeklyBucket = primaryGroup?.weeklyBucket;
    final fiveHourBucket =
        primaryGroup?.fiveHourBucket ?? geminiGroup?.fiveHourBucket;

    final double weeklyPct = weeklyBucket?.remainingPercent ?? 70.0;
    final double hourlyPct = fiveHourBucket?.remainingPercent ?? 95.0;

    final Color weeklyColor = _quotaStatusColor(weeklyPct);
    final Color hourlyColor = _quotaStatusColor(hourlyPct);

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: isMobile ? 10 : 12,
        vertical: isMobile ? 5 : 6,
      ),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow.withAlpha(220),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: colorScheme.outlineVariant.withAlpha(160),
        ),
      ),
      child: Row(
        children: [
          // Chọn nhanh Model AI
          PopupMenuButton<String>(
            tooltip: 'Đổi Model AI đang sử dụng',
            onSelected: widget.onSelectModel,
            itemBuilder: (ctx) => [
              for (final m in widget.availableModels)
                PopupMenuItem<String>(
                  value: m,
                  child: Row(
                    children: [
                      Icon(
                        Icons.auto_awesome_rounded,
                        size: 15,
                        color: m == widget.selectedModel
                            ? colorScheme.primary
                            : colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _formatModelLabel(m),
                        style: TextStyle(
                          fontWeight: m == widget.selectedModel
                              ? FontWeight.w800
                              : FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.memory_rounded,
                  size: 13.5,
                  color: colorScheme.primary,
                ),
                const SizedBox(width: 5),
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: isMobile ? 118 : 200),
                  child: Text(
                    _formatModelLabel(widget.selectedModel),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: colorScheme.onSurface,
                    ),
                  ),
                ),
                Icon(
                  Icons.arrow_drop_down_rounded,
                  size: 15,
                  color: colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),

          const SizedBox(width: 6),

          // Hiển thị 2 cột Limit Tuần & Limit Giờ (5h) chuẩn Antigravity (bấm vào để mở bảng chi tiết tất cả Model)
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: () => _showAntigravityQuotaSheet(context),
              child: Row(
                children: [
                  // 1. Limit Tuần (Weekly Limit Remaining)
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              isMobile ? 'Tuần' : 'Limit Tuần',
                              style: textTheme.labelSmall?.copyWith(
                                fontSize: 10,
                                color: colorScheme.onSurfaceVariant,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              '${weeklyPct.round()}%',
                              style: textTheme.labelSmall?.copyWith(
                                fontFamily: 'monospace',
                                fontSize: 10.5,
                                fontWeight: FontWeight.w800,
                                color: weeklyColor,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2.5),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            minHeight: 4.5,
                            value: (weeklyPct / 100.0).clamp(0.0, 1.0),
                            backgroundColor:
                                colorScheme.surfaceContainerHighest,
                            valueColor:
                                AlwaysStoppedAnimation<Color>(weeklyColor),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(width: 10),

                  // 2. Limit Giờ / 5h (Five Hour Limit Remaining)
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              isMobile ? 'Giờ (5h)' : 'Limit Giờ (5h)',
                              style: textTheme.labelSmall?.copyWith(
                                fontSize: 10,
                                color: colorScheme.onSurfaceVariant,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              '${hourlyPct.round()}%',
                              style: textTheme.labelSmall?.copyWith(
                                fontFamily: 'monospace',
                                fontSize: 10.5,
                                fontWeight: FontWeight.w800,
                                color: hourlyColor,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2.5),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            minHeight: 4.5,
                            value: (hourlyPct / 100.0).clamp(0.0, 1.0),
                            backgroundColor:
                                colorScheme.surfaceContainerHighest,
                            valueColor:
                                AlwaysStoppedAnimation<Color>(hourlyColor),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(width: 4),
                  Icon(
                    Icons.info_outline_rounded,
                    size: 13.5,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Hộp thoại chi tiết toàn bộ các nhóm Quota AI trên Antigravity (Gemini Flash/Pro, Gemini 4 Argon, Claude/GPT)
  void _showAntigravityQuotaSheet(BuildContext context) {
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
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.speed_rounded,
                    size: 20,
                    color: colorScheme.primary,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Antigravity AI Quota & Rate Limits (Realtime)',
                      style: textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => Navigator.of(ctx).pop(),
                  ),
                ],
              ),
              const Divider(height: 16),
              for (final group in widget.modelQuotas)
                Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: colorScheme.outlineVariant),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        group.displayName,
                        style: textTheme.labelLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                          color: colorScheme.primary,
                        ),
                      ),
                      if (group.description.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          group.description,
                          style: textTheme.labelSmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                      const SizedBox(height: 8),
                      for (final b in group.buckets) ...[
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    b.window == '5h'
                                        ? 'Limit Giờ (5-Hour Limit Remaining)'
                                        : 'Limit Tuần (${b.displayName})',
                                    style: textTheme.labelMedium?.copyWith(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  Text(
                                    '${b.remainingPercent.round()}%',
                                    style: textTheme.labelMedium?.copyWith(
                                      fontFamily: 'monospace',
                                      fontWeight: FontWeight.w800,
                                      color: _quotaStatusColor(
                                        b.remainingPercent,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              ClipRRect(
                                borderRadius: BorderRadius.circular(4),
                                child: LinearProgressIndicator(
                                  minHeight: 6,
                                  value: b.remainingFraction.clamp(0.0, 1.0),
                                  backgroundColor:
                                      colorScheme.surfaceContainerHighest,
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                    _quotaStatusColor(b.remainingPercent),
                                  ),
                                ),
                              ),
                              if (b.description.isNotEmpty) ...[
                                const SizedBox(height: 3),
                                Text(
                                  b.description,
                                  style: textTheme.labelSmall?.copyWith(
                                    fontSize: 10.5,
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  /// [3] KHUNG NHẬP CHAT HỢP NHẤT (COMPOSER BOX) — Nằm dưới cùng
  Widget _buildAntigravityComposer(
    BuildContext context,
    bool isMobile,
    bool isTurnRunning,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final activeProjectName = widget.selectedProject?.name ??
        widget.session?.projectName ??
        'muop-erp-server';

    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: colorScheme.outlineVariant,
          width: 1.1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(14),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
              isMobile ? 12 : 16,
              isMobile ? 6 : 8,
              isMobile ? 12 : 16,
              2,
            ),
            child: TextField(
              controller: _promptController,
              focusNode: _inputFocusNode,
              minLines: 1,
              maxLines: isMobile ? 3 : 5,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _handleSend(),
              style: textTheme.bodyMedium?.copyWith(
                height: 1.38,
                fontSize: isMobile ? 13.5 : 14,
                color: colorScheme.onSurface,
              ),
              decoration: InputDecoration(
                hintText: isMobile
                    ? 'Nhập tin nhắn cho Agent ($activeProjectName)...'
                    : 'Ask anything in $activeProjectName, or type / for workflows...',
                hintStyle: textTheme.bodyMedium?.copyWith(
                  fontSize: isMobile ? 13 : 13.5,
                  color: colorScheme.onSurfaceVariant.withAlpha(155),
                ),
                border: InputBorder.none,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 5),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 2, 8, 6),
            child: Row(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: () => _showSlashCommandsPicker(context),
                          child: _ComposerPill(
                            icon: Icons.terminal_rounded,
                            label: '/',
                            colorScheme: colorScheme,
                          ),
                        ),
                        const SizedBox(width: 5),

                        PopupMenuButton<dynamic>(
                          tooltip: 'Chọn Project Workspace',
                          onSelected: (val) {
                            if (val is ProjectWorkspace) {
                              widget.onSelectProject(val);
                            } else if (val == '__create_project__') {
                              widget.onOpenCreateProject?.call();
                            }
                          },
                          itemBuilder: (ctx) => [
                            if (widget.onOpenCreateProject != null)
                              PopupMenuItem<String>(
                                value: '__create_project__',
                                child: Row(
                                  children: [
                                    Icon(
                                      Icons.create_new_folder_outlined,
                                      size: 16,
                                      color: colorScheme.primary,
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      '+ Tạo Project mới',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w700,
                                        color: colorScheme.primary,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            for (final p in widget.projects)
                              PopupMenuItem<ProjectWorkspace>(
                                value: p,
                                child: Row(
                                  children: [
                                    Icon(
                                      Icons.folder_outlined,
                                      size: 16,
                                      color: p.name == activeProjectName
                                          ? colorScheme.primary
                                          : colorScheme.onSurfaceVariant,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        p.name,
                                        style: TextStyle(
                                          fontWeight:
                                              p.name == activeProjectName
                                                  ? FontWeight.w700
                                                  : FontWeight.w500,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                          child: _ComposerPill(
                            icon: Icons.folder_outlined,
                            label: activeProjectName,
                            hasDropdown: true,
                            colorScheme: colorScheme,
                          ),
                        ),
                        const SizedBox(width: 5),

                        PopupMenuButton<String>(
                          tooltip: 'Chọn Agent',
                          onSelected: widget.onSelectAgent,
                          itemBuilder: (ctx) {
                            final effectiveAgents = (widget.session != null &&
                                    widget.session!.availableAgents.isNotEmpty)
                                ? widget.session!.availableAgents
                                : (widget.selectedProject != null &&
                                        widget.selectedProject!.availableAgents.isNotEmpty)
                                    ? widget.selectedProject!.availableAgents
                                    : widget.availableAgents;
                            return [
                              for (final a in effectiveAgents)
                                PopupMenuItem<String>(
                                  value: a,
                                  child: Text(
                                    a,
                                    style: TextStyle(
                                      fontWeight: a == widget.selectedAgent
                                          ? FontWeight.w700
                                          : FontWeight.w500,
                                    ),
                                  ),
                                ),
                            ];
                          },
                          child: _ComposerPill(
                            icon: Icons.smart_toy_outlined,
                            label: widget.selectedAgent,
                            hasDropdown: true,
                            colorScheme: colorScheme,
                          ),
                        ),
                        const SizedBox(width: 5),

                        InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: widget.onOpenFileBrowser,
                          child: _ComposerPill(
                            icon: Icons.dns_outlined,
                            label: isMobile ? 'SFTP' : 'Duyệt SFTP Server',
                            colorScheme: colorScheme,
                          ),
                        ),
                        if (widget.onOpenGitHistory != null) ...[
                          const SizedBox(width: 5),
                          InkWell(
                            borderRadius: BorderRadius.circular(8),
                            onTap: widget.onOpenGitHistory,
                            child: _ComposerPill(
                              icon: Icons.account_tree_outlined,
                              label: isMobile ? 'Git Tree' : 'Git Tree & History',
                              colorScheme: colorScheme,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                if (isTurnRunning)
                  IconButton.filledTonal(
                    tooltip: 'Dừng lượt chạy (Stop)',
                    onPressed: widget.onStopTurn,
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.redAccent.withAlpha(40),
                      foregroundColor: Colors.redAccent,
                      minimumSize: const Size(32, 32),
                      padding: EdgeInsets.zero,
                    ),
                    icon: const Icon(Icons.stop_rounded, size: 17),
                  )
                else
                  IconButton.filled(
                    tooltip: 'Gửi tin nhắn (Enter)',
                    onPressed: _handleSend,
                    style: IconButton.styleFrom(
                      minimumSize: const Size(32, 32),
                      padding: EdgeInsets.zero,
                    ),
                    icon: const Icon(
                      Icons.arrow_upward_rounded,
                      size: 17,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showSlashCommandsPicker(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final allCustom = widget.session?.customAgents ??
        widget.selectedProject?.customAgents ??
        [];
    final projectSkills = allCustom.where((s) => s.kind == 'skill').toList();

    final coreCommands = const [
      (cmd: '/plan', label: 'Lập kế hoạch chi tiết', desc: 'Thiết kế Shared Contract, phân chia tác vụ & chờ duyệt', icon: Icons.architecture_rounded),
      (cmd: '/boost', label: 'Phân tích chuyên sâu', desc: 'Kích hoạt suy luận đa góc nhìn và giải quyết vấn đề phức tạp', icon: Icons.bolt_rounded),
      (cmd: '/goal', label: 'Tự chủ hoàn thành mục tiêu', desc: 'Thực thi không dừng cho đến khi hoàn tất 100% mục tiêu', icon: Icons.flag_rounded),
      (cmd: '/compact', label: 'Thu gọn ngữ cảnh', desc: 'Nén và giải phóng context window cho cuộc hội thoại dài', icon: Icons.compress_rounded),
      (cmd: '/learn', label: 'Ghi nhớ kinh nghiệm', desc: 'Lưu trữ kinh nghiệm và quy tắc xử lý cho các lần sau', icon: Icons.menu_book_rounded),
    ];

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: colorScheme.surfaceContainer,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        String searchQuery = '';
        return StatefulBuilder(
          builder: (modalCtx, setModalState) {
            final query = searchQuery.trim().toLowerCase();

            final filteredCore = coreCommands.where((c) {
              if (query.isEmpty) return true;
              return c.cmd.toLowerCase().contains(query) ||
                  c.label.toLowerCase().contains(query) ||
                  c.desc.toLowerCase().contains(query);
            }).toList();

            final filteredSkills = projectSkills.where((s) {
              if (query.isEmpty) return true;
              return s.name.toLowerCase().contains(query) ||
                  s.description.toLowerCase().contains(query);
            }).toList();

            return DraggableScrollableSheet(
              initialChildSize: 0.65,
              minChildSize: 0.40,
              maxChildSize: 0.90,
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
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.terminal_rounded,
                            size: 20,
                            color: Colors.deepPurpleAccent,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Slash Workflows & Kỹ Năng (/skill)',
                              style: textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.close_rounded),
                            onPressed: () => Navigator.of(ctx).pop(),
                            tooltip: 'Đóng',
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                      child: TextField(
                        onChanged: (val) {
                          setModalState(() {
                            searchQuery = val;
                          });
                        },
                        style: textTheme.bodyMedium,
                        decoration: InputDecoration(
                          hintText: 'Tìm kiếm lệnh hoặc kỹ năng...',
                          prefixIcon: const Icon(Icons.search_rounded, size: 18),
                          isDense: true,
                          filled: true,
                          fillColor: colorScheme.surfaceContainerHighest.withAlpha(120),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: colorScheme.outlineVariant.withAlpha(60)),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: colorScheme.outlineVariant.withAlpha(60)),
                          ),
                        ),
                      ),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: ListView(
                        controller: scrollController,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        children: [
                          if (filteredSkills.isNotEmpty) ...[
                            Padding(
                              padding: const EdgeInsets.only(top: 6, bottom: 6),
                              child: Row(
                                children: [
                                  const Icon(
                                    Icons.auto_awesome_rounded,
                                    size: 14,
                                    color: Colors.deepPurpleAccent,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    'Kỹ năng Dự án & Ecosystem (.agents)',
                                    style: textTheme.labelSmall?.copyWith(
                                      fontWeight: FontWeight.w800,
                                      color: Colors.deepPurpleAccent,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                    decoration: BoxDecoration(
                                      color: Colors.deepPurple.withAlpha(30),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      '${filteredSkills.length}',
                                      style: const TextStyle(
                                        fontSize: 9.5,
                                        fontWeight: FontWeight.w700,
                                        color: Colors.deepPurpleAccent,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            for (final s in filteredSkills)
                              InkWell(
                                borderRadius: BorderRadius.circular(10),
                                onTap: () {
                                  Navigator.of(ctx).pop();
                                  _insertSlashCommand('/${s.name} ');
                                },
                                child: Container(
                                  margin: const EdgeInsets.only(bottom: 6),
                                  padding: const EdgeInsets.all(10),
                                  decoration: BoxDecoration(
                                    color: colorScheme.surfaceContainerHigh,
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(
                                      color: colorScheme.outlineVariant.withAlpha(60),
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.all(6),
                                        decoration: BoxDecoration(
                                          color: Colors.deepPurple.withAlpha(25),
                                          borderRadius: BorderRadius.circular(8),
                                        ),
                                        child: const Icon(
                                          Icons.auto_awesome_rounded,
                                          size: 16,
                                          color: Colors.deepPurpleAccent,
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              '/${s.name}',
                                              style: textTheme.labelLarge?.copyWith(
                                                fontWeight: FontWeight.w700,
                                                color: Colors.deepPurpleAccent,
                                              ),
                                            ),
                                            if (s.description.isNotEmpty) ...[
                                              const SizedBox(height: 2),
                                              Text(
                                                s.description,
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                                style: textTheme.bodySmall?.copyWith(
                                                  color: colorScheme.onSurfaceVariant,
                                                  fontSize: 11,
                                                ),
                                              ),
                                            ],
                                          ],
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      Icon(
                                        Icons.add_rounded,
                                        size: 16,
                                        color: colorScheme.onSurfaceVariant.withAlpha(140),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            const SizedBox(height: 8),
                          ],
                          if (filteredCore.isNotEmpty) ...[
                            Padding(
                              padding: const EdgeInsets.only(top: 6, bottom: 6),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.tune_rounded,
                                    size: 14,
                                    color: colorScheme.primary,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    'Workflows Điều Phối (Core)',
                                    style: textTheme.labelSmall?.copyWith(
                                      fontWeight: FontWeight.w800,
                                      color: colorScheme.primary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            for (final c in filteredCore)
                              InkWell(
                                borderRadius: BorderRadius.circular(10),
                                onTap: () {
                                  Navigator.of(ctx).pop();
                                  _insertSlashCommand('${c.cmd} ');
                                },
                                child: Container(
                                  margin: const EdgeInsets.only(bottom: 6),
                                  padding: const EdgeInsets.all(10),
                                  decoration: BoxDecoration(
                                    color: colorScheme.surfaceContainerHigh,
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(
                                      color: colorScheme.outlineVariant.withAlpha(60),
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.all(6),
                                        decoration: BoxDecoration(
                                          color: colorScheme.primary.withAlpha(25),
                                          borderRadius: BorderRadius.circular(8),
                                        ),
                                        child: Icon(
                                          c.icon,
                                          size: 16,
                                          color: colorScheme.primary,
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
                                                  c.cmd,
                                                  style: textTheme.labelLarge?.copyWith(
                                                    fontWeight: FontWeight.w700,
                                                    color: colorScheme.primary,
                                                  ),
                                                ),
                                                const SizedBox(width: 6),
                                                Text(
                                                  '— ${c.label}',
                                                  style: textTheme.labelMedium?.copyWith(
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                                ),
                                              ],
                                            ),
                                            const SizedBox(height: 2),
                                            Text(
                                              c.desc,
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                              style: textTheme.bodySmall?.copyWith(
                                                color: colorScheme.onSurfaceVariant,
                                                fontSize: 11,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      Icon(
                                        Icons.add_rounded,
                                        size: 16,
                                        color: colorScheme.onSurfaceVariant.withAlpha(140),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                          ],
                          if (filteredSkills.isEmpty && filteredCore.isEmpty)
                            Padding(
                              padding: const EdgeInsets.all(32),
                              child: Center(
                                child: Text(
                                  'Không tìm thấy lệnh hoặc kỹ năng phù hợp với "$searchQuery"',
                                  style: textTheme.bodySmall?.copyWith(
                                    color: colorScheme.onSurfaceVariant,
                                  ),
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
      },
    );
  }

  void _insertSlashCommand(String cmd) {
    final text = _promptController.text;
    if (text.startsWith('/')) {
      final firstSpace = text.indexOf(' ');
      if (firstSpace != -1) {
        _promptController.text = '$cmd${text.substring(firstSpace + 1)}';
      } else {
        _promptController.text = cmd;
      }
    } else {
      _promptController.text = '$cmd$text';
    }
    _promptController.selection = TextSelection.fromPosition(
      TextPosition(offset: _promptController.text.length),
    );
    _inputFocusNode.requestFocus();
  }

  Widget _buildLoadMoreOlderTurnsBanner(
    BuildContext context, {
    required int remainingCount,
    required int loadedCount,
    required int totalCount,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final nextBatch = math.min(_pageSize, remainingCount);

    if (remainingCount == 0 &&
        _hasLoadedAllServerHistory &&
        !_isLoadingMoreTurns) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 18, top: 6),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest.withAlpha(120),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.check_circle_outline_rounded,
                  size: 13,
                  color: colorScheme.outline,
                ),
                const SizedBox(width: 6),
                Text(
                  'Đầu cuộc hội thoại (Đã nạp toàn bộ $totalCount lượt chat)',
                  style: textTheme.labelSmall?.copyWith(
                    color: colorScheme.outline,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 18, top: 6),
      child: Center(
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: _isLoadingMoreTurns ? null : _loadOlderTurnsPage,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: colorScheme.outlineVariant),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_isLoadingMoreTurns) ...[
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: colorScheme.primary,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Đang tải thêm đoạn chat cũ...',
                    style: textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: colorScheme.primary,
                    ),
                  ),
                ] else ...[
                  Icon(
                    Icons.history_rounded,
                    size: 15,
                    color: colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    remainingCount > 0
                        ? 'Tải thêm $nextBatch đoạn hội thoại cũ ($loadedCount/$totalCount)'
                        : 'Nhấn hoặc cuộn để tải thêm lịch sử từ Server...',
                    style: textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: colorScheme.onSurface,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyAntigravityWelcome(BuildContext context, bool isMobile) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final projectName = widget.selectedProject?.name ??
        widget.session?.projectName ??
        'muop-erp-server';

    final quickStarters = [
      (
        icon: Icons.call_split_rounded,
        label: '/erp-parallel-sync',
        desc: 'Đồng bộ tính năng song song giữa muop-erp-server & muop-erp-app',
        prompt:
            '/erp-parallel-sync Kiểm tra và đồng bộ tính năng giữa muop-erp-server và muop-erp-app',
      ),
      (
        icon: Icons.terminal_rounded,
        label: 'Kiểm tra Build & Analyze',
        desc: 'Chạy kiểm tra biên dịch và phân tích mã nguồn trong project',
        prompt:
            'Chạy kiểm tra biên dịch và phân tích tĩnh trong project hiện tại, báo cáo ngắn gọn.',
      ),
      (
        icon: Icons.folder_open_rounded,
        label: 'Khảo sát cấu trúc Project',
        desc: 'Tóm tắt kiến trúc và các module chính trong $projectName',
        prompt:
            'Tóm tắt cấu trúc thư mục và các module chính trong project $projectName.',
      ),
    ];

    return Center(
      child: SingleChildScrollView(
        padding: EdgeInsets.all(isMobile ? 16 : 32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest.withAlpha(180),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: colorScheme.outlineVariant.withAlpha(120),
                  ),
                ),
                padding: const EdgeInsets.all(6),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.asset(
                    'assets/images/logo.png',
                    width: 44,
                    height: 44,
                    fit: BoxFit.contain,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Antigravity — $projectName',
                textAlign: TextAlign.center,
                style: textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  fontSize: isMobile ? 18 : 21,
                  color: colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Trò chuyện với Agent, theo dõi Task Running, % Quota Tuần/Giờ và duyệt tệp SFTP.',
                textAlign: TextAlign.center,
                style: textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 20),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                alignment: WrapAlignment.center,
                children: [
                  for (final item in quickStarters)
                    InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () {
                        _promptController.text = item.prompt;
                        _promptController.selection =
                            TextSelection.fromPosition(
                          TextPosition(offset: _promptController.text.length),
                        );
                        _inputFocusNode.requestFocus();
                      },
                      child: Container(
                        width: isMobile ? double.infinity : 200,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: colorScheme.surfaceContainer,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: colorScheme.outlineVariant),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  item.icon,
                                  size: 16,
                                  color: colorScheme.primary,
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    item.label,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: textTheme.labelMedium?.copyWith(
                                      fontWeight: FontWeight.w700,
                                      color: colorScheme.onSurface,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              item.desc,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: textTheme.labelSmall?.copyWith(
                                color: colorScheme.onSurfaceVariant,
                                height: 1.35,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLiveStreamingBlock(
    BuildContext context,
    ChatTurnStreamState stream,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final lastStep = widget.session?.steps.isNotEmpty == true
        ? widget.session!.steps.last
        : null;

    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (stream.isRunning)
            _AnimatedThinkingRobotCard(
              stream: stream,
              lastStep: lastStep,
              collapsedTailLines: _collapsedTailLines,
            )
          else ...[
            Row(
              children: [
                const Icon(
                  Icons.check_circle_outline_rounded,
                  size: 16,
                  color: Colors.teal,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Hoàn tất xử lý',
                    style: textTheme.labelMedium?.copyWith(
                      color: Colors.teal,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            if (stream.streamingText.trim().isNotEmpty) ...[
              const SizedBox(height: 8),
              SelectableText(
                stream.streamingText
                    .trimRight()
                    .split('\n')
                    .reversed
                    .take(_collapsedTailLines)
                    .toList()
                    .reversed
                    .join('\n'),
                style: textTheme.bodyMedium?.copyWith(
                  height: 1.5,
                  color: colorScheme.onSurface,
                ),
              ),
            ],
          ],
          if (stream.error.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              stream.error,
              style: textTheme.bodySmall?.copyWith(
                color: Colors.redAccent,
              ),
            ),
          ],
        ],
      ),
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
                                    final p = (tc.targetPath ??
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

/// Widget định dạng phản hồi AI theo chuẩn phong cách Antigravity:
/// - Tiêu đề Heading 1..4 to rõ nét, phân cấp trực quan với ký hiệu # mờ
/// - Hộp Inline code màu vàng hổ phách trên nền tối, không tràn dòng
/// - Chip liên kết tệp bấm được với biểu tượng tệp màu xanh lam
/// - Danh sách số thứ tự & bullet tròn căn lề thẳng thớm, thụt lề chuẩn
/// - Hỗ trợ mở rộng / thu gọn 10 dòng cuối
class _AntigravityMarkdownSegment extends StatelessWidget {
  const _AntigravityMarkdownSegment({
    required this.text,
    required this.isExpanded,
    this.onExpand,
    required this.onLinkTap,
    required this.isMobile,
  });

  final String text;
  final bool isExpanded;
  final VoidCallback? onExpand;
  final void Function(String url, String label) onLinkTap;
  final bool isMobile;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    final lines = text.split('\n');
    final children = <Widget>[];

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];
      final trimmed = line.trim();

      if (trimmed.isEmpty) {
        children.add(const SizedBox(height: 6));
        continue;
      }

      // 1. Horizontal Rule (--- hoặc ***)
      if (trimmed == '---' || trimmed == '***' || trimmed == '___') {
        children.add(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Divider(
              height: 1,
              thickness: 1,
              color: colorScheme.outlineVariant.withAlpha(120),
            ),
          ),
        );
        continue;
      }

      // 2. Headings (#, ##, ###, ####)
      if (trimmed.startsWith('# ') ||
          trimmed.startsWith('## ') ||
          trimmed.startsWith('### ') ||
          trimmed.startsWith('#### ')) {
        int level = 1;
        if (trimmed.startsWith('#### ')) {
          level = 4;
        } else if (trimmed.startsWith('### ')) {
          level = 3;
        } else if (trimmed.startsWith('## ')) {
          level = 2;
        }

        final headingContent = trimmed.substring(level + 1).trim();
        final double fontSize = level == 1
            ? (isMobile ? 17.5 : 19.0)
            : level == 2
                ? (isMobile ? 16.0 : 17.0)
                : level == 3
                    ? (isMobile ? 14.8 : 15.5)
                    : (isMobile ? 13.8 : 14.5);

        children.add(
          Padding(
            padding: EdgeInsets.only(
              top: level <= 2 ? 12 : 8,
              bottom: 4,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  '#' * level,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: fontSize * 0.8,
                    fontWeight: FontWeight.w700,
                    color: colorScheme.primary.withAlpha(160),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: _buildInlineSpans(
                        context,
                        headingContent,
                        baseStyle: TextStyle(
                          fontSize: fontSize,
                          fontWeight: FontWeight.w700,
                          color: colorScheme.onSurface,
                          height: 1.35,
                        ),
                        colorScheme: colorScheme,
                        onLinkTap: onLinkTap,
                        isMobile: isMobile,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
        continue;
      }

      // 3. Blockquote (> ...)
      if (trimmed.startsWith('> ') || trimmed == '>') {
        final quoteText = trimmed.length > 2 ? trimmed.substring(2).trim() : '';
        children.add(
          Container(
            margin: const EdgeInsets.symmetric(vertical: 4),
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
            decoration: BoxDecoration(
              color: colorScheme.primaryContainer.withAlpha(35),
              borderRadius:
                  const BorderRadius.horizontal(right: Radius.circular(6)),
              border: Border(
                left: BorderSide(
                  color: colorScheme.primary.withAlpha(200),
                  width: 3.2,
                ),
              ),
            ),
            child: Text.rich(
              TextSpan(
                children: _buildInlineSpans(
                  context,
                  quoteText,
                  baseStyle: TextStyle(
                    fontSize: isMobile ? 13.0 : 13.5,
                    fontStyle: FontStyle.italic,
                    color: colorScheme.onSurface.withAlpha(220),
                    height: 1.45,
                  ),
                  colorScheme: colorScheme,
                  onLinkTap: onLinkTap,
                  isMobile: isMobile,
                ),
              ),
            ),
          ),
        );
        continue;
      }

      // 4. Bullet List (- , * , • )
      final bulletMatch = RegExp(r'^(\s*)([-*•+])\s+(.*)$').firstMatch(line);
      if (bulletMatch != null) {
        final indentSpaces = bulletMatch.group(1)?.length ?? 0;
        final content = bulletMatch.group(3) ?? '';
        final double indent =
            (indentSpaces > 2 ? 24.0 : (indentSpaces > 0 ? 14.0 : 4.0));

        children.add(
          Padding(
            padding: EdgeInsets.only(left: indent, top: 2.5, bottom: 2.5),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 7, right: 8),
                  child: Container(
                    width: 5,
                    height: 5,
                    decoration: BoxDecoration(
                      color: colorScheme.primary.withAlpha(190),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: _buildInlineSpans(
                        context,
                        content,
                        baseStyle: TextStyle(
                          fontSize: isMobile ? 13.5 : 14.0,
                          height: 1.52,
                          color: colorScheme.onSurface,
                        ),
                        colorScheme: colorScheme,
                        onLinkTap: onLinkTap,
                        isMobile: isMobile,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
        continue;
      }

      // 5. Numbered List (1. , 2. )
      final numberMatch = RegExp(r'^(\s*)(\d+)\.\s+(.*)$').firstMatch(line);
      if (numberMatch != null) {
        final indentSpaces = numberMatch.group(1)?.length ?? 0;
        final numStr = numberMatch.group(2) ?? '1';
        final content = numberMatch.group(3) ?? '';
        final double indent =
            (indentSpaces > 2 ? 22.0 : (indentSpaces > 0 ? 12.0 : 2.0));

        children.add(
          Padding(
            padding: EdgeInsets.only(left: indent, top: 3.5, bottom: 3.5),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 22,
                  child: Text(
                    '$numStr.',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: isMobile ? 13.0 : 13.5,
                      fontWeight: FontWeight.w700,
                      color: colorScheme.primary,
                      height: 1.5,
                    ),
                  ),
                ),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: _buildInlineSpans(
                        context,
                        content,
                        baseStyle: TextStyle(
                          fontSize: isMobile ? 13.5 : 14.0,
                          height: 1.52,
                          color: colorScheme.onSurface,
                        ),
                        colorScheme: colorScheme,
                        onLinkTap: onLinkTap,
                        isMobile: isMobile,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
        continue;
      }

      // 6. Normal Paragraph line
      children.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Text.rich(
            TextSpan(
              children: _buildInlineSpans(
                context,
                line,
                baseStyle: TextStyle(
                  fontSize: isMobile ? 13.5 : 14.0,
                  height: 1.55,
                  color: colorScheme.onSurface,
                ),
                colorScheme: colorScheme,
                onLinkTap: onLinkTap,
                isMobile: isMobile,
              ),
            ),
          ),
        ),
      );
    }

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: onExpand,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: children,
      ),
    );
  }

  static final RegExp _inlinePattern = RegExp(
    r'(\[([^\]]+)\]\(([^)]+)\))|(`([^`\n]+)`)|(\*\*([^*]+)\*\*)|(\*([^*]+)\*)',
  );

  List<InlineSpan> _buildInlineSpans(
    BuildContext context,
    String raw, {
    required TextStyle baseStyle,
    required ColorScheme colorScheme,
    required void Function(String url, String label) onLinkTap,
    required bool isMobile,
  }) {
    final spans = <InlineSpan>[];
    int lastIndex = 0;
    for (final match in _inlinePattern.allMatches(raw)) {
      if (match.start > lastIndex) {
        spans.add(TextSpan(
          text: raw.substring(lastIndex, match.start),
          style: baseStyle,
        ));
      }

      if (match.group(1) != null) {
        // Link [label](url)
        final label = match.group(2) ?? '';
        final url = match.group(3) ?? '';
        final isFile = url.startsWith('file://') ||
            url.contains('/') ||
            url.endsWith('.apk') ||
            url.endsWith('.dart') ||
            url.endsWith('.rs') ||
            url.endsWith('.go') ||
            url.endsWith('.json');

        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: GestureDetector(
              onTap: () => onLinkTap(url, label),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 5.5, vertical: 1.5),
                margin: const EdgeInsets.symmetric(horizontal: 2.5),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E293B).withAlpha(190),
                  borderRadius: BorderRadius.circular(4.5),
                  border: Border.all(
                    color: const Color(0xFF3B82F6).withAlpha(140),
                    width: 0.8,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      isFile
                          ? Icons.description_outlined
                          : Icons.open_in_new_rounded,
                      size: 12.5,
                      color: const Color(0xFF60A5FA),
                    ),
                    const SizedBox(width: 3.5),
                    Text(
                      label,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12.0,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF60A5FA),
                        decoration: TextDecoration.underline,
                        decorationColor: Color(0xFF60A5FA),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      } else if (match.group(4) != null) {
        // Inline code `code`
        final codeText = match.group(5) ?? '';
        final screenWidth = MediaQuery.sizeOf(context).width;
        final maxCodeWidth =
            (screenWidth - (isMobile ? 80 : 180)).clamp(160.0, 720.0);

        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 2),
              padding:
                  const EdgeInsets.symmetric(horizontal: 5.5, vertical: 1.5),
              decoration: BoxDecoration(
                color: const Color(0xFF27272A),
                borderRadius: BorderRadius.circular(4.5),
                border: Border.all(
                  color: const Color(0xFF3F3F46),
                  width: 0.7,
                ),
              ),
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxCodeWidth),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Text(
                    codeText,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFFFDE047),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      } else if (match.group(6) != null) {
        // Bold **text**
        final boldText = match.group(7) ?? '';
        spans.add(TextSpan(
          text: boldText,
          style: baseStyle.copyWith(
            fontWeight: FontWeight.w700,
            color: Colors.white,
          ),
        ));
      } else if (match.group(8) != null) {
        // Italic *text*
        final italicText = match.group(9) ?? '';
        spans.add(TextSpan(
          text: italicText,
          style: baseStyle.copyWith(
            fontStyle: FontStyle.italic,
            color: const Color(0xFFA1A1AA),
          ),
        ));
      }

      lastIndex = match.end;
    }

    if (lastIndex < raw.length) {
      spans.add(TextSpan(
        text: raw.substring(lastIndex),
        style: baseStyle,
      ));
    }

    return spans;
  }
}

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
                        color: Colors.teal.withAlpha(30),
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: Text(
                        '+$totalAdded',
                        style: textTheme.labelSmall?.copyWith(
                          fontFamily: 'monospace',
                          fontSize: 10.5,
                          fontWeight: FontWeight.w800,
                          color: Colors.teal,
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
                        color: Colors.redAccent.withAlpha(30),
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: Text(
                        '-$totalRemoved',
                        style: textTheme.labelSmall?.copyWith(
                          fontFamily: 'monospace',
                          fontSize: 10.5,
                          fontWeight: FontWeight.w800,
                          color: Colors.redAccent,
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
                  for (final f in widget.groupedFiles)
                    Padding(
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
                                  crossAxisAlignment: CrossAxisAlignment.start,
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
                              if (f.addedLines > 0) ...[
                                Text(
                                  '+${f.addedLines}',
                                  style: textTheme.labelSmall?.copyWith(
                                    fontFamily: 'monospace',
                                    fontWeight: FontWeight.w800,
                                    color: Colors.teal,
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
                                    color: Colors.redAccent,
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
      bg = Colors.teal.withAlpha(35);
      fg = Colors.teal;
      label = 'NEW';
    } else if (action == 'EDIT') {
      bg = Colors.amber.withAlpha(35);
      fg = Colors.amber.shade700;
      label = 'MOD';
    } else {
      bg = Colors.blueGrey.withAlpha(30);
      fg = Colors.blueGrey;
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
                left: BorderSide(
                  color: colorScheme.outlineVariant,
                  width: 1.5,
                ),
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

class _ComposerPill extends StatelessWidget {
  const _ComposerPill({
    required this.icon,
    required this.label,
    required this.colorScheme,
    this.hasDropdown = false,
  });

  final IconData icon;
  final String label;
  final ColorScheme colorScheme;
  final bool hasDropdown;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withAlpha(180),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13.5, color: colorScheme.onSurfaceVariant),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: colorScheme.onSurface,
            ),
          ),
          if (hasDropdown) ...[
            const SizedBox(width: 2),
            Icon(
              Icons.keyboard_arrow_down_rounded,
              size: 14,
              color: colorScheme.onSurfaceVariant,
            ),
          ],
        ],
      ),
    );
  }
}

String _extractSpecificThinkingDetail(
  String rawStreamText,
  String userPrompt,
  AgentStep? step,
) {
  // 1. Nếu có streaming text từ agent, lấy dòng suy nghĩ có nghĩa gần nhất
  if (rawStreamText.isNotEmpty) {
    final lines = rawStreamText
        .split('\n')
        .map((l) => l.trim())
        .where((l) =>
            l.isNotEmpty &&
            !l.startsWith('```') &&
            !l.startsWith('#') &&
            !l.startsWith('<thought>') &&
            !l.startsWith('</thought>'))
        .toList();
    if (lines.isNotEmpty) {
      for (int i = lines.length - 1; i >= 0; i--) {
        final line = lines[i];
        final clean = line.replaceAll(RegExp(r'^[\*\-\d\.\s\>\:]+'), '').trim();
        if (clean.length >= 8 && !clean.toLowerCase().startsWith('ok')) {
          return clean.length > 95 ? '${clean.substring(0, 95)}...' : clean;
        }
      }
    }
  }

  // 2. Nếu có step.thinking
  if (step != null && step.thinking.isNotEmpty) {
    final lines = step.thinking
        .split('\n')
        .map((l) => l.trim())
        .where((l) =>
            l.isNotEmpty &&
            !l.startsWith('```') &&
            !l.startsWith('#') &&
            !l.startsWith('<thought>') &&
            !l.startsWith('</thought>'))
        .toList();
    if (lines.isNotEmpty) {
      for (int i = lines.length - 1; i >= 0; i--) {
        final line = lines[i];
        final clean = line.replaceAll(RegExp(r'^[\*\-\d\.\s\>\:]+'), '').trim();
        if (clean.length >= 8) {
          return clean.length > 95 ? '${clean.substring(0, 95)}...' : clean;
        }
      }
    }
  }

  // 3. Nếu có step.toolCalls
  if (step != null && step.toolCalls.isNotEmpty) {
    final t = step.toolCalls.last;
    final summary = t.args['toolSummary']?.toString() ?? '';
    if (summary.isNotEmpty) return summary;
    final path = t.args['Path']?.toString() ?? '';
    if (path.isNotEmpty) return '${t.name}: ${path.split('/').last}';
    final cmd = t.args['CommandLine']?.toString() ?? '';
    if (cmd.isNotEmpty) return '${t.name}: $cmd';
  }

  // 4. Nếu có step.vietnameseDetail hoặc vietnameseTitle
  if (step != null && step.vietnameseDetail.isNotEmpty) {
    return step.vietnameseDetail;
  }
  if (step != null && step.vietnameseTitle.isNotEmpty) {
    return step.vietnameseTitle;
  }

  // 5. Fallback vào userPrompt
  if (userPrompt.trim().isNotEmpty) {
    final cleanPrompt = userPrompt.replaceAll('\n', ' ').trim();
    return 'Đang phân tích yêu cầu: ${cleanPrompt.length > 70 ? '${cleanPrompt.substring(0, 70)}...' : cleanPrompt}';
  }

  return 'Đang suy nghĩ và lập kế hoạch thực hiện...';
}

/// Icon con robot với animation đang xử lý (pulsing scale, breathing glow & radar effect)
class _AnimatedThinkingRobotIcon extends StatefulWidget {
  const _AnimatedThinkingRobotIcon({
    this.size = 18,
    this.color,
  });

  final double size;
  final Color? color;

  @override
  State<_AnimatedThinkingRobotIcon> createState() =>
      _AnimatedThinkingRobotIconState();
}

class _AnimatedThinkingRobotIconState extends State<_AnimatedThinkingRobotIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scaleAnimation;
  late final Animation<double> _glowAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);

    _scaleAnimation = Tween<double>(begin: 0.88, end: 1.12).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );

    _glowAnimation = Tween<double>(begin: 0.25, end: 0.85).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final effectiveColor =
        widget.color ?? Theme.of(context).colorScheme.primary;

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Transform.scale(
          scale: _scaleAnimation.value,
          child: Container(
            width: widget.size + 8,
            height: widget.size + 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: effectiveColor.withAlpha((35 * _glowAnimation.value).round()),
              boxShadow: [
                BoxShadow(
                  color: effectiveColor.withAlpha((80 * _glowAnimation.value).round()),
                  blurRadius: 8 * _glowAnimation.value,
                  spreadRadius: 1.2 * _glowAnimation.value,
                ),
              ],
            ),
            child: Center(
              child: Icon(
                Icons.smart_toy_rounded,
                size: widget.size,
                color: effectiveColor,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Card trực quan hiển thị Robot Coordinator đang suy nghĩ & phân tích với animation
class _AnimatedThinkingRobotCard extends StatefulWidget {
  const _AnimatedThinkingRobotCard({
    required this.stream,
    this.lastStep,
    this.collapsedTailLines = 10,
  });

  final ChatTurnStreamState stream;
  final AgentStep? lastStep;
  final int collapsedTailLines;

  @override
  State<_AnimatedThinkingRobotCard> createState() =>
      _AnimatedThinkingRobotCardState();
}

class _AnimatedThinkingRobotCardState extends State<_AnimatedThinkingRobotCard>
    with TickerProviderStateMixin {
  late final AnimationController _pulseController;
  late final Animation<double> _borderGlowAnimation;

  late final AnimationController _rolloutController;
  late final Animation<double> _rolloutAnimation;
  late final Animation<Offset> _rolloutSlide;
  late final Animation<double> _rolloutFade;

  bool _isTraceExpanded = true;
  DateTime? _lastRolloutTrigger;
  int _lastLineCount = 0;
  String _lastAction = '';

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat(reverse: true);

    _borderGlowAnimation = Tween<double>(begin: 0.35, end: 0.95).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _rolloutController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 380),
    );

    _rolloutAnimation = CurvedAnimation(
      parent: _rolloutController,
      curve: Curves.easeOutCubic,
    );

    _rolloutSlide = Tween<Offset>(
      begin: const Offset(0, 0.08),
      end: Offset.zero,
    ).animate(_rolloutAnimation);

    _rolloutFade = Tween<double>(
      begin: 0.15,
      end: 1.0,
    ).animate(_rolloutAnimation);

    final text = widget.stream.streamingText;
    final action = _extractSpecificThinkingDetail(
      text,
      widget.stream.userPrompt,
      widget.lastStep,
    );
    _lastAction = action;
    final lines = text.trimRight().split('\n');
    _lastLineCount = text.trim().isEmpty ? 0 : lines.length;

    if (text.trim().isNotEmpty) {
      // Hiện title trước, sau đó animation chạy ra nội dung 10 dòng gần nhất
      Future.delayed(const Duration(milliseconds: 150), () {
        if (mounted) {
          _rolloutController.forward(from: 0.0);
        }
      });
    } else {
      _rolloutController.value = 0.0;
    }
  }

  @override
  void didUpdateWidget(_AnimatedThinkingRobotCard oldWidget) {
    super.didUpdateWidget(oldWidget);

    final oldText = oldWidget.stream.streamingText;
    final newText = widget.stream.streamingText;

    final newAction = _extractSpecificThinkingDetail(
      newText,
      widget.stream.userPrompt,
      widget.lastStep,
    );

    final newLines = newText.trimRight().split('\n');
    final newLineCount = newText.trim().isEmpty ? 0 : newLines.length;

    bool shouldAnimate = false;

    if (oldText.trim().isEmpty && newText.trim().isNotEmpty) {
      // Lần đầu có content sau khi title đã hiển thị
      shouldAnimate = true;
    } else if (newAction != _lastAction) {
      // Đổi bước / action cụ thể
      _lastAction = newAction;
      shouldAnimate = true;
    } else if (newLineCount != _lastLineCount) {
      // Có dòng mới được sinh ra
      _lastLineCount = newLineCount;
      shouldAnimate = true;
    } else if (newText != oldText) {
      // Content mới đang stream
      final now = DateTime.now();
      if (_lastRolloutTrigger == null ||
          now.difference(_lastRolloutTrigger!).inMilliseconds > 220) {
        shouldAnimate = true;
      }
    }

    if (shouldAnimate) {
      _triggerRollout();
    }
  }

  void _triggerRollout() {
    if (!mounted) return;
    _lastRolloutTrigger = DateTime.now();
    _rolloutController.forward(from: 0.0);
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _rolloutController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final stream = widget.stream;
    final lastStep = widget.lastStep;

    final stepIndex = lastStep?.stepIndex;
    final specificAction = _extractSpecificThinkingDetail(
      stream.streamingText,
      stream.userPrompt,
      lastStep,
    );

    final rawLines = stream.streamingText.trimRight().split('\n');
    final int maxTail = widget.collapsedTailLines > 0 ? widget.collapsedTailLines : 10;
    final recentLines = rawLines.length > maxTail
        ? rawLines.sublist(rawLines.length - maxTail)
        : rawLines;

    return AnimatedBuilder(
      animation: _pulseController,
      builder: (context, child) {
        return Container(
          margin: const EdgeInsets.only(top: 6, bottom: 8),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHigh.withAlpha(240),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: Colors.deepPurpleAccent
                  .withAlpha((180 * _borderGlowAnimation.value).round()),
              width: 1.2,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.deepPurpleAccent
                    .withAlpha((40 * _borderGlowAnimation.value).round()),
                blurRadius: 10 * _borderGlowAnimation.value,
                spreadRadius: 1,
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header Card
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
                child: Row(
                  children: [
                    const _AnimatedThinkingRobotIcon(
                      size: 20,
                      color: Colors.deepPurpleAccent,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                'Robot Coordinator',
                                style: textTheme.labelMedium?.copyWith(
                                  fontWeight: FontWeight.w800,
                                  color: Colors.deepPurpleAccent,
                                ),
                              ),
                              if (stepIndex != null) ...[
                                const SizedBox(width: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 5,
                                    vertical: 1,
                                  ),
                                  decoration: BoxDecoration(
                                    color: colorScheme.primaryContainer.withAlpha(150),
                                    borderRadius: BorderRadius.circular(4),
                                    border: Border.all(
                                      color: colorScheme.primary.withAlpha(120),
                                      width: 0.8,
                                    ),
                                  ),
                                  child: Text(
                                    'Bước #$stepIndex',
                                    style: TextStyle(
                                      fontFamily: 'monospace',
                                      fontSize: 9.5,
                                      fontWeight: FontWeight.w800,
                                      color: colorScheme.onPrimaryContainer,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 2),
                          Row(
                            children: [
                              Container(
                                width: 6,
                                height: 6,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: Colors.tealAccent.shade700,
                                ),
                              ),
                              const SizedBox(width: 4),
                              Text(
                                'AI Thinking • ${stream.activeStepType.isNotEmpty ? stream.activeStepType : 'processing'}',
                                style: textTheme.labelSmall?.copyWith(
                                  fontSize: 10,
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    // Nút thu gọn / mở rộng chi tiết suy nghĩ
                    if (stream.streamingText.trim().isNotEmpty)
                      InkWell(
                        borderRadius: BorderRadius.circular(6),
                        onTap: () => setState(() => _isTraceExpanded = !_isTraceExpanded),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                _isTraceExpanded ? 'Thu gọn' : 'Chi tiết',
                                style: TextStyle(
                                  fontSize: 10.5,
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                              const SizedBox(width: 2),
                              Icon(
                                _isTraceExpanded
                                    ? Icons.keyboard_arrow_up_rounded
                                    : Icons.keyboard_arrow_down_rounded,
                                size: 14,
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),

              // Banner: Đang làm cụ thể những gì
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                  color: Colors.deepPurpleAccent.withAlpha(25),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: Colors.deepPurpleAccent.withAlpha(70),
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(top: 2),
                      child: Icon(
                        Icons.bolt_rounded,
                        size: 14,
                        color: Colors.deepPurpleAccent,
                      ),
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: RichText(
                        text: TextSpan(
                          children: [
                            const TextSpan(
                              text: 'Đang làm: ',
                              style: TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w800,
                                color: Colors.deepPurpleAccent,
                              ),
                            ),
                            TextSpan(
                              text: specificAction,
                              style: TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                                color: colorScheme.onSurface,
                                height: 1.35,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              // Nội dung chi tiết suy nghĩ (khoảng 10 dòng content mới nhất với animation chạy ra)
              if (_isTraceExpanded && stream.streamingText.trim().isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
                  child: AnimatedSize(
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOutCubic,
                    child: AnimatedBuilder(
                      animation: _rolloutController,
                      builder: (context, _) {
                        return SlideTransition(
                          position: _rolloutSlide,
                          child: FadeTransition(
                            opacity: _rolloutFade,
                            child: Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: colorScheme.surfaceContainerLowest,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: Color.lerp(
                                    colorScheme.outlineVariant.withAlpha(70),
                                    Colors.deepPurpleAccent.withAlpha(200),
                                    (1.0 - _rolloutAnimation.value).clamp(0.0, 1.0),
                                  )!,
                                  width: 1.0,
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Row(
                                    children: [
                                      Container(
                                        width: 6,
                                        height: 6,
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: Colors.tealAccent.shade400,
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      Text(
                                        'Console (${recentLines.length} dòng mới nhất)',
                                        style: TextStyle(
                                          fontFamily: 'monospace',
                                          fontSize: 10,
                                          fontWeight: FontWeight.w700,
                                          color: colorScheme.onSurfaceVariant,
                                        ),
                                      ),
                                      const Spacer(),
                                      if (stream.isRunning) ...[
                                        Text(
                                          'LIVE STREAM',
                                          style: TextStyle(
                                            fontFamily: 'monospace',
                                            fontSize: 9,
                                            fontWeight: FontWeight.w800,
                                            color: Colors.deepPurpleAccent,
                                            letterSpacing: 0.5,
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                  const SizedBox(height: 6),
                                  SelectableText.rich(
                                    TextSpan(
                                      children: [
                                        TextSpan(
                                          text: recentLines.join('\n'),
                                          style: textTheme.bodySmall?.copyWith(
                                            fontFamily: 'monospace',
                                            fontSize: 11,
                                            height: 1.45,
                                            color: colorScheme.onSurfaceVariant,
                                          ),
                                        ),
                                        if (stream.isRunning)
                                          TextSpan(
                                            text: ' █',
                                            style: TextStyle(
                                              fontFamily: 'monospace',
                                              fontSize: 11,
                                              color: Colors.deepPurpleAccent
                                                  .withAlpha((255 * _borderGlowAnimation.value).round()),
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ] else
                const SizedBox(height: 6),

              if (stream.error.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
                  child: Text(
                    stream.error,
                    style: textTheme.bodySmall?.copyWith(
                      color: Colors.redAccent,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}
