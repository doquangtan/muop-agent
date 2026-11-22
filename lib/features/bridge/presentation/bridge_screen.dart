import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'package:muop_agent/core/di/app_dependencies.dart';
import 'package:muop_agent/core/state/server_address_provider.dart';
import 'package:muop_agent/core/theme/app_theme.dart';
import 'package:muop_agent/features/bridge/domain/bridge_entities.dart';
import 'package:muop_agent/features/bridge/domain/bridge_repository.dart';
import 'package:muop_agent/features/interactions/domain/interaction_entities.dart';
import 'package:muop_agent/features/interactions/presentation/interaction_dialogs.dart';
import 'package:muop_agent/features/interactions/presentation/interaction_widgets.dart';

const _defaultModel = 'claude-cli:claude-sonnet-5-5';
const _pollInterval = Duration(seconds: 5);

/// Cầu nối tới máy A: cấu hình địa chỉ máy A và gửi lệnh tới agent trên máy A.
/// Cấu hình được lưu trên server đang kết nối; đổi server thì màn được dựng lại.
class BridgeScreen extends ConsumerWidget {
  const BridgeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final serverAddress = ref.watch(serverAddressProvider);
    return BridgeScreenView(
      key: ValueKey(serverAddress),
      serverAddress: serverAddress,
      repository: AppDependencies.bridge,
    );
  }
}

class BridgeScreenView extends StatefulWidget {
  /// Nhúng vào màn khác (tab Cài đặt): chỉ trả phần thân, không có AppBar/Scaffold riêng
  final bool embedded;

  const BridgeScreenView({
    super.key,
    this.embedded = false,
    required this.serverAddress,
    required this.repository,
  });

  final String serverAddress;
  final BridgeRepository repository;

  @override
  State<BridgeScreenView> createState() => _BridgeScreenState();
}

class _BridgeScreenState extends State<BridgeScreenView> {
  BridgeStatus? _status;
  Timer? _poll;

  final _urlCtrl = TextEditingController();
  final _projectCtrl = TextEditingController();
  final _conversationCtrl = TextEditingController();
  final _modelCtrl = TextEditingController(text: _defaultModel);
  final _promptCtrl = TextEditingController();

  bool _savingPeer = false;
  bool _sending = false;
  String? _peerMessage;
  BridgeSendResult? _lastSend;
  String? _stopMessage;

  /// Sự kiện `bridge:*` từ server (trạng thái, lượt đang chạy, conversation thay đổi)
  StreamSubscription<BridgeEvent>? _eventSub;
  /// Lượt đang chạy trên máy A, theo conversation
  final Map<String, BridgeStreamUpdate> _streams = {};
  /// Conversation gần đây trên máy A, mới nhất đứng đầu (tối đa 10)
  final List<BridgeSessionSummary> _sessions = [];

  PendingClaudeInteraction? _pending;
  String? _pendingError;
  bool _checkingPending = false;
  bool _checkedPending = false;

  @override
  void initState() {
    super.initState();
    _refreshStatus();
    _poll = Timer.periodic(_pollInterval, (_) => _refreshStatus());
    _eventSub = widget.repository.watchEvents().listen(_onEvent);
    // Nút "Dừng lượt" phụ thuộc nội dung ô conversation
    _conversationCtrl.addListener(_onConversationChanged);
  }

  void _onConversationChanged() {
    if (!mounted) return;
    setState(() {
      // Tương tác đang hiện thuộc conversation cũ: bỏ đi, người dùng kiểm tra lại
      final current = _conversationCtrl.text.trim();
      if (_pending != null && _pending!.conversationId != current) {
        _pending = null;
        _checkedPending = false;
      }
    });
  }

  void _onEvent(BridgeEvent event) {
    if (!mounted) return;
    final data = event.data;
    if (data is! Map<String, dynamic>) return;
    switch (event.name) {
      case 'bridge:status':
        setState(() => _status = BridgeStatus.fromJson(data));
      case 'bridge:chat:stream':
        final update = BridgeStreamUpdate.fromJson(data);
        if (update.conversationId.isEmpty) return;
        setState(() {
          if (update.isRunning) {
            _streams[update.conversationId] = update;
          } else {
            _streams.remove(update.conversationId);
          }
        });
      case 'bridge:session:update':
        final summary = BridgeSessionSummary.fromJson(data);
        if (summary.id.isEmpty) return;
        setState(() {
          _sessions.removeWhere((s) => s.id == summary.id);
          _sessions.insert(0, summary);
          if (_sessions.length > 10) _sessions.removeRange(10, _sessions.length);
        });
        // Conversation đang xem thay đổi (có thể vừa xuất hiện tương tác): kiểm tra lại âm thầm
        if (summary.id == _conversationCtrl.text.trim()) {
          _checkPending(silent: true);
        }
    }
  }

  /// Hỏi máy A có tương tác Claude nào đang chờ trong conversation đang nhập
  Future<void> _checkPending({bool silent = false}) async {
    final cid = _conversationCtrl.text.trim();
    if (cid.isEmpty) {
      if (mounted) {
        setState(() {
          _pending = null;
          _pendingError = null;
          _checkedPending = false;
        });
      }
      return;
    }
    if (!silent) setState(() => _checkingPending = true);
    final res = await widget.repository.fetchPendingInteraction(
      widget.serverAddress,
      conversationId: cid,
    );
    if (!mounted) return;
    setState(() {
      _checkingPending = false;
      _checkedPending = true;
      _pending = res.interaction;
      _pendingError = res.error.isEmpty ? null : res.error;
    });
  }

  /// Gửi phản hồi của người dùng tới Claude trên máy A. Trả về null nếu thành công.
  Future<String?> _sendResponse(
    PendingClaudeInteraction interaction,
    String decision,
    List<Map<String, String>> answers,
    String feedback,
  ) async {
    final project = _projectCtrl.text.trim();
    if (project.isEmpty) {
      return 'Nhập thư mục project trên máy A trước khi phản hồi';
    }
    final error = await widget.repository.respondInteraction(
      widget.serverAddress,
      conversationId: interaction.conversationId,
      toolUseId: interaction.toolUseId,
      projectPath: project,
      model: _modelCtrl.text.trim(),
      decision: decision,
      answers: answers,
      feedback: feedback,
    );
    if (!mounted) return error;
    if (error == null) {
      setState(() {
        _pending = null;
        _checkedPending = false;
      });
    }
    return error;
  }

  void _openInteraction(PendingClaudeInteraction interaction) {
    if (interaction.isPlan) {
      showPlanReviewDialog(
        context: context,
        title: 'Kế hoạch từ Claude (máy A)',
        subtitle: 'Claude chưa thực hiện thay đổi nào cho đến khi bạn duyệt',
        markdown: interaction.plan,
        onDecision: (decision, feedback) =>
            _sendResponse(interaction, decision.name, const [], feedback),
      );
    } else {
      showQuestionDialog(
        context: context,
        questions: interaction.questions,
        onSubmit: (answers) => _sendResponse(interaction, '', answers, ''),
      );
    }
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    _poll?.cancel();
    _conversationCtrl.removeListener(_onConversationChanged);
    _urlCtrl.dispose();
    _projectCtrl.dispose();
    _conversationCtrl.dispose();
    _modelCtrl.dispose();
    _promptCtrl.dispose();
    super.dispose();
  }

  Future<void> _refreshStatus() async {
    final res = await widget.repository.fetchStatus(widget.serverAddress);
    if (!mounted) return;
    setState(() {
      _status = res;
      // Lần đầu mở màn: điền sẵn địa chỉ đã lưu trên server
      if (_urlCtrl.text.isEmpty && res.url.isNotEmpty) {
        _urlCtrl.text = res.url;
      }
    });
  }

  Future<void> _savePeer({required bool disconnect}) async {
    final url = disconnect ? '' : _urlCtrl.text.trim();
    setState(() {
      _savingPeer = true;
      _peerMessage = null;
    });
    final res = await widget.repository.setPeer(
      widget.serverAddress,
      url: url,
    );
    if (!mounted) return;
    setState(() {
      _savingPeer = false;
      if (!res.ok) {
        _peerMessage = res.error.isEmpty ? 'Không lưu được địa chỉ máy A' : res.error;
      } else {
        _status = res;
        _urlCtrl.text = res.url;
        if (disconnect) {
          _peerMessage = 'Đã ngắt kết nối máy A';
        } else if (res.registerError.isNotEmpty) {
          _peerMessage = 'Máy phụ chưa đăng ký được: ${res.registerError}';
        } else {
          _peerMessage = 'Đã lưu. Máy phụ đã đăng ký; đang kết nối tới máy A...';
        }
      }
    });
    // Kết nối là bất đồng bộ: hỏi lại sau một lúc để hiện trạng thái thật
    await Future<void>.delayed(const Duration(seconds: 2));
    if (mounted) _refreshStatus();
  }

  Future<void> _send() async {
    final prompt = _promptCtrl.text.trim();
    final project = _projectCtrl.text.trim();
    if (prompt.isEmpty || project.isEmpty) {
      setState(() {
        _lastSend = BridgeSendResult.failure(
          'Cần nhập thư mục project trên máy A và nội dung lệnh',
        );
      });
      return;
    }
    setState(() {
      _sending = true;
      _lastSend = null;
      _stopMessage = null;
    });
    final res = await widget.repository.sendPrompt(
      widget.serverAddress,
      prompt: prompt,
      projectPath: project,
      conversationId: _conversationCtrl.text.trim(),
      model: _modelCtrl.text.trim(),
    );
    if (!mounted) return;
    setState(() {
      _sending = false;
      _lastSend = res;
      if (res.ok) {
        // Điền sẵn conversation để lần gửi sau tiếp tục cùng cuộc trò chuyện
        if (res.conversationId.isNotEmpty) {
          _conversationCtrl.text = res.conversationId;
        }
        _promptCtrl.clear();
      }
    });
  }

  Future<void> _stop() async {
    final cid = _conversationCtrl.text.trim();
    if (cid.isEmpty) return;
    final res = await widget.repository.stopTurn(
      widget.serverAddress,
      conversationId: cid,
    );
    if (!mounted) return;
    setState(() {
      _stopMessage = res.ok
          ? 'Đã gửi lệnh dừng tới máy A'
          : (res.error.isEmpty ? 'Không dừng được lượt' : res.error);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final textTheme = Theme.of(context).textTheme;

    final Widget content = ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        children: [
          Text(
            'Dùng máy này để điều khiển agent trên máy A. Cấu hình lưu trên server đang kết nối '
            '(${widget.serverAddress}).',
            style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          _card(
            context,
            title: 'Kết nối tới máy A',
            children: [
              _statusRow(context),
              const SizedBox(height: 12),
              TextField(
                key: const Key('bridge-url'),
                controller: _urlCtrl,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: 'Địa chỉ máy A',
                  hintText: 'http://IP-máy-A:8787',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              if (_peerMessage != null) ...[
                const SizedBox(height: 8),
                Text(
                  _peerMessage!,
                  key: const Key('bridge-peer-message'),
                  style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    key: const Key('bridge-save'),
                    onPressed: _savingPeer ? null : () => _savePeer(disconnect: false),
                    icon: _savingPeer
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.link_rounded, size: 18),
                    label: const Text('Lưu & kết nối'),
                  ),
                  OutlinedButton.icon(
                    key: const Key('bridge-disconnect'),
                    onPressed: _savingPeer || !(_status?.configured ?? false)
                        ? null
                        : () => _savePeer(disconnect: true),
                    icon: const Icon(Icons.link_off_rounded, size: 18),
                    label: const Text('Ngắt kết nối'),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          _activityCard(context),
          const SizedBox(height: 12),
          _pendingCard(context),
          const SizedBox(height: 12),
          _card(
            context,
            title: 'Gửi lệnh tới agent máy A',
            children: [
              TextField(
                key: const Key('bridge-project'),
                controller: _projectCtrl,
                decoration: const InputDecoration(
                  labelText: 'Thư mục project trên máy A',
                  hintText: '/duong/dan/project',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                key: const Key('bridge-conversation'),
                controller: _conversationCtrl,
                decoration: const InputDecoration(
                  labelText: 'Conversation ID (để trống = cuộc trò chuyện mới)',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                key: const Key('bridge-model'),
                controller: _modelCtrl,
                decoration: const InputDecoration(
                  labelText: 'Model',
                  hintText: 'claude-cli:claude-sonnet-5-5 hoặc agy:<model>',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                key: const Key('bridge-prompt'),
                controller: _promptCtrl,
                minLines: 3,
                maxLines: 8,
                decoration: const InputDecoration(
                  labelText: 'Nội dung lệnh',
                  hintText: 'Máy A sẽ thấy nhãn [Từ máy <tên máy này>] ở đầu lệnh',
                  border: OutlineInputBorder(),
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    key: const Key('bridge-send'),
                    onPressed: _sending ? null : _send,
                    icon: _sending
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send_rounded, size: 18),
                    label: Text(_sending ? 'Đang gửi...' : 'Gửi'),
                  ),
                  OutlinedButton.icon(
                    key: const Key('bridge-stop'),
                    onPressed: _conversationCtrl.text.trim().isEmpty ? null : _stop,
                    icon: const Icon(Icons.stop_rounded, size: 18),
                    label: const Text('Dừng lượt'),
                  ),
                ],
              ),
              if (_lastSend != null) ...[
                const SizedBox(height: 10),
                _sendResult(context, _lastSend!),
              ],
              if (_stopMessage != null) ...[
                const SizedBox(height: 6),
                Text(_stopMessage!, style: textTheme.bodySmall),
              ],
            ],
          ),
        ],
      );
    if (widget.embedded) return content;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Cầu nối máy A'),
        actions: [
          IconButton(
            tooltip: 'Làm mới trạng thái',
            onPressed: _refreshStatus,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: content,
    );
  }

  /// Lượt đang chạy trên máy A và conversation gần đây (bấm để chọn conversation)
  Widget _activityCard(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final scheme = context.scheme;
    final hasAny = _streams.isNotEmpty || _sessions.isNotEmpty;
    return _card(
      context,
      title: 'Hoạt động trên máy A',
      children: [
        if (!hasAny)
          Text(
            'Chưa có hoạt động. Mục này cập nhật khi máy A có lượt đang chạy hoặc conversation thay đổi.',
            style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        for (final s in _streams.values) _streamTile(context, s),
        if (_sessions.isNotEmpty) ...[
          if (_streams.isNotEmpty) const SizedBox(height: 8),
          Text(
            'Gần đây (bấm để chọn conversation)',
            style: textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
          for (final s in _sessions) _sessionTile(context, s),
        ],
      ],
    );
  }

  Widget _streamTile(BuildContext context, BridgeStreamUpdate s) {
    final textTheme = Theme.of(context).textTheme;
    final scheme = context.scheme;
    final text = s.streamingText.trim();
    // Chỉ hiện phần cuối để không dựng lại cả câu trả lời dài
    final tail = text.length > 400 ? '…${text.substring(text.length - 400)}' : text;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        key: Key('bridge-stream-${s.conversationId}'),
        onTap: () => _selectConversation(s.conversationId),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                SizedBox(
                  width: 8,
                  height: 8,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: context.status.success,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Đang chạy: ${s.userPrompt.isEmpty ? s.conversationId : s.userPrompt}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            if (tail.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                tail,
                key: const Key('bridge-stream-text'),
                maxLines: 6,
                overflow: TextOverflow.ellipsis,
                style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _sessionTile(BuildContext context, BridgeSessionSummary s) {
    final textTheme = Theme.of(context).textTheme;
    final scheme = context.scheme;
    return InkWell(
      key: Key('bridge-session-${s.id}'),
      onTap: () => _selectConversation(s.id),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Expanded(
              child: Text(
                s.title.isEmpty ? s.id : s.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.bodyMedium,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              s.status,
              style: textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  void _selectConversation(String cid) {
    _conversationCtrl.text = cid;
    _checkPending();
  }

  /// Tương tác Claude đang chờ trong conversation đã chọn (kiểm tra thủ công hoặc khi có cập nhật)
  Widget _pendingCard(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final scheme = context.scheme;
    final pending = _pending;
    final cid = _conversationCtrl.text.trim();
    return _card(
      context,
      title: 'Tương tác Claude đang chờ',
      children: [
        Text(
          'Claude có thể hỏi bạn hoặc chờ duyệt kế hoạch. Chọn conversation rồi kiểm tra. '
          'Phản hồi cần thư mục project và model ở mục gửi lệnh bên dưới.',
          style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          key: const Key('bridge-check-pending'),
          onPressed: _checkingPending || cid.isEmpty ? null : () => _checkPending(),
          icon: _checkingPending
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.search_rounded, size: 18),
          label: const Text('Kiểm tra'),
        ),
        if (_pendingError != null) ...[
          const SizedBox(height: 8),
          Text(
            _pendingError!,
            key: const Key('bridge-pending-error'),
            style: textTheme.bodySmall?.copyWith(color: scheme.error),
          ),
        ],
        if (pending != null) ...[
          const SizedBox(height: 10),
          InteractionBanner(
            key: const Key('bridge-pending-banner'),
            icon: pending.isPlan
                ? Icons.assignment_outlined
                : Icons.help_outline_rounded,
            title: pending.isPlan
                ? 'Claude đã trình kế hoạch, chờ bạn duyệt'
                : 'Claude đang chờ bạn trả lời',
            subtitle: pending.summary,
            actionLabel: pending.isPlan ? 'Xem & duyệt' : 'Trả lời',
            onAction: () => _openInteraction(pending),
          ),
        ] else if (_checkedPending && _pendingError == null) ...[
          const SizedBox(height: 8),
          Text(
            'Không có tương tác đang chờ trong conversation này.',
            key: const Key('bridge-no-pending'),
            style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ],
    );
  }

  Widget _card(
    BuildContext context, {
    required String title,
    required List<Widget> children,
  }) {
    final textTheme = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _statusRow(BuildContext context) {
    final scheme = context.scheme;
    final status = _status;
    final textTheme = Theme.of(context).textTheme;

    if (status == null) {
      return Row(
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
          Text('Đang kiểm tra...', style: textTheme.bodyMedium),
        ],
      );
    }

    final String label;
    final IconData icon;
    final Color color;
    if (!status.ok) {
      label = status.error.isEmpty ? 'Không lấy được trạng thái' : status.error;
      icon = Icons.error_outline_rounded;
      color = scheme.error;
    } else if (!status.configured) {
      label = 'Chưa cấu hình. Nhập địa chỉ máy A rồi bấm Lưu & kết nối.';
      icon = Icons.link_off_rounded;
      color = scheme.onSurfaceVariant;
    } else if (status.connected) {
      label = 'Đã kết nối tới ${status.url}';
      icon = Icons.check_circle_rounded;
      color = context.status.success;
    } else {
      label = status.error.isEmpty
          ? 'Đang kết nối tới ${status.url}...'
          : 'Chưa kết nối tới ${status.url}: ${status.error}';
      icon = Icons.sync_problem_rounded;
      color = scheme.error;
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            label,
            key: const Key('bridge-status-text'),
            style: textTheme.bodyMedium?.copyWith(color: color),
          ),
        ),
      ],
    );
  }

  Widget _sendResult(BuildContext context, BridgeSendResult res) {
    final scheme = context.scheme;
    final textTheme = Theme.of(context).textTheme;
    final color = res.ok ? context.status.success : scheme.error;
    final text = res.ok
        ? 'Đã gửi tới máy A. Conversation: ${res.conversationId}'
            '${res.source.isEmpty ? '' : ' (${res.source})'}'
        : (res.error.isEmpty ? 'Gửi thất bại' : res.error);
    return Text(
      text,
      key: const Key('bridge-send-result'),
      style: textTheme.bodySmall?.copyWith(color: color),
    );
  }
}
