import 'dart:convert';
import 'dart:io';

import 'package:muop_agent/core/config/server_config.dart';

/// Gọi REST tới Rust Server. Trả về (mã HTTP, JSON). Mảng JSON được bọc thành `{'items': [...]}`.
Future<(int, Map<String, dynamic>)> restRequest(
  String address,
  String method,
  String path, {
  Map<String, dynamic>? body,
  Duration timeout = const Duration(seconds: 15),
}) async {
  final baseUrl = normalizeBaseUrl(address);
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
  try {
    final uri = Uri.parse('$baseUrl$path');
    final req = method == 'GET'
        ? await client.getUrl(uri)
        : await client.postUrl(uri);
    req.headers.contentType = ContentType.json;
    if (body != null) req.write(jsonEncode(body));
    final resp = await req.close().timeout(timeout);
    final text = await resp.transform(utf8.decoder).join();
    final decoded = text.isEmpty ? <String, dynamic>{} : jsonDecode(text);
    if (decoded is List) {
      return (resp.statusCode, {'items': decoded});
    }
    return (resp.statusCode, Map<String, dynamic>.from(decoded as Map));
  } finally {
    client.close(force: true);
  }
}

/// GET một endpoint JSON; trả null nếu lỗi hoặc không phải 200
Future<Map<String, dynamic>?> restGetJson(String address, String path) async {
  final baseUrl = normalizeBaseUrl(address);
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
  try {
    final req = await client.getUrl(Uri.parse('$baseUrl$path'));
    final resp = await req.close().timeout(const Duration(seconds: 6));
    if (resp.statusCode == 200) {
      final body = await resp.transform(utf8.decoder).join();
      final map = jsonDecode(body);
      if (map is Map) return Map<String, dynamic>.from(map);
    }
  } catch (_) {
  } finally {
    client.close(force: true);
  }
  return null;
}
