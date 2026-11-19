import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:muop_agent/features/chat/domain/chat_entities.dart';
import 'package:muop_agent/features/sessions/domain/session_entities.dart';

void main() {
  test('ảnh đính kèm được mã hoá base64 đúng khi gửi lên server', () {
    final bytes = Uint8List.fromList([137, 80, 78, 71]);
    final image = ChatImageAttachment(
      name: 'chup.png',
      mimeType: 'image/png',
      bytes: bytes,
    );

    final json = image.toJson();

    expect(json['name'], 'chup.png');
    expect(json['mimeType'], 'image/png');
    expect(base64Decode(json['dataBase64'] as String), bytes);
  });

  test('bước người dùng đọc được imageCount, mặc định 0 khi server không gửi', () {
    final withImages = AgentStep.fromJson({
      'stepIndex': 4,
      'type': 'USER_INPUT',
      'content': 'Ảnh này là gì?',
      'imageCount': 2,
    });
    final withoutField = AgentStep.fromJson({
      'stepIndex': 5,
      'type': 'USER_INPUT',
      'content': 'Chỉ chữ',
    });

    expect(withImages.imageCount, 2);
    expect(withoutField.imageCount, 0);
    expect(withImages.toJson()['imageCount'], 2);
  });
}
