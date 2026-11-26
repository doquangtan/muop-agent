import 'dart:typed_data';

import 'package:muop_agent/features/sftp/domain/sftp_entities.dart';

/// Interface (domain) của SFTP. Mọi thao tác file (máy SSH đã lưu và "Máy này") đi qua Rust Server.
abstract class SftpRepository {
  /// Mở (hoặc gắn lại) phiên "Máy này": cùng API với máy SSH, không cần chọn máy
  Future<SftpReply> openLocal(String address);

  /// Mở (hoặc gắn lại) phiên. `password` rỗng = dùng mật khẩu đã lưu của máy.
  Future<SftpReply> open(
    String address,
    int hostId, {
    String password = '',
    bool savePassword = false,
  });

  Future<void> close(String address, String sessionId);

  Future<SftpReply> list(String address, String sessionId, String path);

  Future<SftpReply> mkdir(String address, String sessionId, String path);

  Future<SftpReply> rename(
    String address,
    String sessionId,
    String from,
    String to,
  );

  /// Xóa file, hoặc thư mục và toàn bộ nội dung khi [isDir]
  Future<SftpReply> delete(
    String address,
    String sessionId,
    String path, {
    required bool isDir,
  });

  /// Tải lên (ghi đè khi [overwrite]). Trả `exists` khi đã có và không ghi đè.
  Future<SftpReply> upload(
    String address,
    String sessionId,
    String path,
    Uint8List bytes, {
    bool overwrite = false,
  });

  /// Đọc file để sửa (tối đa 1MB)
  Future<SftpReply> read(String address, String sessionId, String path);

  /// Chuẩn bị tải xuống các mục đã chọn: một file trực tiếp, nhiều mục hoặc thư mục thành zip
  Future<SftpReply> prepareDownload(
    String address,
    String sessionId,
    List<String> paths,
  );

  /// Tải nội dung theo `downloadId` đã chuẩn bị vào file [destPath], ghi dần (không gom vào bộ nhớ).
  /// [onProgress] báo byte đã nhận và tổng (-1 nếu server không báo kích thước). Ném lỗi nếu thất bại.
  Future<void> downloadToPath(
    String address,
    String downloadId,
    String destPath, {
    void Function(int received, int total)? onProgress,
  });
}
