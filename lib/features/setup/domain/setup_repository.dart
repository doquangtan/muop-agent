import 'package:muop_agent/features/setup/domain/setup_entities.dart';

/// Interface (domain) của wizard khởi tạo. Toàn bộ đi qua Socket.IO: lệnh gửi bằng ack,
/// trạng thái server đẩy qua [updates]. Client không chạy lệnh nào trên máy server.
abstract class SetupRepository {
  /// Mỗi khi server đổi trạng thái tool hoặc tiến trình cài đặt
  Stream<SetupStatus> get updates;

  Future<SetupStatus> fetchStatus();

  /// Bắt đầu cài một CLI (`agy` hoặc `claude`). Trả về ngay; tiến trình đến qua [updates].
  Future<SetupStatus> install(String tool);

  /// Lưu CLI người dùng chọn
  Future<SetupStatus> selectClis(List<String> clis);

  /// Đánh dấu đã khởi tạo xong (vào màn hình chính)
  Future<SetupStatus> complete();

  /// Đặt user SSH của máy này (đổi user thì phải thử đăng nhập lại)
  Future<SetupStatus> configureSsh(String username);

  /// Server tự sinh khóa, publish public key vào authorized_keys của user rồi thử đăng nhập
  Future<SetupStatus> autoSetupSsh();

  /// Xác nhận dòng public key người dùng đã tự publish bằng lệnh hướng dẫn (dán lại)
  Future<SetupStatus> verifySsh(String publicKey);
}
