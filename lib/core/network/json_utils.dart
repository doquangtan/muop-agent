import 'dart:convert';

import 'package:muop_agent/features/chat/domain/chat_entities.dart';

/// Đọc payload socket/HTTP thành Map (chấp nhận Map hoặc chuỗi JSON)
Map<String, dynamic>? asJsonMap(dynamic data) {
  if (data == null) return null;
  if (data is Map<String, dynamic>) return data;
  if (data is Map) return Map<String, dynamic>.from(data);
  if (data is String) {
    final decoded = jsonDecode(data);
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
  }
  return null;
}

/// Đọc map `conversationId → lượt chat` từ payload `activeStreams`
Map<String, ChatTurnStreamState> parseActiveStreams(dynamic raw) {
  final out = <String, ChatTurnStreamState>{};
  if (raw is Map) {
    raw.forEach((k, v) {
      if (v is Map) {
        out['$k'] = ChatTurnStreamState.fromJson(Map<String, dynamic>.from(v));
      }
    });
  }
  return out;
}
