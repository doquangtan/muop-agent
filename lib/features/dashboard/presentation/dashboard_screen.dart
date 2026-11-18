import 'dart:async';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'package:muop_agent/core/config/server_config.dart';
import 'package:muop_agent/core/di/app_dependencies.dart';
import 'package:muop_agent/core/theme/app_theme.dart';
import 'package:muop_agent/core/widgets/desktop_panel.dart';
import 'package:muop_agent/core/widgets/resizable_split.dart';
import 'package:muop_agent/features/chat/domain/chat_entities.dart';
import 'package:muop_agent/features/chat/domain/chat_repository.dart';
import 'package:muop_agent/features/chat/domain/model_groups.dart';
import 'package:muop_agent/features/chat/presentation/chat_canvas_view.dart';
import 'package:muop_agent/features/connection/domain/connection_entities.dart';
import 'package:muop_agent/features/connection/domain/connection_repository.dart';
import 'package:muop_agent/features/docker/presentation/docker_screen.dart';
import 'package:muop_agent/features/interactions/domain/interaction_entities.dart';
import 'package:muop_agent/features/interactions/domain/interactions_repository.dart';
import 'package:muop_agent/features/interactions/presentation/ai_question_dialog.dart';
import 'package:muop_agent/features/interactions/presentation/rate_retry_widgets.dart';
import 'package:muop_agent/features/lsp/presentation/lsp_settings_screen.dart';
import 'package:muop_agent/features/parallel_flow/presentation/parallel_agent_flow_screen.dart';
import 'package:muop_agent/features/projects/domain/project_entities.dart';
import 'package:muop_agent/features/projects/domain/projects_repository.dart';
import 'package:muop_agent/features/projects/presentation/project_git_history_sheet.dart';
import 'package:muop_agent/features/projects/presentation/project_tree_explorer.dart';
import 'package:muop_agent/features/server_files/domain/server_files_repository.dart';
import 'package:muop_agent/features/server_files/presentation/server_file_browser_sheet.dart';
import 'package:muop_agent/features/sessions/domain/session_entities.dart';
import 'package:muop_agent/features/sessions/domain/session_repository.dart';
import 'package:muop_agent/features/sessions/presentation/desktop_conversation_rail.dart';
import 'package:muop_agent/features/ssh/presentation/ssh_hosts_screen.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({
    super.key,
    required this.isDarkMode,
    required this.onToggleTheme,
    required this.seedColor,
    required this.onSeedColorChanged,
  });

  final bool isDarkMode;
  final VoidCallback onToggleTheme;
  final Color seedColor;
  final ValueChanged<Color> onSeedColorChanged;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  /// Trang SSH / Docker / log đang mở trong vùng chính (desktop), xếp chồng lên màn hình chính
  final List<_PanelEntry> _panelPages = [];
  final GlobalKey<NavigatorState> _panelNavKey = GlobalKey<NavigatorState>();
  int _panelSeq = 0;
  final ChatRepository _chatRepo = AppDependencies.chat;
  final ConnectionRepository _connectionRepo = AppDependencies.connection;
  final InteractionsRepository _interactionsRepo = AppDependencies.interactions;
  final ProjectsRepository _projectsRepo = AppDependencies.projects;
  final ServerFilesRepository _serverFilesRepo = AppDependencies.serverFiles;
  final SessionRepository _sessionsRepo = AppDependencies.sessions;
  final TextEditingController _searchController = TextEditingController();

  List<String> _hostLanIps = const ['192.168.31.96', '100.121.158.198'];
  String _serverAddress = defaultHostAddress;
  bool _isRemoteConnected = false;
  bool _isSocketLive = false;
  String _remoteHostName = '';

  List<ConversationSession> _sessions = [];
  List<ProjectWorkspace> _projects = [];
  List<String> _availableModels = defaultModels;
  Map<String, String> _modelLabels = {};
  /// Mức suy nghĩ (effort) do CLI của server hỗ trợ; rỗng cho tới khi có meta
  List<String> _effortLevels = const [];
  Map<String, int> _modelContextLimits = {};
  final List<String> _availableAgents = defaultAgents;
  List<ModelQuotaGroup> _modelQuotas = [];
  Map<String, ChatTurnStreamState> _activeStreams = {};
  // Provider (claude-cli / agy) của các cuộc chat vừa gửi, dùng khi session chưa có trong snapshot
  final Map<String, String> _sourceByConversation = {};

  ProjectWorkspace? _activeChatProject;
  String _selectedAgent = 'Coordinator';
  String _selectedModel = 'claude-cli:claude-sonnet-5-5';
  // Model người dùng đã chọn theo từng conversation ('__new__' cho cuộc chat mới chưa có id)
  final Map<String, String> _modelBySession = {};
  bool _isNewConversationMode = false;
  bool _isSendingPrompt = false;
  /// Rail hội thoại được ghim (mở rộng hẳn) trên desktop; mặc định hiện sidebar
  bool _showDesktopSidebar = true;
  bool _railHovered = false;
  /// null = theo chiều rộng cửa sổ (từ 1200px mở explorer); true/false = người dùng chọn
  bool? _explorerOverride;
  /// File đang mở ở vùng xem file bên trái của chế độ split
  String? _viewerFilePath;
  String? _lastDownloadedFilePath;

  String? _selectedSessionId;
  bool _isLoading = true;
  String _searchQuery = '';
  final Set<String> _expandedProjects = {};

  Timer? _fallbackTimer;
  StreamSubscription<List<ConversationSession>>? _sessionsListSub;
  StreamSubscription<ServerMeta>? _metaSub;
  StreamSubscription<Map<String, ChatTurnStreamState>>? _activeStreamsSub;
  StreamSubscription<String>? _sessionRemovedSub;
  StreamSubscription<ChatTurnStreamState>? _chatStreamSub;
  StreamSubscription<bool>? _socketStatusSub;
  StreamSubscription<ConversationSession>? _sessionUpdateSub;
  StreamSubscription<List<ProjectWorkspace>>? _projectsSub;
  StreamSubscription<List<ModelQuotaGroup>>? _quotasSub;
  StreamSubscription<ConversationSession>? _filesChangeSub;
  StreamSubscription<List<PendingRetry>>? _retrySub;
  /// Danh sách lịch tự gửi lại hiện tại (cập nhật theo event `retry:update`)
  List<PendingRetry> _pendingRetries = const [];
  final ValueNotifier<List<PendingRetry>> _retryNotifier =
      ValueNotifier<List<PendingRetry>>(const []);
  /// Lịch đã bật popup, để không bật lại cho cùng một lần thử
  final Set<String> _retryPopupShown = {};

  List<AIQuestion> _pendingAIQuestions = [];
  PendingClaudeInteraction? _pendingClaudeInteraction;
  Timer? _aiQuestionRefreshTimer;
  String? _currentConversationRoom;

  @override
  void initState() {
    super.initState();
    _bindRealtimeSocketStreams();
    _initEnvironmentAndLoad();
    _fallbackTimer = Timer.periodic(const Duration(seconds: 6), (_) {
      if (!_isSocketLive) {
        _refreshSessions(silent: true);
      }
    });
  }

  @override
  void dispose() {
    _fallbackTimer?.cancel();
    _aiQuestionRefreshTimer?.cancel();
    _sessionsListSub?.cancel();
    _metaSub?.cancel();
    _activeStreamsSub?.cancel();
    _sessionRemovedSub?.cancel();
    _chatStreamSub?.cancel();
    _socketStatusSub?.cancel();
    _sessionUpdateSub?.cancel();
    _projectsSub?.cancel();
    _quotasSub?.cancel();
    _retrySub?.cancel();
    _filesChangeSub?.cancel();
    if (_currentConversationRoom != null) {
      _sessionsRepo.leaveConversation(_currentConversationRoom!);
    }
    super.dispose();
  }

  void _startAIQuestionPoller() {
    _aiQuestionRefreshTimer?.cancel();
    _aiQuestionRefreshTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      _refreshAIQuestions();
      _refreshClaudeInteraction();
    });
  }

  void _stopAIQuestionPoller() {
    _aiQuestionRefreshTimer?.cancel();
    _aiQuestionRefreshTimer = null;
  }

  Future<void> _refreshAIQuestions() async {
    final activeSession = _activeSession;
    if (activeSession == null) {
      setState(() => _pendingAIQuestions = []);
      return;
    }

    final questions = await _interactionsRepo.fetchAIQuestions(activeSession.id);
    if (!mounted) return;

    setState(() {
      _pendingAIQuestions = questions.where((q) => q.isPending).toList();
    });

    // Hiển thị dialog nếu có câu hỏi mới chờ trả lời
    for (final question in _pendingAIQuestions) {
      if (question.answer == null && question.isPending) {
        _showAIQuestionDialog(question);
        break;
      }
    }
  }

  Future<void> _refreshClaudeInteraction() async {
    final session = _activeSession;
    if (session == null || session.source != 'claude-cli') {
      if (_pendingClaudeInteraction != null) {
        setState(() => _pendingClaudeInteraction = null);
      }
      return;
    }
    final interaction = await _interactionsRepo.fetchPendingClaudeInteraction(session.id);
    if (!mounted) return;
    if (interaction?.toolUseId == _pendingClaudeInteraction?.toolUseId &&
        interaction?.conversationId == _pendingClaudeInteraction?.conversationId) {
      return;
    }
    setState(() => _pendingClaudeInteraction = interaction);
  }

  Future<String?> _respondClaudeInteraction(
    PendingClaudeInteraction interaction,
    List<Map<String, String>> answers,
    String decision,
    String feedback,
  ) async {
    final error = await _interactionsRepo.respondClaudeInteraction(
      conversationId: interaction.conversationId,
      toolUseId: interaction.toolUseId,
      projectPath: _activeChatProject?.path ?? _activeSession?.projectPath ?? '',
      model: _effectiveModel,
      decision: decision,
      answers: answers,
      feedback: feedback,
    );
    if (!mounted) return error;
    if (error == null) {
      setState(() => _pendingClaudeInteraction = null);
      _sessionsRepo.requestSync();
    }
    return error;
  }

  void _showAIQuestionDialog(AIQuestion question) {
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AIQuestionDialog(
        question: question,
        onAnswered: () {
          _refreshAIQuestions();
        },
      ),
    );
  }

  void _setupFileChangesListener() {
    // Cancel listener cũ nếu có
    _filesChangeSub?.cancel();

    final activeSession = _activeSession;
    if (activeSession == null) {
      // Leave room cũ nếu không có active session
      if (_currentConversationRoom != null) {
        _sessionsRepo.leaveConversation(_currentConversationRoom!);
        _currentConversationRoom = null;
      }
      return;
    }

    // Leave room cũ nếu đổi sang conversation khác
    if (_currentConversationRoom != activeSession.id) {
      if (_currentConversationRoom != null) {
        _sessionsRepo.leaveConversation(_currentConversationRoom!);
      }
      // Join room mới
      _sessionsRepo.joinConversation(activeSession.id);
      _currentConversationRoom = activeSession.id;
    }

    // Lắng nghe file changes từ server
    _filesChangeSub = _sessionsRepo.filesChangeStream.listen((updatedSession) {
      if (!mounted) return;
      // Update session data khi nhận file changes
      setState(() {
        final idx = _sessions.indexWhere((s) => s.id == updatedSession.id);
        if (idx >= 0) {
          _sessions[idx] = updatedSession;
        }
      });
    });
  }

  void _bindRealtimeSocketStreams() {
    _socketStatusSub = _connectionRepo.socketConnectionStream.listen((connected) {
      if (!mounted) return;
      setState(() {
        _isSocketLive = connected;
        if (connected) {
          _isRemoteConnected = true;
          // Đồng bộ lại toàn bộ snapshot ngay khi kết nối lại sau restart
          _refreshSessions(silent: true);
        }
      });
    });

    // Lắng nghe cập nhật granular cho từng conversation riêng lẻ
    _sessionUpdateSub = _sessionsRepo.sessionUpdateStream.listen((updatedSession) {
      if (!mounted) return;
      _handleSessionUpdate(updatedSession);
    });

    // Lắng nghe cập nhật Projects độc lập
    _projectsSub = _projectsRepo.projectsUpdateStream.listen((projects) {
      if (!mounted) return;
      setState(() {
        _projects = projects;
        if (_activeChatProject != null) {
          _activeChatProject = _projects.firstWhere(
            (p) => p.name == _activeChatProject!.name,
            orElse: () => _activeChatProject!,
          );
        }
      });
    });

    // Lắng nghe cập nhật Model Quotas độc lập
    _quotasSub = _sessionsRepo.quotasUpdateStream.listen((quotas) {
      if (!mounted) return;
      setState(() {
        _modelQuotas = quotas;
      });
    });

    _retrySub = _interactionsRepo.retryUpdateStream.listen((retries) {
      if (!mounted) return;
      setState(() {
        _pendingRetries = retries;
      });
      _retryNotifier.value = retries;
      for (final r in retries) {
        if (_retryPopupShown.add(r.key)) {
          _showRetryPopup(r.conversationId);
        }
      }
      _retryPopupShown.removeWhere((k) => !retries.any((r) => r.key == k));
    });

    _sessionsListSub = _sessionsRepo.sessionsListStream.listen((list) {
      if (!mounted) return;
      _applySessionsList(list);
    });

    _metaSub = _sessionsRepo.metaStream.listen((meta) {
      if (!mounted) return;
      _applyServerMeta(meta);
    });

    _activeStreamsSub = _sessionsRepo.activeStreamsStream.listen((streams) {
      if (!mounted) return;
      _applyActiveStreams(streams);
    });

    _sessionRemovedSub = _sessionsRepo.sessionRemovedStream.listen((id) {
      if (!mounted) return;
      _applySessionRemoved(id);
    });

    _chatStreamSub = _chatRepo.chatStream.listen((streamState) {
      if (!mounted) return;
      setState(() {
        _activeStreams = {
          ..._activeStreams,
          streamState.conversationId: streamState,
        };
        // Chuyển sang conversation thật khi stream của prompt vừa gửi (pending_optimistic)
        // đã có id, kể cả khi lúc gửi chưa có id nên chưa chọn được session nào
        if ((_isNewConversationMode || _selectedSessionId == null) &&
            _activeStreams.containsKey('pending_optimistic') &&
            streamState.conversationId.isNotEmpty &&
            streamState.isRunning) {
          _isNewConversationMode = false;
          _selectedSessionId = streamState.conversationId;
          _activeStreams = Map<String, ChatTurnStreamState>.from(_activeStreams)
            ..remove('pending_optimistic');
        }
      });
    });
  }

  /// Cập nhật một conversation duy nhất mà không ghi đè làm mất các conversation cũ
  void _handleSessionUpdate(ConversationSession updated) {
    setState(() {
      final existingIndex = _sessions.indexWhere((s) => s.id == updated.id);
      if (existingIndex >= 0) {
        final existing = _sessions[existingIndex];
        final mergedFiles = _mergeFilesTouched(existing.filesTouched, updated.filesTouched);
        final mergedLanes = updated.subagentLanes.isNotEmpty ? updated.subagentLanes : existing.subagentLanes;

        List<AgentStep> finalSteps;
        if (existing.steps.isNotEmpty && existing.steps.length > updated.steps.length) {
          finalSteps = _mergeNewerSteps(existing.steps, updated.steps);
        } else if (updated.steps.isEmpty && existing.steps.isNotEmpty) {
          finalSteps = existing.steps;
        } else {
          finalSteps = updated.steps;
        }

        final merged = updated.copyWith(
          steps: finalSteps,
          filesTouched: mergedFiles,
          subagentLanes: mergedLanes,
        );

        _sessions[existingIndex] = merged;
      } else {
        // Conversation mới tinh vừa được tạo trên server!
        _sessions.insert(0, updated);
      }

      // Sắp xếp các session theo updatedAt mới nhất lên đầu
      _sessions.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

      // Cập nhật lại số lượng sessionCount và runningCount trong project tương ứng
      final pIndex = _projects.indexWhere((p) => p.name == updated.projectName);
      if (pIndex >= 0) {
        final p = _projects[pIndex];
        final count = _sessions.where((s) => s.projectName == p.name).length;
        final running = _sessions.where((s) => s.projectName == p.name && s.status == AgentStatus.running).length;
        _projects[pIndex] = ProjectWorkspace(
          id: p.id,
          name: p.name,
          path: p.path,
          sessionCount: count,
          runningCount: running,
          lastActiveAt: updated.updatedAt,
          gitSyncStatus: p.gitSyncStatus,
          customAgents: p.customAgents,
          availableAgents: p.availableAgents,
        );
      }

      if (_selectedSessionId == updated.id) {
        if (updated.isInterrupted ||
            updated.status == AgentStatus.interrupted ||
            updated.status == AgentStatus.completed) {
          _isSendingPrompt = false;
        }
        _syncDefaultSelections();
      }
    });
  }

  /// Gộp danh sách session mới với dữ liệu đã nạp (steps, files, lanes) của session cũ
  List<ConversationSession> _mergeSessionList(List<ConversationSession> incoming) {
    final merged = <ConversationSession>[];
    for (final s in incoming) {
      final existing = _sessions.where((old) => old.id == s.id).firstOrNull;
      if (existing == null) {
        merged.add(s);
        continue;
      }
      final mergedFiles = _mergeFilesTouched(existing.filesTouched, s.filesTouched);
      final mergedLanes = s.subagentLanes.isNotEmpty ? s.subagentLanes : existing.subagentLanes;
      List<AgentStep>? steps;
      if (existing.steps.isNotEmpty && existing.steps.length > s.steps.length) {
        steps = _mergeNewerSteps(existing.steps, s.steps);
      } else if (s.steps.isEmpty && existing.steps.isNotEmpty) {
        steps = existing.steps;
      }
      merged.add(
        s.copyWith(
          steps: steps,
          filesTouched: mergedFiles,
          subagentLanes: mergedLanes,
        ),
      );
    }
    // Server trả tối đa 500 conversation: khi đạt giới hạn thì giữ lại các session cũ để không mất lịch sử
    if (incoming.length >= 500) {
      for (final existing in _sessions) {
        if (!merged.any((s) => s.id == existing.id)) {
          merged.add(existing);
        }
      }
    }
    merged.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return merged;
  }

  /// `sessions:list`: danh sách conversation (không kèm steps)
  void _applySessionsList(List<ConversationSession> list) {
    setState(() {
      _isRemoteConnected = true;
      _sessions = _mergeSessionList(list);
      _isLoading = false;
      _syncDefaultSelections();
    });
    // Bắt đầu poll AI questions cho session đang chọn
    if (_activeSession != null) {
      _startAIQuestionPoller();
      _refreshAIQuestions();
      _refreshClaudeInteraction();
    } else {
      _stopAIQuestionPoller();
    }
    // Setup file changes listener và join conversation room
    _setupFileChangesListener();
  }

  /// `meta:update`: máy chủ, project, danh sách model
  void _applyServerMeta(ServerMeta meta) {
    setState(() {
      _isRemoteConnected = true;
      _remoteHostName = meta.hostname;
      if (meta.lanIps.isNotEmpty) {
        _hostLanIps = meta.lanIps;
      }
      _projects = meta.projects;
      if (_activeChatProject != null) {
        _activeChatProject = _projects.firstWhere(
          (p) => p.name == _activeChatProject!.name,
          orElse: () => _activeChatProject!,
        );
      }
      if (meta.availableModels.isNotEmpty) {
        _availableModels = meta.availableModels;
        _modelLabels = meta.modelLabels;
        _effortLevels = meta.effortLevels;
        _modelContextLimits = meta.modelContextLimits;
      }
      _syncDefaultSelections();
    });
  }

  /// `streams:update`: danh sách đầy đủ các lượt đang chạy trên server
  void _applyActiveStreams(Map<String, ChatTurnStreamState> incoming) {
    setState(() {
      // Chỉ giữ lại stream 'pending_optimistic' (lượt vừa gửi, chờ server gán conversation id).
      // Stream của conversation thật mà server không còn liệt kê nghĩa là lượt đã xong hoặc đã mất
      // khi socket rớt — giữ lại sẽ làm UI kẹt ở trạng thái "đang trả lời".
      final mergedStreams = Map<String, ChatTurnStreamState>.from(incoming);
      final pendingOptimistic = _activeStreams['pending_optimistic'];
      if (pendingOptimistic != null &&
          pendingOptimistic.isRunning &&
          !mergedStreams.containsKey('pending_optimistic')) {
        mergedStreams['pending_optimistic'] = pendingOptimistic;
      }
      for (final entry in _activeStreams.entries) {
        if (entry.key == 'pending_optimistic' || mergedStreams.containsKey(entry.key)) {
          continue;
        }
        if (entry.value.isRunning && entry.key == _selectedSessionId) {
          _isSendingPrompt = false;
        }
      }
      _activeStreams = mergedStreams;
      // Nếu session đang chọn đã hoàn tất hoặc bị gián đoạn, mở khóa composer
      final curActive = _sessions.where((s) => s.id == _selectedSessionId).firstOrNull;
      if (curActive != null &&
          (curActive.isInterrupted ||
              curActive.status == AgentStatus.interrupted ||
              curActive.status == AgentStatus.completed)) {
        _isSendingPrompt = false;
      }
      _syncDefaultSelections();
    });
  }

  /// `session:removed`: conversation đã bị xoá khỏi đĩa
  void _applySessionRemoved(String id) {
    setState(() {
      _sessions = _sessions.where((s) => s.id != id).toList();
    });
  }

  Future<void> _loadFullSessionDetail(String sessionId) async {
    final detailed = await _sessionsRepo.fetchSessionDetail(
      address: _serverAddress,
      sessionId: sessionId,
    );
    if (!mounted || detailed == null) return;
    setState(() {
      final idx = _sessions.indexWhere((s) => s.id == sessionId);
      if (idx >= 0) {
        _sessions[idx] = detailed;
      }
    });
  }

  Future<void> _initEnvironmentAndLoad() async {
    setState(() => _isLoading = true);
    final savedAddress = await _connectionRepo.loadSavedServerAddress();
    if (!mounted) return;
    setState(() {
      _serverAddress = savedAddress;
    });

    _connectionRepo.connectSocket(_serverAddress);
    await _refreshSessions(silent: false);
  }

  Future<void> _refreshSessions({bool silent = false}) async {
    if (!silent && mounted) {
      setState(() => _isLoading = true);
    }

    if (_isSocketLive) {
      _sessionsRepo.requestSync();
      return;
    }

    // Socket chưa kết nối: đọc các phần qua HTTP
    final results = await Future.wait([
      _sessionsRepo.fetchRemoteSessions(_serverAddress),
      _sessionsRepo.fetchRemoteMeta(_serverAddress),
      _sessionsRepo.fetchRemoteStreams(_serverAddress),
    ]);
    if (!mounted) return;
    final sessions = results[0] as List<ConversationSession>?;
    final meta = results[1] as ServerMeta?;
    final streams = results[2] as Map<String, ChatTurnStreamState>?;
    if (sessions == null && meta == null) {
      setState(() {
        _isRemoteConnected = false;
        _isLoading = false;
      });
      return;
    }
    if (meta != null) _applyServerMeta(meta);
    if (streams != null) _applyActiveStreams(streams);
    if (sessions != null) _applySessionsList(sessions);
  }

  /// Model mặc định theo provider: ưu tiên Claude Sonnet 5.5 (claude-cli), còn lại lấy model đầu tiên cùng provider
  String _defaultModelFor(String source) {
    const claudeDefault = 'claude-cli:claude-sonnet-5-5';
    final sameProvider =
        _availableModels.where((m) => _sourceFromModel(m) == source).toList();
    final pool = sameProvider.isNotEmpty ? sameProvider : _availableModels;
    if (pool.isEmpty) return claudeDefault;
    // Model đầu tiên trong danh sách; nếu nhóm có nhiều mức thì dùng mức Medium
    final first = pool.first;
    final group = groupModels(
      pool,
      _modelLabels,
      effortLevels: resolveEffortLevels(_effortLevels),
    ).firstWhere((g) => g.options.any((o) => o.id == first));
    return group.preferredOption().id;
  }

  /// Model kèm mức đã dùng trong conversation, lấy từ bản ghi server (`selectedModel`, ghi khi lượt bắt đầu).
  /// Conversation cũ chưa có bản ghi thì lấy model gốc của lượt phản hồi gần nhất, mức lấy theo mặc định của nhóm.
  /// Trả null nếu không có lịch sử hoặc không khớp danh sách model.
  String? _modelFromHistory(ConversationSession? session) {
    if (session == null) return null;
    final saved = session.selectedModel;
    if (saved.isNotEmpty) {
      return _availableModels.contains(saved) ? saved : null;
    }
    String raw = '';
    for (final step in session.steps.reversed) {
      if (step.model.isNotEmpty) {
        raw = step.model;
        break;
      }
    }
    if (raw.isEmpty) return null;
    if (session.source == 'agy') {
      final candidate = 'agy:$raw';
      return _availableModels.contains(candidate) ? candidate : null;
    }
    final id = raw.replaceFirst(RegExp(r'-\d{8}$'), '');
    final candidate = 'claude-cli:$id';
    final groups = groupModels(
      _availableModels,
      _modelLabels,
      effortLevels: resolveEffortLevels(_effortLevels),
    );
    final group = groups.where((g) => g.id == candidate).firstOrNull;
    return group?.preferredOption().id;
  }

  static String _sourceFromModel(String model) {
    if (model.startsWith('claude-cli:') ||
        model == 'sonnet' ||
        model == 'opus' ||
        model == 'haiku') {
      return 'claude-cli';
    }
    return 'agy';
  }

  /// Khoá ghi nhớ model: id conversation đang chọn, hoặc '__new__' khi chưa có conversation
  String get _effectiveModel =>
      (_selectedModel.isEmpty || _selectedModel == 'default')
          ? 'claude-cli:claude-sonnet-5-5'
          : _selectedModel;

  String get _modelMemoryKey {
    if (_isNewConversationMode) return '__new__';
    final id = _selectedSessionId;
    return (id == null || id.isEmpty) ? '__new__' : id;
  }

  /// Provider của cuộc chat đang chọn.
  /// Ưu tiên `source` của session trên server; nếu session vừa tạo chưa có trong
  /// snapshot thì dùng `source` từ phản hồi `chat:send`; cuối cùng suy ra từ model.
  String get _activeSource {
    final id = _selectedSessionId;
    if (id != null && id.isNotEmpty) {
      for (final s in _sessions) {
        if (s.id == id && s.source.isNotEmpty) return s.source;
      }
      final known = _sourceByConversation[id];
      if (known != null && known.isNotEmpty) return known;
    }
    return _sourceFromModel(_selectedModel);
  }

  String _getAgentForSession(ConversationSession? session) {
    if (session == null) return 'Coordinator';
    // Session của claude-cli chỉ dùng agent của claude-cli (Coordinator)
    if (session.source == 'claude-cli') {
      return 'Coordinator';
    }
    // Session của agy dùng agent của agy
    return 'Coordinator';
  }

  void _syncDefaultSelections() {
    if (_selectedSessionId == null &&
        !_isNewConversationMode &&
        _sessions.isNotEmpty) {
      _selectedSessionId = _sessions.first.id;
    }

    // Xác định model phù hợp dựa trên session được chọn
    final currentSess = _activeSession;
    // Thứ tự ưu tiên: model người dùng vừa chọn trong phiên này → model đã dùng trong conversation
    // (lịch sử) → model mặc định. Conversation mới không có lịch sử nên luôn dùng mặc định.
    final remembered = _modelBySession[_modelMemoryKey];
    final provider = _activeSource;
    final historyModel =
        _isNewConversationMode ? null : _modelFromHistory(currentSess);
    if (remembered != null &&
        _availableModels.contains(remembered) &&
        _sourceFromModel(remembered) == provider) {
      _selectedModel = remembered;
    } else if (historyModel != null &&
        _sourceFromModel(historyModel) == provider) {
      _selectedModel = historyModel;
    } else {
      _selectedModel = _defaultModelFor(provider);
    }

    if (_selectedModel == 'default' || !_availableModels.contains(_selectedModel)) {
      _selectedModel = _availableModels.isNotEmpty
          ? _defaultModelFor(provider)
          : 'claude-cli:claude-sonnet-5-5';
    }

    // Đồng bộ agent dựa trên session
    _selectedAgent = _getAgentForSession(currentSess);

    if (_activeChatProject == null && _projects.isNotEmpty) {
      if (currentSess != null) {
        _activeChatProject = _projects.firstWhere(
          (p) => p.name == currentSess.projectName,
          orElse: () => _projects.first,
        );
      } else {
        _activeChatProject = _projects.first;
      }
    }
  }

  Future<void> _handleSendPrompt(String promptText) async {
    final targetProjectPath = _activeChatProject?.path ??
        _activeSession?.projectPath ??
        '/home/john/Documents/muop-ecosystem/muop-erp-server';
    final targetConvId =
        _isNewConversationMode ? '' : (_selectedSessionId ?? '');

    final optKey = targetConvId.isNotEmpty ? targetConvId : 'pending_optimistic';
    final optState = ChatTurnStreamState(
      conversationId: optKey,
      projectPath: targetProjectPath,
      userPrompt: promptText,
      streamingText: '',
      isRunning: true,
      activeStepType: 'starting',
      startedAt: DateTime.now(),
      error: '',
    );

    setState(() {
      _isSendingPrompt = true;
      _activeStreams = {
        ..._activeStreams,
        optKey: optState,
      };
    });

    final effectiveModel = _effectiveModel;

    final result = await _chatRepo.sendRemoteChatPrompt(
      address: _serverAddress,
      prompt: promptText,
      projectPath: targetProjectPath,
      conversationId: targetConvId,
      agentName: _selectedAgent,
      model: effectiveModel,
    );

    if (!mounted) return;
    setState(() => _isSendingPrompt = false);

    if (result.ok) {
      setState(() {
        _isNewConversationMode = false;
        if (result.conversationId.isNotEmpty && result.source.isNotEmpty) {
          _sourceByConversation[result.conversationId] = result.source;
        }
        if (result.conversationId.isNotEmpty) {
          _selectedSessionId = result.conversationId;
          // Ghi nhớ model đã dùng cho conversation này để lần sau mở lại vẫn giữ nguyên
          _modelBySession[result.conversationId] = effectiveModel;
          if (optKey != result.conversationId && _activeStreams.containsKey(optKey)) {
            final old = _activeStreams[optKey];
            final nextStreams = Map<String, ChatTurnStreamState>.from(_activeStreams);
            nextStreams.remove(optKey);
            if (old != null && !nextStreams.containsKey(result.conversationId)) {
              nextStreams[result.conversationId] =
                  old.copyWith(conversationId: result.conversationId);
            }
            _activeStreams = nextStreams;
          }
        }
      });
      _sessionsRepo.requestSync();
    } else {
      setState(() {
        final currentOpt = _activeStreams[optKey] ?? optState;
        _activeStreams = {
          ..._activeStreams,
          optKey: currentOpt.copyWith(
            isRunning: false,
            activeStepType: 'error',
            error: result.error,
          ),
        };
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Không thể gửi tin nhắn tới Agent: ${result.error}'),
          backgroundColor: context.scheme.error,
        ),
      );
    }
  }

  PendingRetry? _pendingRetryFor(String? conversationId) {
    if (conversationId == null) return null;
    for (final r in _pendingRetries) {
      if (r.conversationId == conversationId) return r;
    }
    return null;
  }

  void _showRetryPopup(String conversationId) {
    showDialog<void>(
      context: context,
      builder: (_) => RetryPopup(
        conversationId: conversationId,
        retries: _retryNotifier,
        onCancel: () => _cancelRetry(conversationId),
      ),
    );
  }

  Future<void> _cancelRetry(String conversationId) async {
    final ok = await _interactionsRepo.cancelRetry(
      address: _serverAddress,
      conversationId: conversationId,
    );
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Không hủy được lịch tự gửi lại'),
          backgroundColor: context.scheme.error,
        ),
      );
    }
  }

  Future<void> _handleStopTurn() async {
    final cid = _selectedSessionId ?? '';
    if (cid.isEmpty) return;
    await _chatRepo.stopRemoteChatTurn(
      address: _serverAddress,
      conversationId: cid,
    );
    _sessionsRepo.requestSync();
  }

  Future<void> _handleApprovePlan(PlanArtifactInfo plan) async {
    final active = _activeSession;
    if (active == null) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: context.scheme.onPrimary,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Đang phê duyệt kế hoạch [${plan.fileName}] và khởi chạy...',
                style: const TextStyle(fontSize: 12.5),
              ),
            ),
          ],
        ),
        duration: const Duration(seconds: 2),
      ),
    );

    final res = await _interactionsRepo.submitPlanAction(
      address: _serverAddress,
      conversationId: active.id,
      fileName: plan.fileName,
      action: 'approve',
      model: _selectedModel,
    );

    if (!mounted) return;

    if (res.ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '✅ Kế hoạch [${plan.fileName}] đã được duyệt thành công! Các Agent đang thực thi.',
          ),
          backgroundColor: context.status.success,
          duration: const Duration(seconds: 3),
        ),
      );
      await _loadFullSessionDetail(active.id);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('❌ Không thể duyệt kế hoạch: ${res.message}'),
          backgroundColor: context.scheme.error,
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  Future<void> _handleRejectPlan(
    PlanArtifactInfo plan,
    String feedback,
  ) async {
    final active = _activeSession;
    if (active == null) return;

    final res = await _interactionsRepo.submitPlanAction(
      address: _serverAddress,
      conversationId: active.id,
      fileName: plan.fileName,
      action: 'reject',
      feedback: feedback,
      model: _selectedModel,
    );

    if (!mounted) return;

    if (res.ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '📝 Đã gửi yêu cầu chỉnh sửa cho kế hoạch [${plan.fileName}]. AI sẽ cập nhật lại.',
          ),
          duration: const Duration(seconds: 3),
        ),
      );
      await _loadFullSessionDetail(active.id);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('❌ Gửi phản hồi thất bại: ${res.message}'),
          backgroundColor: context.scheme.error,
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  Future<void> _handleCancelPlan(PlanArtifactInfo plan) async {
    final active = _activeSession;
    if (active == null) return;

    final res = await _interactionsRepo.submitPlanAction(
      address: _serverAddress,
      conversationId: active.id,
      fileName: plan.fileName,
      action: 'cancel',
      model: _selectedModel,
    );

    if (!mounted) return;

    if (res.ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('🛑 Đã hủy kế hoạch [${plan.fileName}].'),
          duration: const Duration(seconds: 3),
        ),
      );
      await _loadFullSessionDetail(active.id);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('❌ Không thể hủy kế hoạch: ${res.message}'),
          backgroundColor: context.scheme.error,
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  Future<GitPushResponse> _handleGitPush(
    String projectPath,
    String branch,
  ) async {
    return _projectsRepo.gitPush(
      address: _serverAddress,
      projectPath: projectPath,
      branch: branch,
    );
  }

  Future<List<CustomAgentSpec>?> _handleFetchClaudeExtensions(String projectPath) {
    return _projectsRepo.fetchClaudeExtensions(
      address: _serverAddress,
      projectPath: projectPath,
    );
  }

  Future<bool> _handleLoadOlderHistory() async {
    final active = _activeSession;
    if (active == null) return false;

    // Tìm stepIndex nhỏ nhất hiện có trong phiên để nạp trang 30 bước phía trước
    int earliestStep = 999999999;
    for (final s in active.steps) {
      if (s.stepIndex < earliestStep) {
        earliestStep = s.stepIndex;
      }
    }
    if (earliestStep == 999999999) earliestStep = 0;

    final page = await _sessionsRepo.fetchSessionStepsPage(
      address: _serverAddress,
      sessionId: active.id,
      beforeStepIndex: earliestStep > 0 ? earliestStep : null,
      limit: 30,
    );

    if (!mounted || page == null) return false;

    var addedSteps = false;
    if (page.steps.isNotEmpty) {
      final existingIds = active.steps.map((s) => s.stepIndex).toSet();
      final olderSteps =
          page.steps.where((s) => !existingIds.contains(s.stepIndex)).toList();
      if (olderSteps.isNotEmpty) {
        addedSteps = true;
        final merged = [...olderSteps, ...active.steps];
        merged.sort((a, b) => a.stepIndex.compareTo(b.stepIndex));
        setState(() {
          final idx = _sessions.indexWhere((s) => s.id == active.id);
          if (idx >= 0) {
            _sessions[idx] = active.copyWith(steps: merged);
          }
        });
      }
    }
    return page.hasMore && addedSteps;
  }

  void _openParallelAgentFlowScreen() {
    final active = _activeSession;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ParallelAgentFlowScreen(
          session: active,
          activeStream: _activeStreams[active?.id ?? ''],
          serverAddress: _serverAddress,
          onStopTurn: () {
            if (active != null) _handleStopTurn();
          },
          onInspectFile: (path, gf) => _inspectFileChange(path, gf),
        ),
      ),
    );
  }

  List<FileTouchRecord> _mergeFilesTouched(
    List<FileTouchRecord> oldFiles,
    List<FileTouchRecord> newFiles,
  ) {
    if (newFiles.isEmpty) return oldFiles;
    if (oldFiles.isEmpty) return newFiles;

    final seen = <String>{};
    final merged = <FileTouchRecord>[];

    // Ưu tiên các records từ newFiles
    for (final f in newFiles) {
      final key = '${f.path}__${f.stepIndex}__${f.action}';
      if (seen.add(key)) {
        merged.add(f);
      }
    }

    // Bổ sung các records cũ từ oldFiles nếu chưa có
    for (final f in oldFiles) {
      final key = '${f.path}__${f.stepIndex}__${f.action}';
      if (seen.add(key)) {
        merged.add(f);
      }
    }

    return merged;
  }

  List<AgentStep> _mergeNewerSteps(
    List<AgentStep> existing,
    List<AgentStep> incoming,
  ) {
    if (incoming.isEmpty) return existing;
    if (existing.isEmpty) return incoming;

    final existingIndices = existing.map((e) => e.stepIndex).toSet();
    final result = List<AgentStep>.from(existing);

    for (final step in incoming) {
      if (!existingIndices.contains(step.stepIndex)) {
        result.add(step);
      } else {
        final idx = result.indexWhere((e) => e.stepIndex == step.stepIndex);
        if (idx >= 0 && idx == result.length - 1) {
          result[idx] = step;
        }
      }
    }
    result.sort((a, b) => a.stepIndex.compareTo(b.stepIndex));
    return result;
  }

  void _startNewConversationInProject(ProjectWorkspace? project) {
    _closePanelPages();
    setState(() {
      _isNewConversationMode = true;
      _selectedSessionId = null;
      if (project != null) {
        _activeChatProject = project;
      }
    });
  }

  void _openServerFileBrowser({int initialTab = 0}) {
    final activeSession = _activeSession;
    final initialDir = _activeChatProject?.path ??
        activeSession?.projectPath ??
        '/home/john/Documents/muop-ecosystem';

    ServerFileBrowserSheet.show(
      context,
      serverAddress: _serverAddress,
      initialPath: initialDir,
      projects: _projects,
      sessionFiles: activeSession?.filesTouched ?? const [],
      initialTab: initialTab,
    );
  }

  void _inspectFileChange(String filePath, GroupedFileChange? change) {
    ServerFileBrowserSheet.showFilePreviewAndDiff(
      context,
      serverAddress: _serverAddress,
      filePath: filePath,
      groupedChange: change,
      onDownloadFile: _downloadFileDirectly,
    );
  }

  void _openActiveGitHistory() {
    final project = _activeChatProject;
    final path = project?.path ??
        _activeSession?.projectPath ??
        '/home/john/Documents/muop-ecosystem/muop-agent';
    final name = project?.name ?? _activeSession?.projectName;

    ProjectGitHistorySheet.show(
      context,
      serverAddress: _serverAddress,
      projectPath: path,
      projectName: name,
    );
  }

  void _openGitHistorySheet(ProjectWorkspace project) {
    ProjectGitHistorySheet.show(
      context,
      serverAddress: _serverAddress,
      projectPath: project.path,
      projectName: project.name,
    );
  }

  Future<void> _downloadFileDirectly(String remotePath) async {
    final filename = remotePath.split('/').last;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Đang tải file "$filename" từ Rust Server...'),
        duration: const Duration(seconds: 2),
      ),
    );

    final res = await _serverFilesRepo.downloadFileFromServer(
      address: _serverAddress,
      remotePath: remotePath,
    );

    if (!mounted) return;
    if (res.ok) {
      setState(() {
        _lastDownloadedFilePath = res.savedPath;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Đã tải xong: ${res.savedPath}'),
          duration: const Duration(seconds: 5),
          action: SnackBarAction(
            label: 'Mở tệp',
            onPressed: () {
              _serverFilesRepo.openDownloadedFile(res.savedPath);
            },
          ),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Không thể tải file: ${res.error}'),
          backgroundColor: context.scheme.error,
        ),
      );
    }
  }

  Future<void> _showCreateProjectDialog(BuildContext context) async {
    final nameController = TextEditingController();
    final descController = TextEditingController();
    String selectedTemplate = 'standard';
    bool isCreating = false;
    String? validationError;

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (dialogContext, setModalState) {
            final colorScheme = Theme.of(dialogContext).colorScheme;
            final textTheme = Theme.of(dialogContext).textTheme;

            final projectName = nameController.text.trim();
            final targetPath = projectName.isEmpty
                ? '/home/john/Documents/muop-ecosystem/<tên-project>'
                : '/home/john/Documents/muop-ecosystem/$projectName';

            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              title: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: colorScheme.primary.withAlpha(30),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      Icons.create_new_folder_rounded,
                      color: colorScheme.primary,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Tạo Project Mới',
                          style: textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        Text(
                          'Khởi tạo Workspace trong muop-ecosystem',
                          style: textTheme.labelSmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              content: SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 480),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Tên Project
                      TextField(
                        controller: nameController,
                        autofocus: true,
                        decoration: InputDecoration(
                          labelText: 'Tên Project (Thư mục)',
                          hintText: 'muop-service-sample',
                          prefixIcon: const Icon(Icons.folder_outlined, size: 20),
                          errorText: validationError,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          filled: true,
                          isDense: true,
                        ),
                        onChanged: (val) {
                          if (validationError != null) {
                            setModalState(() => validationError = null);
                          } else {
                            setModalState(() {});
                          }
                        },
                      ),
                      const SizedBox(height: 10),

                      // Đường dẫn xem trước
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 7,
                        ),
                        decoration: BoxDecoration(
                          color: colorScheme.surfaceContainerHighest.withAlpha(120),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: colorScheme.outlineVariant.withAlpha(80),
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.terminal_rounded,
                              size: 14,
                              color: colorScheme.primary,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                targetPath,
                                style: const TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 11,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),

                      // Chọn Template
                      Text(
                        'Loại dự án (Template):',
                        style: textTheme.labelMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          ChoiceChip(
                            label: const Text('📦 Tiêu chuẩn (Standard)'),
                            selected: selectedTemplate == 'standard',
                            onSelected: (sel) {
                              if (sel) {
                                setModalState(() => selectedTemplate = 'standard');
                              }
                            },
                          ),
                          ChoiceChip(
                            label: const Text('🐹 Backend Go (Clean Arch)'),
                            selected: selectedTemplate == 'go',
                            onSelected: (sel) {
                              if (sel) {
                                setModalState(() => selectedTemplate = 'go');
                              }
                            },
                          ),
                          ChoiceChip(
                            label: const Text('📱 Frontend Flutter (M3)'),
                            selected: selectedTemplate == 'flutter',
                            onSelected: (sel) {
                              if (sel) {
                                setModalState(() => selectedTemplate = 'flutter');
                              }
                            },
                          ),
                          ChoiceChip(
                            label: const Text('📄 Trống (Empty)'),
                            selected: selectedTemplate == 'empty',
                            onSelected: (sel) {
                              if (sel) {
                                setModalState(() => selectedTemplate = 'empty');
                              }
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),

                      // Mô tả (tùy chọn)
                      TextField(
                        controller: descController,
                        maxLines: 2,
                        decoration: InputDecoration(
                          labelText: 'Mô tả dự án (Tùy chọn)',
                          hintText: 'Dự án backend xử lý nghiệp vụ đơn hàng & thanh toán',
                          alignLabelWithHint: true,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          filled: true,
                          isDense: true,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: isCreating ? null : () => Navigator.of(ctx).pop(),
                  child: const Text('Hủy'),
                ),
                FilledButton.icon(
                  onPressed: isCreating
                      ? null
                      : () async {
                          final name = nameController.text.trim();
                          if (name.isEmpty) {
                            setModalState(() {
                              validationError = 'Vui lòng nhập tên project';
                            });
                            return;
                          }

                          setModalState(() {
                            isCreating = true;
                            validationError = null;
                          });

                          final res = await _projectsRepo.createProject(
                            address: _serverAddress,
                            name: name,
                            template: selectedTemplate,
                            description: descController.text.trim(),
                          );

                          if (!mounted) return;

                          if (res.ok) {
                            if (ctx.mounted) Navigator.of(ctx).pop();
                            final newProj = res.project ??
                                ProjectWorkspace(
                                  id: name,
                                  name: name,
                                  path: '/home/john/Documents/muop-ecosystem/$name',
                                  sessionCount: 0,
                                  runningCount: 0,
                                );
                            setState(() {
                              if (!_projects.any((p) => p.name == newProj.name)) {
                                _projects = [..._projects, newProj];
                              }
                              _activeChatProject = newProj;
                              _startNewConversationInProject(newProj);
                            });
                            _sessionsRepo.requestSync();
                            if (mounted) {
                              ScaffoldMessenger.of(this.context).showSnackBar(
                                SnackBar(
                                  content: Text('🎉 ${res.message}'),
                                  backgroundColor: this.context.status.success,
                                ),
                              );
                            }
                          } else {
                            setModalState(() {
                              isCreating = false;
                              validationError = res.error ?? res.message;
                            });
                          }
                        },
                  icon: isCreating
                      ? SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: context.scheme.onPrimary,
                          ),
                        )
                      : const Icon(Icons.add_circle_outline_rounded, size: 18),
                  label: Text(
                    isCreating ? 'Đang tạo...' : 'Tạo Project & Mở Chat',
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _showServerConfigDialog() async {
    final ipController = TextEditingController(text: _serverAddress);
    RemotePingResult? pingResult;
    bool isPinging = false;

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            final colorScheme = Theme.of(context).colorScheme;
            final textTheme = Theme.of(context).textTheme;

            Future<void> testPing() async {
              setModalState(() {
                isPinging = true;
                pingResult = null;
              });
              final res = await _connectionRepo.pingRemoteServer(ipController.text);
              setModalState(() {
                isPinging = false;
                pingResult = res;
              });
            }

            return AlertDialog(
              title: Row(
                children: [
                  Icon(Icons.bolt_rounded, color: colorScheme.primary),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'Kết nối Rust Server (Socket.IO)',
                      style: TextStyle(
                        fontSize: 16.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: (_isSocketLive ? context.status.success : context.status.warning)
                            .withAlpha(25),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: (_isSocketLive ? context.status.success : context.status.warning)
                              .withAlpha(120),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                _isSocketLive
                                    ? Icons.sensors_rounded
                                    : Icons.sync_problem_rounded,
                                size: 16,
                                color:
                                    _isSocketLive ? context.status.success : context.status.warning,
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  _isSocketLive
                                      ? 'Socket.IO Realtime đang kết nối!'
                                      : 'Đang chờ kết nối Socket.IO...',
                                  style: textTheme.labelMedium?.copyWith(
                                    fontWeight: FontWeight.w800,
                                    color: _isSocketLive
                                        ? context.status.success
                                        : context.status.warning,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 6,
                            children: [
                              for (final ip in _hostLanIps)
                                ActionChip(
                                  avatar: const Icon(
                                    Icons.copy_rounded,
                                    size: 13,
                                  ),
                                  label: Text(
                                    '$ip:$defaultBridgePort',
                                    style: const TextStyle(
                                      fontFamily: 'monospace',
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  onPressed: () {
                                    final addr =
                                        '$ip:$defaultBridgePort';
                                    Clipboard.setData(
                                      ClipboardData(text: addr),
                                    );
                                    setModalState(() {
                                      ipController.text = addr;
                                    });
                                  },
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: ipController,
                      keyboardType: TextInputType.url,
                      decoration: InputDecoration(
                        labelText: 'Địa chỉ IP & Cổng (Rust Server)',
                        hintText: '192.168.31.96:8787',
                        prefixIcon: const Icon(Icons.dns_rounded),
                        suffixIcon: IconButton(
                          icon: const Icon(Icons.clear_rounded, size: 18),
                          onPressed: () => ipController.clear(),
                        ),
                        filled: true,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        ActionChip(
                          label: const Text('192.168.31.96:8787 (LAN)'),
                          onPressed: () {
                            setModalState(() {
                              ipController.text = '192.168.31.96:8787';
                            });
                          },
                        ),
                        ActionChip(
                          label: const Text('100.121.158.198:8787 (VPN)'),
                          onPressed: () {
                            setModalState(() {
                              ipController.text = '100.121.158.198:8787';
                            });
                          },
                        ),
                        ActionChip(
                          label: const Text('127.0.0.1:8787 (Local)'),
                          onPressed: () {
                            setModalState(() {
                              ipController.text = '127.0.0.1:8787';
                            });
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: isPinging ? null : testPing,
                        icon: isPinging
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.network_check_rounded, size: 17),
                        label: Text(
                          isPinging ? 'Đang kiểm tra...' : 'Kiểm tra kết nối',
                        ),
                      ),
                    ),
                    if (pingResult != null) ...[
                      const SizedBox(height: 10),
                      Text(
                        pingResult!.isOnline
                            ? '✓ Kết nối thành công tới ${pingResult!.hostname} (${pingResult!.latencyMs}ms)'
                            : '✕ Lỗi kết nối: ${pingResult!.errorMessage}',
                        style: textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: pingResult!.isOnline
                              ? context.status.success
                              : context.scheme.error,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Hủy'),
                ),
                FilledButton(
                  onPressed: () async {
                    final newAddr = ipController.text.trim().isEmpty
                        ? defaultHostAddress
                        : ipController.text.trim();
                    await _connectionRepo.saveServerAddress(newAddr);
                    if (!mounted) return;
                    setState(() {
                      _serverAddress = newAddr;
                    });
                    _connectionRepo.connectSocket(newAddr);
                    if (ctx.mounted) {
                      Navigator.of(ctx).pop();
                    }
                    await _refreshSessions(silent: false);
                  },
                  child: const Text('Kết nối'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  List<ConversationSession> get _filteredSessions {
    if (_searchQuery.isEmpty) return _sessions;
    final q = _searchQuery.toLowerCase();
    return _sessions.where((s) {
      return s.title.toLowerCase().contains(q) ||
          s.projectName.toLowerCase().contains(q) ||
          s.id.toLowerCase().contains(q);
    }).toList();
  }

  ConversationSession? get _activeSession {
    if (_isNewConversationMode) return null;
    if (_sessions.isEmpty) return null;
    return _sessions.firstWhere(
      (s) => s.id == _selectedSessionId,
      orElse: () => _sessions.first,
    );
  }

  ChatTurnStreamState? get _currentSessionStream {
    if (_isNewConversationMode) {
      return _activeStreams['pending_optimistic'];
    }
    final cid = _selectedSessionId;
    if (cid == null) return _activeStreams['pending_optimistic'];
    return _activeStreams[cid] ?? _activeStreams['pending_optimistic'];
  }

  Widget _buildAIQuestionBanner(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      color: context.status.warning.withAlpha(36),
      child: Row(
        children: [
          Icon(Icons.help_outline, color: context.status.warning, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '❓ AI có ${_pendingAIQuestions.length} câu hỏi chờ trả lời',
                  style: TextStyle(
                    fontWeight: FontWeight.w500,
                    fontSize: 13,
                    color: context.status.warning,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _pendingAIQuestions.first.question,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: context.status.warning,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          ElevatedButton(
            onPressed: () {
              if (_pendingAIQuestions.isNotEmpty) {
                _showAIQuestionDialog(_pendingAIQuestions.first);
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: context.status.warning,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            ),
            child: Text(
              'Trả lời',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: context.scheme.onPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final width = MediaQuery.sizeOf(context).width;
    final isMobile = width < 760;
    final activeSession = _activeSession;

    final Widget scaffoldBody;
    if (isMobile) {
      scaffoldBody = SafeArea(
        child: _buildMainColumn(
          context,
          activeSession,
          isMobile: true,
          content: _buildChatArea(context, activeSession),
        ),
      );
    } else {
      scaffoldBody = PanelScope(
        open: _openPanel,
        child: SafeArea(child: _buildDesktopLayout(context, activeSession, width)),
      );
    }

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: colorScheme.surface,
      drawer: isMobile
          ? Drawer(
              width: 300,
              backgroundColor: colorScheme.surfaceContainerLow,
              child: SafeArea(
                child: RepaintBoundary(
                  child: _buildAntigravitySidebar(context, isMobileDrawer: true),
                ),
              ),
            )
          : null,
      body: scaffoldBody,
    );
  }

  /// Mở SSH / Docker từ sidebar. Desktop: vào vùng chính bên phải. Mobile: push full-screen.
  /// Không dùng [openPanelPage] ở đây vì context của State nằm phía trên [PanelScope].
  Future<void> _openFromSidebar(BuildContext context, Widget page) {
    final desktop = MediaQuery.sizeOf(context).width >= 760;
    if (desktop) return _openPanel(page);
    return Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
  }

  Future<void> _openPanel(Widget page) {
    final entry = _PanelEntry(ValueKey('panel-${_panelSeq++}'), page);
    setState(() => _panelPages.add(entry));
    return entry.done.future;
  }

  /// Quay về màn hình chính (explorer + chat): đóng mọi trang SSH/Docker đang mở trong vùng chính.
  /// Đóng qua Navigator (pop): trang được gỡ khỏi danh sách trong [_onPanelRemovePage].
  void _closePanelPages() {
    if (_panelPages.isEmpty) return;
    final nav = _panelNavKey.currentState;
    if (nav != null) {
      nav.popUntil((route) => route.isFirst);
      return;
    }
    // Chưa có Navigator (chưa dựng lần nào): gỡ thẳng khỏi danh sách
    final closed = List<_PanelEntry>.of(_panelPages);
    setState(() => _panelPages.clear());
    for (final e in closed) {
      if (!e.done.isCompleted) e.done.complete();
    }
  }

  /// Navigator đã gỡ một trang (nút back / pop): đồng bộ danh sách. Không gọi setState ở đây vì callback
  /// có thể chạy trong lúc Navigator build; dashboard sẽ dựng lại với danh sách đã gỡ ở lần build sau.
  void _onPanelRemovePage(Page<Object?> page) {
    final idx = _panelPages.indexWhere((e) => e.key == page.key);
    if (idx < 0) return;
    final entry = _panelPages.removeAt(idx);
    if (!entry.done.isCompleted) entry.done.complete();
    // Dựng lại sau frame hiện tại (callback có thể chạy trong lúc Navigator build): explorer hiện lại khi panel đóng
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  /// Vùng chính desktop: trang dashboard ở đáy, các trang SSH/Docker/log xếp lên trên
  Widget _buildPanelNavigator(BuildContext context, {required Widget mainPage}) {
    return Navigator(
      key: _panelNavKey,
      pages: [
        MaterialPage<void>(key: const ValueKey('dashboard-main'), child: mainPage),
        for (final e in _panelPages) MaterialPage<void>(key: e.key, child: e.page),
      ],
      onDidRemovePage: _onPanelRemovePage,
    );
  }

  /// Layout desktop: rail conversation (thu gọn / ghim) → explorer cây thư mục → vùng chính
  /// chia đôi có thanh kéo (viewer file | chat). Rail mở rộng khi hover được vẽ đè lên các cột.
  Widget _buildDesktopLayout(
    BuildContext context,
    ConversationSession? activeSession,
    double width,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    // Khi đang mở trang SSH/Docker/log, vùng bên phải thuộc về trang đó: ẩn cây thư mục
    final showExplorer = _panelPages.isEmpty && (_explorerOverride ?? width >= 1200);
    final viewerOpen = _viewerFilePath != null;
    final projectRoot = _activeChatProject?.path ?? activeSession?.projectPath ?? '';

    final railConversations = [
      for (final s in _filteredSessions)
        RailConversation(
          id: s.id,
          title: s.title,
          projectName: s.projectName,
          icon: Icons.chat_bubble_outline_rounded,
          color: s.source == 'claude-cli' ? context.status.warning : context.scheme.primary,
        ),
    ];

    return Stack(
      children: [
        Positioned.fill(
          child: Row(
            children: [
              if (_showDesktopSidebar)
                SizedBox(
                  width: 280,
                  child: RepaintBoundary(
                    child: _buildAntigravitySidebar(context, isMobileDrawer: false),
                  ),
                )
              else
                MouseRegion(
                  onEnter: (_) => setState(() => _railHovered = true),
                  onExit: (_) => setState(() => _railHovered = false),
                  child: DesktopConversationRail(
                    conversations: railConversations,
                    selectedId: _isNewConversationMode ? null : _selectedSessionId,
                    onSelect: (id) {
                      final session = _sessions.where((s) => s.id == id).firstOrNull;
                      if (session != null) _selectConversation(session);
                    },
                    onNewConversation: () => _startNewConversationInProject(_activeChatProject),
                    onHoverChanged: (hovered) => setState(() => _railHovered = hovered),
                    isPinned: _showDesktopSidebar,
                    onTogglePin: () => setState(() => _showDesktopSidebar = !_showDesktopSidebar),
                  ),
                ),
              VerticalDivider(width: 1, color: colorScheme.outlineVariant),
              if (showExplorer) ...[
                SizedBox(
                  width: 240,
                  child: RepaintBoundary(
                    child: projectRoot.isEmpty
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Text(
                                'Chọn một project để xem cây thư mục',
                                textAlign: TextAlign.center,
                                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: colorScheme.onSurfaceVariant,
                                    ),
                              ),
                            ),
                          )
                        : ProjectTreeExplorer(
                            serverAddress: _serverAddress,
                            rootPath: projectRoot,
                            selectedFilePath: _viewerFilePath,
                            fileStatuses: _explorerFileStatuses(activeSession),
                            onOpenFile: (path) => setState(() => _viewerFilePath = path),
                            onCollapse: () => setState(() => _explorerOverride = false),
                          ),
                  ),
                ),
                VerticalDivider(width: 1, color: colorScheme.outlineVariant),
              ],
              // Key cố định: explorer ẩn/hiện không được làm Navigator (và state chat bên trong) bị dựng lại
              Expanded(
                key: const ValueKey('desktop-main'),
                child: _buildPanelNavigator(
                  context,
                  mainPage: _buildMainColumn(
                  context,
                  activeSession,
                  isMobile: false,
                  content: ResizableSplitView(
                    showLeft: viewerOpen,
                    left: viewerOpen
                        ? FileDiffAndContentPane(
                            key: ValueKey(_viewerFilePath),
                            serverAddress: _serverAddress,
                            filePath: _viewerFilePath!,
                            onDownloadFile: _downloadFileDirectly,
                            onClose: () => setState(() => _viewerFilePath = null),
                          )
                        : const SizedBox.shrink(),
                    right: _buildChatArea(context, activeSession),
                  ),
                ),
                ),
              ),
            ],
          ),
        ),
        // Rail mở rộng khi hover: nổi lên trên, không đẩy nội dung
        if (_railHovered && !_showDesktopSidebar)
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: 280,
            child: MouseRegion(
              onEnter: (_) => setState(() => _railHovered = true),
              onExit: (_) => setState(() => _railHovered = false),
              child: Material(
                elevation: 8,
                color: colorScheme.surfaceContainerLow,
                child: RepaintBoundary(
                  child: _buildAntigravitySidebar(context, isMobileDrawer: false),
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// Trạng thái thay đổi của file trong session đang chọn để tô màu explorer.
  /// Nếu một file vừa được tạo vừa được sửa thì ưu tiên "mới".
  Map<String, ExplorerChangeStatus> _explorerFileStatuses(ConversationSession? session) {
    final out = <String, ExplorerChangeStatus>{};
    for (final record in session?.filesTouched ?? const <FileTouchRecord>[]) {
      if (record.action == 'created') {
        out[record.path] = ExplorerChangeStatus.created;
      } else if (record.action == 'modified' &&
          out[record.path] != ExplorerChangeStatus.created) {
        out[record.path] = ExplorerChangeStatus.modified;
      }
    }
    return out;
  }

  /// Chọn một conversation từ rail (giống thao tác trong sidebar)
  void _selectConversation(ConversationSession session) {
    _closePanelPages();
    final matchedProj = _projects.firstWhere(
      (p) => p.name == session.projectName,
      orElse: () => ProjectWorkspace(
        id: session.projectName,
        name: session.projectName,
        path: session.projectPath,
        sessionCount: 1,
        runningCount: 0,
      ),
    );
    setState(() {
      _isNewConversationMode = false;
      _selectedSessionId = session.id;
      _activeChatProject = matchedProj;
      _syncDefaultSelections();
    });
    if (session.steps.isEmpty) {
      _loadFullSessionDetail(session.id);
    }
  }

  /// Khung chính: header, banner câu hỏi, rồi nội dung (chat hoặc split viewer | chat)
  Widget _buildMainColumn(
    BuildContext context,
    ConversationSession? activeSession, {
    required bool isMobile,
    required Widget content,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return RepaintBoundary(
      child: Column(
        children: [
          _buildMinimalTopHeader(
            context,
            activeSession,
            isMobile: isMobile,
          ),
          Divider(height: 1, color: colorScheme.outlineVariant),
          if (_pendingAIQuestions.isNotEmpty) _buildAIQuestionBanner(context),
          Expanded(child: content),
        ],
      ),
    );
  }

  /// Nội dung chat: trạng thái tải / mất kết nối, hoặc ChatCanvasView
  Widget _buildChatArea(BuildContext context, ConversationSession? activeSession) {
    if (_isLoading && activeSession == null && !_isNewConversationMode) {
      return const Center(child: CircularProgressIndicator());
    }
    if (!_isRemoteConnected && !_isSocketLive && activeSession == null) {
      return _buildDisconnectedView(context);
    }
    return ChatCanvasView(
                session: activeSession,
                projects: _projects,
                selectedProject: _activeChatProject,
                availableAgents: _availableAgents,
                availableModels: _availableModels,
                modelLabels: _modelLabels,
                effortLevels: _effortLevels,
                modelContextLimits: _modelContextLimits,
                modelQuotas: _modelQuotas,
                selectedAgent: _selectedAgent,
                selectedModel: _selectedModel,
                isNewConversationMode: _isNewConversationMode,
                isSending: _isSendingPrompt,
                activeStream: _currentSessionStream,
                lastDownloadedFilePath: _lastDownloadedFilePath,
                pendingClaudeInteraction: _pendingClaudeInteraction,
                onRespondClaudeInteraction: _respondClaudeInteraction,
                onSelectProject: (p) {
                  setState(() => _activeChatProject = p);
                },
                onSelectAgent: (a) {
                  setState(() => _selectedAgent = a);
                },
                onSelectModel: (m) {
                  setState(() {
                    _selectedModel = m;
                    _modelBySession[_modelMemoryKey] = m;
                  });
                },
                onStartNewConversation: () =>
                    _startNewConversationInProject(
                  _activeChatProject,
                ),
                onSendMessage: _handleSendPrompt,
                onStopTurn: _handleStopTurn,
                pendingRetry: _pendingRetryFor(_selectedSessionId),
                onCancelRetry: _selectedSessionId == null
                    ? null
                    : () => _cancelRetry(_selectedSessionId!),
                onOpenFileBrowser: () =>
                    _openServerFileBrowser(initialTab: 0),
                onOpenChangesTab: () =>
                    _openServerFileBrowser(initialTab: 1),
                onInspectFileChange: _inspectFileChange,
                onDownloadFile: _downloadFileDirectly,
                onOpenDownloadedFile: (path) =>
                    _serverFilesRepo.openDownloadedFile(path),
                onApprovePlan: _handleApprovePlan,
                onRejectPlan: _handleRejectPlan,
                onCancelPlan: _handleCancelPlan,
                onLoadOlderHistory: _handleLoadOlderHistory,
                onFetchClaudeExtensions: _handleFetchClaudeExtensions,
                onOpenParallelFlow: _openParallelAgentFlowScreen,
                onOpenCreateProject: () =>
                    _showCreateProjectDialog(context),
                onGitPush: _handleGitPush,
                onOpenGitHistory: _openActiveGitHistory,
    );
  }

  /// Thanh Header tối giản chuẩn Antigravity
  Widget _buildMinimalTopHeader(
    BuildContext context,
    ConversationSession? activeSession, {
    required bool isMobile,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final title = _isNewConversationMode
        ? 'New Conversation'
        : (activeSession?.title ?? 'Antigravity');
    final projectName = _activeChatProject?.name ??
        activeSession?.projectName ??
        'muop-erp-server';

    return Container(
      height: isMobile ? 46 : 50,
      padding: EdgeInsets.symmetric(horizontal: isMobile ? 6 : 12),
      color: colorScheme.surface,
      child: Row(
        children: [
          IconButton(
            tooltip: isMobile ? 'Mở danh sách Project' : 'Ẩn/Hiện Sidebar',
            visualDensity: VisualDensity.compact,
            icon: Icon(
              isMobile ? Icons.menu_rounded : Icons.view_sidebar_outlined,
              size: 20,
            ),
            onPressed: () {
              if (isMobile) {
                _scaffoldKey.currentState?.openDrawer();
              } else {
                setState(() => _showDesktopSidebar = !_showDesktopSidebar);
              }
            },
          ),
          if (!isMobile) ...[
            IconButton(
              tooltip: 'Ẩn/Hiện explorer thư mục',
              visualDensity: VisualDensity.compact,
              icon: Icon(
                (_explorerOverride ?? MediaQuery.sizeOf(context).width >= 1200)
                    ? Icons.account_tree_rounded
                    : Icons.account_tree_outlined,
                size: 20,
              ),
              onPressed: () => setState(() {
                _explorerOverride = !(_explorerOverride ?? MediaQuery.sizeOf(context).width >= 1200);
              }),
            ),
            const SizedBox(width: 4),
          ],
          const SizedBox(width: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(5),
            child: Image.asset(
              'assets/images/logo.png',
              width: 22,
              height: 22,
              fit: BoxFit.contain,
            ),
          ),
          if (!isMobile) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.folder_outlined,
                    size: 13,
                    color: colorScheme.primary,
                  ),
                  const SizedBox(width: 5),
                  Text(
                    projectName,
                    style: textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: colorScheme.onSurface,
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.titleSmall?.copyWith(
                    fontSize: isMobile ? 13 : 14,
                    fontWeight: FontWeight.w700,
                    color: colorScheme.onSurface,
                  ),
                ),
                if (isMobile)
                  Text(
                    projectName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.labelSmall?.copyWith(
                      fontSize: 10,
                      color: colorScheme.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 6),

          // Trạng thái kết nối Socket.IO với Rust Server
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: _showServerConfigDialog,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
              decoration: BoxDecoration(
                color: (_isSocketLive ? context.status.success : context.status.warning)
                    .withAlpha(25),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: (_isSocketLive ? context.status.success : context.status.warning)
                      .withAlpha(90),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 6.5,
                    height: 6.5,
                    decoration: BoxDecoration(
                      color: _isSocketLive || _isRemoteConnected
                          ? context.status.success
                          : context.status.warning,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    isMobile
                        ? (_isSocketLive ? 'Live' : 'IP')
                        : (_isSocketLive
                            ? 'Socket.IO • $_serverAddress'
                            : _serverAddress),
                    style: textTheme.labelSmall?.copyWith(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      color: _isSocketLive || _isRemoteConnected
                          ? context.status.success
                          : context.status.warning,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 2),
          IconButton(
            tooltip: 'Duyệt SFTP & Tải File từ Rust Server',
            visualDensity: VisualDensity.compact,
            onPressed: () => _openServerFileBrowser(initialTab: 0),
            icon: const Icon(Icons.folder_special_outlined, size: 19),
          ),
          IconButton(
            tooltip: "Xem Git Tree & Lịch sử Commit",
            visualDensity: VisualDensity.compact,
            onPressed: _openActiveGitHistory,
            icon: const Icon(Icons.account_tree_outlined, size: 19),
          ),
          IconButton(
            tooltip: 'New Conversation',
            visualDensity: VisualDensity.compact,
            onPressed: () => _startNewConversationInProject(_activeChatProject),
            icon: const Icon(Icons.add_rounded, size: 20),
          ),
          IconButton(
            tooltip: 'Chọn màu chủ đạo',
            visualDensity: VisualDensity.compact,
            onPressed: () => _showThemeColorPicker(context),
            icon: Icon(
              Icons.palette_outlined,
              size: 18,
              color: context.scheme.primary,
            ),
          ),
          IconButton(
            tooltip: 'Đổi giao diện Sáng/Tối',
            visualDensity: VisualDensity.compact,
            onPressed: widget.onToggleTheme,
            icon: Icon(
              widget.isDarkMode
                  ? Icons.light_mode_outlined
                  : Icons.dark_mode_outlined,
              size: 18,
            ),
          ),
        ],
      ),
    );
  }

  /// Bottom sheet chọn màu chủ đạo (seed) — toàn bộ bảng màu M3 được sinh lại từ màu này
  void _showThemeColorPicker(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        final scheme = Theme.of(sheetContext).colorScheme;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Màu chủ đạo',
                  style: Theme.of(sheetContext).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Bảng màu giao diện được sinh tự động từ màu đã chọn.',
                  style: Theme.of(sheetContext).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 14,
                  runSpacing: 14,
                  children: [
                    for (final preset in kThemeSeedPresets)
                      Tooltip(
                        message: preset.name,
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: () {
                            widget.onSeedColorChanged(preset.color);
                            Navigator.of(sheetContext).pop();
                          },
                          child: Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: preset.color,
                              border: Border.all(
                                color: preset.color.toARGB32() ==
                                        widget.seedColor.toARGB32()
                                    ? scheme.onSurface
                                    : Colors.transparent,
                                width: 2.5,
                              ),
                            ),
                            child: preset.color.toARGB32() ==
                                    widget.seedColor.toARGB32()
                                ? Icon(
                                    Icons.check_rounded,
                                    color: ThemeData.estimateBrightnessForColor(
                                              preset.color,
                                            ) ==
                                            Brightness.dark
                                        ? Colors.white
                                        : Colors.black,
                                  )
                                : null,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Sidebar trái chuẩn Antigravity: phân nhóm theo Project Workspace
  Widget _buildAntigravitySidebar(
    BuildContext context, {
    required bool isMobileDrawer,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final filtered = _filteredSessions;

    final groupedByProject = <String, List<ConversationSession>>{};
    for (final s in filtered) {
      groupedByProject.putIfAbsent(s.projectName, () => []).add(s);
    }

    if (_searchQuery.isEmpty) {
      for (final p in _projects) {
        groupedByProject.putIfAbsent(p.name, () => []);
      }
    }

    final projectNames = groupedByProject.keys.toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 1. Header Sidebar: Antigravity + New Chat
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 10, 8),
          child: Row(
            children: [
              Icon(
                Icons.auto_awesome_rounded,
                size: 18,
                color: colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Antigravity',
                  style: textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.2,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Tạo Project Mới',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.create_new_folder_outlined, size: 18),
                onPressed: () {
                  _showCreateProjectDialog(context);
                },
              ),
              IconButton(
                tooltip: 'New Conversation',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.edit_square, size: 17),
                onPressed: () {
                  _startNewConversationInProject(_activeChatProject);
                  if (isMobileDrawer && Navigator.of(context).canPop()) {
                    Navigator.of(context).pop();
                  }
                },
              ),
            ],
          ),
        ),

        // Menu SSH và Docker: mở màn quản lý máy SSH đã lưu / phiên Docker trên các máy đó
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
          child: Wrap(
            spacing: 4,
            children: [
              TextButton.icon(
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                ),
                onPressed: () {
                  if (Navigator.of(context).canPop() && isMobileDrawer) {
                    Navigator.of(context).pop();
                  }
                  _openFromSidebar(context, SshHostsScreen(serverAddress: _serverAddress));
                },
                icon: Icon(Icons.terminal_rounded,
                    size: 16, color: colorScheme.primary),
                label: Text(
                  'SSH',
                  style: textTheme.labelMedium?.copyWith(
                    color: colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              TextButton.icon(
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                ),
                onPressed: () {
                  if (Navigator.of(context).canPop() && isMobileDrawer) {
                    Navigator.of(context).pop();
                  }
                  _openFromSidebar(context, DockerHostsScreen(serverAddress: _serverAddress));
                },
                icon: Icon(Icons.view_in_ar_rounded,
                    size: 16, color: colorScheme.primary),
                label: Text(
                  'Docker',
                  style: textTheme.labelMedium?.copyWith(
                    color: colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              TextButton.icon(
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                ),
                onPressed: () {
                  if (Navigator.of(context).canPop() && isMobileDrawer) {
                    Navigator.of(context).pop();
                  }
                  _openFromSidebar(
                    context,
                    LspSettingsScreen(serverAddress: _serverAddress),
                  );
                },
                icon: Icon(Icons.settings_suggest_rounded,
                    size: 16, color: colorScheme.primary),
                label: Text(
                  'LSP',
                  style: textTheme.labelMedium?.copyWith(
                    color: colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),

        // 2. Ô tìm kiếm gọn
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: TextField(
            controller: _searchController,
            onChanged: (v) => setState(() => _searchQuery = v.trim()),
            style: textTheme.bodySmall,
            decoration: InputDecoration(
              hintText: 'Search conversations...',
              prefixIcon: const Icon(Icons.search_rounded, size: 16),
              isDense: true,
              filled: true,
              fillColor: colorScheme.surfaceContainerHighest.withAlpha(160),
              contentPadding: const EdgeInsets.symmetric(vertical: 8),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),

        // Tiêu đề phân mục Workspaces & Nút Tạo Project nhanh
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 2, 10, 4),
          child: Row(
            children: [
              Text(
                'WORKSPACES',
                style: textTheme.labelSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  fontSize: 10,
                  letterSpacing: 0.8,
                  color: colorScheme.onSurfaceVariant.withAlpha(160),
                ),
              ),
              const Spacer(),
              InkWell(
                borderRadius: BorderRadius.circular(4),
                onTap: () => _showCreateProjectDialog(context),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.add_rounded, size: 13, color: colorScheme.primary),
                      const SizedBox(width: 2),
                      Text(
                        'Tạo Project',
                        style: textTheme.labelSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          fontSize: 10.5,
                          color: colorScheme.primary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),

        // 3. Danh sách Workspaces / Projects và các cuộc hội thoại
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            itemCount: projectNames.length,
            itemBuilder: (context, index) {
              final projName = projectNames[index];
              final projSessions = groupedByProject[projName] ?? const [];
              final projWorkspace = _projects.firstWhere(
                (p) => p.name == projName,
                orElse: () => ProjectWorkspace(
                  id: projName,
                  name: projName,
                  path: '/home/john/Documents/muop-ecosystem/$projName',
                  sessionCount: projSessions.length,
                  runningCount: 0,
                ),
              );

              return _buildWorkspaceFolder(
                context,
                projWorkspace,
                projSessions,
                closeDrawerOnTap: isMobileDrawer,
              );
            },
          ),
        ),

        // 4. Footer trạng thái Rust Server & Tải File
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(color: colorScheme.outlineVariant),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: _showServerConfigDialog,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Icon(
                          Icons.dns_outlined,
                          size: 15,
                          color: colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _remoteHostName.isNotEmpty
                                ? '$_remoteHostName ($_serverAddress)'
                                : 'Rust Server: $_serverAddress',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: textTheme.labelSmall?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Tải File từ Server',
                visualDensity: VisualDensity.compact,
                onPressed: _openServerFileBrowser,
                icon: Icon(
                  Icons.cloud_download_outlined,
                  size: 17,
                  color: colorScheme.primary,
                ),
              ),
              IconButton(
                tooltip: 'Cấu hình IP Server',
                visualDensity: VisualDensity.compact,
                onPressed: _showServerConfigDialog,
                icon: Icon(
                  Icons.settings_outlined,
                  size: 16,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildWorkspaceFolder(
    BuildContext context,
    ProjectWorkspace project,
    List<ConversationSession> projectSessions, {
    required bool closeDrawerOnTap,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final hasSelected =
        projectSessions.any((s) => s.id == _selectedSessionId) ||
            (_activeChatProject?.name == project.name);

    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        initiallyExpanded: projectSessions.isNotEmpty || hasSelected,
        tilePadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
        childrenPadding: const EdgeInsets.only(left: 10, right: 4, bottom: 4),
        visualDensity: VisualDensity.compact,
        leading: Icon(
          Icons.folder_outlined,
          size: 16,
          color: hasSelected
              ? colorScheme.primary
              : colorScheme.onSurfaceVariant,
        ),
        title: Row(
          children: [
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      project.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.labelMedium?.copyWith(
                        fontWeight:
                            hasSelected ? FontWeight.w800 : FontWeight.w600,
                        color: colorScheme.onSurface,
                      ),
                    ),
                  ),
                  if (projectSessions.isNotEmpty) ...[
                    Container(
                      margin: const EdgeInsets.only(left: 6),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5.5,
                        vertical: 1.5,
                      ),
                      decoration: BoxDecoration(
                        color: hasSelected
                            ? colorScheme.primary.withAlpha(30)
                            : colorScheme.surfaceContainerHighest.withAlpha(120),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '${projectSessions.length}',
                        style: textTheme.labelSmall?.copyWith(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: hasSelected
                              ? colorScheme.primary
                              : colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (project.gitSyncStatus?.isAhead == true &&
                project.gitSyncStatus!.aheadCount > 0) ...[
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 4),
                padding: const EdgeInsets.symmetric(
                  horizontal: 5,
                  vertical: 1.5,
                ),
                decoration: BoxDecoration(
                  color: context.status.warning.withAlpha(35),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                    color: context.status.warning.withAlpha(120),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.cloud_upload_outlined,
                      size: 10,
                      color: context.status.warning,
                    ),
                    const SizedBox(width: 2),
                    Text(
                      '${project.gitSyncStatus!.aheadCount}',
                      style: TextStyle(
                        fontSize: 9.5,
                        fontWeight: FontWeight.bold,
                        color: context.status.warning,
                      ),
                    ),
                  ],
                ),
              ),
            ],
            InkWell(
              borderRadius: BorderRadius.circular(4),
              onTap: () {
                _openGitHistorySheet(project);
                if (closeDrawerOnTap && Navigator.of(context).canPop()) {
                  Navigator.of(context).pop();
                }
              },
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Tooltip(
                  message: "Xem Git Tree & Commit History",
                  child: Icon(
                    Icons.account_tree_outlined,
                    size: 15,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 2),
            InkWell(
              borderRadius: BorderRadius.circular(4),
              onTap: () {
                _startNewConversationInProject(project);
                if (closeDrawerOnTap && Navigator.of(context).canPop()) {
                  Navigator.of(context).pop();
                }
              },
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(
                  Icons.add_rounded,
                  size: 15,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
        children: [
          if (projectSessions.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'No conversations',
                  style: textTheme.labelSmall?.copyWith(
                    color: colorScheme.onSurfaceVariant.withAlpha(150),
                  ),
                ),
              ),
            )
          else ...[
            () {
              final int totalSessions = projectSessions.length;
              final bool hasOverflow = totalSessions > 5;
              final bool isExpanded =
                  _expandedProjects.contains(project.name) ||
                      _searchQuery.isNotEmpty;
              final visibleSessions = (isExpanded || !hasOverflow)
                  ? projectSessions
                  : projectSessions.take(5).toList();
              final int remainingCount = totalSessions - 5;

              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final session in visibleSessions)
                    _buildSidebarConversationItem(
                      context,
                      session,
                      !_isNewConversationMode &&
                          session.id == _selectedSessionId,
                      closeDrawerOnTap: closeDrawerOnTap,
                    ),
                  if (hasOverflow && _searchQuery.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(
                        top: 2,
                        bottom: 4,
                        left: 4,
                        right: 4,
                      ),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(6),
                        onTap: () {
                          setState(() {
                            if (isExpanded) {
                              _expandedProjects.remove(project.name);
                            } else {
                              _expandedProjects.add(project.name);
                            }
                          });
                        },
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: colorScheme.surfaceContainerHighest
                                .withAlpha(90),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: colorScheme.outlineVariant.withAlpha(60),
                              width: 0.8,
                            ),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                isExpanded
                                    ? Icons.keyboard_arrow_up_rounded
                                    : Icons.keyboard_arrow_down_rounded,
                                size: 14,
                                color: colorScheme.primary,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                isExpanded
                                    ? 'Thu gọn danh sách'
                                    : 'Xem thêm ($remainingCount cuộc hội thoại khác)',
                                style: textTheme.labelSmall?.copyWith(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: colorScheme.primary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              );
            }(),
          ],
        ],
      ),
    );
  }

  Widget _buildSidebarConversationItem(
    BuildContext context,
    ConversationSession session,
    bool isSelected, {
    required bool closeDrawerOnTap,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final isRunning = !session.isInterrupted &&
        (session.status == AgentStatus.running ||
            _activeStreams[session.id]?.isRunning == true);

    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () {
          _closePanelPages();
          final matchedProj = _projects.firstWhere(
            (p) => p.name == session.projectName,
            orElse: () => ProjectWorkspace(
              id: session.projectName,
              name: session.projectName,
              path: session.projectPath,
              sessionCount: 1,
              runningCount: 0,
            ),
          );
          setState(() {
            _isNewConversationMode = false;
            _selectedSessionId = session.id;
            _activeChatProject = matchedProj;
            _syncDefaultSelections();
          });
          if (session.steps.isEmpty) {
            _loadFullSessionDetail(session.id);
          }
          if (closeDrawerOnTap && Navigator.of(context).canPop()) {
            Navigator.of(context).pop();
          }
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: isSelected
                ? colorScheme.primaryContainer.withAlpha(140)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              if (isRunning) ...[
                const SizedBox(
                  width: 10,
                  height: 10,
                  child: CircularProgressIndicator(strokeWidth: 1.8),
                ),
                const SizedBox(width: 8),
              ] else if (session.isInterrupted) ...[
                Icon(
                  Icons.pause_circle_outline_rounded,
                  size: 13,
                  color: context.status.warning,
                ),
                const SizedBox(width: 8),
              ] else ...[
                Icon(
                  Icons.chat_bubble_outline_rounded,
                  size: 13,
                  color: session.source == 'claude-cli'
                      ? (isSelected
                          ? context.status.warning
                          : context.status.warning.withAlpha(170))
                      : (isSelected
                          ? context.scheme.primary
                          : context.scheme.primary.withAlpha(170)),
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(
                  session.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.bodySmall?.copyWith(
                    fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                    color: isSelected
                        ? colorScheme.onSurface
                        : colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDisconnectedView(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.cloud_off_rounded,
                size: 40,
                color: colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 12),
              Text(
                'Chưa kết nối tới Rust Server ($_serverAddress)',
                textAlign: TextAlign.center,
                style: textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  FilledButton.tonalIcon(
                    onPressed: _showServerConfigDialog,
                    icon: const Icon(Icons.settings_ethernet_rounded, size: 16),
                    label: const Text('Đổi IP Server'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: () {
                      _connectionRepo.connectSocket(_serverAddress);
                      _refreshSessions(silent: false);
                    },
                    icon: const Icon(Icons.refresh_rounded, size: 16),
                    label: const Text('Thử lại'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Một trang đẩy lên vùng chính. [done] hoàn thành khi trang đóng.
class _PanelEntry {
  _PanelEntry(this.key, this.page);

  final ValueKey<String> key;
  final Widget page;
  final Completer<void> done = Completer<void>();
}
