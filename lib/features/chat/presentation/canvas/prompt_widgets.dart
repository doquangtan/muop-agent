part of '../chat_canvas_view.dart';

/// Khung hiển thị Prompt người dùng có thể cuộn độc lập (khi prompt dài)
class _ScrollablePromptBox extends StatefulWidget {
  const _ScrollablePromptBox({required this.prompt, required this.maxHeight});

  final String prompt;
  final double maxHeight;

  @override
  State<_ScrollablePromptBox> createState() => _ScrollablePromptBoxState();
}

class _ScrollablePromptBoxState extends State<_ScrollablePromptBox> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
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
        border: Border.all(color: colorScheme.outlineVariant.withAlpha(60)),
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
