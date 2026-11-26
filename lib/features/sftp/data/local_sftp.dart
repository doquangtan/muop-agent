import 'package:muop_agent/features/sftp/domain/sftp_entities.dart';
import 'package:muop_agent/features/sftp/domain/sftp_repository.dart';

/// Phiên SFTP của "Máy này" dùng chung cho mọi tính năng file của app (duyệt thư mục,
/// tải xuống từ khung chat, cây project). Mở một lần cho mỗi server; phiên mất thì mở lại.
class LocalSftp {
  LocalSftp(this.repo);

  final SftpRepository repo;
  final Map<String, String> _sessions = {};

  /// Chạy [op] trên phiên của máy này. Phiên đã kết thúc trên server thì mở lại và chạy lại một lần.
  Future<SftpReply> run(
    String address,
    Future<SftpReply> Function(String sessionId) op,
  ) async {
    var reply = await _attempt(address, op);
    if (reply.sessionGone) {
      _sessions.remove(address);
      reply = await _attempt(address, op);
    }
    return reply;
  }

  Future<SftpReply> _attempt(
    String address,
    Future<SftpReply> Function(String sessionId) op,
  ) async {
    var sid = _sessions[address];
    if (sid == null) {
      final opened = await repo.openLocal(address);
      final session = opened.session;
      if (!opened.ok || session == null) return opened;
      sid = session.sessionId;
      _sessions[address] = sid;
    }
    return op(sid);
  }

  /// Quên phiên đã lưu của server (khi đổi địa chỉ hoặc đăng xuất)
  void forget(String address) => _sessions.remove(address);
}
