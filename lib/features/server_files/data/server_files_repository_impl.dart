import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';

import 'package:muop_agent/core/config/server_config.dart';
import 'package:muop_agent/features/server_files/domain/server_file_entities.dart';
import 'package:muop_agent/features/server_files/domain/server_files_repository.dart';
import 'package:muop_agent/features/sftp/data/download_saver.dart';
import 'package:muop_agent/features/sftp/data/local_sftp.dart';
import 'package:muop_agent/features/sftp/data/sftp_transfers.dart';
import 'package:muop_agent/features/sftp/domain/sftp_entities.dart';

/// Duyệt và tải file của máy server qua API SFTP chung ("Máy này"): không còn endpoint file riêng.
/// Đọc nội dung, diff git và phân trang dòng vẫn đi qua `/api/files/*` vì cần git (SFTP không có).
class ServerFilesRepositoryImpl implements ServerFilesRepository {
  ServerFilesRepositoryImpl(this._local, this._transfers);

  final LocalSftp _local;
  final SftpTransfers _transfers;

  /// Duyệt thư mục trên "Máy này" (`/api/sftp/list` với phiên của máy này)
  @override
  Future<ServerDirListResponse> fetchServerDirectory({
    required String address,
    required String path,
    bool showHidden = false,
  }) async {
    final reply = await _local.run(
      address,
      (sid) => _local.repo.list(address, sid, path),
    );
    if (!reply.ok) {
      return ServerDirListResponse(
        ok: false,
        currentPath: path,
        parentPath: '',
        entries: const [],
        error: reply.error,
      );
    }
    final entries = reply.entries
        .where((e) => showHidden || !e.name.startsWith('.'))
        .map(_toFileEntry)
        .toList();
    return ServerDirListResponse(
      ok: true,
      currentPath: path,
      parentPath: sftpParentOf(path),
      entries: entries,
    );
  }

  static ServerFileEntry _toFileEntry(SftpEntry e) {
    final unix = e.modifiedUnix;
    return ServerFileEntry(
      name: e.name,
      path: e.path,
      isDir: e.isDir,
      size: e.size,
      modifiedAt: unix != null
          ? DateTime.fromMillisecondsSinceEpoch(unix * 1000)
          : DateTime.fromMillisecondsSinceEpoch(0),
      permissions: e.mode,
    );
  }

  /// Đọc nội dung tệp và Git Diff trên Rust Server (`/api/files/read`)
  @override
  Future<ServerFileReadResponse> readServerFile({
    required String address,
    required String path,
  }) async {
    final baseUrl = normalizeBaseUrl(address);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 5);
    try {
      final uri = Uri.parse('$baseUrl/api/files/read').replace(
        queryParameters: {'path': path},
      );
      final req = await client.getUrl(uri);
      final resp = await req.close().timeout(const Duration(seconds: 8));
      final body = await resp.transform(utf8.decoder).join();
      final map = jsonDecode(body) as Map<String, dynamic>;
      return ServerFileReadResponse.fromJson(map);
    } catch (e) {
      return ServerFileReadResponse(
        ok: false,
        path: path,
        name: path.split('/').last,
        size: 0,
        isBinary: false,
        content: '',
        gitDiff: '',
        error: '$e',
      );
    } finally {
      client.close(force: true);
    }
  }

  /// Đọc một đoạn dòng của tệp văn bản (`/api/files/lines`); không nạp cả tệp
  @override
  Future<ServerFileLinesResponse> fetchServerFileLines({
    required String address,
    required String path,
    required int offset,
    int limit = 200,
  }) async {
    final baseUrl = normalizeBaseUrl(address);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 5);
    try {
      final uri = Uri.parse('$baseUrl/api/files/lines').replace(
        queryParameters: {
          'path': path,
          'offset': '$offset',
          'limit': '$limit',
        },
      );
      final req = await client.getUrl(uri);
      final resp = await req.close().timeout(const Duration(seconds: 15));
      final body = await resp.transform(utf8.decoder).join();
      final map = jsonDecode(body) as Map<String, dynamic>;
      return ServerFileLinesResponse.fromJson(map);
    } catch (e) {
      return ServerFileLinesResponse.failure(path, '$e');
    } finally {
      client.close(force: true);
    }
  }

  /// Trạng thái git của project (`/api/git/status`); isRepo = false nếu không phải git repository
  @override
  Future<ServerGitStatus> fetchGitStatus({
    required String address,
    required String projectPath,
  }) async {
    final baseUrl = normalizeBaseUrl(address);
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final uri = Uri.parse('$baseUrl/api/git/status').replace(
        queryParameters: {'projectPath': projectPath},
      );
      final req = await client.getUrl(uri);
      final resp = await req.close().timeout(const Duration(seconds: 20));
      final body = await resp.transform(utf8.decoder).join();
      final map = jsonDecode(body) as Map<String, dynamic>;
      final raw = map['kinds'];
      final kinds = <String, String>{};
      if (raw is Map) {
        raw.forEach((k, v) => kinds['$k'] = '$v');
      }
      return ServerGitStatus(
        ok: map['ok'] == true,
        isRepo: map['isRepo'] == true,
        kinds: kinds,
        error: '${map['error'] ?? ''}',
      );
    } catch (e) {
      return ServerGitStatus(ok: false, isRepo: false, kinds: const {}, error: '$e');
    } finally {
      client.close(force: true);
    }
  }

  /// Lấy URL trực tiếp để tải hoặc xem tệp / hình ảnh từ Rust Server
  @override
  String getFileDownloadUrl({
    required String address,
    required String remotePath,
  }) {
    final baseUrl = normalizeBaseUrl(address);
    return Uri.parse('$baseUrl/api/files/download')
        .replace(queryParameters: {'path': remotePath})
        .toString();
  }

  /// Tải file của máy server về thiết bị bằng luồng SFTP chung (chuẩn bị rồi tải theo khối, có tiến trình).
  /// File lưu vào Downloads (máy để bàn) hoặc Downloads/Documents trên điện thoại.
  @override
  Future<FileDownloadResult> downloadFileFromServer({
    required String address,
    required String remotePath,
    void Function(int receivedBytes, int totalBytes)? onProgress,
  }) async {
    try {
      final prepared = await _local.run(
        address,
        (sid) => _local.repo.prepareDownload(address, sid, [remotePath]),
      );
      if (!prepared.ok || prepared.downloadId.isEmpty) {
        return FileDownloadResult(
          ok: false,
          savedPath: '',
          sizeBytes: 0,
          error: prepared.error.isNotEmpty
              ? prepared.error
              : 'Không chuẩn bị được file tải xuống',
        );
      }
      final file = await _transfers.fetchToTemp(
        address: address,
        downloadId: prepared.downloadId,
        name: prepared.downloadName,
        expectedSize: prepared.size,
        onProgress: onProgress,
      );
      final savedPath = await saveToDownloads(file);
      return FileDownloadResult(
        ok: true,
        savedPath: savedPath,
        sizeBytes: file.size,
      );
    } catch (e) {
      return FileDownloadResult(
        ok: false,
        savedPath: '',
        sizeBytes: 0,
        error: '$e',
      );
    }
  }

  static const MethodChannel _fileOpenerChannel =
      MethodChannel('vn.muop.agents/file_opener');

  /// Mở trực tiếp tệp vừa tải về trên thiết bị (Android FileProvider Intent hoặc Linux xdg-open)
  @override
  Future<({bool ok, String error})> openDownloadedFile(String savedPath) async {
    final cleanPath = savedPath.trim();
    if (cleanPath.isEmpty) {
      return (ok: false, error: 'Đường dẫn tệp trống');
    }
    try {
      // Android: đường dẫn content:// (Downloads qua MediaStore) được native xử lý trực tiếp.
      // iOS: native present UIDocumentInteractionController cho tệp trong Documents.
      if (Platform.isAndroid || Platform.isIOS) {
        await _fileOpenerChannel.invokeMethod<bool>(
          'openFile',
          {'path': cleanPath},
        );
        return (ok: true, error: '');
      }

      final f = File(cleanPath);
      if (!await f.exists()) {
        return (ok: false, error: 'Tệp không tồn tại tại: $cleanPath');
      }

      if (Platform.isLinux) {
        final res = await Process.run('xdg-open', [cleanPath]);
        if (res.exitCode == 0) {
          return (ok: true, error: '');
        }
        return (ok: false, error: '${res.stderr}'.trim());
      } else if (Platform.isMacOS) {
        await Process.run('open', [cleanPath]);
        return (ok: true, error: '');
      } else if (Platform.isWindows) {
        await Process.run('explorer', [cleanPath]);
        return (ok: true, error: '');
      }
      return (ok: false, error: 'Nền tảng chưa hỗ trợ mở tệp trực tiếp');
    } catch (e) {
      return (ok: false, error: '$e');
    }
  }
}
