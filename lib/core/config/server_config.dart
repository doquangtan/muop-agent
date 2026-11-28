/// Cấu hình mặc định và chuẩn hoá địa chỉ của Rust Server
library;

import 'package:flutter/foundation.dart' show kIsWeb;

const int defaultBridgePort = 8787;

/// Địa chỉ server mặc định. Trên web là máy đang phục vụ trang (cổng API 8787 cùng IP),
/// vì web được mở từ máy chủ ở cổng 8788; các nền tảng khác là localhost.
String get defaultHostAddress {
  if (kIsWeb) {
    final host = Uri.base.host;
    if (host.isNotEmpty) return '$host:$defaultBridgePort';
  }
  return 'localhost:$defaultBridgePort';
}

/// Danh sách model ban đầu trước khi có metadata đầu tiên. Model Claude cố định;
/// model Antigravity (`agy:`) lấy động từ server (`agy models`).
/// - `claude-cli:<model-id>` → Claude Code CLI (`claude --model <model-id>`, ID đầy đủ có version)
const List<String> defaultModels = [
  'claude-cli:claude-sonnet-5-5',
  'claude-cli:claude-opus-5-5',
  'claude-cli:claude-haiku-5-5',
];

const List<String> defaultAgents = [
  'Coordinator',
  'erp-server-agent',
  'erp-app-agent',
  'erp-contract-verifier',
];

/// Chuẩn hoá địa chỉ người dùng nhập thành `http://host:port`
String normalizeBaseUrl(String input) {
  var trimmed = input.trim();
  if (trimmed.isEmpty) {
    trimmed = defaultHostAddress;
  }
  if (!trimmed.startsWith('http://') && !trimmed.startsWith('https://')) {
    trimmed = 'http://$trimmed';
  }
  if (trimmed.endsWith('/')) {
    trimmed = trimmed.substring(0, trimmed.length - 1);
  }
  final uri = Uri.tryParse(trimmed);
  if (uri != null && !uri.hasPort) {
    return '${uri.scheme}://${uri.host}:$defaultBridgePort';
  }
  return trimmed;
}
