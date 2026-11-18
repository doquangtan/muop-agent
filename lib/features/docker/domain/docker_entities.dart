
/// Container Docker đang chạy trên máy SSH
class DockerContainer {
  const DockerContainer({
    required this.id,
    required this.name,
    required this.image,
    required this.state,
    required this.status,
    required this.ports,
    required this.project,
    required this.service,
    required this.created,
  });

  final String id;
  final String name;
  final String image;
  final String state;
  final String status;
  final String ports;
  /// Tên compose project, rỗng nếu container không thuộc compose
  final String project;
  final String service;
  final String created;

  factory DockerContainer.fromJson(Map<String, dynamic> json) {
    return DockerContainer(
      id: '${json['id'] ?? ''}',
      name: '${json['name'] ?? ''}',
      image: '${json['image'] ?? ''}',
      state: '${json['state'] ?? ''}',
      status: '${json['status'] ?? ''}',
      ports: '${json['ports'] ?? ''}',
      project: '${json['project'] ?? ''}',
      service: '${json['service'] ?? ''}',
      created: '${json['created'] ?? ''}',
    );
  }
}

/// Phiên Docker trên máy SSH: kết nối giữ sẵn tới máy và kết quả quét gần nhất
class DockerSession {
  const DockerSession({
    required this.sessionId,
    required this.hostId,
    required this.hostName,
    required this.startedAt,
    required this.connected,
    required this.scannedAt,
    required this.error,
    required this.containers,
  });

  final String sessionId;
  final int hostId;
  final String hostName;
  final String startedAt;
  final bool connected;
  final String scannedAt;
  /// Lỗi của lần kiểm tra/quét gần nhất (rỗng = ổn)
  final String error;
  final List<DockerContainer> containers;

  factory DockerSession.fromJson(Map<String, dynamic> json) {
    final items = (json['containers'] as List?) ?? const [];
    return DockerSession(
      sessionId: '${json['sessionId'] ?? ''}',
      hostId: (json['hostId'] as num?)?.toInt() ?? 0,
      hostName: '${json['hostName'] ?? ''}',
      startedAt: '${json['startedAt'] ?? ''}',
      connected: json['connected'] == true,
      scannedAt: '${json['scannedAt'] ?? ''}',
      error: '${json['error'] ?? ''}',
      containers: items
          .whereType<Map>()
          .map((e) => DockerContainer.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
    );
  }
}

/// Kết quả của một API Docker (mở, quét, thao tác)
class DockerSessionResult {
  const DockerSessionResult({
    required this.ok,
    required this.error,
    required this.session,
    this.ended = false,
  });

  final bool ok;
  final String error;
  /// Trạng thái phiên sau thao tác (có thể null nếu không mở/tìm được phiên)
  final DockerSession? session;
  /// Server báo phiên không còn tồn tại (đã kết thúc từ app khác hoặc server đã khởi động lại)
  final bool ended;

  factory DockerSessionResult.fromJson(
    Map<String, dynamic> json, {
    bool ended = false,
  }) {
    final raw = json['session'];
    return DockerSessionResult(
      ok: json['ok'] == true,
      error: '${json['error'] ?? ''}',
      session: raw is Map
          ? DockerSession.fromJson(Map<String, dynamic>.from(raw))
          : null,
      ended: ended,
    );
  }

  factory DockerSessionResult.failure(String error) =>
      DockerSessionResult(ok: false, error: error, session: null);
}

/// Kết quả mở luồng log container
class DockerLogsOpenResult {
  const DockerLogsOpenResult({
    required this.ok,
    required this.streamId,
    required this.error,
  });

  final bool ok;
  final String streamId;
  final String error;
}

/// Một lô dòng log từ server (đã có timestamp của docker)
class DockerLogsChunk {
  const DockerLogsChunk({required this.streamId, required this.lines});

  final String streamId;
  final List<String> lines;
}

/// Luồng log đã kết thúc (container dừng, kênh SSH đóng, hoặc đã bị dừng)
class DockerLogsEnd {
  const DockerLogsEnd({required this.streamId, required this.exitCode});

  final String streamId;
  final int? exitCode;
}
