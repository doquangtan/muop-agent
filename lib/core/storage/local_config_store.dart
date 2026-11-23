import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Lưu trữ cấu hình cục bộ bền vững theo từng nền tảng (không dùng `systemTemp` / cache
/// để tránh bị xóa khi cập nhật APK, dọn cache hoặc khởi động lại máy):
/// - Android: `context.filesDir/muop_agent_config` (qua `MethodChannel`)
/// - Linux: `$XDG_CONFIG_HOME/muop-agent` hoặc `~/.config/muop-agent`
/// - macOS / iOS: `~/Library/Application Support/muop-agent`
/// - Windows: `%APPDATA%/muop-agent`
class LocalConfigStore {
  LocalConfigStore._();

  static const MethodChannel _androidChannel = MethodChannel(
    'vn.muop.agents/file_opener',
  );

  @visibleForTesting
  static Directory? testDirectoryOverride;

  static Directory? _cachedBaseDir;

  @visibleForTesting
  static void resetForTest() {
    _cachedBaseDir = null;
    testDirectoryOverride = null;
  }

  static Future<Directory> resolveConfigDir() async {
    final override = testDirectoryOverride;
    if (override != null) return override;
    final cached = _cachedBaseDir;
    if (cached != null) return cached;

    Directory dir;
    if (Platform.environment.containsKey('FLUTTER_TEST')) {
      dir = Directory('${Directory.systemTemp.path}/muop_agent_test_config');
    } else if (Platform.isAndroid) {
      dir = await _resolveAndroidFilesDir();
    } else if (Platform.isLinux) {
      final xdg = (Platform.environment['XDG_CONFIG_HOME'] ?? '').trim();
      final home = (Platform.environment['HOME'] ?? '').trim();
      final root = xdg.isNotEmpty
          ? xdg
          : (home.isNotEmpty ? '$home/.config' : Directory.systemTemp.path);
      dir = Directory('$root/muop-agent');
    } else if (Platform.isMacOS || Platform.isIOS) {
      final home = (Platform.environment['HOME'] ?? '').trim();
      dir = home.isNotEmpty
          ? Directory('$home/Library/Application Support/muop-agent')
          : Directory('${Directory.systemTemp.path}/muop-agent');
    } else if (Platform.isWindows) {
      final appData = (Platform.environment['APPDATA'] ?? '').trim();
      dir = appData.isNotEmpty
          ? Directory('$appData\\muop-agent')
          : Directory('${Directory.systemTemp.path}\\muop-agent');
    } else {
      dir = Directory('${Directory.systemTemp.path}/muop-agent');
    }

    _cachedBaseDir = dir;
    return dir;
  }

  static Future<Directory> _resolveAndroidFilesDir() async {
    try {
      final path = await _androidChannel
          .invokeMethod<String>('getFilesDir')
          .timeout(const Duration(seconds: 1));
      if (path != null && path.trim().isNotEmpty) {
        return Directory('${path.trim()}/muop_agent_config');
      }
    } catch (_) {}
    return Directory('${Directory.systemTemp.path}/muop_agent_config');
  }

  /// Đọc JSON từ thư mục bền vững; nếu chưa có sẽ tự di chuyển (migrate) từ file cũ ở `systemTemp`.
  static Future<Map<String, dynamic>> readJson(String fileName) async {
    try {
      final dir = await resolveConfigDir();
      final file = File('${dir.path}/$fileName');
      if (await file.exists()) {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map<String, dynamic>) return decoded;
      }

      // Di chuyển tự động cấu hình từ vị trí cũ trong systemTemp nếu còn tồn tại
      final legacy = File('${Directory.systemTemp.path}/$fileName');
      if (legacy.path != file.path && await legacy.exists()) {
        final decoded = jsonDecode(await legacy.readAsString());
        if (decoded is Map<String, dynamic>) {
          await writeJson(fileName, decoded);
          return decoded;
        }
      }
    } catch (_) {}
    return <String, dynamic>{};
  }

  /// Ghi JSON an toàn (ghi tạm rồi đổi tên) vào thư mục cấu hình bền vững.
  static Future<void> writeJson(
    String fileName,
    Map<String, dynamic> data,
  ) async {
    try {
      final dir = await resolveConfigDir();
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final target = File('${dir.path}/$fileName');
      final tmp = File('${dir.path}/$fileName.tmp');
      final encoded = jsonEncode(data);
      await tmp.writeAsString(encoded, flush: true);
      try {
        await tmp.rename(target.path);
      } catch (_) {
        await target.writeAsString(encoded, flush: true);
      }
    } catch (_) {}
  }
}
