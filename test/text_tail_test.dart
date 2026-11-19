import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muop_agent/features/chat/presentation/text_tail.dart';

void main() {
  test(
    'textFromVisualLine trả về đúng phần từ dòng hiển thị được chọn trở đi',
    () {
      final text = List.generate(12, (i) => 'Dòng số ${i + 1}').join('\n');
      const style = TextStyle(fontSize: 14, height: 1.45);
      final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: 400);
      final total = painter.computeLineMetrics().length;
      expect(total, 12);

      final tail = textFromVisualLine(painter, text, total - 5);
      final lines = tail.split('\n');
      expect(lines.first, 'Dòng số 8');
      expect(lines.last, 'Dòng số 12');
      expect(lines.length, 5);
    },
  );

  test('firstLine <= 0 trả về toàn bộ văn bản', () {
    const text = 'a\nb';
    final painter = TextPainter(
      text: const TextSpan(text: text),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: 400);
    expect(textFromVisualLine(painter, text, 0), text);
  });
}
