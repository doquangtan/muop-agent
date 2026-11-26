import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:muop_agent/core/config/server_config.dart';
import 'package:muop_agent/core/network/rest_client.dart';
import 'package:muop_agent/features/sftp/domain/sftp_entities.dart';
import 'package:muop_agent/features/sftp/domain/sftp_repository.dart';

class SftpRepositoryImpl implements SftpRepository {
  const SftpRepositoryImpl();

  Future<SftpReply> _post(
    String address,
    String path,
    Map<String, dynamic> body, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    try {
      final (_, json) = await restRequest(address, 'POST', path,
          body: body, timeout: timeout);
      return SftpReply.fromJson(json);
    } catch (e) {
      return SftpReply.failure('Không gọi được server: $e');
    }
  }

  @override
  Future<SftpReply> openLocal(String address) =>
      _post(address, '/api/sftp/local', {}, timeout: const Duration(seconds: 30));

  @override
  Future<SftpReply> open(
    String address,
    int hostId, {
    String password = '',
    bool savePassword = false,
  }) =>
      _post(address, '/api/sftp/open', {
        'hostId': hostId,
        'password': password,
        'savePassword': savePassword,
      }, timeout: const Duration(seconds: 90));

  @override
  Future<void> close(String address, String sessionId) async {
    try {
      await restRequest(address, 'POST', '/api/sftp/close',
          body: {'sessionId': sessionId});
    } catch (_) {
      // Đóng phiên là best-effort: server tự dọn khi không dùng nữa
    }
  }

  @override
  Future<SftpReply> list(String address, String sessionId, String path) =>
      _post(address, '/api/sftp/list', {'sessionId': sessionId, 'path': path});

  @override
  Future<SftpReply> mkdir(String address, String sessionId, String path) =>
      _post(address, '/api/sftp/op', {
        'sessionId': sessionId,
        'action': 'mkdir',
        'path': path,
      });

  @override
  Future<SftpReply> rename(
    String address,
    String sessionId,
    String from,
    String to,
  ) =>
      _post(address, '/api/sftp/op', {
        'sessionId': sessionId,
        'action': 'rename',
        'path': from,
        'target': to,
      });

  @override
  Future<SftpReply> delete(
    String address,
    String sessionId,
    String path, {
    required bool isDir,
  }) =>
      _post(address, '/api/sftp/op', {
        'sessionId': sessionId,
        'action': 'delete',
        'path': path,
        'isDir': isDir,
      }, timeout: const Duration(minutes: 5));

  @override
  Future<SftpReply> upload(
    String address,
    String sessionId,
    String path,
    Uint8List bytes, {
    bool overwrite = false,
  }) =>
      _post(address, '/api/sftp/upload', {
        'sessionId': sessionId,
        'path': path,
        'dataBase64': base64Encode(bytes),
        'overwrite': overwrite,
      }, timeout: const Duration(minutes: 5));

  @override
  Future<SftpReply> read(String address, String sessionId, String path) =>
      _post(address, '/api/sftp/read', {'sessionId': sessionId, 'path': path});

  @override
  Future<SftpReply> prepareDownload(
    String address,
    String sessionId,
    List<String> paths,
  ) =>
      _post(address, '/api/sftp/download/prepare', {
        'sessionId': sessionId,
        'paths': paths,
      }, timeout: const Duration(minutes: 10));

  @override
  Future<void> downloadToPath(
    String address,
    String downloadId,
    String destPath, {
    void Function(int received, int total)? onProgress,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final baseUrl = normalizeBaseUrl(address);
      final req = await client.getUrl(
        Uri.parse('$baseUrl/api/sftp/download/$downloadId'),
      );
      final resp = await req.close().timeout(const Duration(seconds: 30));
      if (resp.statusCode != 200) {
        final text = await resp.transform(utf8.decoder).join();
        var message = 'Lỗi ${resp.statusCode}';
        try {
          final json = jsonDecode(text);
          if (json is Map && json['error'] is String) {
            message = json['error'] as String;
          }
        } catch (_) {}
        throw Exception(message);
      }
      final total = resp.contentLength;
      final raf = await File(destPath).open(mode: FileMode.write);
      var received = 0;
      try {
        // Timeout theo từng khối: một kết nối đứng im quá lâu thì dừng, không chờ mãi
        await for (final chunk in resp.timeout(const Duration(seconds: 60))) {
          await raf.writeFrom(chunk);
          received += chunk.length;
          onProgress?.call(received, total);
        }
      } finally {
        await raf.close();
      }
      if (total >= 0 && received != total) {
        throw Exception('Tải thiếu dữ liệu ($received/$total byte)');
      }
    } finally {
      client.close(force: true);
    }
  }
}
