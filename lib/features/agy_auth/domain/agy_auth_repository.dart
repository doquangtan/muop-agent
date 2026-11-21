import 'package:muop_agent/features/agy_auth/domain/agy_auth_entities.dart';

/// Interface (domain) của feature agy_auth. Presentation chỉ phụ thuộc interface này.
/// Toàn bộ đi qua Socket.IO: lệnh gửi bằng ack, trạng thái server đẩy qua [updates].
abstract class AgyAuthRepository {
  /// Mỗi khi server đổi trạng thái đăng nhập (kể cả khi không có lệnh nào đang chờ)
  Stream<AgyAuthState> get updates;

  Future<AgyAuthState> fetchStatus();

  /// Kiểm tra agy đã đăng nhập chưa (event `agy:auth:check`). Đang có terminal đăng nhập thì đọc màn hình
  /// của nó; khi agy vào màn chat, server kết thúc luồng và trả `logged_in`. Kết quả cũng đến qua [updates].
  Future<AgyAuthState> checkStatus();

  /// Tài khoản agy và Claude Code CLI (gói, trạng thái đăng nhập)
  Future<AccountsStatus> fetchAccounts();

  Future<AgyAuthState> logout();

  /// Mở terminal SSH chạy agy để người dùng tự đăng nhập (trạng thái `login_terminal`).
  /// Kết quả đến qua [updates]: đăng nhập xong, hoặc agy thoát mà chưa đăng nhập.
  Future<AgyAuthState> startLogin();

  /// Gửi mã (hoặc URL callback) người dùng dán vào app vào terminal đăng nhập. Lỗi nhập nằm trong `error`.
  Future<AgyAuthState> submitCode(String code);

  /// Hủy đăng nhập đang chờ: đóng terminal
  Future<AgyAuthState> cancelLogin();
}
