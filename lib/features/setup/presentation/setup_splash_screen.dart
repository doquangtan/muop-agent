import 'package:material_ui/material_ui.dart';

import 'package:muop_agent/core/di/app_dependencies.dart';
import 'package:muop_agent/core/theme/app_theme.dart';
import 'package:muop_agent/features/agy_auth/domain/agy_auth_repository.dart';
import 'package:muop_agent/features/setup/domain/setup_entities.dart';
import 'package:muop_agent/features/setup/domain/setup_repository.dart';

/// Màn splash kiểm tra cài đặt trên server vừa chọn (khi mở app hoặc đổi IP).
/// Chờ kết nối rồi đóng với kết quả: `true` nếu cần mở wizard cài đặt, `false` nếu đã đủ.
/// `null` nếu người dùng bỏ qua (không kết nối được).
class SetupSplashScreen extends StatefulWidget {
  const SetupSplashScreen({
    super.key,
    required this.serverAddress,
    this.repository,
    this.agyRepository,
  });

  final String serverAddress;
  final SetupRepository? repository;
  final AgyAuthRepository? agyRepository;

  static const maxAttempts = 15;
  static const retryInterval = Duration(seconds: 1);

  @override
  State<SetupSplashScreen> createState() => _SetupSplashScreenState();
}

class _SetupSplashScreenState extends State<SetupSplashScreen> {
  late final SetupRepository _repo =
      widget.repository ?? AppDependencies.setup;
  late final AgyAuthRepository _agy =
      widget.agyRepository ?? AppDependencies.agyAuth;

  bool _checking = true;
  int _attempt = 0;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _check();
  }

  /// agy được chọn làm CLI nhưng đã đăng xuất (`logged_out`). Chưa xác định được (hub chưa lên, lỗi)
  /// thì coi như không cần đăng nhập, không chặn vào app.
  Future<bool> _agyLoginRequired(SetupStatus status) async {
    if (!status.selectedClis.contains('agy') || !status.isInstalled('agy')) {
      return false;
    }
    final agyStatus = await _agy.fetchStatus();
    return agyStatus.ok && agyStatus.phase == 'logged_out';
  }

  Future<void> _check() async {
    setState(() {
      _checking = true;
      _attempt = 0;
      _error = '';
    });
    var status = SetupStatus.failure('Chưa kết nối');
    while (mounted && _attempt < SetupSplashScreen.maxAttempts) {
      setState(() => _attempt++);
      status = await _repo.fetchStatus();
      if (!mounted) return;
      if (status.ok) break;
      setState(() => _error = status.error);
      await Future<void>.delayed(SetupSplashScreen.retryInterval);
    }
    if (!mounted) return;
    if (status.ok) {
      // Setup đủ nhưng agy (CLI đã chọn) chưa đăng nhập: mở wizard ở bước đăng nhập
      final needLogin = !status.needsSetup && await _agyLoginRequired(status);
      if (!mounted) return;
      Navigator.of(context).pop(status.needsSetup || needLogin);
      return;
    }
    setState(() {
      _checking = false;
      _error = 'Không kết nối được tới ${widget.serverAddress}. '
          '${_error.isEmpty ? '' : '($_error)'}';
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.travel_explore_rounded, size: 56, color: scheme.primary),
                const SizedBox(height: 16),
                Text('Mướp Agents', style: textTheme.headlineSmall),
                const SizedBox(height: 8),
                Text(
                  'Kiểm tra cài đặt trên ${widget.serverAddress}',
                  style: textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                if (_checking) ...[
                  const CircularProgressIndicator(),
                  const SizedBox(height: 12),
                  Text(
                    'Đang kết nối ($_attempt/${SetupSplashScreen.maxAttempts})…',
                    style: textTheme.bodySmall,
                  ),
                ] else ...[
                  Text(
                    _error,
                    style: TextStyle(color: scheme.error),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('Bỏ qua'),
                      ),
                      const SizedBox(width: 12),
                      FilledButton(
                        onPressed: _check,
                        child: const Text('Thử lại'),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
