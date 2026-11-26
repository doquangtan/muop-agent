import 'dart:io';

import 'package:flutter/services.dart';

import 'package:muop_agent/features/sftp/data/sftp_transfers.dart';

const MethodChannel _fileOpenerChannel = MethodChannel('vn.muop.agents/file_opener');

/// Lưu file tải xong ra thiết bị. Android: Downloads (MediaStore); iOS: Documents;
/// máy để bàn: ~/Downloads (nếu có), không thì thư mục tạm. Trả về đường dẫn đã lưu.
Future<String> saveToDownloads(DownloadedFile file) async {
  final name = file.name;
  if (Platform.isAndroid || Platform.isIOS) {
    // Android: thử chuyển sang Downloads công khai; lỗi (Android cũ) thì giữ bản trong cache.
    try {
      final saved = await _fileOpenerChannel.invokeMethod<String>(
        Platform.isIOS ? 'saveToDocuments' : 'saveToDownloads',
        {'path': file.tempPath, 'name': name},
      );
      if (saved != null && saved.isNotEmpty) {
        await removeTempDownload(file.tempPath);
        return saved;
      }
    } catch (_) {}
    return file.tempPath;
  }

  var targetDir = Directory.systemTemp;
  final home = Platform.environment['HOME'] ?? '';
  if (home.isNotEmpty) {
    final dl = Directory('$home/Downloads');
    if (await dl.exists()) targetDir = dl;
  }
  final target = '${targetDir.path}/$name';
  try {
    await File(file.tempPath).rename(target);
  } on FileSystemException {
    // Khác ổ đĩa: sao chép rồi xóa bản tạm
    await File(file.tempPath).copy(target);
  }
  await removeTempDownload(file.tempPath);
  return target;
}
