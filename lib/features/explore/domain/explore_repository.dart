/// Theo dõi thư mục đang mở trong explorer. Server chỉ theo dõi khi có người xem (room `explore:<khóa>`).
abstract class ExploreRepository {
  /// Một UI bắt đầu xem [path]. Nhiều UI cùng xem một thư mục thì server chỉ theo dõi một lần.
  void watch(String path);

  /// Một UI không xem [path] nữa. Hết người xem thì server dừng theo dõi.
  void unwatch(String path);

  /// Room của [path] khi server đã nhận yêu cầu (null nếu chưa kết nối hoặc chưa có ack)
  String? roomOf(String path);

  /// Room có nội dung thư mục vừa đổi (so với [roomOf])
  Stream<String> get changedRooms;
}
