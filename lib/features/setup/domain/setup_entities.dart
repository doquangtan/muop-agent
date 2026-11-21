/// Một tool mà muop-agent-server cần (hoặc tùy chọn) trên máy đang chạy server.
class SetupTool {
  const SetupTool({
    required this.id,
    required this.label,
    required this.group,
    required this.installed,
    required this.path,
    required this.installable,
    required this.hint,
  });

  final String id;
  final String label;

  /// `base` (bắt buộc, cài thủ công), `cli` (chọn agy/claude), `optional`
  final String group;
  final bool installed;
  final String path;

  /// Server có thể tự cài tool này (chỉ các CLI)
  final bool installable;

  /// Lệnh gợi ý khi chưa cài
  final String hint;

  factory SetupTool.fromJson(Map<String, dynamic> json) {
    return SetupTool(
      id: json['id'] as String? ?? '',
      label: json['label'] as String? ?? '',
      group: json['group'] as String? ?? 'optional',
      installed: json['installed'] as bool? ?? false,
      path: json['path'] as String? ?? '',
      installable: json['installable'] as bool? ?? false,
      hint: json['hint'] as String? ?? '',
    );
  }
}

/// Tiến trình cài một CLI trên server
class SetupJob {
  const SetupJob({
    required this.tool,
    required this.state,
    required this.log,
    required this.error,
    required this.startedAt,
    required this.finishedAt,
  });

  final String tool;

  /// `running` | `done` | `failed`
  final String state;
  final List<String> log;
  final String error;
  final String startedAt;
  final String finishedAt;

  bool get running => state == 'running';

  factory SetupJob.fromJson(Map<String, dynamic> json) {
    return SetupJob(
      tool: json['tool'] as String? ?? '',
      state: json['state'] as String? ?? '',
      log: (json['log'] as List<dynamic>? ?? const [])
          .map((e) => e.toString())
          .toList(),
      error: json['error'] as String? ?? '',
      startedAt: json['startedAt'] as String? ?? '',
      finishedAt: json['finishedAt'] as String? ?? '',
    );
  }
}

/// SSH của máy này: điều kiện bắt buộc của màn cài đặt (mục `ssh` trong setup:status).
class SetupSsh {
  const SetupSsh({
    required this.client,
    required this.sshdRunning,
    required this.username,
    required this.keyPath,
    required this.keyExists,
    required this.publicKey,
    required this.keyAuthorized,
    required this.loginOk,
    required this.ready,
  });

  /// Có lệnh `ssh` (OpenSSH client)
  final bool client;

  /// sshd đang nghe cổng 22 trên máy này
  final bool sshdRunning;
  final String username;
  final String keyPath;
  final bool keyExists;

  /// Dòng public key của server (để người dùng publish thủ công nếu cần)
  final String publicKey;

  /// Public key đã có trong authorized_keys của user
  final bool keyAuthorized;

  /// Lần thử đăng nhập SSH gần nhất thành công
  final bool loginOk;

  /// Đủ điều kiện để mở terminal đồng ý điều khoản agy
  final bool ready;

  static const empty = SetupSsh(
    client: false,
    sshdRunning: false,
    username: '',
    keyPath: '',
    keyExists: false,
    publicKey: '',
    keyAuthorized: false,
    loginOk: false,
    ready: false,
  );

  factory SetupSsh.fromJson(Map<String, dynamic> json) => SetupSsh(
        client: json['client'] == true,
        sshdRunning: json['sshdRunning'] == true,
        username: '${json['username'] ?? ''}',
        keyPath: '${json['keyPath'] ?? ''}',
        keyExists: json['keyExists'] == true,
        publicKey: '${json['publicKey'] ?? ''}',
        keyAuthorized: json['keyAuthorized'] == true,
        loginOk: json['loginOk'] == true,
        ready: json['ready'] == true,
      );
}

/// Trạng thái khởi tạo của server. `ok == false` nghĩa là không gọi được server hoặc lệnh bị từ chối.
class SetupStatus {
  const SetupStatus({
    required this.ok,
    required this.error,
    required this.completed,
    required this.selectedClis,
    required this.tools,
    required this.job,
    required this.ssh,
  });

  final bool ok;
  final String error;

  /// Đã vào màn hình chính ít nhất một lần (hoặc đã bỏ qua bước đăng nhập)
  final bool completed;
  final List<String> selectedClis;
  final List<SetupTool> tools;
  final SetupJob? job;
  final SetupSsh ssh;

  static const empty = SetupStatus(
    ok: false,
    error: '',
    completed: false,
    selectedClis: [],
    tools: [],
    job: null,
    ssh: SetupSsh.empty,
  );

  factory SetupStatus.failure(String error) => SetupStatus(
        ok: false,
        error: error,
        completed: false,
        selectedClis: const [],
        tools: const [],
        job: null,
        ssh: SetupSsh.empty,
      );

  factory SetupStatus.fromJson(Map<String, dynamic> json) {
    final jobJson = json['job'];
    final sshJson = json['ssh'];
    return SetupStatus(
      ok: json['ok'] as bool? ?? false,
      error: json['error'] as String? ?? '',
      completed: json['completed'] as bool? ?? false,
      selectedClis: (json['selectedClis'] as List<dynamic>? ?? const [])
          .map((e) => e.toString())
          .toList(),
      tools: (json['tools'] as List<dynamic>? ?? const [])
          .map((e) => SetupTool.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      job: jobJson is Map
          ? SetupJob.fromJson(Map<String, dynamic>.from(jobJson))
          : null,
      ssh: sshJson is Map
          ? SetupSsh.fromJson(Map<String, dynamic>.from(sshJson))
          : SetupSsh.empty,
    );
  }

  SetupTool? tool(String id) {
    for (final t in tools) {
      if (t.id == id) return t;
    }
    return null;
  }

  bool isInstalled(String id) => tool(id)?.installed ?? false;

  /// Cần mở wizard khi thiếu một mục: chưa khởi tạo, chưa chọn CLI, CLI đã chọn chưa cài,
  /// thiếu tool bắt buộc, hoặc SSH của máy này chưa sẵn sàng. Đăng nhập agy/claude không tính.
  bool get needsSetup =>
      !completed ||
      selectedClis.isEmpty ||
      selectedClis.any((id) => !isInstalled(id)) ||
      tools.any((t) => t.group == 'base' && !t.installed) ||
      !ssh.ready;
}
