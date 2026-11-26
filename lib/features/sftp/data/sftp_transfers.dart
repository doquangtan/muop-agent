import 'dart:io';

import 'package:muop_agent/features/sftp/domain/sftp_repository.dart';

/// File tạm đã tải xong từ server, chờ lưu ra thiết bị
class DownloadedFile {
  const DownloadedFile({
    required this.tempPath,
    required this.name,
    required this.size,
  });

  final String tempPath;
  final String name;
  final int size;

}

/// Xóa file tạm và thư mục riêng chứa nó
Future<void> removeTempDownload(String tempPath) async {
  try {
    await File(tempPath).parent.delete(recursive: true);
  } catch (_) {}
}

/// Luồng tải xuống dùng chung của mọi màn hình: server chuẩn bị (`prepareDownload`), rồi app
/// tải về file tạm theo từng khối và báo tiến trình. Không gom cả file vào bộ nhớ.
class SftpTransfers {
  SftpTransfers(this._repo);

  final SftpRepository _repo;

  /// Dọn file tạm sau khi đã lưu hoặc hủy
  Future<void> discard(DownloadedFile file) => removeTempDownload(file.tempPath);

  /// Tải nội dung đã chuẩn bị vào thư mục tạm riêng. Ném lỗi nếu tải thất bại (thư mục tạm được dọn).
  Future<DownloadedFile> fetchToTemp({
    required String address,
    required String downloadId,
    required String name,
    int expectedSize = -1,
    void Function(int received, int total)? onProgress,
  }) async {
    final dir = await Directory.systemTemp.createTemp('muop-dl-');
    final tempPath = '${dir.path}/$name';
    try {
      await _repo.downloadToPath(
        address,
        downloadId,
        tempPath,
        onProgress: (received, total) =>
            onProgress?.call(received, total < 0 ? expectedSize : total),
      );
    } catch (_) {
      await removeTempDownload(tempPath);
      rethrow;
    }
    final size = await File(tempPath).length();
    return DownloadedFile(tempPath: tempPath, name: name, size: size);
  }
}
