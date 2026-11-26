/// Mục trong thư mục trên máy SSH đã lưu
class SftpEntry {
  const SftpEntry({
    required this.name,
    required this.path,
    required this.isDir,
    required this.isLink,
    required this.size,
    required this.modified,
    required this.mode,
    this.modifiedUnix,
  });

  final String name;
  final String path;
  final bool isDir;
  final bool isLink;
  final int size;

  /// Thời điểm như `ls` in ra (ví dụ `Nov 25 10:00`)
  final String modified;

  /// Chuỗi quyền, ví dụ `-rw-r--r--`
  final String mode;

  /// Giây unix; chỉ có với "Máy này" (null với máy SSH)
  final int? modifiedUnix;

  factory SftpEntry.fromJson(Map<String, dynamic> json) {
    return SftpEntry(
      name: '${json['name'] ?? ''}',
      path: '${json['path'] ?? ''}',
      isDir: json['isDir'] == true,
      isLink: json['isLink'] == true,
      size: (json['size'] as num?)?.toInt() ?? 0,
      modified: '${json['modified'] ?? ''}',
      mode: '${json['mode'] ?? ''}',
      modifiedUnix: (json['modifiedUnix'] as num?)?.toInt(),
    );
  }
}

/// Phiên SFTP đang mở trên server
class SftpSession {
  const SftpSession({
    required this.sessionId,
    required this.hostId,
    required this.hostName,
    required this.home,
  });

  final String sessionId;
  final int hostId;
  final String hostName;

  /// Thư mục đăng nhập của user trên máy đích
  final String home;

  factory SftpSession.fromJson(Map<String, dynamic> json) {
    return SftpSession(
      sessionId: '${json['sessionId'] ?? ''}',
      hostId: (json['hostId'] as num?)?.toInt() ?? 0,
      hostName: '${json['hostName'] ?? ''}',
      home: '${json['home'] ?? '/'}',
    );
  }
}

/// Kết quả một lệnh SFTP. Các trường tùy chọn tùy lệnh (phiên, mục, nội dung).
class SftpReply {
  const SftpReply({
    required this.ok,
    required this.error,
    this.needsPassword = false,
    this.passwordWrong = false,
    this.exists = false,
    this.sessionGone = false,
    this.session,
    this.entries = const [],
    this.content = '',
    this.binary = false,
    this.size = 0,
    this.downloadId = '',
    this.downloadName = '',
  });

  final bool ok;
  final String error;

  /// Máy cần mật khẩu (chưa có hoặc sai): app hỏi rồi mở lại phiên
  final bool needsPassword;

  /// Lần nhập mật khẩu trước bị từ chối
  final bool passwordWrong;

  /// Đích đã tồn tại (khi tải lên không ghi đè)
  final bool exists;

  /// Phiên đã kết thúc trên server: app mở lại phiên
  final bool sessionGone;

  final SftpSession? session;
  final List<SftpEntry> entries;

  /// Nội dung file văn bản (khi đọc để sửa)
  final String content;

  /// File nhị phân: không mở để sửa
  final bool binary;

  final int size;

  /// Liên kết tải xuống đã chuẩn bị (dùng với GET /api/sftp/download/{id})
  final String downloadId;

  /// Tên file tải về (file đơn hoặc tên gói zip)
  final String downloadName;

  factory SftpReply.failure(String error) => SftpReply(ok: false, error: error);

  factory SftpReply.fromJson(Map<String, dynamic> json) {
    final session = json['session'];
    final entries = (json['entries'] as List?) ?? const [];
    return SftpReply(
      ok: json['ok'] == true,
      error: '${json['error'] ?? ''}',
      needsPassword: json['needsPassword'] == true,
      passwordWrong: json['passwordWrong'] == true,
      exists: json['exists'] == true,
      sessionGone: json['sessionGone'] == true,
      session: session is Map
          ? SftpSession.fromJson(Map<String, dynamic>.from(session))
          : null,
      entries: entries
          .whereType<Map>()
          .map((e) => SftpEntry.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
      content: '${json['content'] ?? ''}',
      binary: json['binary'] == true,
      size: (json['size'] as num?)?.toInt() ?? 0,
      downloadId: '${json['downloadId'] ?? ''}',
      downloadName: '${json['name'] ?? ''}',
    );
  }
}

/// Đường dẫn tuyệt đối: thư mục cha ("/" với mục ở gốc)
String sftpParentOf(String path) {
  final trimmed = path.length > 1 ? path.replaceAll(RegExp(r'/+$'), '') : path;
  final idx = trimmed.lastIndexOf('/');
  if (idx <= 0) return '/';
  return trimmed.substring(0, idx);
}

/// Nối thư mục và tên mục
String sftpJoin(String dir, String name) => dir.endsWith('/') ? '$dir$name' : '$dir/$name';
