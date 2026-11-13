import 'dart:async';
import 'package:flutter/material.dart';
import '../models/agent_models.dart';
import '../services/brain_scanner_service.dart';
import 'widgets/server_file_browser_sheet.dart';
import 'theme/app_theme.dart';

/// Màn hình Trực quan hóa Luồng Thực thi Song song (Parallel Agent Flow Screen)
/// Phản ánh kiến trúc Dual-Repo song song: Coordinator ➔ erp-server-agent & erp-app-agent ➔ erp-contract-verifier
/// Tích hợp đồng bộ Realtime (Socket.IO + Snapshot Stream), Animation luồng thực thi và Modal xem chi tiết tác vụ từng Agent.
class ParallelAgentFlowScreen extends StatefulWidget {
  const ParallelAgentFlowScreen({
    super.key,
    required this.session,
    this.activeStream,
    required this.serverAddress,
    this.onStopTurn,
    this.onInspectFile,
  });

  final ConversationSession? session;
  final ChatTurnStreamState? activeStream;
  final String serverAddress;
  final VoidCallback? onStopTurn;
  final void Function(String path, GroupedFileChange? fileChange)? onInspectFile;

  @override
  State<ParallelAgentFlowScreen> createState() =>
      _ParallelAgentFlowScreenState();
}

class _ParallelAgentFlowScreenState extends State<ParallelAgentFlowScreen>
    with TickerProviderStateMixin {
  late TabController _tabController;
  late AnimationController _pulseController;
  late AnimationController _flowController;

  final BrainScannerService _scanner = BrainScannerService();
  StreamSubscription<AgentMonitorSnapshot>? _snapshotSub;
  StreamSubscription<ChatTurnStreamState>? _chatStreamSub;
  StreamSubscription<ConversationSession>? _sessionUpdateSub;

  ConversationSession? _session;
  ChatTurnStreamState? _activeStream;
  List<SubagentLane> _lanes = [];
  String _dialogueFilter = 'all';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);

    _flowController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    )..repeat();

    _session = widget.session;
    _activeStream = widget.activeStream;
    _lanes = widget.session?.subagentLanes ?? const [];

    _bindRealtimeSubscriptions();
  }

  void _bindRealtimeSubscriptions() {
    _snapshotSub = _scanner.snapshotStream.listen((snapshot) {
      if (!mounted) return;
      final currentId = _session?.id ?? widget.session?.id;
      if (currentId == null || currentId.isEmpty) return;

      final updated = snapshot.sessions.cast<ConversationSession?>().firstWhere(
            (s) => s?.id == currentId,
            orElse: () => null,
          );

      if (updated != null) {
        setState(() {
          _session = updated;
          if (updated.subagentLanes.isNotEmpty) {
            _lanes = updated.subagentLanes;
          }
          if (snapshot.activeStreams.containsKey(currentId)) {
            _activeStream = snapshot.activeStreams[currentId];
          }
        });
      }
    });

    _chatStreamSub = _scanner.chatStream.listen((streamState) {
      if (!mounted) return;
      final currentId = _session?.id ?? widget.session?.id;
      if (streamState.conversationId == currentId) {
        setState(() {
          _activeStream = streamState;
          if (streamState.isRunning && _session != null) {
            if (_session!.status != AgentStatus.running) {
              _session = _session!.copyWith(status: AgentStatus.running);
            }
          }
        });
      }
    });

    _sessionUpdateSub = _scanner.sessionUpdateStream.listen((updated) {
      if (!mounted) return;
      final currentId = _session?.id ?? widget.session?.id;
      if (currentId == updated.id) {
        setState(() {
          _session = updated;
          if (updated.subagentLanes.isNotEmpty) {
            _lanes = updated.subagentLanes;
          }
        });
      }
    });
  }

  @override
  void dispose() {
    _snapshotSub?.cancel();
    _chatStreamSub?.cancel();
    _sessionUpdateSub?.cancel();
    _pulseController.dispose();
    _flowController.dispose();
    _tabController.dispose();
    super.dispose();
  }

  bool get _isTurnRunning {
    if (_session?.isInterrupted == true) return false;
    return (_activeStream != null && _activeStream!.isRunning) ||
        (_session != null && _session!.status == AgentStatus.running);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final isMobile = MediaQuery.sizeOf(context).width < 760;

    final session = _session ?? widget.session;
    final isRunning = _isTurnRunning;
    final lanes = _lanes.isNotEmpty ? _lanes : (session?.subagentLanes ?? const <SubagentLane>[]);

    return Scaffold(
      backgroundColor: colorScheme.surface,
      appBar: AppBar(
        backgroundColor: colorScheme.surfaceContainer,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          tooltip: 'Trở lại khung chat',
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.alt_route_rounded,
                  size: 18,
                  color: context.scheme.tertiary,
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    isMobile
                        ? 'Parallel Flow'
                        : 'Luồng Chạy Song Song (Parallel Agents)',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.2,
                    ),
                  ),
                ),
              ],
            ),
            Text(
              '${session?.projectName ?? "muop-ecosystem"} • Live Sync',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: textTheme.labelSmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        actions: [
          // Nút Làm mới Realtime
          IconButton(
            icon: const Icon(Icons.refresh_rounded, size: 20),
            tooltip: 'Làm mới trạng thái Realtime',
            onPressed: () {
              _scanner.requestRealtimeSnapshot();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Đang cập nhật trạng thái mới nhất từ Rust Server...'),
                  duration: Duration(seconds: 1),
                ),
              );
            },
          ),

          // Live status badge có Animation thở (Pulsing indicator)
          AnimatedBuilder(
            animation: _pulseController,
            builder: (context, _) {
              final pulse = _pulseController.value;
              return Container(
                margin: const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: isRunning
                      ? context.status.warning.withAlpha((30 + pulse * 25).toInt())
                      : context.status.success.withAlpha(35),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: isRunning
                        ? context.status.warning.withAlpha((120 + pulse * 135).toInt())
                        : context.status.success.withAlpha(140),
                    width: isRunning ? 1.5 : 1.0,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: isRunning ? context.status.warning : context.status.success,
                        shape: BoxShape.circle,
                        boxShadow: isRunning
                            ? [
                                BoxShadow(
                                  color: context.status.warning.withAlpha((150 * pulse).toInt()),
                                  blurRadius: 5 * pulse,
                                  spreadRadius: 1 * pulse,
                                ),
                              ]
                            : null,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      isRunning ? 'PARALLEL RUNNING' : 'STANDBY',
                      style: textTheme.labelSmall?.copyWith(
                        fontSize: 10,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.5,
                        color: isRunning ? context.status.warning : context.status.success,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),

          if (isRunning && widget.onStopTurn != null)
            IconButton(
              icon: Icon(Icons.stop_circle_outlined, color: context.scheme.error),
              tooltip: 'Dừng tác vụ',
              onPressed: widget.onStopTurn,
            ),
        ],
        bottom: TabBar(
          controller: _tabController,
          labelColor: colorScheme.primary,
          unselectedLabelColor: colorScheme.onSurfaceVariant,
          indicatorColor: colorScheme.primary,
          tabs: const [
            Tab(
              icon: Icon(Icons.account_tree_outlined, size: 18),
              text: 'Biểu đồ Luồng',
            ),
            Tab(
              icon: Icon(Icons.view_column_rounded, size: 18),
              text: 'Lanes Chi Tiết',
            ),
            Tab(
              icon: Icon(Icons.forum_outlined, size: 18),
              text: 'Hội Thoại Agent',
            ),
            Tab(
              icon: Icon(Icons.fact_check_outlined, size: 18),
              text: 'Đối Soát Hợp Đồng',
            ),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          // Tab 1: Biểu đồ trực quan Pipeline quy trình (4 giai đoạn có Animation)
          _buildVisualPipelineTab(context, isMobile, isRunning, lanes),

          // Tab 2: Swimlanes chi tiết từng Subagent (Clickable xem chi tiết)
          _buildSwimlanesTab(context, isMobile, isRunning, lanes),

          // Tab 3: Hội thoại & Trao đổi giữa các Agent (Coordinator ↔ Subagents)
          _buildInterAgentDialogueTab(context, isMobile, isRunning, lanes),

          // Tab 4: Bảng đối soát hợp đồng (Contract Verifier)
          _buildContractVerifierTab(context, isMobile, isRunning),
        ],
      ),
    );
  }

  /// [TAB 1] BIỂU ĐỒ TRỰC QUAN PIPELINE QUY TRÌNH (4 GIAI ĐOẠN CÓ ANIMATION)
  Widget _buildVisualPipelineTab(
    BuildContext context,
    bool isMobile,
    bool isRunning,
    List<SubagentLane> lanes,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final session = _session ?? widget.session;

    // Xác định giai đoạn hiện tại của hệ thống
    final currentPhase = session?.currentPhase ?? AgentWorkflowPhase.contractDiscovery;
    final hasPendingPlans = session?.pendingPlans.isNotEmpty == true;

    final isPhase1Active = isRunning && currentPhase == AgentWorkflowPhase.contractDiscovery;
    final isPhase2Active = hasPendingPlans;
    final isPhase3Active = isRunning &&
        (currentPhase == AgentWorkflowPhase.parallelExecution ||
            lanes.any((l) => l.status == AgentStatus.running));
    final isPhase4Active = isRunning && currentPhase == AgentWorkflowPhase.crossVerification;

    // Lấy thông tin các agent
    final coordinatorLane = lanes.cast<SubagentLane?>().firstWhere(
          (l) => l?.name == 'Coordinator',
          orElse: () => null,
        );
    // Một conversation có thể có nhiều lần spawn cùng tên agent: lấy lần chạy mới nhất (cuối danh sách)
    final serverLane = lanes.cast<SubagentLane?>().lastWhere(
          (l) => l?.name == 'erp-server-agent',
          orElse: () => null,
        );
    final appLane = lanes.cast<SubagentLane?>().lastWhere(
          (l) => l?.name == 'erp-app-agent',
          orElse: () => null,
        );
    final verifierLane = lanes.cast<SubagentLane?>().lastWhere(
          (l) => l?.name == 'erp-contract-verifier',
          orElse: () => null,
        );

    // Bổ sung các custom subagent khác (nếu có)
    final extraSubagents = lanes.where((l) {
      return l.name != 'Coordinator' &&
          l.name != 'erp-server-agent' &&
          l.name != 'erp-app-agent' &&
          l.name != 'erp-contract-verifier';
    }).toList();

    return SingleChildScrollView(
      padding: EdgeInsets.all(isMobile ? 12 : 24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Thông tin tóm tắt quy tắc
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: context.scheme.tertiary.withAlpha(25),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: context.scheme.tertiary.withAlpha(90)),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.info_outline_rounded,
                      color: context.scheme.tertiary,
                      size: 20,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Quy chuẩn Đồng bộ Song song (parallel-erp-sync)',
                            style: textTheme.labelLarge?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: context.scheme.tertiary,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Lên kế hoạch với Shared Contract ➔ Phê duyệt kế hoạch ➔ Chạy song song erp-server-agent & erp-app-agent ➔ Đối soát hợp đồng kép.',
                            style: textTheme.bodySmall?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),

              // Giai đoạn 1: Planning (Lập kế hoạch & Thiết kế hợp đồng)
              _buildPipelineNodeCard(
                context,
                stepNumber: 1,
                title: 'Lập Kế Hoạch & Thiết Kế Hợp Đồng (Shared Contract)',
                subtitle:
                    'Phân tích Canonical API, JSON DTO, RBAC & Socket.IO. Coordinator thống nhất hợp đồng trước khi phân chia.',
                icon: Icons.architecture_rounded,
                nodeColor: context.scheme.secondary,
                status: isPhase1Active
                    ? 'IN PROGRESS'
                    : (session != null && session.steps.isNotEmpty
                        ? 'READY'
                        : 'STANDBY'),
                isActive: isPhase1Active,
                isCompleted: !isPhase1Active && (session?.steps.isNotEmpty ?? false),
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.description_outlined,
                          size: 16, color: context.scheme.secondary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Kế hoạch lưu tại docs/plans/*.md • Đảm bảo 100% Shared Contract trước khi chạy song song.',
                          style: textTheme.bodySmall?.copyWith(
                            fontFamily: 'monospace',
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              _buildFlowArrow(context, isActive: isPhase2Active || isPhase3Active),

              // Giai đoạn 2: User Approval Gate (Phê duyệt kế hoạch)
              _buildPipelineNodeCard(
                context,
                stepNumber: 2,
                title: 'Phê Duyệt Kế Hoạch (User Approval Gate)',
                subtitle:
                    'Agent xuất trình kế hoạch và chờ phê duyệt. Không tự ý sửa mã nguồn khi chưa được xác nhận.',
                icon: Icons.how_to_reg_rounded,
                nodeColor: context.status.warning,
                status: isPhase2Active
                    ? 'AWAITING APPROVAL'
                    : (hasPendingPlans ? 'PENDING' : 'APPROVED / PASSED'),
                isActive: isPhase2Active,
                isCompleted: !hasPendingPlans && (session?.steps.length ?? 0) > 2,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: context.status.warning.withAlpha(25),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: context.status.warning.withAlpha(110)),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        isPhase2Active
                            ? Icons.hourglass_top_rounded
                            : Icons.check_circle_outline_rounded,
                        size: 16,
                        color: context.status.warning,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          isPhase2Active
                              ? '⚠️ Đang có kế hoạch chờ duyệt! Hãy bấm nút Duyệt trên màn hình Chat để bắt đầu chạy song song.'
                              : 'Kế hoạch đã được phê duyệt. Hệ thống đang/đã kích hoạt các nhánh thực thi.',
                          style: textTheme.bodySmall?.copyWith(
                            fontWeight: FontWeight.w600,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              _buildFlowArrow(context, isActive: isPhase3Active),

              // Giai đoạn 3: Parallel Execution (Khối Thực thi song song có Coordinator điều phối)
              AnimatedBuilder(
                animation: _pulseController,
                builder: (context, _) {
                  final pulse = _pulseController.value;
                  return Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: isPhase3Active
                            ? context.scheme.tertiary.withAlpha((140 + pulse * 115).toInt())
                            : colorScheme.outlineVariant,
                        width: isPhase3Active ? 2.0 : 1.2,
                      ),
                      boxShadow: isPhase3Active
                          ? [
                              BoxShadow(
                                color: context.scheme.tertiary.withAlpha((40 * pulse).toInt()),
                                blurRadius: 10 * pulse,
                                spreadRadius: 1,
                              ),
                            ]
                          : null,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Header Giai đoạn 3
                        Row(
                          children: [
                            Container(
                              width: 28,
                              height: 28,
                              decoration: BoxDecoration(
                                color: isPhase3Active ? context.scheme.tertiary : context.scheme.onSurfaceVariant,
                                shape: BoxShape.circle,
                              ),
                              child: Center(
                                child: Text(
                                  '3',
                                  style: TextStyle(
                                    color: context.scheme.onPrimary,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Flexible(
                                        child: Text(
                                          'THỰC THI SONG SONG (PARALLEL AGENTS)',
                                          style: textTheme.titleSmall?.copyWith(
                                            fontWeight: FontWeight.w800,
                                            color: context.scheme.tertiary,
                                            letterSpacing: 0.5,
                                          ),
                                        ),
                                      ),
                                      if (isPhase3Active) ...[
                                        const SizedBox(width: 8),
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: context.status.warning.withAlpha(35),
                                            borderRadius: BorderRadius.circular(6),
                                            border: Border.all(color: context.status.warning),
                                          ),
                                          child: Text(
                                            'PARALLEL ACTIVE',
                                            style: textTheme.labelSmall?.copyWith(
                                              fontSize: 9,
                                              fontWeight: FontWeight.w900,
                                              color: context.status.warning,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                  Text(
                                    'Coordinator phân chia tác vụ và điều phối song song cho các Subagent',
                                    style: textTheme.bodySmall?.copyWith(
                                      color: colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),

                        // THẺ ĐIỀU PHỐI VIÊN CHÍNH (COORDINATOR DISPATCHER)
                        if (coordinatorLane != null) ...[
                          _buildInteractiveAgentCard(
                            context,
                            lane: coordinatorLane,
                            accentColor: context.scheme.tertiary,
                            icon: Icons.hub_rounded,
                            isMobile: isMobile,
                            subtitle: 'Orchestrator Lead • Phân chia nhiệm vụ song song',
                          ),
                          const SizedBox(height: 12),
                          // Đường liên kết mũi tên động từ Coordinator xuống các Agent nhánh
                          Center(
                            child: AnimatedBuilder(
                              animation: _flowController,
                              builder: (context, _) {
                                return Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                      Icons.south_west_rounded,
                                      size: 16,
                                      color: isPhase3Active
                                          ? context.scheme.secondary
                                          : colorScheme.outlineVariant,
                                    ),
                                    const SizedBox(width: 32),
                                    Icon(
                                      Icons.south_east_rounded,
                                      size: 16,
                                      color: isPhase3Active
                                          ? context.status.success
                                          : colorScheme.outlineVariant,
                                    ),
                                  ],
                                );
                              },
                            ),
                          ),
                          const SizedBox(height: 12),
                        ],

                        // HAI NHÁNH SONG SONG: Server & App (Clickable để xem chi tiết tác vụ & logs)
                        if (isMobile) ...[
                          if (serverLane != null)
                            _buildInteractiveAgentCard(
                              context,
                              lane: serverLane,
                              accentColor: context.scheme.secondary,
                              icon: Icons.dns_rounded,
                              isMobile: isMobile,
                              subtitle: 'Backend Go • Hexagonal Clean Arch',
                            ),
                          const SizedBox(height: 12),
                          if (appLane != null)
                            _buildInteractiveAgentCard(
                              context,
                              lane: appLane,
                              accentColor: context.status.success,
                              icon: Icons.phone_android_rounded,
                              isMobile: isMobile,
                              subtitle: 'Frontend Flutter • Material 3 & Riverpod',
                            ),
                        ] else ...[
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: serverLane != null
                                    ? _buildInteractiveAgentCard(
                                        context,
                                        lane: serverLane,
                                        accentColor: context.scheme.secondary,
                                        icon: Icons.dns_rounded,
                                        isMobile: isMobile,
                                        subtitle: 'Backend Go • Hexagonal Clean Arch',
                                      )
                                    : const SizedBox.shrink(),
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: appLane != null
                                    ? _buildInteractiveAgentCard(
                                        context,
                                        lane: appLane,
                                        accentColor: context.status.success,
                                        icon: Icons.phone_android_rounded,
                                        isMobile: isMobile,
                                        subtitle: 'Frontend Flutter • Material 3 & Riverpod',
                                      )
                                    : const SizedBox.shrink(),
                              ),
                            ],
                          ),
                        ],

                        // Các Subagent bổ sung (nếu có, vd: research, custom workers)
                        if (extraSubagents.isNotEmpty) ...[
                          const SizedBox(height: 14),
                          Text(
                            'Subagents Chuyên Biệt Khác (${extraSubagents.length}):',
                            style: textTheme.labelSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 8),
                          for (final sub in extraSubagents) ...[
                            _buildInteractiveAgentCard(
                              context,
                              lane: sub,
                              accentColor: context.scheme.tertiary,
                              icon: Icons.psychology_rounded,
                              isMobile: isMobile,
                              subtitle: sub.role,
                            ),
                            const SizedBox(height: 8),
                          ],
                        ],
                      ],
                    ),
                  );
                },
              ),

              _buildFlowArrow(context, isActive: isPhase4Active),

              // Giai đoạn 4: Contract Verifier (Đối soát hợp đồng & Nghiệm thu kép)
              _buildPipelineNodeCard(
                context,
                stepNumber: 4,
                title: 'Đối Soát & Nghiệm Thu (erp-contract-verifier)',
                subtitle:
                    'Kiểm tra chéo Canonical Endpoint, JSON payload, RBAC, Socket.IO. Xác nhận go build & flutter analyze sạch lỗi 100%.',
                icon: Icons.verified_rounded,
                nodeColor: context.status.success,
                status: isPhase4Active
                    ? 'VERIFYING...'
                    : ((verifierLane?.status == AgentStatus.completed ||
                            session?.status == AgentStatus.completed)
                        ? 'CONTRACT PASS'
                        : 'STANDBY'),
                isActive: isPhase4Active,
                isCompleted: verifierLane?.status == AgentStatus.completed ||
                    session?.status == AgentStatus.completed,
                child: verifierLane != null
                    ? InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: () => _showAgentDetailModal(context, verifierLane),
                        child: Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: context.status.success.withAlpha(25),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: context.status.success.withAlpha(100)),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.task_alt_rounded,
                                  size: 16, color: context.status.success),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  verifierLane.currentActionText.isNotEmpty
                                      ? verifierLane.currentActionText
                                      : 'Hợp đồng đồng bộ 100% • Sẵn sàng phát hành lên Production.',
                                  style: textTheme.bodySmall?.copyWith(
                                    fontWeight: FontWeight.w600,
                                    color: context.status.success,
                                    fontSize: 11,
                                  ),
                                ),
                              ),
                              Icon(Icons.chevron_right_rounded,
                                  size: 16, color: context.status.success),
                            ],
                          ),
                        ),
                      )
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// [TAB 2] SWIMLANES CHI TIẾT TỪNG SUBAGENT (CLICKABLE ĐỂ XEM CHI TIẾT TÁC VỤ & LOGS)
  Widget _buildSwimlanesTab(
    BuildContext context,
    bool isMobile,
    bool isRunning,
    List<SubagentLane> lanes,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    if (lanes.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.hub_outlined,
                size: 48, color: colorScheme.onSurfaceVariant.withAlpha(120)),
            const SizedBox(height: 12),
            Text(
              'Chưa có Subagent nào được phân bổ',
              style: textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Khi bạn khởi chạy lượt xử lý hoặc duyệt plan, các Agent song song sẽ hiển thị tại đây.',
              style: textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }

    return ListView.separated(
      padding: EdgeInsets.all(isMobile ? 12 : 20),
      itemCount: lanes.length,
      separatorBuilder: (_, _) => const SizedBox(height: 14),
      itemBuilder: (context, i) {
        final lane = lanes[i];
        final laneRunning = lane.status == AgentStatus.running;

        return Card(
          elevation: 0,
          color: colorScheme.surfaceContainerHigh,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(
              color: laneRunning
                  ? context.status.warning.withAlpha(180)
                  : colorScheme.outlineVariant,
              width: laneRunning ? 1.5 : 1.0,
            ),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => _showAgentDetailModal(context, lane),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: (laneRunning ? context.status.warning : colorScheme.primary)
                              .withAlpha(30),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          lane.name.contains('server')
                              ? Icons.dns_rounded
                              : lane.name.contains('verifier')
                                  ? Icons.verified_user_rounded
                                  : lane.name.contains('Coordinator')
                                      ? Icons.hub_rounded
                                      : Icons.phone_android_rounded,
                          size: 18,
                          color: laneRunning ? context.status.warning : colorScheme.primary,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              lane.name,
                              style: textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            Text(
                              lane.role.isNotEmpty
                                  ? lane.role
                                  : lane.targetRepo,
                              style: textTheme.bodySmall?.copyWith(
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      // Badge Trạng thái
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3.5,
                        ),
                        decoration: BoxDecoration(
                          color: laneRunning
                              ? context.status.warning.withAlpha(35)
                              : context.status.success.withAlpha(35),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: laneRunning
                                ? context.status.warning.withAlpha(160)
                                : context.status.success.withAlpha(120),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (laneRunning) ...[
                              SizedBox(
                                width: 10,
                                height: 10,
                                child: CircularProgressIndicator(
                                  strokeWidth: 1.6,
                                  color: context.status.warning,
                                ),
                              ),
                              const SizedBox(width: 5),
                            ],
                            Text(
                              lane.status.name.toUpperCase(),
                              style: textTheme.labelSmall?.copyWith(
                                fontSize: 9.5,
                                fontWeight: FontWeight.w800,
                                color: laneRunning ? context.status.warning : context.status.success,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  // Hành động & Công cụ hiện tại
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              laneRunning ? Icons.bolt_rounded : Icons.check_circle_rounded,
                              size: 14,
                              color: laneRunning ? context.status.warning : context.status.success,
                            ),
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                              decoration: BoxDecoration(
                                color: colorScheme.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                lane.currentToolName,
                                style: const TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            const Spacer(),
                            Text(
                              '${lane.steps.length} bước thực thi',
                              style: textTheme.labelSmall?.copyWith(
                                fontSize: 10,
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          lane.currentActionText.isNotEmpty
                              ? lane.currentActionText
                              : 'Đang theo dõi và chờ tác vụ tiếp theo...',
                          style: textTheme.bodySmall?.copyWith(
                            fontFamily: 'monospace',
                            fontSize: 11.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),

                  // Thanh tiến trình
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: laneRunning ? null : lane.progress,
                      backgroundColor: colorScheme.surfaceContainerHighest,
                      color: laneRunning ? context.status.warning : context.status.success,
                      minHeight: 4,
                    ),
                  ),
                  const SizedBox(height: 10),

                  // Footer: File tác động & Nút Bấm xem chi tiết
                  Row(
                    children: [
                      if (lane.filesModified.isNotEmpty)
                        Text(
                          '${lane.filesModified.length} tệp đã sửa',
                          style: textTheme.labelSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: context.status.success,
                          ),
                        )
                      else
                        Text(
                          'Kho: ${lane.targetRepo}',
                          style: textTheme.labelSmall?.copyWith(
                            fontFamily: 'monospace',
                            fontSize: 10,
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      const Spacer(),
                      TextButton.icon(
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        ),
                        onPressed: () => _showAgentDetailModal(context, lane),
                        icon: const Icon(Icons.visibility_outlined, size: 14),
                        label: const Text('Xem tác vụ & Logs', style: TextStyle(fontSize: 11)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// Thẻ Agent tương tác trong Tab 1 (Clickable để mở Modal chi tiết)
  Widget _buildInteractiveAgentCard(
    BuildContext context, {
    required SubagentLane lane,
    required Color accentColor,
    required IconData icon,
    required bool isMobile,
    required String subtitle,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final isRunning = lane.status == AgentStatus.running;

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => _showAgentDetailModal(context, lane),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainer,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isRunning
                ? context.status.warning
                : accentColor.withAlpha(120),
            width: isRunning ? 1.5 : 1.0,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(icon, size: 16, color: isRunning ? context.status.warning : accentColor),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    lane.name,
                    style: textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: isRunning ? context.status.warning : accentColor,
                    ),
                  ),
                ),
                if (isRunning) ...[
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.8,
                      color: context.status.warning,
                    ),
                  ),
                  const SizedBox(width: 6),
                ],
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: (isRunning ? context.status.warning : context.status.success).withAlpha(30),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    lane.status.name.toUpperCase(),
                    style: textTheme.labelSmall?.copyWith(
                      fontSize: 8.5,
                      fontWeight: FontWeight.w800,
                      color: isRunning ? context.status.warning : context.status.success,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              subtitle,
              style: textTheme.labelSmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
                fontSize: 10,
              ),
            ),
            const SizedBox(height: 8),

            // Hành động hiện tại
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest.withAlpha(120),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                children: [
                  Icon(
                    isRunning ? Icons.bolt_rounded : Icons.terminal_rounded,
                    size: 13,
                    color: isRunning ? context.status.warning : colorScheme.primary,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      lane.currentActionText.isNotEmpty
                          ? lane.currentActionText
                          : 'Đang theo dõi tác vụ...',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 10.5,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),

            // Nút Chạm để xem chi tiết
            Row(
              children: [
                if (lane.steps.isNotEmpty)
                  Text(
                    '${lane.steps.length} bước',
                    style: textTheme.labelSmall?.copyWith(fontSize: 10),
                  ),
                if (lane.filesModified.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Text(
                    '${lane.filesModified.length} tệp sửa',
                    style: textTheme.labelSmall?.copyWith(
                      fontSize: 10,
                      color: context.status.success,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
                const Spacer(),
                Text(
                  'Chạm để xem chi tiết ➔',
                  style: textTheme.labelSmall?.copyWith(
                    fontSize: 9.5,
                    fontWeight: FontWeight.w700,
                    color: isRunning ? context.status.warning : colorScheme.primary,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// [MODAL DIALOG / BOTTOM SHEET] XEM CHI TIẾT TÁC VỤ & NHẬT KÝ THỰC THI CỦA TỪNG AGENT
  void _showAgentDetailModal(BuildContext context, SubagentLane lane) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final colorScheme = Theme.of(ctx).colorScheme;
        final textTheme = Theme.of(ctx).textTheme;
        final isRunning = lane.status == AgentStatus.running;

        return DraggableScrollableSheet(
          initialChildSize: 0.82,
          minChildSize: 0.5,
          maxChildSize: 0.95,
          builder: (_, scrollController) {
            return Container(
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerLow,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
              ),
              child: Column(
                children: [
                  // Drag Handle
                  Container(
                    margin: const EdgeInsets.only(top: 10, bottom: 6),
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: colorScheme.outlineVariant,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),

                  // Header Agent
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: (isRunning ? context.status.warning : colorScheme.primary)
                                .withAlpha(35),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(
                            lane.name.contains('server')
                                ? Icons.dns_rounded
                                : lane.name.contains('verifier')
                                    ? Icons.verified_user_rounded
                                    : Icons.phone_android_rounded,
                            color: isRunning ? context.status.warning : colorScheme.primary,
                            size: 22,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                lane.name,
                                style: textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              Text(
                                '${lane.role} • Kho: ${lane.targetRepo}',
                                style: textTheme.bodySmall?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: isRunning
                                ? context.status.warning.withAlpha(35)
                                : context.status.success.withAlpha(35),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: isRunning ? context.status.warning : context.status.success,
                            ),
                          ),
                          child: Text(
                            lane.status.name.toUpperCase(),
                            style: textTheme.labelSmall?.copyWith(
                              fontSize: 10,
                              fontWeight: FontWeight.w900,
                              color: isRunning ? context.status.warning : context.status.success,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),

                  // Nội dung chi tiết cuộn được
                  Expanded(
                    child: ListView(
                      controller: scrollController,
                      padding: const EdgeInsets.all(16),
                      children: [
                        // Khối 1: Hành động hiện tại
                        Text(
                          'Hành Động Đang Thực Thi:',
                          style: textTheme.labelMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: colorScheme.surfaceContainerHigh,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: isRunning
                                  ? context.status.warning.withAlpha(160)
                                  : colorScheme.outlineVariant,
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    isRunning ? Icons.bolt_rounded : Icons.check_circle_rounded,
                                    size: 16,
                                    color: isRunning ? context.status.warning : context.status.success,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    'Tool: ${lane.currentToolName}',
                                    style: TextStyle(
                                      fontFamily: 'monospace',
                                      fontWeight: FontWeight.w700,
                                      color: colorScheme.primary,
                                      fontSize: 12,
                                    ),
                                  ),
                                  const Spacer(),
                                  if (isRunning)
                                    SizedBox(
                                      width: 12,
                                      height: 12,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: context.status.warning,
                                      ),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Text(
                                lane.currentActionText.isNotEmpty
                                    ? lane.currentActionText
                                    : 'Agent đang sẵn sàng nhận lệnh.',
                                style: textTheme.bodySmall?.copyWith(
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),

                        // Khối 2: Nhiệm vụ được giao (Prompt Brief)
                        Text(
                          'Nhiệm Vụ Được Giao (Prompt Brief):',
                          style: textTheme.labelMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: colorScheme.surfaceContainer,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: colorScheme.outlineVariant),
                          ),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxHeight: 140),
                            child: SingleChildScrollView(
                              physics: const ClampingScrollPhysics(),
                              child: Text(
                                lane.promptBrief.isNotEmpty
                                    ? lane.promptBrief
                                    : 'Chuyên trách thực thi các tác vụ được Coordinator phân bổ.',
                                style: textTheme.bodySmall?.copyWith(
                                  height: 1.45,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),

                        // Khối 3: Tệp mã nguồn đã tác động
                        if (lane.filesModified.isNotEmpty) ...[
                          Row(
                            children: [
                              Text(
                                'Tệp Mã Nguồn Đã Tác Động (${lane.filesModified.length}):',
                                style: textTheme.labelMedium?.copyWith(
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const Spacer(),
                              Text(
                                'Chạm để xem diff',
                                style: textTheme.labelSmall?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final f in lane.filesModified)
                                InkWell(
                                  borderRadius: BorderRadius.circular(8),
                                  onTap: () {
                                    widget.onInspectFile?.call(f, null);
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 5,
                                    ),
                                    decoration: BoxDecoration(
                                      color: colorScheme.surfaceContainerHighest,
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                        color: colorScheme.outlineVariant,
                                      ),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          Icons.edit_document,
                                          size: 13,
                                          color: context.status.success,
                                        ),
                                        const SizedBox(width: 6),
                                        Text(
                                          f.split('/').last,
                                          style: const TextStyle(
                                            fontFamily: 'monospace',
                                            fontSize: 11,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 16),
                        ],

                        // Khối 4: Nhật ký thực thi chi tiết (Steps & Trajectory)
                        Row(
                          children: [
                            Text(
                              'Nhật Ký Thực Thi (${lane.steps.length} bước):',
                              style: textTheme.labelMedium?.copyWith(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const Spacer(),
                            if (isRunning)
                              Text(
                                'Đang ghi nhận...',
                                style: textTheme.labelSmall?.copyWith(
                                  color: context.status.warning,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        if (lane.steps.isEmpty)
                          Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: colorScheme.surfaceContainer,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Center(
                              child: Text(
                                'Agent đang ở trạng thái Standby. Các bước thực thi sẽ xuất hiện tại đây khi Agent bắt đầu chạy.',
                                style: textTheme.bodySmall?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          )
                        else
                          for (final step in lane.steps.reversed)
                            _buildStepDetailCard(ctx, step, colorScheme, textTheme),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  /// Card từng bước thực thi trong Modal chi tiết Agent
  Widget _buildStepDetailCard(
    BuildContext context,
    AgentStep step,
    ColorScheme colorScheme,
    TextTheme textTheme,
  ) {
    final hasTool = step.toolCalls.isNotEmpty;
    final tool = hasTool ? step.toolCalls.first : null;

    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => _showStepDetailModal(context, step),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainer,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: colorScheme.outlineVariant.withAlpha(90)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: colorScheme.primaryContainer.withAlpha(120),
                  ),
                  child: Text(
                    '#${step.stepIndex}',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      color: colorScheme.primary,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                if (tool != null) ...[
                  Icon(Icons.build_circle_outlined, size: 13, color: colorScheme.primary),
                  const SizedBox(width: 4),
                  Text(
                    tool.name,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.w700,
                      fontSize: 11,
                    ),
                  ),
                ],
                const Spacer(),
                Text(
                  '${step.createdAt.hour.toString().padLeft(2, '0')}:${step.createdAt.minute.toString().padLeft(2, '0')}:${step.createdAt.second.toString().padLeft(2, '0')}',
                  style: textTheme.labelSmall?.copyWith(
                    fontSize: 10,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 14,
                  color: colorScheme.onSurfaceVariant.withAlpha(140),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              step.vietnameseTitle.isNotEmpty
                  ? step.vietnameseTitle
                  : (tool != null ? tool.summaryLabel : step.content),
              style: textTheme.bodySmall?.copyWith(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (step.thinking.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                'Suy nghĩ: ${step.thinking.length > 160 ? "${step.thinking.substring(0, 160)}..." : step.thinking}',
                style: textTheme.labelSmall?.copyWith(
                  fontStyle: FontStyle.italic,
                  color: colorScheme.onSurfaceVariant.withAlpha(190),
                ),
              ),
            ],
          ],
        ),
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
          minChildSize: 0.40,
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
                if (step.vietnameseDetail.isNotEmpty) ...[
                  Text(
                    'Chi tiết bước thực thi',
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
                      step.vietnameseDetail,
                      style: textTheme.bodySmall?.copyWith(height: 1.45),
                    ),
                  ),
                  const SizedBox(height: 14),
                ],
                if (step.thinking.trim().isNotEmpty) ...[
                  Text(
                    'Thought Process (Suy luận chiến lược)',
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
                  for (final tool in step.toolCalls) ...[
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
                              Text(
                                tool.name,
                                style: textTheme.labelLarge?.copyWith(
                                  fontWeight: FontWeight.w800,
                                  color: colorScheme.primary,
                                ),
                              ),
                              const Spacer(),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: colorScheme.primaryContainer,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  tool.repoTag,
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w700,
                                    color: colorScheme.onPrimaryContainer,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          if (tool.summaryLabel.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              tool.summaryLabel,
                              style: textTheme.bodySmall?.copyWith(
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                          if (tool.args.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: colorScheme.surfaceContainerLowest,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: SelectableText(
                                tool.args.entries.map((e) => '${e.key}: ${e.value}').join('\n'),
                                style: const TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 11,
                                  height: 1.35,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 14),
                ],
                if (step.content.trim().isNotEmpty) ...[
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
                      style: textTheme.bodySmall?.copyWith(height: 1.45),
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

  /// [TAB 3] HỘI THOẠI AGENT & TIẾN TRÌNH SUBAGENTS (INTER-AGENT DIALOGUES)
  Widget _buildInterAgentDialogueTab(
    BuildContext context,
    bool isMobile,
    bool isRunning,
    List<SubagentLane> lanes,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final session = _session ?? widget.session;

    final dialogues = _extractInterAgentDialogues(session, lanes);
    final runningLanes = lanes.where((l) => l.status == AgentStatus.running).toList();

    // Lọc danh sách theo filter hiện tại
    final filteredDialogues = dialogues.where((item) {
      if (_dialogueFilter == 'all') return true;
      if (_dialogueFilter == 'running') return item.status == AgentStatus.running;
      if (_dialogueFilter == 'dispatch') return item.type == 'dispatch';
      if (_dialogueFilter == 'report') return item.type == 'report';
      if (_dialogueFilter == 'message') return item.type == 'message';
      return item.sender == _dialogueFilter || item.receiver == _dialogueFilter;
    }).toList();

    // Danh sách các agent có mặt để tạo filter chips
    final agentNames = <String>{'Coordinator'};
    for (final l in lanes) {
      if (l.name.isNotEmpty) agentNames.add(l.name);
    }

    return ListView(
      padding: EdgeInsets.all(isMobile ? 12 : 20),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 960),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 1. Khối Giám Sát Subagents Đang Chạy (Running Subagents Overview)
                _buildRunningSubagentsCard(context, isMobile, runningLanes),

                const SizedBox(height: 16),

                // 2. Thanh Filter Chips
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _buildDialogueFilterChip('all', 'Tất cả (${dialogues.length})', Icons.filter_list_rounded),
                      const SizedBox(width: 8),
                      if (runningLanes.isNotEmpty) ...[
                        _buildDialogueFilterChip('running', 'Đang chạy (${runningLanes.length})', Icons.directions_run_rounded, isOrange: true),
                        const SizedBox(width: 8),
                      ],
                      _buildDialogueFilterChip('dispatch', 'Giao việc (${dialogues.where((d) => d.type == 'dispatch').length})', Icons.assignment_outlined),
                      const SizedBox(width: 8),
                      _buildDialogueFilterChip('report', 'Báo cáo (${dialogues.where((d) => d.type == 'report').length})', Icons.assignment_turned_in_outlined),
                      const SizedBox(width: 8),
                      _buildDialogueFilterChip('message', 'Trao đổi (${dialogues.where((d) => d.type == 'message').length})', Icons.chat_bubble_outline_rounded),
                      const SizedBox(width: 8),
                      for (final name in agentNames) ...[
                        _buildDialogueFilterChip(name, name, Icons.person_outline_rounded),
                        const SizedBox(width: 8),
                      ],
                    ],
                  ),
                ),

                const SizedBox(height: 16),

                // 3. Danh sách Hội thoại hoặc Trạng thái trống
                if (filteredDialogues.isEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 20),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: colorScheme.outlineVariant),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.forum_outlined,
                          size: 48,
                          color: colorScheme.onSurfaceVariant.withAlpha(120),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          _dialogueFilter == 'all'
                              ? 'Chưa có thông điệp trao đổi giữa các Agent'
                              : 'Không tìm thấy thông điệp cho bộ lọc này',
                          style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Khi Coordinator điều phối Subagent song song, các lượt giao task, báo cáo và trao đổi sẽ xuất hiện tại đây theo thời gian thực.',
                          textAlign: TextAlign.center,
                          style: textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  )
                else
                  for (final item in filteredDialogues) ...[
                    _buildDialogueCard(context, isMobile, item),
                    const SizedBox(height: 12),
                  ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Khối giám sát các Subagents đang chạy trực tiếp
  Widget _buildRunningSubagentsCard(
    BuildContext context,
    bool isMobile,
    List<SubagentLane> runningLanes,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    if (runningLanes.isEmpty) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: context.status.success.withAlpha(18),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: context.status.success.withAlpha(80)),
        ),
        child: Row(
          children: [
            Icon(Icons.check_circle_rounded, color: context.status.success, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Subagents ở chế độ Chờ / Đã hoàn thành',
                    style: textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: context.status.success,
                    ),
                  ),
                  Text(
                    'Hiện tại không có subagent song song nào đang chạy. Các tác vụ đã đồng bộ ổn định.',
                    style: textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: context.status.warning.withAlpha(20),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: context.status.warning.withAlpha(130), width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AnimatedBuilder(
                animation: _pulseController,
                builder: (context, _) {
                  return Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: context.status.warning,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: context.status.warning.withAlpha((140 * _pulseController.value).toInt()),
                          blurRadius: 6,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                  );
                },
              ),
              const SizedBox(width: 10),
              Text(
                '${runningLanes.length} Subagent đang chạy song song',
                style: textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: context.status.warning,
                ),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: context.status.warning.withAlpha(40),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: context.status.warning.withAlpha(160)),
                ),
                child: Text(
                  'REALTIME EXECUTING',
                  style: TextStyle(
                    fontSize: 9.5,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.5,
                    color: context.status.warning,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Column(
            children: runningLanes.map((lane) {
              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: context.status.warning.withAlpha(90)),
                ),
                child: Row(
                  children: [
                    _buildAgentAvatar(lane.name, size: 28),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                lane.name,
                                style: textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w800),
                              ),
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                                decoration: BoxDecoration(
                                  color: colorScheme.surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  lane.targetRepo,
                                  style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            lane.currentActionText.isNotEmpty
                                ? lane.currentActionText
                                : 'Đang xử lý công cụ: ${lane.currentToolName}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: textTheme.bodySmall?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        side: BorderSide(color: context.status.warning.withAlpha(150)),
                      ),
                      onPressed: () => _showAgentDetailModal(context, lane),
                      icon: Icon(Icons.tune_rounded, size: 14, color: context.status.warning),
                      label: Text('Xem Lane', style: TextStyle(fontSize: 11, color: context.status.warning)),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  /// Chip bộ lọc loại trao đổi
  Widget _buildDialogueFilterChip(
    String filterKey,
    String label,
    IconData icon, {
    bool isOrange = false,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final isSelected = _dialogueFilter == filterKey;

    return FilterChip(
      selected: isSelected,
      showCheckmark: false,
      avatar: Icon(
        icon,
        size: 14,
        color: isSelected
            ? (isOrange ? context.status.warning : colorScheme.primary)
            : colorScheme.onSurfaceVariant,
      ),
      label: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
          color: isSelected
              ? (isOrange ? context.status.warning : colorScheme.primary)
              : colorScheme.onSurfaceVariant,
        ),
      ),
      backgroundColor: colorScheme.surfaceContainer,
      selectedColor: (isOrange ? context.status.warning : colorScheme.primary).withAlpha(35),
      side: BorderSide(
        color: isSelected
            ? (isOrange ? context.status.warning : colorScheme.primary)
            : colorScheme.outlineVariant,
      ),
      onSelected: (_) {
        setState(() {
          _dialogueFilter = filterKey;
        });
      },
    );
  }

  /// Thẻ hiển thị một cuộc trao đổi / chỉ đạo / báo cáo
  Widget _buildDialogueCard(
    BuildContext context,
    bool isMobile,
    _InterAgentDialogueItem item,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    Color badgeColor;
    String badgeText;
    IconData typeIcon;
    switch (item.type) {
      case 'dispatch':
        badgeColor = context.scheme.tertiary;
        badgeText = 'GIAO VIỆC';
        typeIcon = Icons.assignment_outlined;
        break;
      case 'report':
        badgeColor = context.status.success;
        badgeText = 'BÁO CÁO';
        typeIcon = Icons.assignment_turned_in_outlined;
        break;
      case 'message':
        badgeColor = context.scheme.secondary;
        badgeText = 'TRAO ĐỔI';
        typeIcon = Icons.chat_bubble_outline_rounded;
        break;
      case 'action':
      default:
        badgeColor = context.status.warning;
        badgeText = 'ĐANG XỬ LÝ';
        typeIcon = Icons.bolt_rounded;
        break;
    }

    final timeStr =
        '${item.timestamp.hour.toString().padLeft(2, '0')}:${item.timestamp.minute.toString().padLeft(2, '0')}:${item.timestamp.second.toString().padLeft(2, '0')}';

    return Card(
      elevation: 0,
      color: colorScheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: item.status == AgentStatus.running
              ? context.status.warning.withAlpha(140)
              : colorScheme.outlineVariant,
          width: item.status == AgentStatus.running ? 1.5 : 1.0,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Row Tiêu đề & Hướng trao đổi
            Row(
              children: [
                _buildAgentAvatar(item.sender, size: 24),
                const SizedBox(width: 6),
                Text(
                  item.sender,
                  style: textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 6),
                Icon(
                  Icons.arrow_forward_rounded,
                  size: 14,
                  color: colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                _buildAgentAvatar(item.receiver, size: 24),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    item.receiver,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const Spacer(),
                // Badge Loại hội thoại
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
                  decoration: BoxDecoration(
                    color: badgeColor.withAlpha(30),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: badgeColor.withAlpha(120)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(typeIcon, size: 11, color: badgeColor),
                      const SizedBox(width: 4),
                      Text(
                        badgeText,
                        style: TextStyle(
                          fontSize: 9.5,
                          fontWeight: FontWeight.w800,
                          color: badgeColor,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  timeStr,
                  style: textTheme.labelSmall?.copyWith(
                    fontSize: 10,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 10),

            // Tiêu đề nội dung trao đổi
            Text(
              item.title,
              style: textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: -0.1,
              ),
            ),

            const SizedBox(height: 6),

            // Hộp nội dung trao đổi (Prompt / Tin nhắn / Báo cáo)
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainer,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: colorScheme.outlineVariant.withAlpha(80)),
              ),
              child: Text(
                item.content.trim(),
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: textTheme.bodySmall?.copyWith(
                  fontFamily: item.toolArgs != null ? 'monospace' : null,
                  fontSize: 11.5,
                  height: 1.4,
                  color: colorScheme.onSurface,
                ),
              ),
            ),

            // Tool Call Args preview (nếu có)
            if (item.toolName != null) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      item.toolName!,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (item.targetRepo != null && item.targetRepo!.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: context.scheme.secondary.withAlpha(25),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        item.targetRepo!,
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: context.scheme.secondary,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ],

            const SizedBox(height: 10),

            // Action footer
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (item.lane != null) ...[
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    ),
                    onPressed: () => _showAgentDetailModal(context, item.lane!),
                    icon: const Icon(Icons.tune_rounded, size: 14),
                    label: const Text('Xem Lane tác vụ', style: TextStyle(fontSize: 11)),
                  ),
                  const SizedBox(width: 8),
                ],
                FilledButton.tonalIcon(
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  ),
                  onPressed: () => _showDialogueDetailModal(context, item),
                  icon: const Icon(Icons.fullscreen_rounded, size: 14),
                  label: const Text('Chi tiết trao đổi', style: TextStyle(fontSize: 11)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Modal xem toàn bộ thông điệp trao đổi giữa các Agent
  void _showDialogueDetailModal(BuildContext context, _InterAgentDialogueItem item) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final colorScheme = Theme.of(ctx).colorScheme;
        final textTheme = Theme.of(ctx).textTheme;

        final timeStr =
            '${item.timestamp.hour.toString().padLeft(2, '0')}:${item.timestamp.minute.toString().padLeft(2, '0')}:${item.timestamp.second.toString().padLeft(2, '0')}';

        return DraggableScrollableSheet(
          initialChildSize: 0.75,
          minChildSize: 0.45,
          maxChildSize: 0.95,
          builder: (_, scrollController) {
            return Container(
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerLow,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
              ),
              child: Column(
                children: [
                  // Handle
                  Container(
                    margin: const EdgeInsets.only(top: 10, bottom: 6),
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: colorScheme.outlineVariant,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),

                  // Header
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
                    child: Row(
                      children: [
                        _buildAgentAvatar(item.sender, size: 28),
                        const SizedBox(width: 8),
                        Text(
                          item.sender,
                          style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(width: 8),
                        const Icon(Icons.arrow_forward_rounded, size: 16),
                        const SizedBox(width: 8),
                        _buildAgentAvatar(item.receiver, size: 28),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            item.receiver,
                            style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close_rounded, size: 20),
                          onPressed: () => Navigator.of(ctx).pop(),
                        ),
                      ],
                    ),
                  ),

                  const Divider(height: 1),

                  // Body
                  Expanded(
                    child: ListView(
                      controller: scrollController,
                      padding: const EdgeInsets.all(16),
                      children: [
                        // Meta Box
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: colorScheme.surfaceContainerHigh,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                item.title,
                                style: textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Row(
                                children: [
                                  Icon(Icons.access_time_rounded, size: 14, color: colorScheme.onSurfaceVariant),
                                  const SizedBox(width: 4),
                                  Text(
                                    'Thời gian: $timeStr',
                                    style: textTheme.labelSmall?.copyWith(color: colorScheme.onSurfaceVariant),
                                  ),
                                  if (item.stepIndex != null) ...[
                                    const SizedBox(width: 12),
                                    Text(
                                      'Bước: #${item.stepIndex}',
                                      style: textTheme.labelSmall?.copyWith(color: colorScheme.onSurfaceVariant),
                                    ),
                                  ],
                                ],
                              ),
                            ],
                          ),
                        ),

                        const SizedBox(height: 14),

                        // Nội dung chi tiết
                        Text(
                          'Nội dung trao đổi / Chỉ thị:',
                          style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: colorScheme.surfaceContainer,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: colorScheme.outlineVariant),
                          ),
                          child: SelectableText(
                            item.content.trim(),
                            style: textTheme.bodyMedium?.copyWith(
                              height: 1.45,
                              fontFamily: item.toolArgs != null ? 'monospace' : null,
                            ),
                          ),
                        ),

                        // Tool args nếu có
                        if (item.toolArgs != null && item.toolArgs!.isNotEmpty) ...[
                          const SizedBox(height: 14),
                          Text(
                            'Tham số công cụ (${item.toolName ?? "tool_call"}):',
                            style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 8),
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: colorScheme.surfaceContainerHighest.withAlpha(120),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: item.toolArgs!.entries.map((entry) {
                                return Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 3),
                                  child: Row(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '${entry.key}: ',
                                        style: const TextStyle(
                                          fontFamily: 'monospace',
                                          fontSize: 11,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      Expanded(
                                        child: SelectableText(
                                          '${entry.value}',
                                          style: const TextStyle(
                                            fontFamily: 'monospace',
                                            fontSize: 11,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              }).toList(),
                            ),
                          ),
                        ],

                        if (item.lane != null) ...[
                          const SizedBox(height: 20),
                          FilledButton.icon(
                            onPressed: () {
                              Navigator.of(ctx).pop();
                              _showAgentDetailModal(context, item.lane!);
                            },
                            icon: const Icon(Icons.tune_rounded, size: 16),
                            label: Text('Mở toàn bộ Lane của ${item.lane!.name}'),
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
      },
    );
  }

  /// Trích xuất danh sách các tương tác trao đổi giữa các Agent
  List<_InterAgentDialogueItem> _extractInterAgentDialogues(
    ConversationSession? session,
    List<SubagentLane> lanes,
  ) {
    final items = <_InterAgentDialogueItem>[];
    final seenIds = <String>{};

    // 1. Quét các steps của Coordinator / parent session
    final steps = session?.steps ?? const <AgentStep>[];
    for (final step in steps) {
      // 1.1 Kiểm tra toolCalls invoke_subagent & send_message
      for (final tc in step.toolCalls) {
        if (tc.name == 'invoke_subagent') {
          final role = tc.args['Role']?.toString() ?? 'Subagent Worker';
          final typeName = tc.args['TypeName']?.toString() ?? '';
          final prompt = tc.args['Prompt']?.toString() ?? '';
          final receiverName = typeName.isNotEmpty ? typeName : role;

          final lane = lanes.cast<SubagentLane?>().firstWhere(
                (l) => l?.name == receiverName || l?.role == role,
                orElse: () => null,
              );

          final id = 'dispatch_${step.stepIndex}_${tc.name}';
          if (seenIds.add(id)) {
            items.add(_InterAgentDialogueItem(
              id: id,
              sender: 'Coordinator',
              receiver: receiverName,
              type: 'dispatch',
              title: 'Coordinator giao nhiệm vụ cho $receiverName',
              content: prompt,
              timestamp: step.createdAt,
              status: lane?.status ?? AgentStatus.completed,
              toolName: 'invoke_subagent',
              toolArgs: tc.args,
              targetRepo: lane?.targetRepo,
              lane: lane,
              stepIndex: step.stepIndex,
            ));
          }
        } else if (tc.name == 'send_message') {
          final recipient = tc.args['Recipient']?.toString() ?? 'Subagent';
          final message = tc.args['Message']?.toString() ?? '';
          final sender = step.agentName.isNotEmpty ? step.agentName : 'Coordinator';

          final id = 'msg_${step.stepIndex}_${tc.name}';
          if (seenIds.add(id)) {
            items.add(_InterAgentDialogueItem(
              id: id,
              sender: sender,
              receiver: recipient,
              type: 'message',
              title: '$sender trao đổi với $recipient',
              content: message,
              timestamp: step.createdAt,
              status: AgentStatus.completed,
              toolName: 'send_message',
              toolArgs: tc.args,
              stepIndex: step.stepIndex,
            ));
          }
        }
      }

      // 1.2 Báo cáo từ subagent qua SYSTEM_MESSAGE
      if (step.content.contains('<SYSTEM_MESSAGE>') && step.content.contains('sender=')) {
        final senderMatch = RegExp(r'sender=([a-zA-Z0-9_-]+)').firstMatch(step.content);
        final rawSender = senderMatch?.group(1) ?? 'Subagent';
        final matchedLane = lanes.cast<SubagentLane?>().firstWhere(
              (l) => l?.id == rawSender || l?.name == rawSender,
              orElse: () => null,
            );
        final senderName = matchedLane?.name ?? rawSender;

        var messageBody = step.content;
        const startTag = '<SYSTEM_MESSAGE>';
        const endTag = '</SYSTEM_MESSAGE>';
        final sIdx = messageBody.indexOf(startTag);
        final eIdx = messageBody.indexOf(endTag);
        if (sIdx != -1 && eIdx != -1 && eIdx > sIdx) {
          messageBody = messageBody.substring(sIdx + startTag.length, eIdx).trim();
        }

        final id = 'report_${step.stepIndex}';
        if (seenIds.add(id)) {
          items.add(_InterAgentDialogueItem(
            id: id,
            sender: senderName,
            receiver: 'Coordinator',
            type: 'report',
            title: '$senderName báo cáo tiến độ/kết quả',
            content: messageBody,
            timestamp: step.createdAt,
            status: matchedLane?.status ?? AgentStatus.completed,
            targetRepo: matchedLane?.targetRepo,
            lane: matchedLane,
            stepIndex: step.stepIndex,
          ));
        }
      }
    }

    // 2. Quét từ danh sách lanes (Bổ sung nhiệm vụ nếu session steps chưa tải hết do phân trang)
    for (final lane in lanes) {
      if (lane.name == 'Coordinator') continue;

      final hasDispatch = items.any((it) => it.type == 'dispatch' && (it.receiver == lane.name || it.receiver == lane.role));
      if (!hasDispatch && (lane.promptBrief.isNotEmpty || lane.role.isNotEmpty)) {
        final id = 'lane_prompt_${lane.id}_${lane.name}';
        if (seenIds.add(id)) {
          items.add(_InterAgentDialogueItem(
            id: id,
            sender: 'Coordinator',
            receiver: lane.name,
            type: 'dispatch',
            title: 'Chỉ đạo phân bổ nhiệm vụ: ${lane.role.isNotEmpty ? lane.role : lane.name}',
            content: lane.promptBrief.isNotEmpty
                ? lane.promptBrief
                : 'Thực thi mã nguồn repo ${lane.targetRepo} theo kiến trúc song song.',
            timestamp: lane.lastUpdated ?? DateTime.now(),
            status: lane.status,
            targetRepo: lane.targetRepo,
            lane: lane,
          ));
        }
      }

      // Các bước gửi tin nhắn trong lane.steps
      for (final s in lane.steps) {
        if (s.toolCalls.any((t) => t.name == 'send_message')) {
          for (final tc in s.toolCalls.where((t) => t.name == 'send_message')) {
            final id = 'subagent_msg_${s.stepIndex}_${lane.id}';
            if (seenIds.add(id)) {
              items.add(_InterAgentDialogueItem(
                id: id,
                sender: lane.name,
                receiver: tc.args['Recipient']?.toString() ?? 'Coordinator',
                type: 'message',
                title: '${lane.name} gửi thông điệp',
                content: tc.args['Message']?.toString() ?? '',
                timestamp: s.createdAt,
                status: lane.status,
                toolName: 'send_message',
                toolArgs: tc.args,
                lane: lane,
                stepIndex: s.stepIndex,
              ));
            }
          }
        }
      }

      // Nếu lane đang chạy, bổ sung live status action card
      if (lane.status == AgentStatus.running) {
        final id = 'running_action_${lane.id}';
        if (seenIds.add(id)) {
          items.add(_InterAgentDialogueItem(
            id: id,
            sender: lane.name,
            receiver: 'Coordinator',
            type: 'action',
            title: '${lane.name} đang trực tiếp xử lý',
            content: lane.currentActionText.isNotEmpty
                ? lane.currentActionText
                : 'Đang chạy công cụ ${lane.currentToolName}',
            timestamp: lane.lastUpdated ?? DateTime.now(),
            status: AgentStatus.running,
            toolName: lane.currentToolName,
            targetRepo: lane.targetRepo,
            lane: lane,
          ));
        }
      }
    }

    // Sắp xếp theo thời gian mới nhất lên đầu
    items.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return items;
  }

  /// Avatar đại diện cho từng loại Agent
  Widget _buildAgentAvatar(String agentName, {double size = 24}) {
    Color bg;
    IconData icon;
    final lower = agentName.toLowerCase();
    if (lower.contains('coordinator')) {
      bg = context.scheme.tertiary;
      icon = Icons.hub_rounded;
    } else if (lower.contains('server')) {
      bg = context.scheme.secondary;
      icon = Icons.dns_rounded;
    } else if (lower.contains('app')) {
      bg = context.status.success;
      icon = Icons.phone_android_rounded;
    } else if (lower.contains('verifier')) {
      bg = context.status.success;
      icon = Icons.verified_user_rounded;
    } else if (lower.contains('research')) {
      bg = context.status.warning;
      icon = Icons.travel_explore_rounded;
    } else {
      bg = context.scheme.tertiary;
      icon = Icons.smart_toy_rounded;
    }
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: bg.withAlpha(40),
        shape: BoxShape.circle,
        border: Border.all(color: bg.withAlpha(120), width: 1),
      ),
      child: Center(
        child: Icon(icon, size: size * 0.6, color: bg),
      ),
    );
  }

  /// [TAB 4] BẢNG ĐỐI SOÁT HỢP ĐỒNG (CONTRACT VERIFIER CHECKLIST)
  Widget _buildContractVerifierTab(
    BuildContext context,
    bool isMobile,
    bool isRunning,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final contractItems = [
      (
        'Canonical API Endpoints',
        'Mỗi tài nguyên chỉ có 1 URL chuẩn duy nhất (vd: /api/v1/order). Tuyệt đối không dùng alias.',
        true,
      ),
      (
        'JSON DTO Schema Match',
        'Cấu trúc trường, kiểu dữ liệu camelCase/snakeCase khớp tuyệt đối giữa Go struct và Dart class.',
        true,
      ),
      (
        'RBAC Permission Prefix',
        'Mọi quyền chuyên biệt phải có prefix domain (vd: retail:pos_view, education:kitchen_view).',
        true,
      ),
      (
        'Socket.IO Realtime Contract',
        'Namespace /admin, tên room theo tenant, tên event và payload đối soát khớp 100%.',
        true,
      ),
      (
        'Server Build Check (go build -v .)',
        'Biên dịch Go module muop/erp không có lỗi compile, không còn code legacy.',
        true,
      ),
      (
        'Client Analyze Check (flutter analyze)',
        'Flutter engine muop-agent / muop-erp-app đạt trạng thái "No issues found!".',
        true,
      ),
    ];

    return ListView(
      padding: EdgeInsets.all(isMobile ? 12 : 24),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 840),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Tiêu Chí Nghiệm Thu Hợp Đồng (Contract Verification)',
                  style: textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Hệ thống tự động kiểm tra chéo các ràng buộc kỹ thuật giữa muop-erp-server và muop-erp-app.',
                  style: textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 16),
                for (final item in contractItems)
                  Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: context.status.success.withAlpha(90),
                      ),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            color: context.status.success,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(Icons.check,
                              size: 14, color: context.scheme.onPrimary),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                item.$1,
                                style: textTheme.bodyMedium?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                item.$2,
                                style: textTheme.bodySmall?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                  fontSize: 11.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPipelineNodeCard(
    BuildContext context, {
    required int stepNumber,
    required String title,
    required String subtitle,
    required IconData icon,
    required Color nodeColor,
    required String status,
    required bool isActive,
    required bool isCompleted,
    Widget? child,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final isMobile = MediaQuery.sizeOf(context).width < 760;

    return AnimatedBuilder(
      animation: _pulseController,
      builder: (context, _) {
        final pulse = _pulseController.value;
        return Container(
          padding: EdgeInsets.all(isMobile ? 12 : 16),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isActive
                  ? nodeColor.withAlpha((140 + pulse * 115).toInt())
                  : (isCompleted ? context.status.success.withAlpha(120) : colorScheme.outlineVariant),
              width: isActive ? 2.0 : 1.0,
            ),
            boxShadow: isActive
                ? [
                    BoxShadow(
                      color: nodeColor.withAlpha((40 * pulse).toInt()),
                      blurRadius: 8 * pulse,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      color: isActive
                          ? nodeColor
                          : (isCompleted ? context.status.success : context.scheme.onSurfaceVariant),
                      shape: BoxShape.circle,
                    ),
                    child: Center(
                      child: isCompleted && !isActive
                          ? Icon(Icons.check, size: 14, color: context.scheme.onPrimary)
                          : Text(
                              '$stepNumber',
                              style: TextStyle(
                                color: context.scheme.onPrimary,
                                fontWeight: FontWeight.bold,
                                fontSize: 12.5,
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Icon(icon, size: 18, color: isActive ? nodeColor : colorScheme.onSurface),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      title,
                      style: textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                        fontSize: isMobile ? 12.5 : 13.5,
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
                    decoration: BoxDecoration(
                      color: (isActive ? nodeColor : (isCompleted ? context.status.success : context.scheme.onSurfaceVariant))
                          .withAlpha(30),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      status,
                      style: textTheme.labelSmall?.copyWith(
                        fontSize: 9.5,
                        fontWeight: FontWeight.w900,
                        color: isActive ? nodeColor : (isCompleted ? context.status.success : context.scheme.onSurfaceVariant),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.only(left: 36),
                child: Text(
                  subtitle,
                  style: textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              if (child != null) ...[
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.only(left: 36),
                  child: child,
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildFlowArrow(BuildContext context, {bool isActive = false}) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Icon(
          Icons.arrow_downward_rounded,
          size: 20,
          color: isActive ? context.scheme.tertiary : colorScheme.outlineVariant,
        ),
      ),
    );
  }
}

/// DTO biểu diễn một lượt trao đổi, giao việc, báo cáo giữa các Agent
class _InterAgentDialogueItem {
  const _InterAgentDialogueItem({
    required this.id,
    required this.sender,
    required this.receiver,
    required this.type,
    required this.title,
    required this.content,
    required this.timestamp,
    this.status = AgentStatus.idle,
    this.toolName,
    this.toolArgs,
    this.targetRepo,
    this.lane,
    this.stepIndex,
  });

  final String id;
  final String sender;
  final String receiver;
  final String type; // 'dispatch', 'report', 'message', 'action'
  final String title;
  final String content;
  final DateTime timestamp;
  final AgentStatus status;
  final String? toolName;
  final Map<String, dynamic>? toolArgs;
  final String? targetRepo;
  final SubagentLane? lane;
  final int? stepIndex;
}
