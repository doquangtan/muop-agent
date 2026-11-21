/// Trạng thái đăng nhập Claude Code CLI trên server (socket `claude:auth:update` và ack `claude:auth:*`)
class ClaudeAuthState {
  const ClaudeAuthState({
    required this.ok,
    required this.loggedIn,
    this.email = '',
    this.subscriptionType = '',
    required this.loginUrl,
    required this.error,
    this.phase = '',
  });

  final bool ok;
  final bool loggedIn;

  /// Email tài khoản đã đăng nhập (nếu có)
  final String email;

  /// Gói dịch vụ: pro, team, enterprise, free... (nếu có)
  final String subscriptionType;

  /// Link đăng nhập Anthropic OAuth đang chờ mã xác thực (rỗng nếu không có phiên đăng nhập)
  final String loginUrl;
  final String error;

  /// idle | logged_out | waiting_code | verifying | logged_in | failed | cancelled | expired
  final String phase;

  bool get awaitingCode => loginUrl.isNotEmpty;

  bool get verifying => phase == 'verifying';

  factory ClaudeAuthState.failure(String error) => ClaudeAuthState(
        ok: false,
        loggedIn: false,
        email: '',
        subscriptionType: '',
        loginUrl: '',
        error: error,
        phase: 'failed',
      );

  factory ClaudeAuthState.fromJson(Map<String, dynamic> json) => ClaudeAuthState(
        ok: json['ok'] == true,
        loggedIn: json['loggedIn'] == true,
        email: '${json['email'] ?? ''}',
        subscriptionType: '${json['subscriptionType'] ?? ''}',
        loginUrl: '${json['loginUrl'] ?? ''}',
        error: '${json['error'] ?? ''}',
        phase: '${json['phase'] ?? ''}',
      );
}
