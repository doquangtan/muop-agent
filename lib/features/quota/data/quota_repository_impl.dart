import 'package:muop_agent/core/network/rest_client.dart';
import 'package:muop_agent/features/quota/domain/quota_entities.dart';
import 'package:muop_agent/features/quota/domain/quota_repository.dart';

class QuotaRepositoryImpl implements QuotaRepository {
  @override
  Future<QuotaSnapshot?> fetchAll(String address) async {
    final map = await restGetJson(address, '/api/quota');
    if (map == null) return null;
    return QuotaSnapshot.fromJson(map);
  }

  @override
  Future<QuotaReport?> fetchProvider(String address, String provider) async {
    final map = await restGetJson(address, '/api/quota/$provider');
    if (map == null) return null;
    return QuotaReport.fromJson(provider, map);
  }
}
