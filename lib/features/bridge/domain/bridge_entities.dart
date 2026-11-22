/// Trạng thái cầu nối của server đang kết nối tới máy A (`GET /api/bridge/status`)
class BridgeStatus {
  const BridgeStatus({
    required this.url,
    required this.connected,
    required this.error,
    this.ok = true,
    this.registered = false,
    this.registerError = '',
  });

  /// Địa chỉ máy A đã lưu trên server (rỗng nếu chưa cấu hình)
  final String url;
  final bool connected;

  /// Lỗi của lần kết nối gần nhất (rỗng khi đang kết nối tốt)
  final String error;

  /// false khi server từ chối yêu cầu (ví dụ địa chỉ sai); `error` ghi lý do
  final bool ok;

  /// Máy phụ đã đăng ký máy này khi được thêm vào cầu nối (chỉ có sau `POST /api/bridge/peer`)
  final bool registered;

  /// Lý do máy phụ không đăng ký được (ví dụ thiếu FUSE, không kết nối được tới máy này)
  final String registerError;

  bool get configured => url.isNotEmpty;

  factory BridgeStatus.fromJson(Map<String, dynamic> json) => BridgeStatus(
        url: (json['url'] ?? '') as String,
        connected: json['connected'] == true,
        error: (json['error'] ?? '') as String,
        ok: json['ok'] != false,
        registered: json['registered'] == true,
        registerError: (json['registerError'] ?? '') as String,
      );

  factory BridgeStatus.failure(String error) =>
      BridgeStatus(url: '', connected: false, error: error, ok: false);
}

/// Kết quả gửi lượt chat tới máy A (ack của `chat:send` trên A)
class BridgeSendResult {
  const BridgeSendResult({
    required this.ok,
    required this.error,
    this.conversationId = '',
    this.source = '',
  });

  final bool ok;
  final String error;
  final String conversationId;

  /// `claude-cli` hoặc `agy`, do máy A trả về
  final String source;

  factory BridgeSendResult.fromJson(Map<String, dynamic> json) => BridgeSendResult(
        ok: json['ok'] == true,
        error: (json['error'] ?? '') as String,
        conversationId: (json['conversationId'] ?? '') as String,
        source: (json['source'] ?? '') as String,
      );

  factory BridgeSendResult.failure(String error) =>
      BridgeSendResult(ok: false, error: error);
}

/// Thông tin máy A lấy qua cầu nối (`GET /api/bridge/meta` → `/api/meta` của A):
/// tên máy và danh sách model để thêm vào màn chat.
class PeerMeta {
  const PeerMeta({
    required this.ok,
    required this.hostname,
    required this.models,
    required this.labels,
    required this.error,
  });

  final bool ok;
  final String hostname;
  final List<String> models;
  final Map<String, String> labels;
  final String error;

  factory PeerMeta.fromJson(Map<String, dynamic> json) {
    final rawModels = json['availableModels'];
    final rawLabels = json['modelLabels'];
    final models = rawModels is List
        ? rawModels.map((e) => '$e').where((e) => e.isNotEmpty).toList()
        : <String>[];
    final labels = <String, String>{};
    if (rawLabels is Map) {
      rawLabels.forEach((k, v) => labels['$k'] = '$v');
    }
    // Lỗi từ server (ok=false) hoặc máy A chưa có model: báo lý do thay vì danh sách rỗng im lặng
    final String error;
    if (json['ok'] == false) {
      error = '${json['error'] ?? 'Không lấy được thông tin máy phụ'}';
    } else if (models.isEmpty) {
      error = 'Máy phụ chưa có model nào';
    } else {
      error = '';
    }
    return PeerMeta(
      ok: error.isEmpty,
      hostname: '${json['hostname'] ?? ''}',
      models: models,
      labels: labels,
      error: error,
    );
  }

  factory PeerMeta.failure(String error) =>
      PeerMeta(ok: false, hostname: '', models: const [], labels: const {}, error: error);
}

/// Một sự kiện Socket.IO do server chuyển tiếp từ máy A (tên đã bỏ tiền tố `bridge:`)
class BridgeEvent {
  const BridgeEvent({required this.name, required this.data});

  /// Ví dụ `chat:stream`, `session:update`, `status`
  final String name;
  final Object? data;
}

/// Tiến trình một lượt đang chạy trên máy A (sự kiện `bridge:chat:stream`)
class BridgeStreamUpdate {
  const BridgeStreamUpdate({
    required this.conversationId,
    required this.projectPath,
    required this.userPrompt,
    required this.streamingText,
    required this.isRunning,
    required this.activeStepType,
  });

  final String conversationId;
  final String projectPath;
  final String userPrompt;
  final String streamingText;
  final bool isRunning;
  final String activeStepType;

  factory BridgeStreamUpdate.fromJson(Map<String, dynamic> json) => BridgeStreamUpdate(
        conversationId: '${json['conversationId'] ?? ''}',
        projectPath: '${json['projectPath'] ?? ''}',
        userPrompt: '${json['userPrompt'] ?? ''}',
        streamingText: '${json['streamingText'] ?? ''}',
        isRunning: json['isRunning'] == true,
        activeStepType: '${json['activeStepType'] ?? ''}',
      );
}

/// Tóm tắt một conversation trên máy A (sự kiện `bridge:session:update`)
class BridgeSessionSummary {
  const BridgeSessionSummary({
    required this.id,
    required this.title,
    required this.status,
  });

  final String id;
  final String title;
  final String status;

  factory BridgeSessionSummary.fromJson(Map<String, dynamic> json) => BridgeSessionSummary(
        id: '${json['id'] ?? ''}',
        title: '${json['title'] ?? ''}',
        status: '${json['status'] ?? ''}',
      );
}
