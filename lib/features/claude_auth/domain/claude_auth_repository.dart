import 'package:muop_agent/features/claude_auth/domain/claude_auth_entities.dart';

/// Interface (domain) của feature claude_auth. Presentation chỉ phụ thuộc interface này.
/// Toàn bộ đi qua Socket.IO: lệnh gửi bằng ack, trạng thái server đẩy qua [updates].
abstract class ClaudeAuthRepository {
  /// Mỗi khi server đổi trạng thái đăng nhập
  Stream<ClaudeAuthState> get updates;

  Future<ClaudeAuthState> fetchStatus();

  Future<ClaudeAuthState> logout();

  /// Bắt đầu đăng nhập; trả về link Anthropic OAuth trong `loginUrl`
  Future<ClaudeAuthState> startLogin();

  /// Gửi mã (hoặc URL callback) người dùng dán vào. Trả về ngay ở trạng thái `verifying`.
  Future<ClaudeAuthState> submitCode(String code);

  Future<ClaudeAuthState> cancelLogin();
}
