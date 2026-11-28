import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'package:muop_agent/core/config/server_config.dart';

/// Phản hồi HTTP tối thiểu (mã trạng thái + thân nhị phân). Dùng `package:http` nên chạy được cả trên web.
class HttpReply {
  const HttpReply(this.status, this.bytes, [this.headers = const {}]);

  final int status;
  final Uint8List bytes;

  /// Header phản hồi, tên viết thường (ví dụ `x-frame-seq`)
  final Map<String, String> headers;

  /// Thân dạng UTF-8. Không dùng `Response.body` của package:http vì nó đọc theo latin1 khi thiếu charset.
  String get text => utf8.decode(bytes, allowMalformed: true);
}

final http.Client _httpClient = http.Client();

/// Gọi HTTP tới Rust Server. [json] (nếu có) được gửi làm thân JSON. [timeout] áp cho cả lượt
/// (kết nối, gửi và đọc hết thân). Ném lỗi khi mạng lỗi hoặc quá thời gian.
Future<HttpReply> httpRequest(
  String method,
  Uri uri, {
  Object? json,
  Duration timeout = const Duration(seconds: 15),
}) async {
  final req = http.Request(method, uri);
  if (json != null) {
    req.headers['content-type'] = 'application/json; charset=utf-8';
    req.bodyBytes = utf8.encode(jsonEncode(json));
  }
  final streamed = await _httpClient.send(req).timeout(timeout);
  final resp = await http.Response.fromStream(streamed).timeout(timeout);
  final headers = {
    for (final e in resp.headers.entries) e.key.toLowerCase(): e.value,
  };
  return HttpReply(resp.statusCode, resp.bodyBytes, headers);
}

/// Mở luồng GET (dùng để tải file theo khối). Chỉ phần đầu có thời hạn; thân được đọc theo luồng.
Future<http.StreamedResponse> httpOpenStream(Uri uri) =>
    _httpClient.send(http.Request('GET', uri));

/// Gọi REST tới Rust Server. Trả về (mã HTTP, JSON). Mảng JSON được bọc thành `{'items': [...]}`.
Future<(int, Map<String, dynamic>)> restRequest(
  String address,
  String method,
  String path, {
  Map<String, dynamic>? body,
  Duration timeout = const Duration(seconds: 15),
}) async {
  final baseUrl = normalizeBaseUrl(address);
  final reply = await httpRequest(
    method,
    Uri.parse('$baseUrl$path'),
    json: body,
    timeout: timeout,
  );
  final decoded = reply.text.isEmpty ? <String, dynamic>{} : jsonDecode(reply.text);
  if (decoded is List) {
    return (reply.status, {'items': decoded});
  }
  return (reply.status, Map<String, dynamic>.from(decoded as Map));
}

/// GET một endpoint trả dữ liệu nhị phân (file tải xuống). Ném lỗi kèm thông báo của server nếu không phải 200.
Future<Uint8List> restGetBytes(
  String address,
  String path, {
  Duration timeout = const Duration(minutes: 5),
}) async {
  final baseUrl = normalizeBaseUrl(address);
  final reply = await httpRequest(
    'GET',
    Uri.parse('$baseUrl$path'),
    timeout: timeout,
  );
  if (reply.status != 200) {
    var message = 'Lỗi ${reply.status}';
    try {
      final json = jsonDecode(reply.text);
      if (json is Map && json['error'] is String) {
        message = json['error'] as String;
      }
    } catch (_) {}
    throw Exception(message);
  }
  return reply.bytes;
}

/// GET một endpoint JSON; trả null nếu lỗi hoặc không phải 200
Future<Map<String, dynamic>?> restGetJson(
  String address,
  String path, {
  Duration timeout = const Duration(seconds: 6),
}) async {
  final baseUrl = normalizeBaseUrl(address);
  try {
    final reply = await httpRequest(
      'GET',
      Uri.parse('$baseUrl$path'),
      timeout: timeout,
    );
    if (reply.status == 200) {
      final map = jsonDecode(reply.text);
      if (map is Map) return Map<String, dynamic>.from(map);
    }
  } catch (_) {}
  return null;
}
