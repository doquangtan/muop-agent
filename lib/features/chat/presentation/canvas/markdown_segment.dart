part of '../chat_canvas_view.dart';

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
            padding: EdgeInsets.only(top: level <= 2 ? 12 : 8, bottom: 4),
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
              borderRadius: const BorderRadius.horizontal(
                right: Radius.circular(6),
              ),
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
        final double indent = (indentSpaces > 2
            ? 24.0
            : (indentSpaces > 0 ? 14.0 : 4.0));

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
        final double indent = (indentSpaces > 2
            ? 22.0
            : (indentSpaces > 0 ? 12.0 : 2.0));

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
        spans.add(
          TextSpan(
            text: raw.substring(lastIndex, match.start),
            style: baseStyle,
          ),
        );
      }

      if (match.group(1) != null) {
        // Link [label](url)
        final label = match.group(2) ?? '';
        final url = match.group(3) ?? '';
        final isFile =
            url.startsWith('file://') ||
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
                padding: const EdgeInsets.symmetric(
                  horizontal: 5.5,
                  vertical: 1.5,
                ),
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
                    // Tên tệp dài được cắt bằng "…" thay vì làm tràn khung
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12.0,
                          fontWeight: FontWeight.w600,
                          color: context.scheme.primary,
                          decoration: TextDecoration.underline,
                          decorationColor: context.scheme.primary,
                        ),
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
        final maxCodeWidth = (screenWidth - (isMobile ? 80 : 180)).clamp(
          160.0,
          720.0,
        );

        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 2),
              padding: const EdgeInsets.symmetric(
                horizontal: 5.5,
                vertical: 1.5,
              ),
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
        spans.add(
          TextSpan(
            text: boldText,
            style: baseStyle.copyWith(
              fontWeight: FontWeight.w700,
              color: context.scheme.onPrimary,
            ),
          ),
        );
      } else if (match.group(8) != null) {
        // Italic *text*
        final italicText = match.group(9) ?? '';
        spans.add(
          TextSpan(
            text: italicText,
            style: baseStyle.copyWith(
              fontStyle: FontStyle.italic,
              color: context.scheme.onSurfaceVariant,
            ),
          ),
        );
      }

      lastIndex = match.end;
    }

    if (lastIndex < raw.length) {
      spans.add(TextSpan(text: raw.substring(lastIndex), style: baseStyle));
    }

    return spans;
  }
}
