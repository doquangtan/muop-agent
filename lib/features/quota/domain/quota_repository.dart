import 'package:muop_agent/features/quota/domain/quota_entities.dart';

/// Interface (domain) của feature quota. Mỗi màn hình chỉ gọi endpoint của provider nó hiển thị.
abstract class QuotaRepository {
  /// Quota của cả hai provider (`GET /api/quota`). Trả về `null` khi không kết nối được server.
  Future<QuotaSnapshot?> fetchAll(String address);

  /// Quota một provider (`GET /api/quota/agy` hoặc `/api/quota/claude`).
  /// Trả về `null` khi không kết nối được server.
  Future<QuotaReport?> fetchProvider(String address, String provider);
}
