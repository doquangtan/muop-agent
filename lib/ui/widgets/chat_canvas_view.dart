import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/agent_models.dart';
import 'interaction_dialogs.dart';
import 'interaction_widgets.dart';
import 'server_file_browser_sheet.dart';
import '../theme/app_theme.dart';

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
    this.pendingClaudeInteraction,
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
    this.onRespondClaudeInteraction,
    this.onApprovePlan,
    this.onRejectPlan,
    this.onCancelPlan,
    this.onLoadOlderHistory,
    this.onFetchClaudeExtensions,
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
  final PendingClaudeInteraction? pendingClaudeInteraction;
  final Future<String?> Function(
    PendingClaudeInteraction interaction,
    List<Map<String, String>> answers,
    String decision,
    String feedback,
  )? onRespondClaudeInteraction;
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
  final ValueChanged<PlanArtifactInfo>? onCancelPlan;
  final Future<bool> Function()? onLoadOlderHistory;
  final Future<List<CustomAgentSpec>?> Function(String projectPath)?
      onFetchClaudeExtensions;
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
  aiTurnCard,
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
    this.stream,
    this.isLastTurn = false,
    this.remainingCount = 0,
    this.loadedCount = 0,
    this.totalTurnsCount = 0,
  });

  final _ChatBlockKind kind;
  final String keyId;
  final _ChatTurnGroup? turn;
  final ChatTurnStreamState? stream;
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
  bool _composerRevealed = false;

  /// Lưu trạng thái mở rộng (show full) của từng đoạn response theo turnIndex
  final Set<int> _expandedResponseTurns = {};

  /// Lưu trạng thái mở rộng (show full) của prompt người dùng theo turnIndex
  final Set<int> _expandedPromptTurns = {};

  /// Cache danh sách các đoạn văn/code đã tách để không phải regex lại khi cuộn
  final Map<String, List<_ParsedResponseSegment>> _segmentCache = {};

  /// Cache tính toán turns & flat blocks để không bị lag giật mỗi khi gõ phím hoặc rebuild
  String? _lastSessionId;
  // Chữ ký nội dung steps: số lượng không đủ vì snapshot cắt còn 100 step nên
  // lượt trả lời mới có thể làm số lượng giữ nguyên. Dùng thêm step cuối và updatedAt.
  int _lastStepsSignature = -1;
  int _lastFilesTouchedCount = -1;
  int _lastLoadedTurnCount = -1;
  int _lastExpandedResponseTurnsHash = 0;
  int _lastExpandedPromptTurnsHash = 0;
  List<_ChatTurnGroup> _cachedAllTurns = const [];
  List<_ChatFlatBlock> _cachedFlatBlocks = const [];

  /// Cache danh sách files thay đổi để tránh groupRecords lặp lại trên mỗi frame render
  int _lastGroupedFilesRecordCount = -1;
  String? _lastGroupedFilesSessionId;
  List<GroupedFileChange> _cachedGroupedSessionFiles = const [];
  int _cachedTotalAdded = 0;
  int _cachedTotalRemoved = 0;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToBottom(animated: false);
      _maybeLoadOlderTurns();
    });
  }

  @override
  void didUpdateWidget(covariant ChatCanvasView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldId = oldWidget.session?.id;
    final newId = widget.session?.id;
    if (_isTurnRunning(oldWidget) && !_isTurnRunning(widget)) {
      _composerRevealed = false;
    }
    if (oldId != newId ||
        oldWidget.isNewConversationMode != widget.isNewConversationMode) {
      _composerRevealed = false;
      _loadedTurnCount = _pageSize;
      _isLoadingMoreTurns = false;
      _hasLoadedAllServerHistory = false;
      _expandedResponseTurns.clear();
      _expandedPromptTurns.clear();
      _lastSessionId = null;
      _lastStepsSignature = -1;
      _lastFilesTouchedCount = -1;
      _lastLoadedTurnCount = -1;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToBottom(animated: false);
        _maybeLoadOlderTurns();
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

    _maybeLoadOlderTurns();
  }

  /// Nạp thêm lịch sử khi banner đầu danh sách còn nằm trong khung nhìn.
  /// Được gọi lại sau mỗi lần nạp để tiếp tục cho đến khi banner bị đẩy ra ngoài
  /// hoặc hết dữ liệu cũ.
  void _maybeLoadOlderTurns() {
    if (!_scrollController.hasClients || _isLoadingMoreTurns) return;
    final pos = _scrollController.position;
    if (pos.maxScrollExtent - pos.pixels < pos.viewportDimension) {
      _loadOlderTurnsPage();
    }
  }

  void _scheduleOlderTurnsCheck() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _maybeLoadOlderTurns();
    });
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
      _scheduleOlderTurnsCheck();
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
          _scheduleOlderTurnsCheck();
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

  static bool _isTurnRunning(ChatCanvasView w) {
    final session = w.session;
    return !w.isNewConversationMode &&
        (session?.isInterrupted != true) &&
        (w.isSending ||
            (w.activeStream != null &&
                w.activeStream!.isRunning &&
                w.activeStream!.activeStepType != 'interrupted') ||
            (session != null && session.status == AgentStatus.running));
  }

  void _handleSend() {
    final text = _promptController.text.trim();
    if (text.isEmpty || widget.isSending) return;
    _promptController.clear();
    setState(() => _composerRevealed = false);
    widget.onSendMessage(text);
    Future.delayed(const Duration(milliseconds: 100), () {
      _scrollToBottom(animated: true);
    });
  }

  KeyEventResult _handleComposerKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key != LogicalKeyboardKey.enter && key != LogicalKeyboardKey.numpadEnter) {
      return KeyEventResult.ignored;
    }
    if (HardwareKeyboard.instance.isShiftPressed) return KeyEventResult.ignored;
    if (_promptController.value.composing.isValid) return KeyEventResult.ignored;
    _handleSend();
    return KeyEventResult.handled;
  }

  /// Model thuộc Claude Code CLI (id dạng `claude-cli:<alias>`), còn lại là Antigravity (`agy:<model>`)
  bool _isClaudeCliModel(String modelId) => modelId.startsWith('claude-cli:');

  String _formatModelLabel(String modelId) {
    switch (modelId) {
      case 'default':
      case 'claude-cli:claude-sonnet-5-5':
        return 'Claude Sonnet 5.5';
      case 'claude-cli:claude-opus-5-5':
        return 'Claude Opus 5.5';
      case 'claude-cli:claude-haiku-5-5':
        return 'Claude Haiku 5.5';
      case 'agy:gemini-3.8-flash-high':
        return 'Gemini 3.8 Flash (High)';
      case 'agy:gemini-3.8-flash-medium':
        return 'Gemini 3.8 Flash (Medium)';
      case 'agy:claude-sonnet-5-5-high':
        return 'Claude Sonnet 5.5 (agy)';
      case 'agy:claude-opus-5-5-high':
        return 'Claude Opus 5.5 (agy)';
      case 'agy:gemini-4-argon-high':
        return 'Gemini 4 Argon (High)';
      case 'agy:gemini-4-argon-medium':
        return 'Gemini 4 Argon (Medium)';
      default:
        // Model Antigravity lấy động từ `agy models`: hiển thị id không có tiền tố provider
        return modelId.startsWith('agy:') ? modelId.substring(4) : modelId;
    }
  }

  /// Model đầu tiên của một nhóm provider (để chèn header trong popup)
  bool _isGroupStart(String modelId) {
    final index = widget.availableModels.indexOf(modelId);
    if (index <= 0) return true;
    return _isClaudeCliModel(modelId) !=
        _isClaudeCliModel(widget.availableModels[index - 1]);
  }

  /// Header của mỗi nhóm provider trong popup chọn model
  List<PopupMenuEntry<String>> _providerHeaderEntries(
    String modelId,
    ColorScheme colorScheme, {
    required bool showDivider,
  }) {
    final isClaude = _isClaudeCliModel(modelId);
    return [
      if (showDivider) const PopupMenuDivider(),
      PopupMenuItem<String>(
        enabled: false,
        height: 34,
        child: Row(
          children: [
            Icon(
              isClaude ? Icons.terminal_rounded : Icons.hub_rounded,
              size: 14,
              color: colorScheme.primary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                isClaude
                    ? 'Claude Code CLI · limit tài khoản Claude'
                    : 'Antigravity (agy) · quota Gemini/Claude',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    ];
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
    final stream = widget.activeStream;
    final streamRunning = stream != null && stream.isRunning;
    // Khi session đang chạy, thinking của stream nằm bên trong thẻ AI của lượt mới nhất
    final liveAttached = streamRunning &&
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
      final hasAiContent = turn.finalAgentResponse.isNotEmpty ||
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

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isMobile = MediaQuery.sizeOf(context).width < 760;
    final session = widget.session;
    final isTurnRunning = _isTurnRunning(widget);

    final currentSessionId = session?.id;
    final lastStepForSig =
        (session != null && session.steps.isNotEmpty) ? session.steps.last : null;
    final currentStepsSignature = Object.hash(
      session?.steps.length ?? 0,
      lastStepForSig?.stepIndex,
      lastStepForSig?.status,
      lastStepForSig?.content.length,
      lastStepForSig?.thinking.length,
      lastStepForSig?.toolCalls.length,
      session?.updatedAt.millisecondsSinceEpoch,
      session?.status,
      widget.activeStream?.isRunning,
    );
    final currentFilesTouchedCount = session?.filesTouched.length ?? 0;
    final currentResponseTurnsHash =
        _expandedResponseTurns.fold<int>(0, (prev, e) => prev ^ e);
    final currentPromptTurnsHash =
        _expandedPromptTurns.fold<int>(0, (prev, e) => prev ^ e);

    final bool shouldRecomputeBlocks = widget.isNewConversationMode ||
        session == null ||
        _lastSessionId != currentSessionId ||
        _lastStepsSignature != currentStepsSignature ||
        _lastFilesTouchedCount != currentFilesTouchedCount ||
        _lastLoadedTurnCount != _loadedTurnCount ||
        _lastExpandedResponseTurnsHash != currentResponseTurnsHash ||
        _lastExpandedPromptTurnsHash != currentPromptTurnsHash;

    if (shouldRecomputeBlocks) {
      _lastSessionId = currentSessionId;
      _lastStepsSignature = currentStepsSignature;
      _lastFilesTouchedCount = currentFilesTouchedCount;
      _lastLoadedTurnCount = _loadedTurnCount;
      _lastExpandedResponseTurnsHash = currentResponseTurnsHash;
      _lastExpandedPromptTurnsHash = currentPromptTurnsHash;

      _cachedAllTurns = (!widget.isNewConversationMode && session != null)
          ? _buildTurnGroups(session.steps, session.filesTouched)
          : const <_ChatTurnGroup>[];

      final int startIdx =
          math.max(0, _cachedAllTurns.length - _loadedTurnCount);
      final visibleTurns = _cachedAllTurns.sublist(startIdx);
      final int remainingOlderTurns = startIdx;

      _cachedFlatBlocks = _buildFlatBlocks(
        visibleTurns: visibleTurns,
        remainingOlderTurns: remainingOlderTurns,
        totalTurnsCount: _cachedAllTurns.length,
      );
    }

    final flatBlocks = _cachedFlatBlocks;

    return Column(
      children: [
        // 1. Luồng tin nhắn đã được làm phẳng (flattened) & ảo hóa bằng ListView.builder
        Expanded(
          child: RepaintBoundary(
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
        ),

        // 2. BOTTOM DOCK:
        //    [Trên]   Task Running Panel (nằm phía trên khung chat)
        //    [Giữa]   Thanh % Usage (Limit Tuần / Limit Giờ chuẩn Antigravity)
        //    [Dưới]   Khung nhập Chat (Composer Box)
        RepaintBoundary(
          child: _buildBottomDockStack(context, isMobile, isTurnRunning),
        ),
      ],
    );
  }

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
        return _buildStandaloneLiveCard(context, block.stream!);

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
                          maxLines: (exceedsFiveLines && !isExpanded) ? 5 : null,
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
                                setState(() {
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
        final liveStream = (block.isLastTurn &&
                widget.activeStream != null &&
                widget.activeStream!.isRunning &&
                widget.session?.status == AgentStatus.running)
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
                  bottom: BorderSide(color: context.scheme.outlineVariant, width: 0.8),
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
    final claudeInteraction = widget.pendingClaudeInteraction;
    final showClaudeInteraction = claudeInteraction != null &&
        widget.onRespondClaudeInteraction != null &&
        claudeInteraction.conversationId == widget.session?.id &&
        !isTurnRunning;

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

              // [3] PHẦN DƯỚI: KHUNG NHẬP CHAT (ẩn khi đang chạy, bấm để hiện)
              if (isTurnRunning && !_composerRevealed)
                _buildHiddenComposerBar(context)
              else ...[
                if (isTurnRunning)
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: () => setState(() => _composerRevealed = false),
                      icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 18),
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
            icon: Icon(Icons.stop_rounded, size: 18, color: context.scheme.error),
          ),
          TextButton.icon(
            onPressed: () => setState(() => _composerRevealed = true),
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
                                    Icon(
                                      Icons.check_circle_rounded,
                                      color: context.scheme.onPrimary,
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
                                backgroundColor: context.status.success,
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

  Widget _buildPlanBanner(BuildContext context, PlanArtifactInfo plan) {
    return InteractionBanner(
      icon: Icons.assignment_outlined,
      title: 'Agent đã trình kế hoạch, chờ bạn duyệt',
      subtitle: plan.fileName,
      actionLabel: 'Xem & duyệt',
      onAction: () => _showPlanReview(context, plan),
    );
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
                                      color: context.status.warning.withAlpha(100),
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
                                    AlwaysStoppedAnimation<Color>(
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
                                      color: context.status.warning,
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
                          icon: Icon(
                            Icons.alt_route_rounded,
                            size: 16,
                            color: context.scheme.tertiary,
                          ),
                          label: Text(
                            'Xem toàn bộ Sơ đồ Luồng Parallel Agent',
                            style: TextStyle(color: context.scheme.tertiary),
                          ),
                          style: OutlinedButton.styleFrom(
                            side: BorderSide(
                              color: context.scheme.tertiary,
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
                                      color: context.status.success.withAlpha(100),
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
            Icon(
              Icons.check_circle_outline_rounded,
              size: 15,
              color: context.status.success,
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
                    color: context.scheme.tertiary.withAlpha(35),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: context.scheme.tertiary.withAlpha(120),
                    ),
                  ),
                  child: Text(
                    'Parallel Flow',
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      color: context.scheme.tertiary,
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
          coordinatorActionTitle = 'Bước #$currentStepIndex: ${summary.isNotEmpty ? summary : (lastStep.vietnameseTitle.isNotEmpty ? lastStep.vietnameseTitle : 'Thực thi lệnh terminal')}';
          coordinatorActionDetail = cmd.isNotEmpty ? cmd : lastStep.vietnameseDetail;
          break;
        case 'edit_file':
          coordinatorBadgeColor = context.status.warning;
          coordinatorActionIcon = Icons.edit_note_rounded;
          final path = lastTool.args['Path']?.toString() ?? '';
          coordinatorActionTitle = 'Bước #$currentStepIndex: ${lastStep.vietnameseTitle.isNotEmpty ? lastStep.vietnameseTitle : 'Chỉnh sửa tệp nguồn'}';
          coordinatorActionDetail = path.isNotEmpty ? path.split('/').last : lastStep.vietnameseDetail;
          break;
        case 'write_file':
          coordinatorBadgeColor = context.status.success;
          coordinatorActionIcon = Icons.note_add_rounded;
          final path = lastTool.args['Path']?.toString() ?? '';
          coordinatorActionTitle = 'Bước #$currentStepIndex: ${lastStep.vietnameseTitle.isNotEmpty ? lastStep.vietnameseTitle : 'Tạo mới tệp tin'}';
          coordinatorActionDetail = path.isNotEmpty ? path.split('/').last : lastStep.vietnameseDetail;
          break;
        case 'read_file':
          coordinatorBadgeColor = context.status.warning;
          coordinatorActionIcon = Icons.search_rounded;
          final path = lastTool.args['Path']?.toString() ?? '';
          coordinatorActionTitle = 'Bước #$currentStepIndex: ${lastStep.vietnameseTitle.isNotEmpty ? lastStep.vietnameseTitle : 'Đọc nội dung tệp tin'}';
          coordinatorActionDetail = path.isNotEmpty ? path.split('/').last : lastStep.vietnameseDetail;
          break;
        case 'invoke_subagent':
          coordinatorBadgeColor = context.scheme.tertiary;
          coordinatorActionIcon = Icons.alt_route_rounded;
          final role = lastTool.args['Role']?.toString() ?? '';
          coordinatorActionTitle = 'Bước #$currentStepIndex: ${role.isNotEmpty ? 'Phân quyền: $role' : 'Điều phối Subagent song song'}';
          coordinatorActionDetail = lastTool.args['Prompt']?.toString() ?? lastStep.vietnameseDetail;
          break;
        default:
          coordinatorBadgeColor = context.scheme.tertiary;
          coordinatorActionIcon = Icons.build_circle_outlined;
          coordinatorActionTitle = 'Bước #$currentStepIndex: ${lastStep.vietnameseTitle.isNotEmpty ? lastStep.vietnameseTitle : 'Công cụ: $toolName'}';
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
      coordinatorBadgeColor = isPlanner ? context.scheme.tertiary : colorScheme.primary;
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
                          color: context.status.success.withAlpha(35),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: context.status.success.withAlpha(100)),
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
                          color: context.scheme.tertiary.withAlpha(35),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: context.scheme.tertiary.withAlpha(120),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.alt_route_rounded,
                              size: 11,
                              color: context.scheme.tertiary,
                            ),
                            const SizedBox(width: 3),
                            Text(
                              'Flow',
                              style: textTheme.labelSmall?.copyWith(
                                fontSize: 9.5,
                                fontWeight: FontWeight.w800,
                                color: context.scheme.tertiary,
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
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.8,
                        valueColor:
                            AlwaysStoppedAnimation<Color>(context.status.warning),
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
                          color: context.scheme.tertiary.withAlpha(25),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: context.scheme.tertiary.withAlpha(90),
                          ),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.account_tree_outlined,
                              size: 14,
                              color: context.scheme.tertiary,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              'Xem biểu đồ trực quan Luồng chạy Parallel Agent (Swimlanes & Checklist)',
                              style: textTheme.labelSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                                color: context.scheme.tertiary,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Icon(
                              Icons.arrow_forward_rounded,
                              size: 13,
                              color: context.scheme.tertiary,
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

  /// Lọc danh sách model dựa trên session source
  List<String> _getFilteredModelsForSession() {
    final session = widget.session;
    if (session == null || widget.isNewConversationMode) {
      return widget.availableModels;
    }

    if (session.source == 'claude-cli') {
      return widget.availableModels
          .where((m) => m.startsWith('claude-cli:'))
          .toList();
    } else {
      return widget.availableModels
          .where((m) => m.startsWith('agy:'))
          .toList();
    }
  }

  /// Tìm nhóm Quota Antigravity khớp với Model đang chọn
  ({
    ModelQuotaGroup? primaryGroup,
    ModelQuotaGroup? geminiGroup,
  }) _resolveQuotaForSelectedModel() {
    ModelQuotaGroup? gemini;
    ModelQuotaGroup? claudeGpt;
    ModelQuotaGroup? argon;

    ModelQuotaGroup? claudeCode;
    for (final g in widget.modelQuotas) {
      final lower = g.displayName.toLowerCase();
      if (lower.contains('claude code')) {
        // Limit tài khoản của Claude Code CLI: chỉ dùng cho model claude-cli
        claudeCode = g;
      } else if (lower.contains('argon')) {
        argon = g;
      } else if (lower.contains('claude') || lower.contains('gpt')) {
        claudeGpt = g;
      } else if (lower.contains('gemini')) {
        gemini = g;
      }
    }

    if (_isClaudeCliModel(widget.selectedModel)) {
      return (primaryGroup: claudeCode, geminiGroup: null);
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
    if (remainingPct <= 15) return context.scheme.error;
    if (remainingPct <= 45) return context.status.warning;
    return context.status.success;
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
            tooltip:
                'Chọn model: Claude Code CLI (claude) hoặc Antigravity (agy)',
            onSelected: widget.onSelectModel,
            itemBuilder: (ctx) {
              final filteredModels = _getFilteredModelsForSession();
              return [
                for (final m in filteredModels) ...[
                  if (_isGroupStart(m))
                    ..._providerHeaderEntries(
                      m,
                      colorScheme,
                      showDivider: filteredModels.indexOf(m) > 0,
                    ),
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
              ];
            },
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
                      'Quota & Limits: Antigravity + Claude Code CLI (Realtime)',
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
            color: context.scheme.shadow.withAlpha(14),
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
            child: RepaintBoundary(
              child: Focus(
                onKeyEvent: isMobile ? null : _handleComposerKeyEvent,
                child: TextField(
                  controller: _promptController,
                  focusNode: _inputFocusNode,
                  minLines: 4,
                  maxLines: 10,
                  keyboardType: TextInputType.multiline,
                  autocorrect: false,
                  enableSuggestions: true,
                  textInputAction: TextInputAction.newline,
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
                      backgroundColor: context.scheme.error.withAlpha(40),
                      foregroundColor: context.scheme.error,
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

  Future<void> _showSlashCommandsPicker(BuildContext context) async {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final isClaude = _isClaudeCliModel(widget.selectedModel);
    final List<CustomAgentSpec> projectSkills;
    final List<CustomAgentSpec> claudeAgents;
    final List<CustomAgentSpec> claudeCommands;
    if (isClaude) {
      final projectPath =
          widget.session?.projectPath ?? widget.selectedProject?.path ?? '';
      final items = await widget.onFetchClaudeExtensions?.call(projectPath) ??
          const <CustomAgentSpec>[];
      if (!context.mounted) return;
      projectSkills = items.where((s) => s.kind == 'skill').toList();
      claudeAgents = items.where((s) => s.kind == 'agent').toList();
      claudeCommands = items.where((s) => s.kind == 'command').toList();
    } else {
      final sessionCustom = widget.session?.customAgents ?? const [];
      final allCustom = sessionCustom.isNotEmpty
          ? sessionCustom
          : widget.selectedProject?.customAgents ?? const [];
      projectSkills = allCustom.where((s) => s.kind == 'skill').toList();
      claudeAgents = const [];
      claudeCommands = const [];
    }
    final skillSourceLabel = isClaude
        ? 'Kỹ năng Claude Code (.claude/skills)'
        : 'Kỹ năng Dự án & Ecosystem (.agents)';

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

            bool matchesQuery(CustomAgentSpec s) {
              if (query.isEmpty) return true;
              return s.name.toLowerCase().contains(query) ||
                  s.description.toLowerCase().contains(query);
            }

            final filteredSkills = projectSkills.where(matchesQuery).toList();
            final filteredAgents = claudeAgents.where(matchesQuery).toList();
            final filteredCommands =
                claudeCommands.where(matchesQuery).toList();

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
                          Icon(
                            Icons.terminal_rounded,
                            size: 20,
                            color: context.scheme.tertiary,
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
                          if (filteredSkills.isNotEmpty)
                            ..._buildSlashGroup(
                              ctx,
                              title: skillSourceLabel,
                              icon: Icons.auto_awesome_rounded,
                              color: context.scheme.tertiary,
                              itemIcon: Icons.auto_awesome_rounded,
                              items: filteredSkills,
                              tokenOf: (s) => '/${s.name}',
                            ),
                          if (filteredAgents.isNotEmpty)
                            ..._buildSlashGroup(
                              ctx,
                              title: 'Sub-agents Claude Code (.claude/agents)',
                              icon: Icons.smart_toy_rounded,
                              color: context.status.success,
                              itemIcon: Icons.smart_toy_outlined,
                              items: filteredAgents,
                              tokenOf: (s) => '@agent-${s.name}',
                            ),
                          if (filteredCommands.isNotEmpty)
                            ..._buildSlashGroup(
                              ctx,
                              title: 'Lệnh Claude Code (.claude/commands)',
                              icon: Icons.terminal_rounded,
                              color: colorScheme.secondary,
                              itemIcon: Icons.code_rounded,
                              items: filteredCommands,
                              tokenOf: (s) => '/${s.name}',
                            ),
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
                          if (filteredSkills.isEmpty &&
                              filteredAgents.isEmpty &&
                              filteredCommands.isEmpty &&
                              filteredCore.isEmpty)
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

  List<Widget> _buildSlashGroup(
    BuildContext sheetCtx, {
    required String title,
    required IconData icon,
    required Color color,
    required IconData itemIcon,
    required List<CustomAgentSpec> items,
    required String Function(CustomAgentSpec spec) tokenOf,
  }) {
    final colorScheme = Theme.of(sheetCtx).colorScheme;
    final textTheme = Theme.of(sheetCtx).textTheme;
    return [
      Padding(
        padding: const EdgeInsets.only(top: 6, bottom: 6),
        child: Row(
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 6),
            Text(
              title,
              style: textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.w800,
                color: color,
              ),
            ),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: color.withAlpha(30),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                '${items.length}',
                style: TextStyle(
                  fontSize: 9.5,
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
            ),
          ],
        ),
      ),
      for (final s in items)
        InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () {
            Navigator.of(sheetCtx).pop();
            _insertSlashCommand('${tokenOf(s)} ');
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
                    color: color.withAlpha(25),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(itemIcon, size: 16, color: color),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        tokenOf(s),
                        style: textTheme.labelLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: color,
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
    ];
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
                _lastLinesOf(visibleText, _collapsedTailLines),
                turnIndex: -1,
                isExpanded: true,
                isMobile: isMobile,
              ),
            ),
            const SizedBox(height: 8),
          ],
          if (stream.isRunning)
            _AnimatedThinkingRobotCard(
              stream: stream,
              lastStep: lastStep,
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
    final responseText =
        liveText.trim().isNotEmpty ? liveText : turn.finalAgentResponse;
    final hasTools = turn.totalToolCount > 0 || turn.totalThoughtCount > 0;
    final isSessionRunning = widget.session?.status == AgentStatus.running;
    final lastStep = turn.agentSteps.isNotEmpty ? turn.agentSteps.last : null;

    final allLines = responseText.trimRight().split('\n');
    final canCollapse =
        responseText.isNotEmpty && allLines.length > _collapsedTailLines;
    final isExpanded = _expandedResponseTurns.contains(turn.turnIndex);
    final hiddenLines = canCollapse ? allLines.length - _collapsedTailLines : 0;
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
                  ? _lastLinesOf(visibleText, _collapsedTailLines)
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
                setState(() {
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
          _AnimatedThinkingRobotCard(
            stream: liveStream,
            lastStep: lastStep,
          ),
        ] else if (isLastTurn && isSessionRunning && responseText.isEmpty)
          Padding(
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
                    lastStep?.vietnameseTitle ?? 'Đang xử lý...',
                    style: textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        if (hasTools || turn.groupedFiles.isNotEmpty) ...[
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (hasTools) _buildToolActionsButton(context, turn),
                if (hasTools && turn.groupedFiles.isNotEmpty)
                  const SizedBox(width: 8),
                if (turn.groupedFiles.isNotEmpty)
                  _buildFilesChip(context, turn),
              ],
            ),
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
                  color: context.scheme.surfaceContainerHighest.withAlpha(190),
                  borderRadius: BorderRadius.circular(4.5),
                  border: Border.all(
                    color: context.scheme.secondary.withAlpha(140),
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
                      color: context.scheme.primary,
                    ),
                    const SizedBox(width: 3.5),
                    Text(
                      label,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12.0,
                        fontWeight: FontWeight.w600,
                        color: context.scheme.primary,
                        decoration: TextDecoration.underline,
                        decorationColor: context.scheme.primary,
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
                color: context.scheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(4.5),
                border: Border.all(
                  color: context.scheme.outlineVariant,
                  width: 0.7,
                ),
              ),
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxCodeWidth),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Text(
                    codeText,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: context.status.warning,
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
            color: context.scheme.onPrimary,
          ),
        ));
      } else if (match.group(8) != null) {
        // Italic *text*
        final italicText = match.group(9) ?? '';
        spans.add(TextSpan(
          text: italicText,
          style: baseStyle.copyWith(
            fontStyle: FontStyle.italic,
            color: context.scheme.onSurfaceVariant,
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

/// Hiệu ứng đẻ ra từng từ / từng chữ kiểu AI (Streaming Typewriter with Pulsing Cursor)
/// Gõ từng chữ cho nội dung phản hồi AI.
/// Dữ liệu mới được nối tiếp vào phần đang hiện (không gõ lại từ đầu).
/// Nếu nội dung thay đổi không phải là phần nối thêm thì hiện ngay toàn bộ.
/// Lần đầu hiển thị (lịch sử cũ) cũng hiện ngay, không gõ.
class _AiResponseTypewriter extends StatefulWidget {
  const _AiResponseTypewriter({
    required this.text,
    required this.builder,
  });

  final String text;
  final Widget Function(BuildContext context, String visibleText) builder;

  @override
  State<_AiResponseTypewriter> createState() => _AiResponseTypewriterState();
}

class _AiResponseTypewriterState extends State<_AiResponseTypewriter> {
  static const Duration _tick = Duration(milliseconds: 20);
  Timer? _timer;
  late int _visibleLength = widget.text.length;

  @override
  void didUpdateWidget(covariant _AiResponseTypewriter oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text == widget.text) return;
    if (!widget.text.startsWith(oldWidget.text)) {
      // Không phải nội dung nối thêm (vd. đổi lượt, làm lại): hiện ngay
      _timer?.cancel();
      _visibleLength = widget.text.length;
      return;
    }
    if (_visibleLength > widget.text.length) {
      _visibleLength = widget.text.length;
    }
    _ensureTimer();
  }

  void _ensureTimer() {
    if (_timer?.isActive == true) return;
    if (_visibleLength >= widget.text.length) return;
    _timer = Timer.periodic(_tick, (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      final remaining = widget.text.length - _visibleLength;
      if (remaining <= 0) {
        timer.cancel();
        return;
      }
      final step = math.max(1, (remaining / 18).ceil());
      setState(() {
        _visibleLength = math.min(_visibleLength + step, widget.text.length);
      });
      if (_visibleLength >= widget.text.length) timer.cancel();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final len = _visibleLength.clamp(0, widget.text.length);
    return widget.builder(context, widget.text.substring(0, len));
  }
}

class _AiStreamingTypewriterText extends StatefulWidget {
  const _AiStreamingTypewriterText({
    required this.text,
    this.prefix = '',
    this.prefixStyle,
    this.textStyle,
    this.cursorColor,
  });

  final String text;
  final String prefix;
  final TextStyle? prefixStyle;
  final TextStyle? textStyle;
  final Color? cursorColor;
  static const Duration charInterval = Duration(milliseconds: 20);

  @override
  State<_AiStreamingTypewriterText> createState() =>
      _AiStreamingTypewriterTextState();
}

class _AiStreamingTypewriterTextState extends State<_AiStreamingTypewriterText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _cursorBlinkController;
  Timer? _typewriterTimer;
  int _displayedLength = 0;
  String _targetText = '';

  @override
  void initState() {
    super.initState();
    _cursorBlinkController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 450),
    )..repeat(reverse: true);

    _targetText = widget.text;
    _displayedLength = 0;
    _startTyping();
  }

  @override
  void didUpdateWidget(covariant _AiStreamingTypewriterText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      _targetText = widget.text;
      // Nếu text mới bắt đầu bằng phần đã hiển thị, giữ nguyên tiến trình và gõ tiếp
      final currentSub = oldWidget.text.length >= _displayedLength
          ? oldWidget.text.substring(0, _displayedLength)
          : oldWidget.text;
      if (!widget.text.startsWith(currentSub)) {
        // Tìm prefix chung
        int common = 0;
        final minLen = math.min(_displayedLength, widget.text.length);
        while (common < minLen && oldWidget.text[common] == widget.text[common]) {
          common++;
        }
        _displayedLength = common;
      }
      _startTyping();
    }
  }

  void _startTyping() {
    _typewriterTimer?.cancel();
    if (_displayedLength >= _targetText.length) {
      if (mounted) setState(() {});
      return;
    }

    _typewriterTimer =
        Timer.periodic(_AiStreamingTypewriterText.charInterval, (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_displayedLength < _targetText.length) {
        final remaining = _targetText.length - _displayedLength;
        final stepChars = math.max(2, (remaining / 24).ceil());
        setState(() {
          _displayedLength =
              math.min(_displayedLength + stepChars, _targetText.length);
        });
      } else {
        timer.cancel();
      }
    });
  }

  @override
  void dispose() {
    _typewriterTimer?.cancel();
    _cursorBlinkController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final effectiveText =
        _targetText.substring(0, _displayedLength.clamp(0, _targetText.length));
    final isTyping = _displayedLength < _targetText.length;
    final cursorColor = widget.cursorColor ?? context.scheme.tertiary;

    return AnimatedBuilder(
      animation: _cursorBlinkController,
      builder: (context, _) {
        final cursorAlpha =
            (isTyping || _cursorBlinkController.value > 0.35) ? 1.0 : 0.0;
        return RichText(
          text: TextSpan(
            children: [
              if (widget.prefix.isNotEmpty)
                TextSpan(
                  text: widget.prefix,
                  style: widget.prefixStyle,
                ),
              TextSpan(
                text: effectiveText,
                style: widget.textStyle,
              ),
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: Opacity(
                  opacity: cursorAlpha,
                  child: Container(
                    margin: const EdgeInsets.only(left: 2.5),
                    width: 6.5,
                    height: 12,
                    decoration: BoxDecoration(
                      color: cursorColor,
                      borderRadius: BorderRadius.circular(1.5),
                      boxShadow: [
                        BoxShadow(
                          color: cursorColor.withAlpha(140),
                          blurRadius: 4,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
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
  });

  final ChatTurnStreamState stream;
  final AgentStep? lastStep;

  @override
  State<_AnimatedThinkingRobotCard> createState() =>
      _AnimatedThinkingRobotCardState();
}

class _AnimatedThinkingRobotCardState extends State<_AnimatedThinkingRobotCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;
  late final Animation<double> _borderGlowAnimation;

  bool _isTraceExpanded = false;

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
  }

  @override
  void dispose() {
    _pulseController.dispose();
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

    // Xác định Tool đang dùng
    String toolName = 'Thinking';
    IconData toolIcon = Icons.psychology_rounded;
    Color toolColor = context.scheme.tertiary;

    final activeTool =
        lastStep?.toolCalls.isNotEmpty == true ? lastStep!.toolCalls.last : null;
    if (activeTool != null) {
      toolName = activeTool.name;
    } else if (stream.activeStepType.isNotEmpty &&
        stream.activeStepType.toLowerCase() != 'step') {
      toolName = stream.activeStepType;
    }

    switch (toolName) {
      case 'run_command':
        toolIcon = Icons.terminal_rounded;
        toolColor = context.scheme.secondary;
        break;
      case 'edit_file':
        toolIcon = Icons.edit_note_rounded;
        toolColor = context.status.warning;
        break;
      case 'write_file':
        toolIcon = Icons.note_add_rounded;
        toolColor = context.status.success;
        break;
      case 'read_file':
        toolIcon = Icons.menu_book_rounded;
        toolColor = context.status.warning;
        break;
      case 'search_web':
        toolIcon = Icons.travel_explore_rounded;
        toolColor = context.scheme.secondary;
        break;
      case 'invoke_subagent':
        toolIcon = Icons.hub_rounded;
        toolColor = context.scheme.error;
        break;
      case 'define_subagent':
      case 'manage_subagents':
        toolIcon = Icons.supervised_user_circle_rounded;
        toolColor = context.scheme.tertiary;
        break;
      case 'schedule':
      case 'manage_task':
        toolIcon = Icons.schedule_rounded;
        toolColor = context.scheme.secondary;
        break;
      case 'ask_question':
        toolIcon = Icons.help_outline_rounded;
        toolColor = context.status.warning;
        break;
      default:
        toolIcon = Icons.psychology_rounded;
        toolColor = context.scheme.tertiary;
        break;
    }

    // Xác định Title của bước / hành động
    String actionTitle = '';
    if (activeTool != null) {
      final summary = activeTool.args['toolSummary']?.toString() ?? '';
      if (summary.isNotEmpty) {
        actionTitle = summary;
      } else {
        final path = activeTool.args['Path']?.toString() ?? '';
        if (path.isNotEmpty) {
          actionTitle = '${activeTool.name}: ${path.split('/').last}';
        } else {
          final cmd = activeTool.args['CommandLine']?.toString() ?? '';
          if (cmd.isNotEmpty) {
            actionTitle = cmd.length > 55 ? '${cmd.substring(0, 55)}...' : cmd;
          }
        }
      }
    }

    if (actionTitle.isEmpty) {
      if (lastStep != null && lastStep.vietnameseTitle.isNotEmpty) {
        actionTitle = lastStep.vietnameseTitle;
      } else if (stream.userPrompt.isNotEmpty) {
        final firstPromptLine = stream.userPrompt.split('\n').first.trim();
        actionTitle = firstPromptLine.length > 50
            ? '${firstPromptLine.substring(0, 50)}...'
            : firstPromptLine;
      } else {
        actionTitle = 'Đang phân tích & xử lý tác vụ...';
      }
    }

    return AnimatedBuilder(
      animation: _pulseController,
      builder: (context, child) {
        return Padding(
          padding: EdgeInsets.zero,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header Card
              Padding(
                padding: EdgeInsets.zero,
                child: Row(
                  children: [
                    _AnimatedThinkingRobotIcon(
                      size: 20,
                      color: context.scheme.tertiary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              // 1. Badge: AI Thinking
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 7,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    colors: [
                                      context.scheme.tertiary,
                                      context.scheme.tertiary,
                                    ],
                                  ),
                                  borderRadius: BorderRadius.circular(6),
                                  boxShadow: [
                                    BoxShadow(
                                      color: context.scheme.tertiary.withAlpha(
                                        (90 * _borderGlowAnimation.value).round(),
                                      ),
                                      blurRadius: 5,
                                    ),
                                  ],
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Container(
                                      width: 6,
                                      height: 6,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: context.status.success,
                                      ),
                                    ),
                                    const SizedBox(width: 5),
                                    Text(
                                      'AI Thinking',
                                      style: TextStyle(
                                        fontFamily: 'monospace',
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.w800,
                                        color: context.scheme.onPrimary,
                                        letterSpacing: 0.3,
                                      ),
                                    ),
                                  ],
                                ),
                              ),

                              // 2. Badge: Tool
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: toolColor.withAlpha(35),
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(
                                    color: toolColor.withAlpha(160),
                                    width: 0.8,
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      toolIcon,
                                      size: 11.5,
                                      color: toolColor,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      toolName,
                                      style: TextStyle(
                                        fontFamily: 'monospace',
                                        fontSize: 10,
                                        fontWeight: FontWeight.w700,
                                        color: toolColor,
                                      ),
                                    ),
                                  ],
                                ),
                              ),

                              // Bước #index nếu có
                              if (stepIndex != null)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 5,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: colorScheme.surfaceContainerHighest.withAlpha(180),
                                    borderRadius: BorderRadius.circular(5),
                                    border: Border.all(
                                      color: colorScheme.outlineVariant.withAlpha(90),
                                      width: 0.8,
                                    ),
                                  ),
                                  child: Text(
                                    'Bước #$stepIndex',
                                    style: TextStyle(
                                      fontFamily: 'monospace',
                                      fontSize: 9.5,
                                      fontWeight: FontWeight.w700,
                                      color: colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 3),
                          // 3. Title: Tóm tắt hành động
                          Text(
                            actionTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: textTheme.labelMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                              fontSize: 12,
                              color: colorScheme.onSurface,
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Nút thu gọn / mở rộng chi tiết suy nghĩ
                    if (stream.thinkingText.trim().isNotEmpty)
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

              // Banner: Đang làm cụ thể những gì (với hiệu ứng đẻ ra từng chữ kiểu AI)
              Padding(
                padding: EdgeInsets.zero,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: EdgeInsets.only(top: 2),
                      child: Icon(
                        Icons.bolt_rounded,
                        size: 14,
                        color: context.scheme.tertiary,
                      ),
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: _AiStreamingTypewriterText(
                        prefix: 'Đang làm: ',
                        prefixStyle: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w800,
                          color: context.scheme.tertiary,
                        ),
                        text: specificAction,
                        textStyle: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: colorScheme.onSurface,
                          height: 1.35,
                        ),
                        cursorColor: context.scheme.tertiary,
                      ),
                    ),
                  ],
                ),
              ),

              // Thinking block: Chỉ hiện khi đang ở bước thinking, ẩn hoàn toàn ở các bước khác
              if (_isTraceExpanded &&
                  stream.thinkingText.trim().isNotEmpty &&
                  stream.activeStepType == 'thinking') ...[
                Padding(
                  padding: EdgeInsets.zero,
                  child: AnimatedSize(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOutCubic,
                    child: Padding(
                      padding: EdgeInsets.zero,
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
                                  color: context.scheme.tertiary,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                'Thought Process',
                                style: TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  color: context.scheme.tertiary,
                                ),
                              ),
                              if (stream.isRunning &&
                                  stream.activeStepType == 'thinking') ...[
                                const SizedBox(width: 8),
                                Text(
                                  'LIVE',
                                  style: TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 9,
                                    fontWeight: FontWeight.w800,
                                    color: context.scheme.tertiary,
                                    letterSpacing: 0.5,
                                  ),
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 6),
                          SelectableText(
                            stream.thinkingText.trim(),
                            style: textTheme.bodySmall?.copyWith(
                              fontFamily: 'monospace',
                              fontSize: 10.5,
                              height: 1.45,
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],

              if (stream.error.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
                  child: Text(
                    stream.error,
                    style: textTheme.bodySmall?.copyWith(
                      color: context.scheme.error,
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

/// Khung hiển thị Prompt người dùng có thể cuộn độc lập (khi prompt dài)
class _ScrollablePromptBox extends StatefulWidget {
  const _ScrollablePromptBox({
    required this.prompt,
    required this.maxHeight,
  });

  final String prompt;
  final double maxHeight;

  @override
  State<_ScrollablePromptBox> createState() => _ScrollablePromptBoxState();
}

class _ScrollablePromptBoxState extends State<_ScrollablePromptBox> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Container(
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
          Row(
            children: [
              Text(
                'Yêu cầu của bạn (Prompt):',
                style: textTheme.labelSmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              Icon(
                Icons.unfold_more_rounded,
                size: 14,
                color: colorScheme.onSurfaceVariant.withAlpha(160),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: widget.maxHeight),
            child: Scrollbar(
              controller: _scrollController,
              thumbVisibility: true,
              child: SingleChildScrollView(
                controller: _scrollController,
                physics: const ClampingScrollPhysics(),
                child: Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: SelectableText(
                    widget.prompt,
                    style: textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      height: 1.45,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
