import 'package:muop_agent/features/sessions/domain/session_entities.dart';

/// Provider có quota: khớp với `/api/quota/<provider>` của server
const String kQuotaProviderAgy = 'agy';
const String kQuotaProviderClaude = 'claude';

/// Tiền tố phạm vi quota của máy phụ (ví dụ `peer:agy`): quota lấy từ tài khoản máy phụ, không lẫn với máy chính
const String kPeerQuotaScopePrefix = 'peer:';

bool isPeerQuotaScope(String scope) => scope.startsWith(kPeerQuotaScopePrefix);

/// Provider gốc của phạm vi quota (`peer:claude` → `claude`)
String quotaProviderOf(String scope) =>
    isPeerQuotaScope(scope) ? scope.substring(kPeerQuotaScopePrefix.length) : scope;

/// Quota của một provider. Khi không lấy được dữ liệu thì `groups` rỗng và `error` ghi lý do.
class QuotaReport {
  const QuotaReport({
    required this.provider,
    required this.groups,
    this.error = '',
    this.loading = false,
  });

  /// Báo cáo khi chưa có dữ liệu (chưa tải, không kết nối được server...)
  factory QuotaReport.missing(String provider, [String error = 'Chưa lấy được dữ liệu quota']) =>
      QuotaReport(provider: provider, groups: const [], error: error);

  /// Đang chờ server đọc quota (chưa có dữ liệu cũ để hiển thị)
  factory QuotaReport.loading(String provider) =>
      QuotaReport(provider: provider, groups: const [], loading: true);

  factory QuotaReport.fromJson(String provider, Map<String, dynamic> json) {
    final groups = <ModelQuotaGroup>[];
    if (json['groups'] is List) {
      for (final item in json['groups'] as List) {
        if (item is Map) {
          groups.add(ModelQuotaGroup.fromJson(Map<String, dynamic>.from(item)));
        }
      }
    }
    return QuotaReport(
      provider: '${json['provider'] ?? provider}',
      groups: groups,
      error: '${json['error'] ?? ''}',
    );
  }

  final String provider;
  final List<ModelQuotaGroup> groups;
  final String error;
  final bool loading;

  /// Có ít nhất một cửa sổ quota để hiển thị
  bool get hasData => groups.any((g) => g.buckets.isNotEmpty);

  String get providerLabel => provider == kQuotaProviderClaude
      ? 'Claude Code CLI'
      : 'Antigravity (agy)';
}

/// Quota của cả hai provider: `GET /api/quota`
class QuotaSnapshot {
  const QuotaSnapshot({required this.agy, required this.claude});

  factory QuotaSnapshot.fromJson(Map<String, dynamic> json) => QuotaSnapshot(
        agy: _reportOf(json, kQuotaProviderAgy),
        claude: _reportOf(json, kQuotaProviderClaude),
      );

  final QuotaReport agy;
  final QuotaReport claude;

  static QuotaReport _reportOf(Map<String, dynamic> json, String provider) {
    final value = json[provider];
    if (value is Map) {
      return QuotaReport.fromJson(provider, Map<String, dynamic>.from(value));
    }
    return QuotaReport.missing(provider, 'Không đọc được dữ liệu quota');
  }
}
