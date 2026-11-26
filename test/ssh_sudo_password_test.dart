import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:muop_agent/core/theme/app_theme.dart';
import 'package:muop_agent/features/ssh/domain/ssh_entities.dart';
import 'package:muop_agent/features/ssh/presentation/ssh_password_dialog.dart';

void main() {
  test('yêu cầu mật khẩu sudo và kết quả exec đọc đúng loại', () {
    final req = SshPasswordRequest.fromJson({
      'sessionId': 'ssh-1-2',
      'hostName': 'Máy này',
      'wrong': false,
      'kind': 'sudo',
    });
    expect(req.kind, 'sudo');

    // Phiên cũ không gửi kind: mặc định là ssh
    expect(
      SshPasswordRequest.fromJson({'sessionId': 'x'}).kind,
      'ssh',
    );

    final res = SshExecResult.fromJson({
      'ok': false,
      'needsPassword': true,
      'passwordKind': 'sudo',
    });
    expect(res.passwordKind, 'sudo');
  });

  testWidgets('hộp thoại sudo có tiêu đề và nhãn lưu riêng', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(
          seedColor: const Color(0xFF4C8DFF),
          brightness: Brightness.dark,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showSshPasswordDialog(
                  context,
                  hostName: 'Máy này',
                  address: 'john@127.0.0.1:22',
                  kind: 'sudo',
                ),
                child: const Text('mở'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('mở'));
    await tester.pumpAndSettle();

    expect(find.text('Nhập mật khẩu sudo'), findsOneWidget);
    expect(find.text('Lưu mật khẩu cho máy này (dùng cho sudo)'), findsOneWidget);
  });
}
