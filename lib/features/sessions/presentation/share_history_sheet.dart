import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'package:muop_agent/core/theme/app_theme.dart';
import 'package:muop_agent/core/widgets/throttled_spinner.dart';
import 'package:muop_agent/features/bridge/domain/peer_models.dart';
import 'package:muop_agent/features/chat/domain/model_groups.dart';
import 'package:muop_agent/features/sessions/domain/session_share.dart';

/// Conversation có thể nhận link chia sẻ
class ShareTargetConversation {
  const ShareTargetConversation({
    required this.id,
    required this.title,
    required this.model,
  });

  final String id;
  final String title;

  /// Model sẽ dùng khi gửi vào conversation này (model đã dùng gần nhất)
  final String model;
}

/// Kết quả người dùng chọn trong bảng chia sẻ
class ShareSendRequest {
  const ShareSendRequest({
    required this.conversationId,
    required this.model,
    required this.prompt,
  });

  /// Rỗng = tạo conversation mới trong cùng project
  final String conversationId;
  final String model;
  final String prompt;
}

/// Mở bảng chia sẻ lịch sử. Trả về lựa chọn gửi, hoặc null nếu người dùng đóng.
Future<ShareSendRequest?> showShareHistorySheet({
  required BuildContext context,
  required String shareUrl,
  required Future<SessionSharePage?> Function() loadFirstPage,
  required List<ShareTargetConversation> conversations,
  required List<String> availableModels,
  required Map<String, String> modelLabels,
  required List<String> effortLevels,
  required String defaultModel,
  required int fromStep,
}) {
  return showModalBottomSheet<ShareSendRequest>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    constraints: const BoxConstraints(maxWidth: 600),
    builder: (_) => ShareHistorySheet(
      shareUrl: shareUrl,
      loadFirstPage: loadFirstPage,
      conversations: conversations,
      availableModels: availableModels,
      modelLabels: modelLabels,
      effortLevels: effortLevels,
      defaultModel: defaultModel,
      fromStep: fromStep,
    ),
  );
}

enum _ShareMode { existing, fresh }

class ShareHistorySheet extends StatefulWidget {
  const ShareHistorySheet({
    super.key,
    required this.shareUrl,
    required this.loadFirstPage,
    required this.conversations,
    required this.availableModels,
    required this.modelLabels,
    required this.effortLevels,
    required this.defaultModel,
    required this.fromStep,
  });

  final String shareUrl;
  final Future<SessionSharePage?> Function() loadFirstPage;
  final List<ShareTargetConversation> conversations;
  final List<String> availableModels;
  final Map<String, String> modelLabels;
  final List<String> effortLevels;
  final String defaultModel;
  final int fromStep;

  @override
  State<ShareHistorySheet> createState() => _ShareHistorySheetState();
}

class _ShareHistorySheetState extends State<ShareHistorySheet> {
  final TextEditingController _promptController = TextEditingController();
  SessionSharePage? _page;
  bool _loading = true;
  bool _promptEdited = false;
  late _ShareMode _mode;
  String? _conversationId;
  late String _model;

  @override
  void initState() {
    super.initState();
    _mode = widget.conversations.isEmpty
        ? _ShareMode.fresh
        : _ShareMode.existing;
    _conversationId = widget.conversations.firstOrNull?.id;
    _model = widget.availableModels.contains(widget.defaultModel)
        ? widget.defaultModel
        : (widget.availableModels.firstOrNull ?? widget.defaultModel);
    _promptController.addListener(() {
      if (_promptController.text != _generatedPrompt()) _promptEdited = true;
    });
    _load();
  }

  @override
  void dispose() {
    _promptController.dispose();
    super.dispose();
  }

  String _generatedPrompt() => buildSharePrompt(
    url: widget.shareUrl,
    totalPages: _page?.totalPages ?? 0,
  );

  Future<void> _load() async {
    setState(() => _loading = true);
    final page = await widget.loadFirstPage();
    if (!mounted) return;
    setState(() {
      _page = page;
      _loading = false;
      if (page != null && !_promptEdited) {
        _promptController.text = _generatedPrompt();
        _promptEdited = false;
      }
    });
  }

  ShareTargetConversation? get _selectedConversation => widget
      .conversations
      .where((c) => c.id == _conversationId)
      .firstOrNull;

  bool get _canSend =>
      _page != null &&
      _promptController.text.trim().isNotEmpty &&
      (_mode == _ShareMode.fresh
          ? _model.isNotEmpty
          : _selectedConversation != null);

  void _send() {
    final existing = _mode == _ShareMode.existing
        ? _selectedConversation
        : null;
    Navigator.of(context).pop(
      ShareSendRequest(
        conversationId: existing?.id ?? '',
        model: existing?.model.isNotEmpty == true ? existing!.model : _model,
        prompt: _promptController.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final textTheme = Theme.of(context).textTheme;
    final page = _page;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.ios_share_rounded, size: 20, color: scheme.primary),
                const SizedBox(width: 8),
                Text(
                  'Chia sẻ lịch sử',
                  style: textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            _buildSummary(textTheme, scheme, page),
            const SizedBox(height: 10),
            _buildLinkBox(textTheme, scheme),
            const SizedBox(height: 16),
            SegmentedButton<_ShareMode>(
              key: const Key('share-mode'),
              segments: [
                ButtonSegment(
                  value: _ShareMode.existing,
                  enabled: widget.conversations.isNotEmpty,
                  icon: const Icon(Icons.forum_outlined, size: 16),
                  label: const Text('Conversation hiện có'),
                ),
                const ButtonSegment(
                  value: _ShareMode.fresh,
                  icon: Icon(Icons.add_comment_outlined, size: 16),
                  label: Text('Conversation mới'),
                ),
              ],
              selected: {_mode},
              onSelectionChanged: (s) => setState(() => _mode = s.first),
            ),
            const SizedBox(height: 12),
            if (_mode == _ShareMode.existing)
              _buildExistingPicker()
            else
              _buildModelPicker(textTheme, scheme),
            const SizedBox(height: 12),
            TextField(
              key: const Key('share-prompt'),
              controller: _promptController,
              minLines: 3,
              maxLines: 6,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Nội dung gửi cho agent',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Hủy'),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  key: const Key('share-send'),
                  onPressed: _canSend ? _send : null,
                  icon: const Icon(Icons.send_rounded, size: 16),
                  label: Text(
                    _mode == _ShareMode.existing
                        ? 'Gửi vào conversation'
                        : 'Tạo conversation mới',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSummary(TextTheme textTheme, ColorScheme scheme, page) {
    if (_loading) {
      return Row(
        children: [
          const ThrottledSpinner(size: 12),
          const SizedBox(width: 8),
          Text('Đang kiểm tra link...', style: textTheme.bodySmall),
        ],
      );
    }
    if (page == null) {
      return Row(
        children: [
          Expanded(
            child: Text(
              'Không đọc được lịch sử từ server.',
              style: textTheme.bodySmall?.copyWith(color: scheme.error),
            ),
          ),
          TextButton(onPressed: _load, child: const Text('Thử lại')),
        ],
      );
    }
    return Text(
      'Từ bước #${widget.fromStep} đến tin mới nhất · ${page.totalPages} trang '
      '(${page.pageSize} bước/trang)',
      style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
    );
  }

  Widget _buildLinkBox(TextTheme textTheme, ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Expanded(
            child: SelectableText(
              widget.shareUrl,
              key: const Key('share-url'),
              maxLines: 2,
              style: textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
            ),
          ),
          IconButton(
            tooltip: 'Sao chép link',
            icon: const Icon(Icons.copy_rounded, size: 18),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: widget.shareUrl));
              if (!mounted) return;
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('Đã sao chép link')));
            },
          ),
        ],
      ),
    );
  }

  Widget _buildExistingPicker() {
    return DropdownButtonFormField<String>(
      key: const Key('share-conversation'),
      initialValue: _conversationId,
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: 'Conversation (cùng project)',
        border: OutlineInputBorder(),
      ),
      items: [
        for (final c in widget.conversations)
          DropdownMenuItem(
            value: c.id,
            child: Text(
              c.title.isEmpty ? c.id : c.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: (v) => setState(() => _conversationId = v),
    );
  }

  Widget _buildModelPicker(TextTheme textTheme, ColorScheme scheme) {
    final levels = resolveEffortLevels(widget.effortLevels);
    final groups = groupModels(
      widget.availableModels,
      widget.modelLabels,
      effortLevels: levels,
    );
    final current = groups
        .where((g) => g.options.any((o) => o.id == _model))
        .firstOrNull;
    final currentEffort = current?.options
        .where((o) => o.id == _model)
        .firstOrNull
        ?.effort;
    String groupLabel(ModelGroup g) =>
        isPeerModel(g.id) ? '${g.label} (máy phụ)' : g.label;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: 3,
          child: DropdownButtonFormField<String>(
            key: const Key('share-model'),
            initialValue: current?.id,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Model',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final g in groups)
                DropdownMenuItem(
                  value: g.id,
                  child: Text(
                    groupLabel(g),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (id) {
              if (id == null) return;
              final group = groups.firstWhere((g) => g.id == id);
              setState(
                () => _model = group
                    .preferredOption(currentEffort: currentEffort)
                    .id,
              );
            },
          ),
        ),
        if (current != null && current.hasEffortChoices) ...[
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: DropdownButtonFormField<String>(
              key: ValueKey('share-effort-${current.id}'),
              initialValue: _model,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Mức suy luận',
                border: OutlineInputBorder(),
              ),
              items: [
                for (final o in current.options)
                  DropdownMenuItem(
                    value: o.id,
                    child: Text(ModelGroup.effortLabel(o.effort ?? '—')),
                  ),
              ],
              onChanged: (id) {
                if (id != null) setState(() => _model = id);
              },
            ),
          ),
        ],
      ],
    );
  }
}
