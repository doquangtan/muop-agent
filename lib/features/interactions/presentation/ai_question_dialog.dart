import 'package:material_ui/material_ui.dart';

import 'package:muop_agent/core/di/app_dependencies.dart';
import 'package:muop_agent/core/theme/app_theme.dart';
import 'package:muop_agent/features/interactions/domain/interaction_entities.dart';
import 'package:muop_agent/features/interactions/domain/interactions_repository.dart';

class AIQuestionDialog extends StatefulWidget {
  final AIQuestion question;
  final VoidCallback onAnswered;

  const AIQuestionDialog({
    super.key,
    required this.question,
    required this.onAnswered,
  });

  @override
  State<AIQuestionDialog> createState() => _AIQuestionDialogState();
}

class _AIQuestionDialogState extends State<AIQuestionDialog> {
  late TextEditingController _answerController;
  bool _isSubmitting = false;
  final InteractionsRepository _interactionsRepo = AppDependencies.interactions;

  @override
  void initState() {
    super.initState();
    _answerController = TextEditingController(text: widget.question.answer ?? '');
  }

  @override
  void dispose() {
    super.dispose();
  }

  Future<void> _submitAnswer() async {
    if (_answerController.text.trim().isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Vui lòng nhập câu trả lời')),
      );
      return;
    }

    setState(() => _isSubmitting = true);
    final success = await _interactionsRepo.submitAIAnswer(
      widget.question.id,
      _answerController.text.trim(),
    );
    if (!mounted) return;
    setState(() => _isSubmitting = false);

    if (success) {
      widget.onAnswered();
      if (!mounted) return;
      Navigator.of(context).pop();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('✅ Câu trả lời đã được gửi')),
      );
    } else {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('❌ Lỗi khi gửi câu trả lời')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '❓ AI hỏi bạn',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: context.scheme.primary,
              ),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: context.scheme.secondary.withAlpha(36),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: context.scheme.secondary.withAlpha(36)),
              ),
              child: Text(
                widget.question.question,
                style: TextStyle(
                  fontSize: 14,
                  color: context.scheme.onSurface,
                ),
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              'Câu trả lời:',
              style: TextStyle(fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _answerController,
              maxLines: 3,
              decoration: InputDecoration(
                hintText: 'Nhập câu trả lời của bạn...',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                contentPadding: const EdgeInsets.all(12),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _isSubmitting ? null : () => Navigator.of(context).pop(),
                  child: const Text('Huỷ'),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _isSubmitting ? null : _submitAnswer,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: context.scheme.primary,
                  ),
                  child: _isSubmitting
                      ? SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(context.scheme.onPrimary),
                          ),
                        )
                      : const Text('Gửi'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
