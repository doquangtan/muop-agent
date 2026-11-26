
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
    this.needsPassword = false,
    this.passwordKind = 'ssh',
  });

  final bool ok;
  final int? exitCode;
  final String stdout;
  final String stderr;
  final String error;

  /// `ssh` cần mật khẩu (chưa có hoặc sai): app hỏi người dùng rồi chạy lại. `error` là lý do.
  final bool needsPassword;

  /// Loại mật khẩu cần: `ssh` hoặc `sudo` (lệnh sudo trên máy này)
  final String passwordKind;

  factory SshExecResult.fromJson(Map<String, dynamic> json) {
    return SshExecResult(
      ok: json['ok'] == true,
      exitCode: (json['exitCode'] as num?)?.toInt(),
      stdout: '${json['stdout'] ?? ''}',
      stderr: '${json['stderr'] ?? ''}',
      error: '${json['error'] ?? ''}',
      needsPassword: json['needsPassword'] == true,
      passwordKind: '${json['passwordKind'] ?? 'ssh'}',
    );
  }
}

/// Mật khẩu người dùng nhập trong hộp thoại: có lưu cho máy này hay không
class SshPasswordInput {
  const SshPasswordInput({required this.password, required this.save});

  final String password;
  final bool save;
}

/// `ssh` trên server đang hỏi mật khẩu của một phiên terminal
class SshPasswordRequest {
  const SshPasswordRequest({
    required this.sessionId,
    required this.hostName,
    required this.wrong,
    this.kind = 'ssh',
  });

  final String sessionId;
  final String hostName;

  /// Lần nhập trước bị từ chối
  final bool wrong;

  /// `ssh` (mật khẩu đăng nhập máy khác) hoặc `sudo` (mật khẩu sudo trên máy này)
  final String kind;

  factory SshPasswordRequest.fromJson(Map<String, dynamic> json) {
    return SshPasswordRequest(
      sessionId: '${json['sessionId'] ?? ''}',
      hostName: '${json['hostName'] ?? ''}',
      wrong: json['wrong'] == true,
      kind: '${json['kind'] ?? 'ssh'}',
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
    this.awaitingPassword = false,
    this.passwordWrong = false,
    this.passwordKind = 'ssh',
  });

  final bool ok;
  final String sessionId;
  final String hostName;
  final List<int> buffer;
  final String error;

  /// Phiên đang chờ mật khẩu: hiện hộp thoại nhập
  final bool awaitingPassword;

  /// Lần nhập trước bị từ chối
  final bool passwordWrong;

  /// Loại mật khẩu đang chờ: `ssh` hoặc `sudo`
  final String passwordKind;
}
