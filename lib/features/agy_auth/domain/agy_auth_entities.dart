/// Trạng thái đăng nhập agy trên server (socket `agy:auth:update` và ack `agy:auth:*`)
class AgyAuthState {
  const AgyAuthState({
    required this.ok,
    required this.loggedIn,
    required this.error,
    this.phase = '',
    this.sshSessionId = '',
    this.sshHostId = 0,
    this.loginUrl = '',
    this.loginStage = '',
  });

  final bool ok;
  final bool loggedIn;
  final String error;

  /// Link Google OAuth đầy đủ lấy từ terminal đăng nhập (rỗng nếu agy chưa in ra)
  final String loginUrl;

  /// Bước trong terminal: waiting_link | awaiting_token | verifying | awaiting_terms (rỗng ngoài luồng)
  final String loginStage;

  /// idle | logged_out | unknown | login_terminal | logged_in | failed | cancelled | expired
  final String phase;

  /// Phiên SSH đang chạy `agy` để người dùng tự đăng nhập (chỉ khi [terminalOpen])
  final String sshSessionId;

  /// Id máy SSH đã lưu của máy này (đi kèm [sshSessionId])
  final int sshHostId;

  /// Terminal SSH chạy agy đang mở: người dùng đăng nhập ngay trong terminal đó
  bool get terminalOpen => phase == 'login_terminal' && sshSessionId.isNotEmpty;

  bool get hasLoginUrl => loginUrl.isNotEmpty;

  /// Bước hiện tại; nếu server chưa gửi bước thì suy ra từ link
  String get stage => loginStage.isNotEmpty
      ? loginStage
      : (hasLoginUrl ? 'awaiting_token' : 'waiting_link');

  /// Trạng thái để hiển thị khi server báo lỗi (`ok = false`): giữ phiên, bước và link đang có,
  /// để màn hình không rơi khỏi bước đang làm. Lỗi nằm trong [error].
  AgyAuthState get displayed => AgyAuthState(
        ok: true,
        loggedIn: loggedIn,
        error: error,
        phase: phase,
        sshSessionId: sshSessionId,
        sshHostId: sshHostId,
        loginUrl: loginUrl,
        loginStage: loginStage,
      );

  factory AgyAuthState.failure(String error) => AgyAuthState(
        ok: false,
        loggedIn: false,
        error: error,
        phase: 'failed',
      );

  factory AgyAuthState.fromJson(Map<String, dynamic> json) => AgyAuthState(
        ok: json['ok'] == true,
        loggedIn: json['loggedIn'] == true,
        error: '${json['error'] ?? ''}',
        phase: '${json['phase'] ?? ''}',
        sshSessionId: '${json['sshSessionId'] ?? ''}',
        sshHostId: (json['sshHostId'] as num?)?.toInt() ?? 0,
        loginUrl: '${json['loginUrl'] ?? ''}',
        loginStage: '${json['loginStage'] ?? ''}',
      );
}

/// Trạng thái hai tài khoản (socket `accounts:status`): agy và Claude Code CLI
class AccountsStatus {
  const AccountsStatus({
    required this.agyLoggedIn,
    required this.agyEmail,
    required this.agyPlan,
    required this.claudeLoggedIn,
    required this.claudePlan,
  });

  final bool agyLoggedIn;
  final String agyEmail;

  /// Gói của tài khoản agy, ví dụ "Pro"
  final String agyPlan;
  final bool claudeLoggedIn;

  /// Gói của tài khoản Claude, ví dụ "pro"
  final String claudePlan;

  static const empty = AccountsStatus(
    agyLoggedIn: false,
    agyEmail: '',
    agyPlan: '',
    claudeLoggedIn: false,
    claudePlan: '',
  );

  factory AccountsStatus.fromJson(Map<String, dynamic> json) => AccountsStatus(
        agyLoggedIn: json['agyLoggedIn'] == true,
        agyEmail: '${json['agyEmail'] ?? ''}',
        agyPlan: '${json['agyPlan'] ?? ''}',
        claudeLoggedIn: json['claudeLoggedIn'] == true,
        claudePlan: '${json['claudePlan'] ?? ''}',
      );
}
