import 'package:flutter/painting.dart';

/// Phần văn bản bắt đầu từ dòng hiển thị thứ [firstLine] (đếm từ 0) của [painter] đã layout.
String textFromVisualLine(TextPainter painter, String text, int firstLine) {
  if (firstLine <= 0) return text;
  final metrics = painter.computeLineMetrics();
  if (firstLine >= metrics.length) return text;
  final line = metrics[firstLine];
  // Đỉnh của dòng = baseline - ascent; lấy vị trí ký tự tại mép trên của dòng
  final top = line.baseline - line.ascent;
  final position = painter.getPositionForOffset(Offset(0, top + 1));
  final offset = position.offset.clamp(0, text.length).toInt();
  return text.substring(offset);
}
