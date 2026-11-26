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
    this.source = '',
    this.overridden = '',
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

  /// Nguồn đường dẫn: `override` (người dùng chọn), `which`, `dev` (bản build trong repo), hoặc rỗng
  final String source;

  /// Đường dẫn người dùng đã lưu (rỗng nếu chưa chọn)
  final String overridden;

  factory SetupTool.fromJson(Map<String, dynamic> json) {
    return SetupTool(
      id: json['id'] as String? ?? '',
      label: json['label'] as String? ?? '',
      group: json['group'] as String? ?? 'optional',
      installed: json['installed'] as bool? ?? false,
      path: json['path'] as String? ?? '',
      installable: json['installable'] as bool? ?? false,
      hint: json['hint'] as String? ?? '',
      source: json['source'] as String? ?? '',
      overridden: json['overridden'] as String? ?? '',
    );
  }
}

/// Một gói apt mà server quản lý (danh sách cố định ở server, `APT_PACKAGES`)
class SetupAptPackage {
  const SetupAptPackage({
    required this.package,
    required this.label,
    required this.note,
    required this.installed,
    this.required = false,
  });

  final String package;
  final String label;

  /// Lý do cần gói
  final String note;

  /// Bắt buộc: chưa cài thì wizard không cho đi tiếp
  final bool required;
  final bool installed;

  factory SetupAptPackage.fromJson(Map<String, dynamic> json) {
    return SetupAptPackage(
      package: json['package'] as String? ?? '',
      label: json['label'] as String? ?? '',
      note: json['note'] as String? ?? '',
      installed: json['installed'] as bool? ?? false,
      required: json['required'] as bool? ?? false,
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

/// Một thư mục con trong kết quả duyệt thư mục trên server
class SetupDirEntry {
  const SetupDirEntry({required this.name, required this.path});

  final String name;
  final String path;

  factory SetupDirEntry.fromJson(Map<String, dynamic> json) => SetupDirEntry(
        name: json['name'] as String? ?? '',
        path: json['path'] as String? ?? '',
      );
}

/// Kết quả duyệt một thư mục trên máy server (cây thư mục để chọn project)
class SetupDirListing {
  const SetupDirListing({
    required this.ok,
    required this.error,
    required this.path,
    required this.parent,
    required this.home,
    required this.dirs,
  });

  final bool ok;
  final String error;

  /// Thư mục đang xem (tuyệt đối, đã chuẩn hóa trên server)
  final String path;

  /// Thư mục cha; rỗng khi ở thư mục gốc
  final String parent;

  /// Thư mục home của user chạy server (điểm bắt đầu)
  final String home;
  final List<SetupDirEntry> dirs;

  factory SetupDirListing.failure(String error) => SetupDirListing(
        ok: false,
        error: error,
        path: '',
        parent: '',
        home: '',
        dirs: const [],
      );

  factory SetupDirListing.fromJson(Map<String, dynamic> json) => SetupDirListing(
        ok: json['ok'] as bool? ?? false,
        error: json['error'] as String? ?? '',
        path: json['path'] as String? ?? '',
        parent: json['parent'] as String? ?? '',
        home: json['home'] as String? ?? '',
        dirs: (json['dirs'] as List<dynamic>? ?? const [])
            .map((e) => SetupDirEntry.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
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
    this.aptPackages = const [],
    this.aptInstallCommand = '',
    this.brewPackages = const [],
    this.brewInstallCommand = '',
    this.workspaceRoot = '',
    this.workspaceReady = false,
    this.platform = 'linux',
  });

  /// Nền tảng của máy chạy server: `linux`, `macos` hoặc `other`. Quyết định nội dung màn Khởi tạo
  /// (mục apt và FUSE chỉ có trên Linux; macOS dùng Xcode Command Line Tools).
  final String platform;

  /// Server đang chạy trên macOS
  bool get isMacOS => platform == 'macos';

  /// Thư mục project đã chọn khi khởi tạo (rỗng nếu chưa chọn)
  final String workspaceRoot;

  /// Đã khởi tạo xong và có thư mục project: đang quét project
  final bool workspaceReady;

  final bool ok;
  final String error;

  /// Các gói apt server quản lý, kèm trạng thái đã cài
  final List<SetupAptPackage> aptPackages;

  /// Lệnh cài các gói còn thiếu (rỗng nếu đủ); server tạo, client chạy trong terminal
  final String aptInstallCommand;

  /// Các cask Homebrew server quản lý trên macOS (FUSE-T...), kèm trạng thái đã cài
  final List<SetupAptPackage> brewPackages;

  /// Lệnh `brew install --cask ...` cho các cask còn thiếu (rỗng nếu đủ hoặc chưa có Homebrew)
  final String brewInstallCommand;

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
      aptPackages: (json['aptPackages'] as List<dynamic>? ?? const [])
          .map((e) => SetupAptPackage.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      aptInstallCommand: json['aptInstallCommand'] as String? ?? '',
      brewPackages: (json['brewPackages'] as List<dynamic>? ?? const [])
          .map((e) => SetupAptPackage.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      brewInstallCommand: json['brewInstallCommand'] as String? ?? '',
      workspaceRoot: json['workspaceRoot'] as String? ?? '',
      workspaceReady: json['workspaceReady'] as bool? ?? false,
      platform: json['platform'] as String? ?? 'linux',
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
  /// hoặc thiếu tool bắt buộc. SSH không tính: máy này dùng shell của server trực tiếp. Đăng nhập agy/claude không tính.
  /// Server đang cài một CLI (có thể do app đã thoát và mở lại giữa chừng)
  bool get installing => job != null && job!.running;

  bool get needsSetup =>
      !completed ||
      installing ||
      workspaceRoot.isEmpty ||
      // Chỉ cần một CLI đã chọn được cài là đủ (chọn cả hai thì cài thêm sau cũng không chặn)
      !selectedClis.any(isInstalled) ||
      tools.any((t) => t.group == 'base' && !t.installed) ||
      // macOS: gói Homebrew bắt buộc (FUSE-T) phải cài qua wizard
      brewPackages.any((p) => p.required && !p.installed);
}
