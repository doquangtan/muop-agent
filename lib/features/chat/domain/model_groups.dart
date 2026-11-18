/// Gom các id model thành nhóm theo tên, và tách mức suy luận (effort) ở cuối id.
///
/// Ví dụ với `agy:gemini-4-argon-medium`, `agy:gemini-4-argon-high`:
/// - nhóm `agy:gemini-4-argon` (nhãn "Gemini 4 Argon")
/// - các mức `low`, `medium`, `high`, `xhigh`, `max` lấy từ hậu tố id.
///
/// Model không có hậu tố mức (ví dụ `claude-cli:claude-sonnet-5-5`) là nhóm có một lựa chọn.
library;

/// Mức suy luận dự phòng, chỉ dùng khi server chưa gửi danh sách mức (`effortLevels` trong meta).
/// Nguồn chính là CLI của server (`claude --help`), nên danh sách thực tế do server quyết định.
const List<String> kFallbackEffortLevels = ['low', 'medium', 'high', 'xhigh', 'max'];

/// Danh sách mức đang dùng: lấy từ server, hoặc dự phòng khi server chưa gửi
List<String> resolveEffortLevels(List<String> fromServer) =>
    fromServer.isEmpty ? kFallbackEffortLevels : fromServer;

/// Mức mặc định khi chọn một nhóm
const String kDefaultModelEffort = 'medium';

class ModelOption {
  const ModelOption({
    required this.id,
    required this.groupId,
    required this.effort,
    required this.label,
  });

  /// Id đầy đủ gửi lên server, ví dụ `agy:gemini-4-argon-medium`
  final String id;

  /// Id nhóm (không có hậu tố mức), ví dụ `agy:gemini-4-argon`
  final String groupId;

  /// Mức suy luận, null nếu model không có mức
  final String? effort;

  /// Nhãn hiển thị đầy đủ từ server (nếu có)
  final String label;
}

class ModelGroup {
  const ModelGroup({
    required this.id,
    required this.label,
    required this.options,
  });

  final String id;
  final String label;

  /// Các lựa chọn trong nhóm, sắp theo mức tăng dần
  final List<ModelOption> options;

  bool get hasEffortChoices => options.length > 1 || options.first.effort != null;

  /// Lựa chọn có đúng mức [effort]; null nếu nhóm không có mức đó
  ModelOption? optionWithEffort(String? effort) {
    for (final option in options) {
      if (option.effort == effort) return option;
    }
    return null;
  }

  /// Lựa chọn nên dùng khi chuyển sang nhóm này: giữ nguyên mức [currentEffort] nếu có,
  /// không thì lấy mức mặc định [kDefaultModelEffort], cuối cùng là lựa chọn đầu tiên.
  ModelOption preferredOption({String? currentEffort}) {
    return optionWithEffort(currentEffort) ??
        optionWithEffort(kDefaultModelEffort) ??
        options.first;
  }

  /// Chữ hoa đầu cho mức, ví dụ `xhigh` → `XHigh`, `medium` → `Medium`
  static String effortLabel(String effort) {
    if (effort == 'xhigh') return 'XHigh';
    if (effort.isEmpty) return effort;
    return effort[0].toUpperCase() + effort.substring(1);
  }
}

/// Tách một id model thành (id nhóm, mức). Mức là null nếu id không có hậu tố mức.
({String groupId, String? effort}) parseModelId(
  String id, {
  List<String> levels = kFallbackEffortLevels,
}) {
  final colon = id.indexOf(':');
  final prefix = colon >= 0 ? id.substring(0, colon + 1) : '';
  final rest = id.substring(prefix.length);
  final dash = rest.lastIndexOf('-');
  if (dash > 0) {
    final suffix = rest.substring(dash + 1);
    if (levels.contains(suffix)) {
      return (groupId: '$prefix${rest.substring(0, dash)}', effort: suffix);
    }
  }
  return (groupId: id, effort: null);
}

/// Bỏ phần nhãn trong ngoặc ở cuối, ví dụ `Gemini 4 Argon (Medium)` → `Gemini 4 Argon`
String _stripEffortSuffixFromLabel(String label) {
  return label.replaceFirst(RegExp(r'\s*\([^()]*\)\s*$'), '').trim();
}

/// Tên nhóm khi không có nhãn từ server: bỏ tiền tố provider, viết hoa từng từ
String _fallbackGroupLabel(String groupId) {
  final colon = groupId.indexOf(':');
  final bare = colon >= 0 ? groupId.substring(colon + 1) : groupId;
  return bare
      .split(RegExp(r'[-_]'))
      .where((w) => w.isNotEmpty)
      .map((w) => w.length == 1 ? w.toUpperCase() : w[0].toUpperCase() + w.substring(1))
      .join(' ');
}

/// Gom danh sách model thành nhóm, giữ thứ tự xuất hiện lần đầu.
/// [labels] là nhãn hiển thị theo id đầy đủ, có thể rỗng.
List<ModelGroup> groupModels(
  Iterable<String> models,
  Map<String, String> labels, {
  List<String> effortLevels = kFallbackEffortLevels,
}) {
  final order = <String>[];
  final byGroup = <String, List<ModelOption>>{};
  for (final id in models) {
    final parsed = parseModelId(id, levels: effortLevels);
    final option = ModelOption(
      id: id,
      groupId: parsed.groupId,
      effort: parsed.effort,
      label: labels[id] ?? '',
    );
    byGroup.putIfAbsent(parsed.groupId, () {
      order.add(parsed.groupId);
      return <ModelOption>[];
    }).add(option);
  }

  return [
    for (final groupId in order)
      () {
        final options = byGroup[groupId]!
          ..sort((a, b) => _effortRank(a.effort, effortLevels).compareTo(_effortRank(b.effort, effortLevels)));
        final sample = options.firstWhere(
          (o) => o.label.isNotEmpty,
          orElse: () => options.first,
        );
        final label = sample.label.isNotEmpty
            ? _stripEffortSuffixFromLabel(sample.label)
            : _fallbackGroupLabel(groupId);
        return ModelGroup(id: groupId, label: label, options: options);
      }(),
  ];
}

int _effortRank(String? effort, List<String> levels) {
  if (effort == null) return -1;
  return levels.indexOf(effort);
}
