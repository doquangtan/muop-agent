import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';

import 'package:muop_agent/core/config/server_config.dart';
import 'package:muop_agent/features/server_files/domain/server_file_entities.dart';
import 'package:muop_agent/features/server_files/domain/server_files_repository.dart';

class ServerFilesRepositoryImpl implements ServerFilesRepository {
  ServerFilesRepositoryImpl();

  /// Duyệt danh sách file và thư mục trên Rust Server (`/api/files/list`)
  @override
  Future<ServerDirListResponse> fetchServerDirectory({
    required String address,
    required String path,
    bool showHidden = false,
  }) async {
    final baseUrl = normalizeBaseUrl(address);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 4);
    try {
      final uri = Uri.parse('$baseUrl/api/files/list').replace(
        queryParameters: {
          'path': path,
          'showHidden': showHidden ? 'true' : 'false',
        },
      );
      final req = await client.getUrl(uri);
      final resp = await req.close().timeout(const Duration(seconds: 6));
      final body = await resp.transform(utf8.decoder).join();
      final map = jsonDecode(body) as Map<String, dynamic>;
      return ServerDirListResponse.fromJson(map);
    } catch (e) {
      return ServerDirListResponse(
        ok: false,
        currentPath: path,
        parentPath: '',
        entries: const [],
        error: '$e',
      );
    } finally {
      client.close(force: true);
    }
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

  /// Tải file từ Rust Server (`/api/files/download`) về thư mục Downloads trên thiết bị
  @override
  Future<FileDownloadResult> downloadFileFromServer({
    required String address,
    required String remotePath,
    void Function(int receivedBytes, int totalBytes)? onProgress,
  }) async {
    final baseUrl = normalizeBaseUrl(address);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8);
    try {
      final uri = Uri.parse('$baseUrl/api/files/download').replace(
        queryParameters: {'path': remotePath},
      );
      final req = await client.getUrl(uri);
      final resp = await req.close();

      if (resp.statusCode != 200) {
        final errBody = await resp.transform(utf8.decoder).join();
        return FileDownloadResult(
          ok: false,
          savedPath: '',
          sizeBytes: 0,
          error: 'HTTP ${resp.statusCode}: $errBody',
        );
      }

      final filename = remotePath
          .split('/')
          .where((s) => s.isNotEmpty)
          .lastOrNull ??
          'downloaded_file';

      // Android: dùng systemTemp (app cache dir) — không cần quyền external storage.
      // Desktop: ưu tiên ~/Downloads, fallback về systemTemp.
      Directory targetDir = Directory.systemTemp;
      if (!Platform.isAndroid) {
        final home = Platform.environment['HOME'] ?? '';
        if (home.isNotEmpty) {
          final dl = Directory('$home/Downloads');
          if (await dl.exists()) targetDir = dl;
        }
      }

      File outFile = File('${targetDir.path}/$filename');

      // RandomAccessFile.writeFrom() ghi mỗi chunk thẳng ra disk và await từng lần,
      // không buffer toàn bộ file → tránh flush() block ở cuối gây "đứng im ở 100%".
      late RandomAccessFile raf;
      try {
        raf = await outFile.open(mode: FileMode.write);
      } catch (_) {
        // Fallback về systemTemp nếu thư mục đích không ghi được
        outFile = File('${Directory.systemTemp.path}/$filename');
        raf = await outFile.open(mode: FileMode.write);
      }

      final totalBytes = resp.contentLength;
      int received = 0;

      try {
        await for (final chunk in resp) {
          await raf.writeFrom(chunk);
          received += chunk.length;
          onProgress?.call(received, totalBytes);
        }
      } finally {
        await raf.close();
      }

      var savedPath = outFile.path;
      if (Platform.isAndroid || Platform.isIOS) {
        // Android: chuyển bản tạm sang Downloads công khai (MediaStore).
        // iOS: chuyển sang thư mục Documents (hiện trong app Tệp).
        // Nếu thất bại (ví dụ Android < 10) thì giữ bản trong cache.
        try {
          final saved = await _fileOpenerChannel.invokeMethod<String>(
            Platform.isIOS ? 'saveToDocuments' : 'saveToDownloads',
            {'path': outFile.path, 'name': filename},
          );
          if (saved != null && saved.isNotEmpty) {
            await outFile.delete();
            savedPath = saved;
          }
        } catch (_) {}
      }

      return FileDownloadResult(
        ok: true,
        savedPath: savedPath,
        sizeBytes: received,
      );
    } catch (e) {
      return FileDownloadResult(
        ok: false,
        savedPath: '',
        sizeBytes: 0,
        error: '$e',
      );
    } finally {
      client.close(force: true);
    }
  }

  static const MethodChannel _fileOpenerChannel =
      MethodChannel('vn.muop.muop_agent/file_opener');

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
