import 'package:material_ui/material_ui.dart';

import 'package:muop_agent/core/widgets/complete_markdown_doc_view.dart';
import 'package:muop_agent/features/interactions/domain/interaction_entities.dart';
import 'package:muop_agent/features/interactions/presentation/interaction_widgets.dart';

const String _otherKey = '__other__';

enum PlanDecision { approve, cancel, feedback }

Future<void> showPlanReviewDialog({
  required BuildContext context,
  required String title,
  required String subtitle,
  required String markdown,
  required Future<String?> Function(PlanDecision decision, String feedback)
      onDecision,
}) {
  return _showInteractionDialog(
    context,
    _PlanReviewBody(
      title: title,
      subtitle: subtitle,
      markdown: markdown,
      onDecision: onDecision,
    ),
  );
}

Future<void> showQuestionDialog({
  required BuildContext context,
  required List<ClaudeQuestionItem> questions,
  required Future<String?> Function(List<Map<String, String>> answers) onSubmit,
}) {
  return _showInteractionDialog(
    context,
    _QuestionForm(questions: questions, onSubmit: onSubmit),
  );
}

Future<void> _showInteractionDialog(BuildContext context, Widget child) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      insetPadding: const EdgeInsets.all(20),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 720),
        child: child,
      ),
    ),
  );
}

class _PlanReviewBody extends StatefulWidget {
  final String title;
  final String subtitle;
  final String markdown;
  final Future<String?> Function(PlanDecision decision, String feedback)
      onDecision;

  const _PlanReviewBody({
    required this.title,
    required this.subtitle,
    required this.markdown,
    required this.onDecision,
  });

  @override
  State<_PlanReviewBody> createState() => _PlanReviewBodyState();
}

class _PlanReviewBodyState extends State<_PlanReviewBody> {
  final TextEditingController _feedbackController = TextEditingController();
  bool _submitting = false;
  PlanDecision? _active;
  String? _error;

  @override
  void dispose() {
    super.dispose();
  }

  Future<void> _send(PlanDecision decision, String feedback) async {
    setState(() {
      _submitting = true;
      _active = decision;
      _error = null;
    });
    final error = await widget.onDecision(decision, feedback);
    if (!mounted) return;
    if (error == null) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _submitting = false;
      _active = null;
      _error = error;
    });
  }

  bool _busy(PlanDecision decision) => _submitting && _active == decision;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final hasFeedback = _feedbackController.text.trim().isNotEmpty;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InteractionDialogHeader(
          icon: Icons.assignment_outlined,
          title: widget.title,
          subtitle: widget.subtitle,
        ),
        const Divider(height: 1),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: CompleteMarkdownDocView(
              markdown: widget.markdown.trim().isEmpty
                  ? '*Không có nội dung chi tiết.*'
                  : widget.markdown,
            ),
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _feedbackController,
                enabled: !_submitting,
                minLines: 1,
                maxLines: 3,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'Góp ý để sửa kế hoạch (tùy chọn)',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: textTheme.bodySmall?.copyWith(color: scheme.error),
                ),
              ],
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: scheme.error,
                      ),
                      onPressed: _submitting
                          ? null
                          : () => _send(PlanDecision.cancel, ''),
                      child: _busy(PlanDecision.cancel)
                          ? const _Spinner()
                          : const Text('Hủy plan'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: !_submitting && hasFeedback
                          ? () => _send(
                                PlanDecision.feedback,
                                _feedbackController.text.trim(),
                              )
                          : null,
                      child: _busy(PlanDecision.feedback)
                          ? const _Spinner()
                          : const Text('Gửi góp ý'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      onPressed: _submitting
                          ? null
                          : () => _send(PlanDecision.approve, ''),
                      child: _busy(PlanDecision.approve)
                          ? const _Spinner()
                          : const Text('Duyệt kế hoạch'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      width: 18,
      height: 18,
      child: CircularProgressIndicator(strokeWidth: 2),
    );
  }
}

class _QuestionForm extends StatefulWidget {
  final List<ClaudeQuestionItem> questions;
  final Future<String?> Function(List<Map<String, String>> answers) onSubmit;

  const _QuestionForm({required this.questions, required this.onSubmit});

  @override
  State<_QuestionForm> createState() => _QuestionFormState();
}

class _QuestionFormState extends State<_QuestionForm> {
  final Map<int, Set<String>> _selected = {};
  final Map<int, TextEditingController> _custom = {};
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    for (var i = 0; i < widget.questions.length; i++) {
      _custom[i] = TextEditingController();
    }
  }

  @override
  void dispose() {
    for (final controller in _custom.values) {
      controller.dispose();
    }
    super.dispose();
  }

  String? _answerFor(int index) {
    final question = widget.questions[index];
    final picked = _selected[index] ?? const <String>{};
    final parts = <String>[
      for (final option in question.options)
        if (picked.contains(option.label)) option.label,
    ];
    if (picked.contains(_otherKey)) {
      final text = _custom[index]!.text.trim();
      if (text.isEmpty) return null;
      parts.add(text);
    }
    return parts.isEmpty ? null : parts.join(', ');
  }

  void _toggle(int index, String key, bool multiSelect) {
    setState(() {
      final picked = _selected.putIfAbsent(index, () => <String>{});
      if (multiSelect) {
        if (picked.contains(key)) {
          picked.remove(key);
        } else {
          picked.add(key);
        }
      } else {
        final wasSelected = picked.contains(key);
        picked.clear();
        if (!wasSelected) picked.add(key);
      }
      _error = null;
    });
  }

  Future<void> _submit() async {
    final answers = <Map<String, String>>[];
    for (var i = 0; i < widget.questions.length; i++) {
      final answer = _answerFor(i);
      if (answer == null) return;
      answers.add({'question': widget.questions[i].question, 'answer': answer});
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    final error = await widget.onSubmit(answers);
    if (!mounted) return;
    if (error == null) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _submitting = false;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final canSubmit = !_submitting &&
        List.generate(widget.questions.length, _answerFor)
            .every((answer) => answer != null);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const InteractionDialogHeader(
          icon: Icons.help_outline_rounded,
          title: 'Claude đang chờ bạn trả lời',
        ),
        const Divider(height: 1),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < widget.questions.length; i++) ...[
                  if (i > 0) const SizedBox(height: 16),
                  _buildQuestion(context, i, widget.questions[i]),
                ],
              ],
            ),
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_error != null) ...[
                Text(
                  _error!,
                  style: textTheme.bodySmall?.copyWith(color: scheme.error),
                ),
                const SizedBox(height: 8),
              ],
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed: canSubmit ? _submit : null,
                  child: _submitting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Gửi trả lời'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildQuestion(
    BuildContext context,
    int index,
    ClaudeQuestionItem question,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final picked = _selected[index] ?? const <String>{};
    final otherSelected = picked.contains(_otherKey);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (question.header.isNotEmpty) ...[
          Text(
            question.header.toUpperCase(),
            style: textTheme.labelSmall?.copyWith(
              color: scheme.primary,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
            ),
          ),
          const SizedBox(height: 2),
        ],
        Text(
          question.question,
          style: textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
            color: scheme.onSurface,
          ),
        ),
        const SizedBox(height: 8),
        for (final option in question.options)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: _OptionTile(
              label: option.label,
              description: option.description,
              multiSelect: question.multiSelect,
              selected: picked.contains(option.label),
              enabled: !_submitting,
              onTap: () => _toggle(index, option.label, question.multiSelect),
            ),
          ),
        _OptionTile(
          label: 'Khác',
          description: 'Tự nhập câu trả lời',
          multiSelect: question.multiSelect,
          selected: otherSelected,
          enabled: !_submitting,
          onTap: () => _toggle(index, _otherKey, question.multiSelect),
        ),
        if (otherSelected)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: TextField(
              controller: _custom[index],
              enabled: !_submitting,
              minLines: 1,
              maxLines: 3,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Nhập câu trả lời...',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _OptionTile extends StatelessWidget {
  final String label;
  final String description;
  final bool multiSelect;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  const _OptionTile({
    required this.label,
    this.description = '',
    required this.multiSelect,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final icon = multiSelect
        ? (selected ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded)
        : (selected ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded);

    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(10),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? scheme.primary.withAlpha(28) : scheme.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected ? scheme.primary : scheme.outlineVariant.withAlpha(120),
              width: selected ? 1.2 : 0.8,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                icon,
                size: 18,
                color: selected ? scheme.primary : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurface,
                      ),
                    ),
                    if (description.isNotEmpty)
                      Text(
                        description,
                        style: textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
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
  }
}
