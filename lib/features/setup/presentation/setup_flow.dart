import 'package:material_ui/material_ui.dart';

import 'package:muop_agent/features/agy_auth/domain/agy_auth_repository.dart';
import 'package:muop_agent/features/setup/domain/setup_repository.dart';
import 'package:muop_agent/features/setup/presentation/setup_splash_screen.dart';
import 'package:muop_agent/features/setup/presentation/setup_wizard_screen.dart';

/// Đang chạy luồng splash/wizard (tránh mở chồng nhiều lần khi nhiều nơi cùng yêu cầu)
bool _flowRunning = false;

/// Splash kiểm tra cài đặt trên [serverAddress], rồi mở wizard nếu thiếu mục nào.
/// Dùng [navigator] đã chụp trước đó (không dùng context): màn đang gọi có thể đã bị gỡ khi máy chủ đổi.
/// Trả về `true` nếu luồng đã chạy xong (kể cả khi người dùng đóng wizard), `false` nếu bị bỏ qua.
Future<bool> runSetupFlow(
  NavigatorState navigator,
  String serverAddress, {
  VoidCallback? onChangeServer,
  SetupRepository? setupRepository,
  AgyAuthRepository? agyRepository,
}) async {
  if (_flowRunning) return false;
  _flowRunning = true;
  try {
    final needsSetup = await navigator.push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => SetupSplashScreen(
          serverAddress: serverAddress,
          repository: setupRepository,
          agyRepository: agyRepository,
          onChangeServer: onChangeServer,
        ),
      ),
    );
    if (needsSetup == true) {
      await navigator.push<void>(
        MaterialPageRoute<void>(builder: (_) => SetupWizardScreen()),
      );
    }
    return true;
  } finally {
    _flowRunning = false;
  }
}
