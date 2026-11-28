/// Chia sẻ lịch sử một conversation bằng link tới API của server.
///
/// Link trỏ tới `GET /api/session/share`: trang `page` (đếm từ 0) của các bước có
/// `step_index` từ `fromStep` tới tin mới nhất. Agent đọc từng trang để nắm lại ngữ cảnh.
library;

const int kSharePageSize = 50;

/// Link của trang [page] (mặc định trang đầu)
String buildShareUrl({
  required String baseUrl,
  required String sessionId,
  required int fromStep,
  int page = 0,
  int limit = kSharePageSize,
}) {
  final base = baseUrl.endsWith('/')
      ? baseUrl.substring(0, baseUrl.length - 1)
      : baseUrl;
  final query = Uri(
    queryParameters: {
      'id': sessionId,
      'from_step': '$fromStep',
      'page': '$page',
      'limit': '$limit',
    },
  ).query;
  return '$base/api/session/share?$query';
}

/// Prompt mặc định gửi cho agent: dẫn link, tổng số trang và cách đổi trang
String buildSharePrompt({required String url, required int totalPages}) {
  final last = totalPages <= 0 ? 0 : totalPages - 1;
  return 'Hãy đọc toàn bộ lịch sử từ api $url, có tổng số trang là $totalPages '
      '(đổi tham số page từ 0 đến $last, các tham số khác giữ nguyên) '
      'và tiếp tục thực hiện công việc.';
}

/// Một trang đã tải của link chia sẻ (chỉ lấy phần cần để dựng prompt)
class SessionSharePage {
  const SessionSharePage({
    required this.sessionId,
    required this.fromStep,
    required this.page,
    required this.pageSize,
    required this.totalPages,
    required this.stepCount,
  });

  final String sessionId;
  final int fromStep;
  final int page;
  final int pageSize;
  final int totalPages;

  /// Số bước có trong trang này
  final int stepCount;

  factory SessionSharePage.fromJson(Map<String, dynamic> json) {
    int n(String key) => (json[key] as num?)?.toInt() ?? 0;
    return SessionSharePage(
      sessionId: json['sessionId']?.toString() ?? '',
      fromStep: n('fromStep'),
      page: n('page'),
      pageSize: n('pageSize'),
      totalPages: n('totalPages'),
      stepCount: (json['steps'] as List?)?.length ?? 0,
    );
  }
}
