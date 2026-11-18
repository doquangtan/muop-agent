import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'package:muop_agent/core/theme/app_theme.dart';

/// Trình hiển thị tài liệu Markdown hoàn chỉnh (Complete Markdown Document View)
/// Hỗ trợ đầy đủ:
/// - Tiêu đề đa cấp (#, ##, ###, ####)
/// - Sơ đồ Mermaid & Khối mã lệnh (```lang ... ```) với thanh công cụ sao chép & cuộn ngang
/// - Bảng dữ liệu Markdown (| Col 1 | Col 2 |) cuộn ngang mượt mà, định dạng ô chuẩn
/// - Thẻ cảnh báo GitHub Alerts (> [!NOTE], > [!IMPORTANT], > [!WARNING], > [!TIP], > [!CAUTION])
/// - Khối trích dẫn (> Blockquote)
/// - Danh sách công việc Checkbox (- [x], - [ ])
/// - Danh sách gạch đầu dòng & đánh số (- , * , 1. )
/// - Định dạng nội dòng: **in đậm**, *in nghiêng*, `inline code`, [liên kết](url)
class CompleteMarkdownDocView extends StatelessWidget {
  const CompleteMarkdownDocView({
    super.key,
    required this.markdown,
    this.isMobile = false,
    this.onLinkTap,
  });

  final String markdown;
  final bool isMobile;
  final void Function(String url, String label)? onLinkTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final blocks = _parseMarkdown(markdown);

    return SelectionArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (int i = 0; i < blocks.length; i++)
            _buildBlockWidget(context, blocks[i], colorScheme, textTheme),
        ],
      ),
    );
  }

  Widget _buildBlockWidget(
    BuildContext context,
    _DocBlock block,
    ColorScheme colorScheme,
    TextTheme textTheme,
  ) {
    switch (block.kind) {
      case _DocBlockKind.heading:
        return _buildHeading(context, block as _HeadingBlock, colorScheme);

      case _DocBlockKind.code:
        return _buildCodeBlock(context, block as _CodeBlock, colorScheme);

      case _DocBlockKind.table:
        return _buildTable(context, block as _TableBlock, colorScheme);

      case _DocBlockKind.alert:
        return _buildAlert(context, block as _AlertBlock, colorScheme);

      case _DocBlockKind.quote:
        return _buildQuote(context, block as _QuoteBlock, colorScheme);

      case _DocBlockKind.taskItem:
        return _buildTaskItem(context, block as _TaskItemBlock, colorScheme);

      case _DocBlockKind.bullet:
        return _buildBullet(context, block as _BulletBlock, colorScheme);

      case _DocBlockKind.numbered:
        return _buildNumbered(context, block as _NumberedBlock, colorScheme);

      case _DocBlockKind.divider:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Divider(
            height: 1,
            thickness: 1,
            color: colorScheme.outlineVariant.withAlpha(120),
          ),
        );

      case _DocBlockKind.paragraph:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Text.rich(
            TextSpan(
              children: _buildInlineSpans(
                context,
                (block as _ParagraphBlock).text,
                baseStyle: TextStyle(
                  fontSize: isMobile ? 13.5 : 14.0,
                  height: 1.55,
                  color: colorScheme.onSurface,
                ),
                colorScheme: colorScheme,
              ),
            ),
          ),
        );
    }
  }

  // --- 1. Headings ---
  Widget _buildHeading(
    BuildContext context,
    _HeadingBlock block,
    ColorScheme colorScheme,
  ) {
    final double fontSize = block.level == 1
        ? (isMobile ? 18.0 : 20.0)
        : block.level == 2
            ? (isMobile ? 16.0 : 17.5)
            : block.level == 3
                ? (isMobile ? 14.5 : 15.5)
                : (isMobile ? 13.5 : 14.5);

    final isMain = block.level <= 2;

    return Padding(
      padding: EdgeInsets.only(
        top: isMain ? 16 : 10,
        bottom: 6,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                '#' * block.level,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: fontSize * 0.8,
                  fontWeight: FontWeight.w800,
                  color: colorScheme.primary.withAlpha(180),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: _buildInlineSpans(
                      context,
                      block.text,
                      baseStyle: TextStyle(
                        fontSize: fontSize,
                        fontWeight: FontWeight.w800,
                        color: colorScheme.onSurface,
                        height: 1.35,
                      ),
                      colorScheme: colorScheme,
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (block.level == 1) ...[
            const SizedBox(height: 4),
            Container(
              height: 2.5,
              width: 50,
              decoration: BoxDecoration(
                color: colorScheme.primary,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // --- 2. Code Block ---
  Widget _buildCodeBlock(
    BuildContext context,
    _CodeBlock block,
    ColorScheme colorScheme,
  ) {
    final langUpper = block.language.toUpperCase().trim();
    final isMermaid = langUpper == 'MERMAID';
    final lineCount = block.code.split('\n').length;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: context.scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isMermaid
              ? context.scheme.tertiary.withAlpha(120)
              : context.scheme.outlineVariant,
          width: 1,
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 4,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header Bar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: isMermaid
                  ? context.scheme.tertiary.withAlpha(45)
                  : context.scheme.surfaceContainerLow,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(9)),
              border: Border(
                bottom: BorderSide(
                  color: isMermaid
                      ? context.scheme.tertiary.withAlpha(80)
                      : context.scheme.outlineVariant,
                  width: 0.8,
                ),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  isMermaid
                      ? Icons.account_tree_outlined
                      : Icons.code_rounded,
                  size: 14,
                  color: isMermaid ? context.scheme.tertiary : context.scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Text(
                  isMermaid
                      ? 'MERMAID WORKFLOW GRAPH'
                      : (langUpper.isNotEmpty ? langUpper : 'CODE'),
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    color: isMermaid
                        ? context.scheme.tertiary
                        : context.scheme.onSurfaceVariant,
                    letterSpacing: 0.6,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '($lineCount dòng)',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 10,
                    color: context.scheme.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: block.code));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Đã sao chép đoạn mã!'),
                        duration: Duration(seconds: 2),
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                  },
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.copy_rounded,
                          size: 13,
                          color: context.scheme.onSurfaceVariant,
                        ),
                        SizedBox(width: 4),
                        Text(
                          'Sao chép',
                          style: TextStyle(
                            fontSize: 11,
                            color: context.scheme.onSurfaceVariant,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Code body with horizontal scrolling
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(12),
            child: SelectableText(
              block.code,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12.0,
                height: 1.48,
                color: context.scheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // --- 3. Markdown Table ---
  Widget _buildTable(
    BuildContext context,
    _TableBlock block,
    ColorScheme colorScheme,
  ) {
    if (block.headers.isEmpty) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: colorScheme.outlineVariant.withAlpha(120),
          width: 1,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Table(
            defaultVerticalAlignment: TableCellVerticalAlignment.middle,
            defaultColumnWidth: const IntrinsicColumnWidth(),
            border: TableBorder(
              horizontalInside: BorderSide(
                color: colorScheme.outlineVariant.withAlpha(70),
                width: 0.8,
              ),
              verticalInside: BorderSide(
                color: colorScheme.outlineVariant.withAlpha(50),
                width: 0.6,
              ),
            ),
            children: [
              // Header Row
              TableRow(
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest.withAlpha(180),
                ),
                children: [
                  for (int c = 0; c < block.headers.length; c++)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 9,
                      ),
                      child: Text(
                        block.headers[c],
                        textAlign: c < block.alignments.length
                            ? block.alignments[c]
                            : TextAlign.left,
                        style: TextStyle(
                          fontSize: isMobile ? 12.5 : 13.0,
                          fontWeight: FontWeight.w800,
                          color: colorScheme.onSurface,
                        ),
                      ),
                    ),
                ],
              ),
              // Data Rows
              for (int r = 0; r < block.rows.length; r++)
                TableRow(
                  decoration: BoxDecoration(
                    color: r % 2 == 0
                        ? colorScheme.surfaceContainerLow.withAlpha(90)
                        : colorScheme.surfaceContainerLowest,
                  ),
                  children: [
                    for (int c = 0; c < block.headers.length; c++)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 7.5,
                        ),
                        child: c < block.rows[r].length
                            ? _buildTableCellContent(
                                context,
                                block.rows[r][c],
                                c < block.alignments.length
                                    ? block.alignments[c]
                                    : TextAlign.left,
                                colorScheme,
                              )
                            : const SizedBox.shrink(),
                      ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTableCellContent(
    BuildContext context,
    String cellText,
    TextAlign align,
    ColorScheme colorScheme,
  ) {
    final clean = cellText.trim();
    // Phát hiện HTTP Method badge: POST, GET, PUT, DELETE, PATCH
    final methodMatch = RegExp(r'^`?(GET|POST|PUT|DELETE|PATCH)`?$').firstMatch(clean);
    if (methodMatch != null) {
      final method = methodMatch.group(1)!;
      final Color bg;
      final Color fg;
      switch (method) {
        case 'GET':
          bg = context.scheme.secondary.withAlpha(35);
          fg = context.scheme.secondary;
          break;
        case 'POST':
          bg = context.status.success.withAlpha(35);
          fg = context.status.success;
          break;
        case 'PUT':
          bg = context.status.warning.withAlpha(35);
          fg = context.status.warning;
          break;
        case 'DELETE':
          bg = context.scheme.error.withAlpha(35);
          fg = context.scheme.error;
          break;
        default:
          bg = context.scheme.tertiary.withAlpha(35);
          fg = context.scheme.tertiary;
      }
      return Align(
        alignment: Alignment.centerLeft,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: fg.withAlpha(90), width: 0.8),
          ),
          child: Text(
            method,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 11,
              fontWeight: FontWeight.w800,
              color: fg,
            ),
          ),
        ),
      );
    }

    return Text.rich(
      TextSpan(
        children: _buildInlineSpans(
          context,
          cellText,
          baseStyle: TextStyle(
            fontSize: isMobile ? 12.0 : 13.0,
            height: 1.45,
            color: colorScheme.onSurface,
          ),
          colorScheme: colorScheme,
        ),
      ),
      textAlign: align,
    );
  }

  // --- 4. GitHub Alerts ---
  Widget _buildAlert(
    BuildContext context,
    _AlertBlock block,
    ColorScheme colorScheme,
  ) {
    Color accentColor;
    IconData icon;
    String title;

    switch (block.alertKind) {
      case _AlertKind.tip:
        accentColor = context.status.success;
        icon = Icons.lightbulb_outline_rounded;
        title = 'TIP';
        break;
      case _AlertKind.important:
        accentColor = context.scheme.tertiary;
        icon = Icons.priority_high_rounded;
        title = 'IMPORTANT';
        break;
      case _AlertKind.warning:
        accentColor = context.status.warning;
        icon = Icons.warning_amber_rounded;
        title = 'WARNING';
        break;
      case _AlertKind.caution:
        accentColor = context.scheme.error;
        icon = Icons.dangerous_outlined;
        title = 'CAUTION';
        break;
      case _AlertKind.note:
        accentColor = context.scheme.secondary;
        icon = Icons.info_outline_rounded;
        title = 'NOTE';
        break;
    }

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: accentColor.withAlpha(20),
        borderRadius: BorderRadius.circular(8),
        border: Border(
          left: BorderSide(color: accentColor, width: 3.5),
        ),
      ),
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 15, color: accentColor),
              const SizedBox(width: 6),
              Text(
                title,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: accentColor,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Text.rich(
            TextSpan(
              children: _buildInlineSpans(
                context,
                block.content,
                baseStyle: TextStyle(
                  fontSize: isMobile ? 13.0 : 13.5,
                  height: 1.45,
                  color: colorScheme.onSurface,
                ),
                colorScheme: colorScheme,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // --- 5. Blockquote ---
  Widget _buildQuote(
    BuildContext context,
    _QuoteBlock block,
    ColorScheme colorScheme,
  ) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 5),
      padding: const EdgeInsets.fromLTRB(12, 7, 10, 7),
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer.withAlpha(35),
        borderRadius: const BorderRadius.horizontal(right: Radius.circular(6)),
        border: Border(
          left: BorderSide(
            color: colorScheme.primary.withAlpha(210),
            width: 3.5,
          ),
        ),
      ),
      child: Text.rich(
        TextSpan(
          children: _buildInlineSpans(
            context,
            block.text,
            baseStyle: TextStyle(
              fontSize: isMobile ? 13.0 : 13.5,
              fontStyle: FontStyle.italic,
              color: colorScheme.onSurface.withAlpha(225),
              height: 1.45,
            ),
            colorScheme: colorScheme,
          ),
        ),
      ),
    );
  }

  // --- 6. Task Item (Checkbox) ---
  Widget _buildTaskItem(
    BuildContext context,
    _TaskItemBlock block,
    ColorScheme colorScheme,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1.5, right: 8),
            child: Icon(
              block.isChecked
                  ? Icons.check_box_rounded
                  : Icons.check_box_outline_blank_rounded,
              size: 17,
              color: block.isChecked
                  ? context.status.success
                  : colorScheme.onSurfaceVariant.withAlpha(160),
            ),
          ),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: _buildInlineSpans(
                  context,
                  block.text,
                  baseStyle: TextStyle(
                    fontSize: isMobile ? 13.5 : 14.0,
                    height: 1.48,
                    color: block.isChecked
                        ? colorScheme.onSurface.withAlpha(200)
                        : colorScheme.onSurface,
                    decoration: block.isChecked ? TextDecoration.none : null,
                  ),
                  colorScheme: colorScheme,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // --- 7. Bullet List ---
  Widget _buildBullet(
    BuildContext context,
    _BulletBlock block,
    ColorScheme colorScheme,
  ) {
    final indent = block.indent > 2 ? 24.0 : (block.indent > 0 ? 14.0 : 4.0);
    return Padding(
      padding: EdgeInsets.only(left: indent, top: 2.5, bottom: 2.5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 7.5, right: 8),
            child: Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(
                color: colorScheme.primary.withAlpha(200),
                shape: BoxShape.circle,
              ),
            ),
          ),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: _buildInlineSpans(
                  context,
                  block.text,
                  baseStyle: TextStyle(
                    fontSize: isMobile ? 13.5 : 14.0,
                    height: 1.52,
                    color: colorScheme.onSurface,
                  ),
                  colorScheme: colorScheme,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // --- 8. Numbered List ---
  Widget _buildNumbered(
    BuildContext context,
    _NumberedBlock block,
    ColorScheme colorScheme,
  ) {
    final indent = block.indent > 2 ? 22.0 : (block.indent > 0 ? 12.0 : 2.0);
    return Padding(
      padding: EdgeInsets.only(left: indent, top: 3, bottom: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 22,
            child: Text(
              '${block.number}.',
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
                  block.text,
                  baseStyle: TextStyle(
                    fontSize: isMobile ? 13.5 : 14.0,
                    height: 1.52,
                    color: colorScheme.onSurface,
                  ),
                  colorScheme: colorScheme,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // --- Inline Formatting ---
  static final RegExp _inlinePattern = RegExp(
    r'(\[([^\]]+)\]\(([^)]+)\))|(`([^`\n]+)`)|(\*\*([^*]+)\*\*)|(\*([^*]+)\*)',
  );

  List<InlineSpan> _buildInlineSpans(
    BuildContext context,
    String raw, {
    required TextStyle baseStyle,
    required ColorScheme colorScheme,
  }) {
    final spans = <InlineSpan>[];
    int lastIndex = 0;
    for (final match in _inlinePattern.allMatches(raw)) {
      if (match.start > lastIndex) {
        spans.add(TextSpan(
          text: raw.substring(lastIndex, match.start),
          style: baseStyle,
        ));
      }

      if (match.group(1) != null) {
        // Link [label](url)
        final label = match.group(2) ?? '';
        final url = match.group(3) ?? '';
        final isFile = url.startsWith('file://') ||
            url.contains('/') ||
            url.endsWith('.apk') ||
            url.endsWith('.dart') ||
            url.endsWith('.rs') ||
            url.endsWith('.go') ||
            url.endsWith('.md') ||
            url.endsWith('.json');

        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: GestureDetector(
              onTap: () => onLinkTap?.call(url, label),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                margin: const EdgeInsets.symmetric(horizontal: 2),
                decoration: BoxDecoration(
                  color: context.scheme.surfaceContainerHighest.withAlpha(190),
                  borderRadius: BorderRadius.circular(4),
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
                      size: 12,
                      color: context.scheme.primary,
                    ),
                    const SizedBox(width: 3),
                    Text(
                      label,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: context.scheme.primary,
                        decoration: TextDecoration.underline,
                        decorationColor: context.scheme.primary,
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
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 2),
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: context.scheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color: context.scheme.outlineVariant,
                  width: 0.7,
                ),
              ),
              child: Text(
                codeText,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12.0,
                  fontWeight: FontWeight.w600,
                  color: context.status.warning,
                ),
              ),
            ),
          ),
        );
      } else if (match.group(6) != null) {
        // **bold**
        spans.add(TextSpan(
          text: match.group(7) ?? '',
          style: baseStyle.copyWith(fontWeight: FontWeight.w800),
        ));
      } else if (match.group(8) != null) {
        // *italic*
        spans.add(TextSpan(
          text: match.group(9) ?? '',
          style: baseStyle.copyWith(fontStyle: FontStyle.italic),
        ));
      }

      lastIndex = match.end;
    }

    if (lastIndex < raw.length) {
      spans.add(TextSpan(
        text: raw.substring(lastIndex),
        style: baseStyle,
      ));
    }

    return spans;
  }

  // --- Block Parser ---
  static List<_DocBlock> _parseMarkdown(String raw) {
    final lines = raw.split('\n');
    final blocks = <_DocBlock>[];

    int i = 0;
    while (i < lines.length) {
      final line = lines[i];
      final trimmed = line.trim();

      // 1. Fenced Code Block
      if (trimmed.startsWith('```')) {
        final lang = trimmed.substring(3).trim();
        final codeBuffer = StringBuffer();
        i++;
        while (i < lines.length && !lines[i].trim().startsWith('```')) {
          codeBuffer.writeln(lines[i]);
          i++;
        }
        if (i < lines.length) i++; // Bỏ qua dòng đóng ```
        blocks.add(_CodeBlock(language: lang, code: codeBuffer.toString().trimRight()));
        continue;
      }

      // 2. Empty line
      if (trimmed.isEmpty) {
        i++;
        continue;
      }

      // 3. Horizontal Rule
      if (trimmed == '---' || trimmed == '***' || trimmed == '___') {
        blocks.add(const _DocBlock(_DocBlockKind.divider));
        i++;
        continue;
      }

      // 4. GitHub Alert (> [!NOTE])
      final alertMatch = RegExp(r'^>\s*\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\](.*)$', caseSensitive: false).firstMatch(trimmed);
      if (alertMatch != null) {
        final kindStr = alertMatch.group(1)!.toUpperCase();
        _AlertKind alertKind;
        switch (kindStr) {
          case 'TIP':
            alertKind = _AlertKind.tip;
            break;
          case 'IMPORTANT':
            alertKind = _AlertKind.important;
            break;
          case 'WARNING':
            alertKind = _AlertKind.warning;
            break;
          case 'CAUTION':
            alertKind = _AlertKind.caution;
            break;
          default:
            alertKind = _AlertKind.note;
        }
        final alertBuffer = StringBuffer();
        final firstContent = alertMatch.group(2)?.trim() ?? '';
        if (firstContent.isNotEmpty) alertBuffer.writeln(firstContent);
        i++;
        while (i < lines.length && lines[i].trim().startsWith('>')) {
          var lineContent = lines[i].trim().substring(1).trim();
          alertBuffer.writeln(lineContent);
          i++;
        }
        blocks.add(_AlertBlock(alertKind: alertKind, content: alertBuffer.toString().trim()));
        continue;
      }

      // 5. Blockquote
      if (trimmed.startsWith('> ') || trimmed == '>') {
        final quoteBuffer = StringBuffer();
        while (i < lines.length && (lines[i].trim().startsWith('> ') || lines[i].trim() == '>')) {
          var qText = lines[i].trim();
          qText = qText.length > 1 ? qText.substring(1).trim() : '';
          quoteBuffer.writeln(qText);
          i++;
        }
        blocks.add(_QuoteBlock(text: quoteBuffer.toString().trim()));
        continue;
      }

      // 6. Markdown Table (| Col 1 | Col 2 |)
      if (trimmed.startsWith('|') && trimmed.endsWith('|') && trimmed.length > 2) {
        final tableLines = <String>[];
        while (i < lines.length && lines[i].trim().startsWith('|') && lines[i].trim().endsWith('|')) {
          tableLines.add(lines[i].trim());
          i++;
        }
        if (tableLines.length >= 2) {
          final headerCols = tableLines[0]
              .substring(1, tableLines[0].length - 1)
              .split('|')
              .map((c) => c.trim())
              .toList();

          final alignments = <TextAlign>[];
          if (tableLines.length >= 2) {
            final sepCols = tableLines[1]
                .substring(1, tableLines[1].length - 1)
                .split('|')
                .map((c) => c.trim())
                .toList();
            for (final sep in sepCols) {
              if (sep.startsWith(':') && sep.endsWith(':')) {
                alignments.add(TextAlign.center);
              } else if (sep.endsWith(':')) {
                alignments.add(TextAlign.right);
              } else {
                alignments.add(TextAlign.left);
              }
            }
          }

          final dataRows = <List<String>>[];
          for (int r = 2; r < tableLines.length; r++) {
            final rowCols = tableLines[r]
                .substring(1, tableLines[r].length - 1)
                .split('|')
                .map((c) => c.trim())
                .toList();
            dataRows.add(rowCols);
          }

          blocks.add(_TableBlock(
            headers: headerCols,
            rows: dataRows,
            alignments: alignments,
          ));
          continue;
        }
      }

      // 7. Headings (#, ##, ###, ####)
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
        blocks.add(_HeadingBlock(
          level: level,
          text: trimmed.substring(level + 1).trim(),
        ));
        i++;
        continue;
      }

      // 8. Task Item (- [x] hoặc - [ ])
      final taskMatch = RegExp(r'^(\s*)[-*+]\s+\[([ xX])\]\s+(.*)$').firstMatch(line);
      if (taskMatch != null) {
        final isChecked = taskMatch.group(2)?.trim().toLowerCase() == 'x';
        final content = taskMatch.group(3) ?? '';
        blocks.add(_TaskItemBlock(isChecked: isChecked, text: content));
        i++;
        continue;
      }

      // 9. Bullet List (- , * , + )
      final bulletMatch = RegExp(r'^(\s*)([-*•+])\s+(.*)$').firstMatch(line);
      if (bulletMatch != null) {
        final indent = bulletMatch.group(1)?.length ?? 0;
        final content = bulletMatch.group(3) ?? '';
        blocks.add(_BulletBlock(indent: indent, text: content));
        i++;
        continue;
      }

      // 10. Numbered List (1. , 2. )
      final numberMatch = RegExp(r'^(\s*)(\d+)\.\s+(.*)$').firstMatch(line);
      if (numberMatch != null) {
        final indent = numberMatch.group(1)?.length ?? 0;
        final numStr = numberMatch.group(2) ?? '1';
        final content = numberMatch.group(3) ?? '';
        blocks.add(_NumberedBlock(indent: indent, number: numStr, text: content));
        i++;
        continue;
      }

      // 11. Normal Paragraph Line
      blocks.add(_ParagraphBlock(text: line));
      i++;
    }

    return blocks;
  }
}

// --- Data Models for Blocks ---
enum _DocBlockKind {
  heading,
  code,
  table,
  alert,
  quote,
  taskItem,
  bullet,
  numbered,
  divider,
  paragraph,
}

enum _AlertKind {
  note,
  tip,
  important,
  warning,
  caution,
}

class _DocBlock {
  const _DocBlock(this.kind);
  final _DocBlockKind kind;
}

class _HeadingBlock extends _DocBlock {
  const _HeadingBlock({required this.level, required this.text})
      : super(_DocBlockKind.heading);
  final int level;
  final String text;
}

class _CodeBlock extends _DocBlock {
  const _CodeBlock({required this.language, required this.code})
      : super(_DocBlockKind.code);
  final String language;
  final String code;
}

class _TableBlock extends _DocBlock {
  const _TableBlock({
    required this.headers,
    required this.rows,
    required this.alignments,
  }) : super(_DocBlockKind.table);
  final List<String> headers;
  final List<List<String>> rows;
  final List<TextAlign> alignments;
}

class _AlertBlock extends _DocBlock {
  const _AlertBlock({required this.alertKind, required this.content})
      : super(_DocBlockKind.alert);
  final _AlertKind alertKind;
  final String content;
}

class _QuoteBlock extends _DocBlock {
  const _QuoteBlock({required this.text}) : super(_DocBlockKind.quote);
  final String text;
}

class _TaskItemBlock extends _DocBlock {
  const _TaskItemBlock({required this.isChecked, required this.text})
      : super(_DocBlockKind.taskItem);
  final bool isChecked;
  final String text;
}

class _BulletBlock extends _DocBlock {
  const _BulletBlock({required this.indent, required this.text})
      : super(_DocBlockKind.bullet);
  final int indent;
  final String text;
}

class _NumberedBlock extends _DocBlock {
  const _NumberedBlock({
    required this.indent,
    required this.number,
    required this.text,
  }) : super(_DocBlockKind.numbered);
  final int indent;
  final String number;
  final String text;
}

class _ParagraphBlock extends _DocBlock {
  const _ParagraphBlock({required this.text}) : super(_DocBlockKind.paragraph);
  final String text;
}
