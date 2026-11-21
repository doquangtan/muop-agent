
/// Máy SSH đã lưu trên server (không chứa mật khẩu hay private key)
class SshHost {
  const SshHost({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.username,
    required this.authType,
    required this.hasPassword,
    required this.hasKey,
    this.builtin = false,
  });

  final int id;
  final String name;
  final String host;
  final int port;
  final String username;
  /// `password` hoặc `key`
  final String authType;
  final bool hasPassword;
  final bool hasKey;
  /// Mục mặc định "Máy này" của server: chỉ dùng được, không sửa hay xóa
  final bool builtin;

  String get address => '$username@$host:$port';

  factory SshHost.fromJson(Map<String, dynamic> json) {
    return SshHost(
      id: (json['id'] as num?)?.toInt() ?? 0,
      name: '${json['name'] ?? ''}',
      host: '${json['host'] ?? ''}',
      port: (json['port'] as num?)?.toInt() ?? 22,
      username: '${json['username'] ?? ''}',
      authType: '${json['authType'] ?? 'password'}',
      hasPassword: json['hasPassword'] == true,
      hasKey: json['hasKey'] == true,
      builtin: json['builtin'] == true,
    );
  }
}

/// Kết quả chạy một lệnh SSH
class SshExecResult {
  const SshExecResult({
    required this.ok,
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    required this.error,
  });

  final bool ok;
  final int? exitCode;
  final String stdout;
  final String stderr;
  final String error;

  factory SshExecResult.fromJson(Map<String, dynamic> json) {
    return SshExecResult(
      ok: json['ok'] == true,
      exitCode: (json['exitCode'] as num?)?.toInt(),
      stdout: '${json['stdout'] ?? ''}',
      stderr: '${json['stderr'] ?? ''}',
      error: '${json['error'] ?? ''}',
    );
  }
}

/// Kết quả mở phiên terminal SSH
class SshTerminalOpenResult {
  const SshTerminalOpenResult({
    required this.ok,
    required this.sessionId,
    required this.error,
  });

  final bool ok;
  final String sessionId;
  final String error;
}

/// Dữ liệu đầu ra của một phiên terminal (đã giải mã base64)
class SshTerminalData {
  const SshTerminalData({required this.sessionId, required this.bytes});

  final String sessionId;
  final List<int> bytes;
}

/// Phiên terminal đã kết thúc
class SshTerminalClosed {
  const SshTerminalClosed({required this.sessionId, required this.exitCode});

  final String sessionId;
  final int? exitCode;
}

/// Phiên terminal SSH đang chạy trên server
class SshTerminalSession {
  const SshTerminalSession({
    required this.sessionId,
    required this.hostId,
    required this.hostName,
    required this.startedAt,
  });

  final String sessionId;
  final int hostId;
  final String hostName;
  final String startedAt;

  factory SshTerminalSession.fromJson(Map<String, dynamic> json) {
    return SshTerminalSession(
      sessionId: '${json['sessionId'] ?? ''}',
      hostId: (json['hostId'] as num?)?.toInt() ?? 0,
      hostName: '${json['hostName'] ?? ''}',
      startedAt: '${json['startedAt'] ?? ''}',
    );
  }
}

/// Kết quả gắn lại phiên: đầu ra đã đệm để vẽ lại màn hình
class SshTerminalAttachResult {
  const SshTerminalAttachResult({
    required this.ok,
    required this.sessionId,
    required this.hostName,
    required this.buffer,
    required this.error,
  });

  final bool ok;
  final String sessionId;
  final String hostName;
  final List<int> buffer;
  final String error;
}
