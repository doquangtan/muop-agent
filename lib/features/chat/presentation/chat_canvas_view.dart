import 'dart:async';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/rendering.dart' show RenderProxyBox, ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';
import 'package:material_ui/material_ui.dart';

import 'package:muop_agent/core/theme/app_theme.dart';
import 'package:muop_agent/core/theme/chat_theme_painter.dart';
import 'package:muop_agent/core/widgets/liquid_glass.dart';
import 'package:muop_agent/core/widgets/spinning_icon.dart';
import 'package:muop_agent/features/chat/domain/chat_entities.dart';
import 'package:muop_agent/features/chat/domain/model_groups.dart';
import 'package:muop_agent/features/bridge/domain/peer_models.dart';
import 'package:muop_agent/features/chat/presentation/quota_detail_sheet.dart';
import 'package:muop_agent/features/chat/presentation/run_command_dialog.dart';
import 'package:muop_agent/features/chat/presentation/text_tail.dart';
import 'package:muop_agent/features/interactions/domain/interaction_entities.dart';
import 'package:muop_agent/features/interactions/presentation/interaction_dialogs.dart';
import 'package:muop_agent/features/interactions/presentation/interaction_widgets.dart';
import 'package:muop_agent/features/interactions/presentation/rate_retry_widgets.dart';
import 'package:muop_agent/features/interactions/presentation/retry_config_sheet.dart';
import 'package:muop_agent/features/quota/domain/quota_entities.dart';
import 'package:muop_agent/features/projects/domain/project_entities.dart';
import 'package:muop_agent/features/server_files/presentation/server_file_browser_sheet.dart';
import 'package:muop_agent/features/sessions/domain/session_entities.dart';
import 'package:muop_agent/features/sessions/presentation/agent_presentation.dart';

part 'canvas/blocks.dart';
part 'canvas/canvas_models.dart';
part 'canvas/chat_wallpaper.dart';
part 'canvas/composer.dart';
part 'canvas/composer_pill.dart';
part 'canvas/dialogs.dart';
part 'canvas/dock.dart';
part 'canvas/files_changed_card.dart';
part 'canvas/markdown_segment.dart';
part 'canvas/model_bar.dart';
part 'canvas/prompt_widgets.dart';
part 'canvas/running_modals.dart';
part 'canvas/scroll.dart';
part 'canvas/task_panel.dart';
part 'canvas/thinking_widgets.dart';
part 'canvas/trajectory_section.dart';
part 'canvas/turns.dart';
part 'canvas/welcome.dart';

class ChatCanvasView extends StatefulWidget {
  const ChatCanvasView({
    super.key,
    required this.session,
    required this.projects,
    required this.selectedProject,
    required this.availableAgents,
    required this.availableModels,
    this.modelLabels = const {},
    this.blockedReason,
    this.effortLevels = const [],
    this.modelContextLimits = const {},
    required this.quotaScope,
    required this.quotaReports,
    required this.selectedAgent,
    required this.selectedModel,
    required this.isNewConversationMode,
    required this.isSending,
    required this.activeStream,
    this.lastDownloadedFilePath,
    this.pendingRetry,
    this.onCancelRetry,
    this.onFetchRetryConfig,
    this.onSaveRetryConfig,
    this.pendingClaudeInteraction,
    required this.onSelectProject,
    required this.onSelectAgent,
    required this.onSelectModel,
    required this.onStartNewConversation,
    required this.onSendMessage,
    this.serverBaseUrl = '',
    this.workspaceRoot = '',
    this.peerHost = '',
    this.isPeerSession = false,
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
    this.onOpenAgentMap,
    this.onOpenCreateProject,
    this.onGitPush,
    this.onOpenGitHistory,
    this.floatingTopHeader,
    this.desktopLeftInset = 0.0,
  });

  final ConversationSession? session;
  final List<ProjectWorkspace> projects;
  final ProjectWorkspace? selectedProject;
  final List<String> availableAgents;
  final List<String> availableModels;

  /// Nhãn hiển thị theo id model (lấy từ `agy models`)
  final Map<String, String> modelLabels;

  /// Lý do khóa khung chat (ví dụ máy phụ mất kết nối). Null = được phép gửi.
  final String? blockedReason;

  /// Mức suy nghĩ (effort) mà CLI của server hỗ trợ; rỗng thì dùng mức dự phòng
  final List<String> effortLevels;

  /// Giới hạn context theo model id, dùng để hiển thị mức đã dùng trên chip context
  final Map<String, int> modelContextLimits;
  /// Provider của màn chat (`claude` / `agy`); rỗng ở màn chung (hiện cả hai)
  final String quotaScope;
  /// Quota theo provider (`agy`, `claude`), lấy từ `/api/quota/<provider>` hoặc `/api/quota`
  final Map<String, QuotaReport> quotaReports;
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
  )?
  onRespondClaudeInteraction;
  final ValueChanged<ProjectWorkspace> onSelectProject;
  final ValueChanged<String> onSelectAgent;
  final ValueChanged<String> onSelectModel;
  final VoidCallback onStartNewConversation;

  /// Gửi tin nhắn: nội dung chữ (có thể rỗng nếu có ảnh) và danh sách ảnh đính kèm
  final void Function(String text, List<ChatImageAttachment> images)
  onSendMessage;

  /// Địa chỉ gốc của Rust server (vd. `http://192.168.1.10:8787`), dùng để tải ảnh đính kèm trong lịch sử
  final String serverBaseUrl;
  /// Thư mục project gốc do server cấu hình (fallback khi chưa có project được chọn)
  final String workspaceRoot;

  /// Tên máy phụ đang kết nối (dùng cho tiêu đề khối model của máy phụ)
  final String peerHost;

  /// Conversation đang mở chạy trên máy phụ: chỉ hiện model của máy phụ
  final bool isPeerSession;
  final VoidCallback onStopTurn;

  /// Lịch tự gửi lại sau rate limit của conversation đang mở (null nếu không có)
  final PendingRetry? pendingRetry;
  final Future<void> Function()? onCancelRetry;

  /// Đọc và lưu cấu hình tự gửi lại của conversation đang mở (nút trên thanh model)
  final Future<ConversationRetryConfig?> Function(String conversationId)?
  onFetchRetryConfig;
  final Future<({bool ok, String message})> Function(
    ConversationRetryConfig config,
  )?
  onSaveRetryConfig;
  final VoidCallback onOpenFileBrowser;
  final VoidCallback onOpenChangesTab;
  final void Function(String filePath, GroupedFileChange? change)
  onInspectFileChange;
  final ValueChanged<String> onDownloadFile;
  final ValueChanged<String> onOpenDownloadedFile;
  final ValueChanged<PlanArtifactInfo>? onApprovePlan;
  final void Function(PlanArtifactInfo plan, String feedback)? onRejectPlan;
  final ValueChanged<PlanArtifactInfo>? onCancelPlan;
  final Future<bool?> Function()? onLoadOlderHistory;
  final Future<List<CustomAgentSpec>?> Function(String projectPath)?
  onFetchClaudeExtensions;

  /// Mở sơ đồ Agent map (cây subagent) của conversation đang chọn
  final VoidCallback? onOpenAgentMap;
  final VoidCallback? onOpenCreateProject;
  final Future<GitPushResponse> Function(String projectPath, String branch)?
  onGitPush;
  final VoidCallback? onOpenGitHistory;

  /// Thanh header Liquid Glass nổi trên luồng chat (tùy chọn, dùng trong DashboardScreen).
  final Widget? floatingTopHeader;

  /// Khoảng đệm bên trái trên Desktop để nội dung chat không bị che bởi Sidebar & Explorer nổi.
  final double desktopLeftInset;

  @override
  State<ChatCanvasView> createState() => _ChatCanvasViewState();
}

class _ChatCanvasViewState extends State<ChatCanvasView> {
  /// Gọi setState từ các extension trong thư mục canvas/ (setState là @protected)
  void _applyState(VoidCallback fn) => setState(fn);
  static const int _pageSize = 20;
  static const int _collapsedTailLines = 5;

  final TextEditingController _promptController = TextEditingController();

  /// Nội dung đang gõ dở của từng conversation (khóa theo [_draftKey]); chuyển conversation thì đổi nội dung ô nhập
  final Map<String, String> _drafts = {};

  /// Ảnh đính kèm đang chọn cho conversation hiện tại (chưa gửi), và ảnh của các nháp khác
  List<ChatImageAttachment> _pendingImages = const [];
  final Map<String, List<ChatImageAttachment>> _draftImages = {};
  final ScrollController _scrollController = ScrollController();
  final FocusNode _inputFocusNode = FocusNode();
  final LiquidGlassViewController _glassViewController =
      LiquidGlassViewController();

  int _loadedTurnCount = _pageSize;
  bool _isLoadingMoreTurns = false;
  bool _hasLoadedAllServerHistory = false;
  bool _hasOlderHistoryError = false;
  bool _pendingServerTurnsExpand = false;
  final ValueNotifier<bool> _showScrollToBottomNotifier = ValueNotifier<bool>(
    false,
  );
  final ValueNotifier<double> _dockHeightNotifier = ValueNotifier<double>(
    110.0,
  );
  final ValueNotifier<double> _topOverlayHeightNotifier = ValueNotifier<double>(
    16.0,
  );
  late final Listenable _overlayPaddingListenable = Listenable.merge([
    _dockHeightNotifier,
    _topOverlayHeightNotifier,
  ]);
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

  /// Cache đo layout thu gọn 5 dòng của prompt người dùng để không phải chạy TextPainter lại khi cuộn
  final Map<int, _CollapsedPromptLayout> _promptLayoutCache = {};

  /// Cache tính toán turns & flat blocks để không bị lag giật mỗi khi gõ phím hoặc rebuild
  String? _lastSessionId;
  // Chữ ký nội dung steps: số lượng không đủ vì snapshot cắt còn 100 step nên
  // lượt trả lời mới có thể làm số lượng giữ nguyên. Dùng thêm step cuối và updatedAt.
  int _lastStepsSignature = -1;
  int _lastFilesTouchedCount = -1;
  int _lastLoadedTurnCount = -1;
  bool _lastIsLoadingMoreTurns = false;
  bool _lastHasLoadedAllServerHistory = false;
  bool _lastHasOlderHistoryError = false;
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
    if (oldWidget.desktopLeftInset != widget.desktopLeftInset) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _glassViewController.captureOnce();
      });
    }
    if (oldId != newId ||
        oldWidget.isNewConversationMode != widget.isNewConversationMode) {
      _switchDraft(oldWidget);
      _composerRevealed = false;
      _loadedTurnCount = _pageSize;
      _isLoadingMoreTurns = false;
      _hasLoadedAllServerHistory = false;
      _hasOlderHistoryError = false;
      _pendingServerTurnsExpand = false;
      _showScrollToBottomNotifier.value = false;
      _expandedResponseTurns.clear();
      _expandedPromptTurns.clear();
      _promptLayoutCache.clear();
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
      final oldSteps = oldWidget.session?.steps ?? const [];
      final newSteps = widget.session?.steps ?? const [];
      final oldStepsCount = oldSteps.length;
      final newStepsCount = newSteps.length;
      if (oldStepsCount == 0 && newStepsCount > 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _scrollToBottom(animated: false);
          _maybeLoadOlderTurns();
        });
      } else if (newStepsCount > oldStepsCount) {
        final prependedOlder =
            newSteps.isNotEmpty &&
            oldSteps.isNotEmpty &&
            newSteps.first.stepIndex < oldSteps.first.stepIndex;
        if (prependedOlder && _pendingServerTurnsExpand) {
          _pendingServerTurnsExpand = false;
          final newTotalTurns = _countTurnGroups(newSteps);
          _loadedTurnCount = math.max(
            _loadedTurnCount,
            math.min(newTotalTurns, _loadedTurnCount + _pageSize),
          );
          _scheduleOlderTurnsCheck();
        }
        final appendedNewer =
            newSteps.isNotEmpty &&
            oldSteps.isNotEmpty &&
            newSteps.last.stepIndex > oldSteps.last.stepIndex;
        // Chỉ tự động cuộn xuống đáy khi có bước mới ở cuối và người dùng đang ở gần đáy (pixels < 120)
        if (!_isLoadingMoreTurns &&
            appendedNewer &&
            _scrollController.hasClients &&
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

  /// Khóa nháp: conversation đã có id, hoặc `new:` + đường dẫn project khi đang soạn conversation mới
  String _draftKey(ChatCanvasView w) {
    final id = w.session?.id;
    if (id != null && id.isNotEmpty) return id;
    return 'new:${w.selectedProject?.path ?? ''}';
  }

  /// Lưu nháp của conversation cũ rồi nạp nháp của conversation mới vào ô nhập
  void _switchDraft(ChatCanvasView oldWidget) {
    final oldKey = _draftKey(oldWidget);
    final newKey = _draftKey(widget);
    if (oldKey == newKey) return;
    final typed = _promptController.text;
    if (typed.trim().isEmpty) {
      _drafts.remove(oldKey);
    } else {
      _drafts[oldKey] = typed;
    }
    if (_pendingImages.isEmpty) {
      _draftImages.remove(oldKey);
    } else {
      _draftImages[oldKey] = _pendingImages;
    }
    _pendingImages = _draftImages.remove(newKey) ?? const [];
    final next = _drafts[newKey] ?? '';
    _promptController.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: next.length),
    );
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _promptController.dispose();
    _inputFocusNode.dispose();
    _showScrollToBottomNotifier.dispose();
    _dockHeightNotifier.dispose();
    _topOverlayHeightNotifier.dispose();
    super.dispose();
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

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isMobile = MediaQuery.sizeOf(context).width < 760;
    final session = widget.session;
    final isTurnRunning = _isTurnRunning(widget);

    final currentSessionId = session?.id;
    final firstStepForSig = (session != null && session.steps.isNotEmpty)
        ? session.steps.first
        : null;
    final lastStepForSig = (session != null && session.steps.isNotEmpty)
        ? session.steps.last
        : null;
    final currentStepsSignature = Object.hash(
      session?.steps.length ?? 0,
      firstStepForSig?.stepIndex,
      lastStepForSig?.stepIndex,
      lastStepForSig?.status,
      lastStepForSig?.content.length,
      lastStepForSig?.thinking.length,
      lastStepForSig?.toolCalls.length,
      session?.updatedAt.millisecondsSinceEpoch,
      session?.status,
      widget.activeStream?.isRunning,
      // Nội dung stream đổi liên tục trong khi agy chưa ghi bước mới vào transcript:
      // các trường này phải nằm trong chữ ký thì khối chat mới được dựng lại
      widget.activeStream?.streamingText.length,
      widget.activeStream?.thinkingText.length,
      widget.activeStream?.activeStepType,
    );
    final currentFilesTouchedCount = session?.filesTouched.length ?? 0;
    final currentResponseTurnsHash = _expandedResponseTurns.fold<int>(
      0,
      (prev, e) => prev ^ e,
    );
    final currentPromptTurnsHash = _expandedPromptTurns.fold<int>(
      0,
      (prev, e) => prev ^ e,
    );

    final bool shouldRecomputeBlocks =
        widget.isNewConversationMode ||
        session == null ||
        _lastSessionId != currentSessionId ||
        _lastStepsSignature != currentStepsSignature ||
        _lastFilesTouchedCount != currentFilesTouchedCount ||
        _lastLoadedTurnCount != _loadedTurnCount ||
        _lastIsLoadingMoreTurns != _isLoadingMoreTurns ||
        _lastHasLoadedAllServerHistory != _hasLoadedAllServerHistory ||
        _lastHasOlderHistoryError != _hasOlderHistoryError ||
        _lastExpandedResponseTurnsHash != currentResponseTurnsHash ||
        _lastExpandedPromptTurnsHash != currentPromptTurnsHash;

    if (shouldRecomputeBlocks) {
      _lastSessionId = currentSessionId;
      _lastStepsSignature = currentStepsSignature;
      _lastFilesTouchedCount = currentFilesTouchedCount;
      _lastLoadedTurnCount = _loadedTurnCount;
      _lastIsLoadingMoreTurns = _isLoadingMoreTurns;
      _lastHasLoadedAllServerHistory = _hasLoadedAllServerHistory;
      _lastHasOlderHistoryError = _hasOlderHistoryError;
      _lastExpandedResponseTurnsHash = currentResponseTurnsHash;
      _lastExpandedPromptTurnsHash = currentPromptTurnsHash;

      _cachedAllTurns = (!widget.isNewConversationMode && session != null)
          ? _buildTurnGroups(session.steps, session.filesTouched)
          : const <_ChatTurnGroup>[];

      final int startIdx = math.max(
        0,
        _cachedAllTurns.length - _loadedTurnCount,
      );
      final visibleTurns = _cachedAllTurns.sublist(startIdx);
      final int remainingOlderTurns = startIdx;

      _cachedFlatBlocks = _buildFlatBlocks(
        visibleTurns: visibleTurns,
        remainingOlderTurns: remainingOlderTurns,
        totalTurnsCount: _cachedAllTurns.length,
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _glassViewController.captureOnce();
      });
    }

    final flatBlocks = _cachedFlatBlocks;

    final Widget backdropLayer = Stack(
      fit: StackFit.expand,
      children: [
        const _TelegramChatWallpaper(),
        flatBlocks.isEmpty
            ? Padding(
                padding: EdgeInsets.only(left: widget.desktopLeftInset),
                child: _buildEmptyAntigravityWelcome(context, isMobile),
              )
            : SelectionArea(
                child: NotificationListener<ScrollNotification>(
                  onNotification: (notification) {
                    if (notification is ScrollStartNotification) {
                      _glassViewController.startRealtimeCapture();
                    } else if (notification is ScrollEndNotification) {
                      _glassViewController.stopRealtimeCapture();
                    } else if (notification is OverscrollNotification &&
                        notification.overscroll > 0) {
                      _maybeLoadOlderTurns();
                    }
                    return false;
                  },
                  child: ListenableBuilder(
                    listenable: _overlayPaddingListenable,
                    builder: (context, _) => ListView.builder(
                      controller: _scrollController,
                      reverse: true,
                      scrollCacheExtent: const ScrollCacheExtent.pixels(600),
                      addAutomaticKeepAlives: false,
                      padding: EdgeInsets.fromLTRB(
                        widget.desktopLeftInset + (isMobile ? 12 : 28),
                        _topOverlayHeightNotifier.value + 12,
                        isMobile ? 12 : 28,
                        // Đệm đáy theo đúng chiều cao thực tế của đảo nổi để tin nhắn cuối không bị che
                        _dockHeightNotifier.value + 18,
                      ),
                      itemCount: flatBlocks.length,
                      itemBuilder: (context, index) {
                        final block = flatBlocks[index];
                        return RepaintBoundary(
                          key: ValueKey(block.keyId),
                          child: Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 840),
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
                ),
              ),
      ],
    );

    final topOverlay = Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: EdgeInsets.only(left: widget.desktopLeftInset),
        child: RepaintBoundary(
          child: _DockSizeMeasurer(
          onHeightChanged: (h) {
            if (mounted && (_topOverlayHeightNotifier.value - h).abs() > 0.5) {
              _topOverlayHeightNotifier.value = h;
            }
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.floatingTopHeader != null) widget.floatingTopHeader!,
              _buildTopPinnedGlassBar(context, isMobile, isTurnRunning),
            ],
          ),
        ),
      ),
      ),
    );

    return LiquidGlassView(
      controller: _glassViewController,
      pixelRatio: 0.75,
      realTimeCapture: false,
      useSync: true,
      refreshRate: LiquidGlassRefreshRate.high,
      backgroundWidget: backdropLayer,
      child: Stack(
        fit: StackFit.expand,
        children: [
          topOverlay,
          if (flatBlocks.isNotEmpty)
            ValueListenableBuilder<bool>(
              valueListenable: _showScrollToBottomNotifier,
              builder: (context, showBtn, _) {
                if (!showBtn) return const SizedBox.shrink();
                return ValueListenableBuilder<double>(
                  valueListenable: _dockHeightNotifier,
                  builder: (context, dockHeight, _) => Positioned(
                    right: isMobile ? 14 : 24,
                    bottom: dockHeight + 12,
                    child: Tooltip(
                      message: 'Cuộn xuống đoạn chat mới nhất',
                      child: LiquidGlassPill(
                        cornerRadius: 21,
                        refractionWidth: 10,
                        shadowBlur: 10,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(21),
                          onTap: () => _scrollToBottom(animated: true),
                          child: SizedBox(
                            width: 42,
                            height: 42,
                            child: Icon(
                              Icons.keyboard_arrow_down_rounded,
                              size: 24,
                              color: colorScheme.onSurface,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: EdgeInsets.only(left: widget.desktopLeftInset),
              child: RepaintBoundary(
                child: _DockSizeMeasurer(
                  onHeightChanged: (h) {
                    if (mounted && (_dockHeightNotifier.value - h).abs() > 0.5) {
                      _dockHeightNotifier.value = h;
                    }
                  },
                  child: _buildBottomDockStack(context, isMobile, isTurnRunning),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _formatTokensShort(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).round()}K';
    return '$n';
  }
}

/// Đo chiều cao thực tế của floating dock để làm vùng đệm đáy cho ListView.
class _DockSizeMeasurer extends SingleChildRenderObjectWidget {
  const _DockSizeMeasurer({required this.onHeightChanged, super.child});

  final ValueChanged<double> onHeightChanged;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderDockSizeMeasurer(onHeightChanged);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderDockSizeMeasurer renderObject,
  ) {
    renderObject.onHeightChanged = onHeightChanged;
  }
}

class _RenderDockSizeMeasurer extends RenderProxyBox {
  _RenderDockSizeMeasurer(this.onHeightChanged);

  ValueChanged<double> onHeightChanged;
  double? _lastHeight;

  @override
  void performLayout() {
    super.performLayout();
    final h = child?.size.height ?? 0.0;
    if (_lastHeight == null || (h - _lastHeight!).abs() > 0.5) {
      _lastHeight = h;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        onHeightChanged(h);
      });
    }
  }
}
