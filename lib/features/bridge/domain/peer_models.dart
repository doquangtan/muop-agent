/// Quy tắc dùng chung cho model và conversation chạy trên máy phụ (máy A) qua cầu nối.
///
/// Model của máy phụ được thêm vào danh sách model của app với tiền tố `peer:`,
/// ví dụ `peer:claude-cli:claude-haiku-5-5-low`. Khi gửi, tiền tố được bỏ và lệnh đi
/// qua `/api/bridge/send` của server đang kết nối, nên máy phụ tự thêm nhãn nguồn.

library;

/// Tiền tố đánh dấu model chạy trên máy phụ
const String kPeerModelPrefix = 'peer:';

bool isPeerModel(String id) => id.startsWith(kPeerModelPrefix);

/// Id model trong danh sách của app, từ id trên máy phụ
String toPeerModelId(String remoteId) => '$kPeerModelPrefix$remoteId';

/// Id model trên máy phụ (bỏ tiền tố `peer:`). Id thường được trả nguyên.
String remoteModelId(String id) =>
    isPeerModel(id) ? id.substring(kPeerModelPrefix.length) : id;

/// Danh sách model hiển thị: model của máy đang kết nối trước, rồi model máy phụ (không trùng)
List<String> mergeModelLists(List<String> local, List<String> peer) {
  final merged = [...local];
  for (final model in peer) {
    if (!merged.contains(model)) merged.add(model);
  }
  return merged;
}

/// Nhãn hiển thị của model máy phụ. Không gắn tên máy vào nhãn: menu gom model theo khối
/// `Claude Cli · <máy>` / `Agy · <máy>`, nên tên máy nằm ở tiêu đề khối.
Map<String, String> peerModelLabels({
  required Iterable<String> remoteModels,
  required Map<String, String> remoteLabels,
}) {
  final labels = <String, String>{};
  for (final id in remoteModels) {
    final label = remoteLabels[id] ?? '';
    labels[toPeerModelId(id)] = label.isEmpty ? id : label;
  }
  return labels;
}

/// Lý do khóa khung chat, null nếu được phép gửi. Chỉ khóa khi model đang chọn chạy trên máy phụ
/// và máy phụ mất kết nối.
String? peerBlockReason({
  required String model,
  required bool connected,
  required String host,
}) {
  if (!isPeerModel(model) || connected) return null;
  final who = host.isEmpty ? 'máy phụ' : 'máy phụ $host';
  return 'Mất kết nối tới $who. Khung chat bị khóa cho model này cho đến khi kết nối lại.';
}

/// Tiêu đề conversation máy phụ trong sidebar. Không gắn tag chữ: conversation máy phụ được
/// nhận biết bằng màu (tertiary). Bỏ nhãn `[Từ máy …]` của bản cũ còn trong lịch sử.
String peerSessionTitle({required String title}) {
  final t = title.trim().replaceFirst(RegExp(r'^\[Từ máy [^\]]*\]\s*'), '').trim();
  return t.isEmpty ? '(không tiêu đề)' : t;
}

/// JSON conversation từ máy phụ, đổi `selectedModel` sang id có tiền tố `peer:` để khớp
/// danh sách model của app (mở lại conversation sẽ chọn đúng model của máy phụ).
Map<String, dynamic> asPeerSessionJson(Map<String, dynamic> json) {
  final copy = Map<String, dynamic>.from(json);
  final selected = '${copy['selectedModel'] ?? ''}';
  copy['selectedModel'] = selected.isEmpty ? '' : toPeerModelId(selected);
  // Model dùng cho context chip: cùng id với `selectedModel` để tra giới hạn context của máy phụ
  final ctx = '${copy['contextModel'] ?? ''}';
  if (ctx.isNotEmpty) copy['contextModel'] = toPeerModelId(ctx);
  return copy;
}
