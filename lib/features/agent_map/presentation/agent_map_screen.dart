import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'package:muop_agent/core/theme/app_theme.dart';
import 'package:muop_agent/core/widgets/glass_scaffold.dart';
import 'package:muop_agent/features/bridge/domain/peer_models.dart';
import 'package:muop_agent/features/sessions/domain/session_entities.dart';

/// Sơ đồ cây các agent của một conversation.
///
/// Dữ liệu hoàn toàn lấy từ server: gốc là conversation, mỗi [SubagentLane] là một nhánh,
/// và quan hệ cha-con đến từ `parentId` (agent nào đã gọi tool spawn agent đó).
/// Màn hình tự cập nhật theo snapshot nên các nhánh xuất hiện khi subagent được spawn.
class AgentMapScreen extends StatefulWidget {
  const AgentMapScreen({super.key, required this.sessionReader});

  /// Đọc session hiện tại mỗi lần vẽ lại (session có thể thay đổi khi đang chạy)
  final ConversationSession? Function() sessionReader;

  @override
  State<AgentMapScreen> createState() => _AgentMapScreenState();
}

// Kích thước nút và khoảng cách cây (điểm logic)
const double _cardWidth = 300;
const double _cardHeight = 118;
const double _siblingGap = 12;
const double _connectorWidth = 44;
const double _connectorBend = 14;
const double _minScale = 0.2;

class _AgentMapScreenState extends State<AgentMapScreen> {
  Timer? _refreshTimer;

  /// Điều khiển zoom/pan của sơ đồ. Giữ ở state để nút "Vừa màn hình" đưa được cả cây về khung nhìn
  final TransformationController _viewController = TransformationController();

  /// Kích thước khung nhìn và kích thước cả cây (đã tính padding), cập nhật mỗi lần vẽ
  Size _viewportSize = Size.zero;
  Size _contentSize = Size.zero;

  /// Mở màn hình thì tự vừa khung nhìn; sau đó, khi cây thêm nhánh mới, tự vừa lại
  /// trừ khi người dùng đã tự zoom/kéo (khi đó giữ nguyên vị trí của họ)
  bool _fitPending = true;
  bool _userInteracted = false;

  @override
  void initState() {
    super.initState();
    // Cập nhật thời gian chạy và trạng thái của các nhánh mỗi giây
    _refreshTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _viewController.dispose();
    super.dispose();
  }

  /// Zoom và đặt sơ đồ vào giữa khung nhìn để thấy toàn bộ cây
  void _fitToViewport() {
    if (_viewportSize.isEmpty || _contentSize.isEmpty) return;
    const margin = 24.0;
    final scale = math
        .min(
          (_viewportSize.width - margin * 2) / _contentSize.width,
          (_viewportSize.height - margin * 2) / _contentSize.height,
        )
        .clamp(_minScale, 1.0)
        .toDouble();
    final dx = (_viewportSize.width - _contentSize.width * scale) / 2;
    final dy = (_viewportSize.height - _contentSize.height * scale) / 2;
    _viewController.value = Matrix4.identity()
      ..translateByDouble(dx, dy, 0, 1)
      ..scaleByDouble(scale, scale, 1, 1);
    _userInteracted = false;
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.sessionReader();
    final lanes = session?.subagentLanes ?? const <SubagentLane>[];
    final runningCount = lanes
        .where((lane) => lane.status == AgentStatus.running)
        .length;
    final colorScheme = Theme.of(context).colorScheme;

    return GlassScreenScaffold(
      titleSpacing: 0,
      titleWidget: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Agent map',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 17),
          ),
          Text(
            '${lanes.length} agents · bấm một agent để xem chi tiết',
            style: TextStyle(
              fontSize: 11.5,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      actions: [
        IconButton(
          tooltip: 'Vừa màn hình',
          onPressed: session == null ? null : _fitToViewport,
          icon: const Icon(Icons.fit_screen_outlined),
        ),
        TextButton.icon(
          onPressed: session == null
              ? null
              : () => _showHistory(context, session),
          icon: const Icon(Icons.history_rounded, size: 18),
          label: const Text('Lịch sử'),
        ),
        const SizedBox(width: 6),
      ],
      body: session == null
          ? Center(
              child: Text(
                'Chưa có conversation nào được chọn.',
                style: TextStyle(color: colorScheme.onSurfaceVariant),
              ),
            )
          : LayoutBuilder(
              builder: (context, constraints) {
                final root = _buildTree(session, lanes);
                _viewportSize = constraints.biggest;
                final content = _treeSize(root);
                final contentChanged = content != _contentSize;
                _contentSize = content;
                if (_fitPending || (contentChanged && !_userInteracted)) {
                  _fitPending = false;
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) _fitToViewport();
                  });
                }
                return InteractiveViewer(
                  transformationController: _viewController,
                  onInteractionStart: (_) => _userInteracted = true,
                  constrained: false,
                  minScale: _minScale,
                  maxScale: 2.5,
                  // Không giới hạn pan: người dùng luôn kéo về được mọi nhánh sau khi zoom
                  boundaryMargin: const EdgeInsets.all(double.infinity),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(28, 28, 60, 60),
                    child: _buildRow(context, root),
                  ),
                );
              },
            ),
      bottomNavigationBar: SafeArea(
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(color: colorScheme.outlineVariant, width: 0.8),
            ),
          ),
          child: Text(
            '$runningCount tác vụ nền đang chạy · bấm một tác vụ để xem chi tiết',
            style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
          ),
        ),
      ),
    );
  }

  /// Kích thước cả cây kể cả padding bao quanh (dùng để vừa khung nhìn)
  Size _treeSize(_MapNode root) =>
      Size(_widthOf(root) + 28 + 60, _heightOf(root) + 28 + 60);

  double _widthOf(_MapNode node) {
    if (node.children.isEmpty) return _cardWidth;
    var widest = 0.0;
    for (final child in node.children) {
      widest = math.max(widest, _widthOf(child));
    }
    return _cardWidth + _connectorWidth + widest;
  }

  /// Dựng cây: gốc là Coordinator (điều phối viên của conversation), con là các subagent
  /// được gọi thật (`spawned`). Lane có `parentId` trỏ tới agent khác thì nằm dưới agent đó.
  /// Lane không có cha hợp lệ, hoặc cha là Coordinator, được gắn vào gốc.
  _MapNode _buildTree(ConversationSession session, List<SubagentLane> lanes) {
    SubagentLane? coordinator;
    for (final lane in lanes) {
      if (lane.id == 'Coordinator') {
        coordinator = lane;
        break;
      }
    }
    final root = _MapNode(
      isRoot: true,
      title: 'Coordinator',
      detail: session.title.isEmpty ? 'Conversation' : session.title,
      subtitle: _rootSubtitle(session),
      status:
          coordinator?.status ??
          (session.status == AgentStatus.running
              ? AgentStatus.running
              : AgentStatus.completed),
      steps: coordinator != null && coordinator.steps.isNotEmpty
          ? coordinator.steps
          : session.steps,
      files: session.filesTouched.map((f) => f.path).toSet().toList(),
      prompt: _userRequest(session),
    );
    final spawned = lanes
        .where((lane) => lane.spawned && lane.id != 'Coordinator')
        .toList();
    final nodes = <String, _MapNode>{};
    for (final lane in spawned) {
      nodes[lane.id] = _MapNode(
        lane: lane,
        title: lane.name.isEmpty ? lane.id : lane.name,
        detail: _firstLine(
          lane.promptBrief.isNotEmpty ? lane.promptBrief : lane.role,
        ),
        subtitle: _laneSubtitle(lane),
        status: lane.status,
        steps: lane.steps,
        files: lane.filesModified,
        prompt: lane.promptBrief,
      );
    }
    for (final lane in spawned) {
      final node = nodes[lane.id]!;
      final parentId = lane.parentId;
      final parent = (parentId.isEmpty || parentId == 'Coordinator')
          ? null
          : nodes[parentId];
      // Cha không tồn tại hoặc trỏ tới chính nó thì gắn vào gốc để không bị mất
      if (parent == null || identical(parent, node)) {
        root.children.add(node);
      } else {
        parent.children.add(node);
      }
    }
    return root;
  }

  static String _firstLine(String text) {
    final line = text.trim().split('\n').first.trim();
    return line.length > 90 ? '${line.substring(0, 90)}…' : line;
  }

  /// Nhiệm vụ đầu tiên của người dùng trong conversation (hiện làm nhiệm vụ của Coordinator)
  String _userRequest(ConversationSession session) {
    for (final step in session.steps.reversed) {
      if (step.type == 'USER_INPUT' && step.content.trim().isNotEmpty) {
        return step.content.trim();
      }
    }
    return session.title;
  }

  /// Chiều cao cần thiết để vẽ cả nhánh (nút cha và toàn bộ con cháu)
  double _heightOf(_MapNode node) {
    if (node.children.isEmpty) return _cardHeight;
    final childrenBlock = _childrenBlockHeight(node);
    return math.max(_cardHeight, childrenBlock);
  }

  double _childrenBlockHeight(_MapNode node) {
    var total = 0.0;
    for (final child in node.children) {
      total += _heightOf(child);
    }
    return total + _siblingGap * (node.children.length - 1);
  }

  /// Một hàng: nút cha, đường nối, rồi cột các nhánh con (căn giữa theo chiều cao nút cha)
  Widget _buildRow(BuildContext context, _MapNode node) {
    final height = _heightOf(node);
    final card = SizedBox(
      width: _cardWidth,
      height: height,
      child: Center(
        child: _AgentCard(
          node: node,
          onTap: () => _showNodeDetail(context, node),
        ),
      ),
    );
    if (node.children.isEmpty) return card;

    final childHeights = [for (final c in node.children) _heightOf(c)];
    final blockHeight = _childrenBlockHeight(node);
    final blockTop = (height - blockHeight) / 2;
    final childCenters = <double>[];
    var y = blockTop;
    for (final h in childHeights) {
      childCenters.add(y + h / 2);
      y += h + _siblingGap;
    }

    final connectorColor = Theme.of(context).colorScheme.outline;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        card,
        SizedBox(
          width: _connectorWidth,
          height: height,
          child: CustomPaint(
            painter: _BracketPainter(
              parentY: height / 2,
              childYs: childCenters,
              color: connectorColor,
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.only(top: blockTop),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < node.children.length; i++) ...[
                if (i > 0) const SizedBox(height: _siblingGap),
                SizedBox(
                  height: childHeights[i],
                  child: _buildRow(context, node.children[i]),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  String _rootSubtitle(ConversationSession session) {
    // Model máy phụ có tiền tố `peer:` trong app: bỏ để nhãn gọn như máy chính
    final model = remoteModelId(session.contextModel.isNotEmpty
        ? session.contextModel
        : session.selectedModel);
    final modelLabel = model.isEmpty ? 'Chưa rõ model' : _modelLabel(model);
    return '$modelLabel · ${_formatTokens(session.contextTokens)} tokens trong ngữ cảnh';
  }

  String _laneSubtitle(SubagentLane lane) {
    final tokens = lane.steps.fold<int>(
      0,
      (sum, step) => sum + step.inputTokens + step.outputTokens,
    );
    final start = lane.steps.isNotEmpty ? lane.steps.first.createdAt : null;
    final isLive =
        lane.status == AgentStatus.running ||
        lane.status == AgentStatus.waiting;
    final end = isLive
        ? DateTime.now()
        : (lane.lastUpdated ??
              (lane.steps.isNotEmpty ? lane.steps.last.createdAt : null));
    final parts = <String>[];
    if (start != null && end != null) {
      parts.add(_formatDuration(end.difference(start)));
    }
    parts.add('${_formatTokens(tokens)} tokens');
    return parts.join(' · ');
  }

  void _showNodeDetail(BuildContext context, _MapNode node) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => _NodeDetailSheet(node: node),
    );
  }

  void _showHistory(BuildContext context, ConversationSession session) {
    final lanes = session.subagentLanes;
    final entries = <_HistoryEntry>[
      for (final step in session.steps)
        _HistoryEntry(agent: 'Conversation', step: step),
      for (final lane in lanes)
        for (final step in lane.steps)
          _HistoryEntry(
            agent: lane.name.isEmpty ? lane.id : lane.name,
            step: step,
          ),
    ]..sort((a, b) => b.step.createdAt.compareTo(a.step.createdAt));

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => _HistorySheet(entries: entries),
    );
  }
}

class _MapNode {
  _MapNode({
    this.lane,
    required this.title,
    this.detail = '',
    required this.subtitle,
    required this.status,
    this.isRoot = false,
    this.steps = const [],
    this.files = const [],
    this.prompt = '',
  });

  final SubagentLane? lane;
  final String title;

  /// Dòng mô tả: nhiệm vụ được giao (agent) hoặc tiêu đề conversation (gốc)
  final String detail;
  final String subtitle;
  final AgentStatus status;
  final bool isRoot;

  /// Các bước của nút (để hiện bước gần nhất, công cụ đã gọi và lịch sử)
  final List<AgentStep> steps;

  /// Đường dẫn các tệp đã thay đổi
  final List<String> files;

  /// Nhiệm vụ đầy đủ, hiện trong phần chi tiết
  final String prompt;
  final List<_MapNode> children = [];

  int get toolCount => steps.fold<int>(0, (n, s) => n + s.toolCalls.length);
  bool get isRunning => status == AgentStatus.running;
}

class _HistoryEntry {
  const _HistoryEntry({required this.agent, required this.step});

  final String agent;
  final AgentStep step;
}

/// Nút một agent (hoặc gốc Coordinator) trong sơ đồ.
/// Khi đang chạy: chấm có vòng sáng lan ra, viền phát sáng và dòng bước có dấu "..." chạy.
class _AgentCard extends StatefulWidget {
  const _AgentCard({required this.node, required this.onTap});

  final _MapNode node;
  final VoidCallback onTap;

  @override
  State<_AgentCard> createState() => _AgentCardState();
}

class _AgentCardState extends State<_AgentCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void initState() {
    super.initState();
    _syncPulse();
  }

  @override
  void didUpdateWidget(covariant _AgentCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncPulse();
  }

  void _syncPulse() {
    if (widget.node.isRunning) {
      if (!_pulse.isAnimating) _pulse.repeat();
    } else {
      _pulse.stop();
      _pulse.value = 0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final node = widget.node;
    final scheme = Theme.of(context).colorScheme;
    final running = node.isRunning;
    final runColor = context.status.success;
    final dotColor = _statusColor(context, node.status);
    final baseBorder = node.isRoot
        ? scheme.primary.withAlpha(140)
        : scheme.outlineVariant;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      child: AnimatedBuilder(
        animation: _pulse,
        builder: (context, _) {
          final t = _pulse.value;
          final wave = math.sin(t * math.pi); // 0 → 1 → 0 mỗi chu kỳ
          final border = running
              ? (Color.lerp(baseBorder, runColor, 0.3 + 0.5 * wave) ??
                    baseBorder)
              : baseBorder;
          final dots = '.' * (1 + (t * 3).floor().clamp(0, 2));
          return Container(
            width: _cardWidth,
            height: _cardHeight,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            decoration: BoxDecoration(
              color: context.glassCardColor,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: border,
                width: running ? 1.6 : (node.isRoot ? 1.2 : 0.9),
              ),
              boxShadow: running
                  ? [
                      BoxShadow(
                        color: runColor.withAlpha(
                          (30 + 50 * wave).round().clamp(0, 255),
                        ),
                        blurRadius: 12,
                        spreadRadius: 1,
                      ),
                    ]
                  : null,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _StatusDot(color: dotColor, running: running, progress: t),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        node.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: scheme.onSurface,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  _currentStepLine(node, running ? dots : ''),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: running ? runColor : scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  node.subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 5),
                Row(
                  children: [
                    Flexible(
                      child: _InfoChip(
                        icon: Icons.build_outlined,
                        label: '${node.toolCount} công cụ',
                      ),
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: _InfoChip(
                        icon: Icons.description_outlined,
                        label: '${node.files.length} tệp thay đổi',
                      ),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Chấm trạng thái; khi đang chạy có vòng sáng lan ra và mờ dần
class _StatusDot extends StatelessWidget {
  const _StatusDot({
    required this.color,
    required this.running,
    required this.progress,
  });

  final Color color;
  final bool running;
  final double progress;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 18,
      height: 18,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (running)
            Container(
              width: 9 + 9 * progress,
              height: 9 + 9 * progress,
              decoration: BoxDecoration(
                color: color.withAlpha(((1 - progress) * 110).round()),
                shape: BoxShape.circle,
              ),
            ),
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
        ],
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: scheme.outlineVariant.withAlpha(160),
          width: 0.6,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: scheme.onSurfaceVariant),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Dòng bước gần nhất: đang chạy hay đã xong, kèm tên bước
String _currentStepLine(_MapNode node, String dots) {
  if (node.steps.isEmpty) {
    return node.isRunning ? 'Đang khởi động$dots' : 'Chưa có bước nào';
  }
  final last = node.steps.last;
  final title = last.vietnameseTitle.isNotEmpty
      ? last.vietnameseTitle
      : last.content.split('\n').first.trim();
  final label = title.isEmpty ? last.type : title;
  final state = node.isRunning ? 'Đang chạy' : 'Đã xong';
  return 'Bước ${last.stepIndex} · $state: $label$dots';
}

Color _statusColor(BuildContext context, AgentStatus status) {
  switch (status) {
    case AgentStatus.running:
      return context.status.success;
    case AgentStatus.waiting:
      return context.status.warning;
    case AgentStatus.error:
    case AgentStatus.interrupted:
      return context.scheme.error;
    case AgentStatus.completed:
    case AgentStatus.idle:
      return context.scheme.outline;
  }
}

/// Vẽ đường nối từ nút cha sang các nhánh con: ngang từ cha, dọc qua cột, rẽ ngang vào từng con
class _BracketPainter extends CustomPainter {
  const _BracketPainter({
    required this.parentY,
    required this.childYs,
    required this.color,
  });

  final double parentY;
  final List<double> childYs;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color.withAlpha(150)
      ..strokeWidth = 1.2
      ..isAntiAlias = true;
    final ys = [parentY, ...childYs];
    final top = ys.reduce(math.min);
    final bottom = ys.reduce(math.max);
    canvas.drawLine(Offset(0, parentY), Offset(_connectorBend, parentY), paint);
    canvas.drawLine(
      Offset(_connectorBend, top),
      Offset(_connectorBend, bottom),
      paint,
    );
    for (final y in childYs) {
      canvas.drawLine(Offset(_connectorBend, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _BracketPainter oldDelegate) {
    return oldDelegate.parentY != parentY ||
        oldDelegate.color != color ||
        oldDelegate.childYs.length != childYs.length ||
        !_sameOffsets(oldDelegate.childYs, childYs);
  }

  static bool _sameOffsets(List<double> a, List<double> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Chi tiết một agent: nhiệm vụ, file đã sửa và lịch sử bước của agent đó
class _NodeDetailSheet extends StatelessWidget {
  const _NodeDetailSheet({required this.node});

  final _MapNode node;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final steps = node.steps.reversed.toList();
    // Model đang dùng: lấy từ bước gần nhất có ghi model
    final withModel = steps.where((step) => step.model.isNotEmpty);
    final model = withModel.isEmpty ? '' : withModel.first.model;
    final tools = [
      for (final step in node.steps)
        for (final tool in step.toolCalls) (step, tool),
    ].reversed.take(200).toList();
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.85,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
        children: [
          Text(
            node.title,
            style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          if (node.isRoot && node.detail.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              node.detail,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                color: scheme.onSurface.withAlpha(210),
              ),
            ),
          ],
          const SizedBox(height: 4),
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: _statusColor(context, node.status),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                node.status.label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  node.subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          if (model.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              'Model: $model',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: scheme.primary,
              ),
            ),
          ],
          if (node.prompt.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text('Nhiệm vụ', style: _sectionStyle(context)),
            const SizedBox(height: 4),
            Text(
              node.prompt,
              maxLines: 10,
              overflow: TextOverflow.ellipsis,
              style: textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: 14),
          Text(
            'Công cụ đã gọi (${node.toolCount})',
            style: _sectionStyle(context),
          ),
          const SizedBox(height: 6),
          if (tools.isEmpty)
            Text(
              'Chưa gọi công cụ nào.',
              style: TextStyle(color: scheme.onSurfaceVariant),
            )
          else
            for (final (step, tool) in tools)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  '#${step.stepIndex} · ${tool.summaryLabel.isEmpty ? tool.name : tool.summaryLabel}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12.5),
                ),
              ),
          const SizedBox(height: 14),
          Text(
            'Tệp đã thay đổi (${node.files.length})',
            style: _sectionStyle(context),
          ),
          const SizedBox(height: 4),
          if (node.files.isEmpty)
            Text(
              'Chưa thay đổi tệp nào.',
              style: TextStyle(color: scheme.onSurfaceVariant),
            )
          else
            for (final path in node.files.take(60))
              Text(
                path,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontFamily: 'monospace',
                  color: scheme.onSurfaceVariant,
                ),
              ),
          const SizedBox(height: 14),
          Text('Lịch sử (${steps.length} bước)', style: _sectionStyle(context)),
          const SizedBox(height: 6),
          if (steps.isEmpty)
            Text(
              'Chưa có bước nào.',
              style: TextStyle(color: scheme.onSurfaceVariant),
            )
          else
            for (final step in steps) _StepTile(step: step),
        ],
      ),
    );
  }
}

class _HistorySheet extends StatelessWidget {
  const _HistorySheet({required this.entries});

  final List<_HistoryEntry> entries;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.85,
      child: entries.isEmpty
          ? Center(
              child: Text(
                'Chưa có lịch sử.',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
              itemCount: entries.length,
              itemBuilder: (context, index) {
                final entry = entries[index];
                return _StepTile(step: entry.step, agent: entry.agent);
              },
            ),
    );
  }
}

class _StepTile extends StatelessWidget {
  const _StepTile({required this.step, this.agent});

  final AgentStep step;
  final String? agent;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final title = step.vietnameseTitle.isNotEmpty
        ? step.vietnameseTitle
        : step.content.split('\n').first;
    final time = step.createdAt.toLocal();
    final clock =
        '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}:${time.second.toString().padLeft(2, '0')}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 58,
            child: Text(
              clock,
              style: TextStyle(
                fontSize: 11,
                fontFamily: 'monospace',
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (agent != null)
                  Text(
                    agent!,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: scheme.primary,
                    ),
                  ),
                Text(
                  title.isEmpty ? step.type : title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (step.toolCalls.isNotEmpty)
                  Text(
                    step.toolCalls.map((t) => t.name).take(4).join(' · '),
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

TextStyle _sectionStyle(BuildContext context) => TextStyle(
  fontSize: 12,
  fontWeight: FontWeight.w800,
  letterSpacing: 0.3,
  color: Theme.of(context).colorScheme.primary,
);

String _formatDuration(Duration d) {
  final total = d.inSeconds < 0 ? 0 : d.inSeconds;
  if (total < 60) return '${total}s';
  final minutes = total ~/ 60;
  if (minutes < 60) return '${minutes}m ${total % 60}s';
  return '${minutes ~/ 60}h ${minutes % 60}m';
}

String _formatTokens(int tokens) {
  if (tokens < 1000) return '$tokens';
  return '${(tokens / 1000).toStringAsFixed(1)}k';
}

/// Tên model dễ đọc, vd. `claude-cli:claude-opus-5-5` → `Opus 5.5`
String _modelLabel(String id) {
  var name = id;
  if (name.startsWith('claude-cli:')) {
    name = name.substring('claude-cli:'.length);
  }
  if (name.startsWith('agy:')) return name.substring('agy:'.length);
  if (name.startsWith('claude-')) {
    name = name.substring('claude-'.length);
  }
  final parts = name.split('-').where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return id;
  final words = <String>[];
  for (final p in parts) {
    if (int.tryParse(p) != null && words.isNotEmpty) {
      words.add(p);
    } else {
      words.add(p[0].toUpperCase() + p.substring(1));
    }
  }
  // Số phiên bản ghép bằng dấu chấm: Opus 5 5 → Opus 5.5
  final numericStart = words.indexWhere((w) => int.tryParse(w) != null);
  if (numericStart > 0) {
    final head = words.sublist(0, numericStart).join(' ');
    final version = words.sublist(numericStart).join('.');
    return '$head $version';
  }
  return words.join(' ');
}
