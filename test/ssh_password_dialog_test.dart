import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:muop_agent/core/theme/app_theme.dart';
import 'package:muop_agent/features/ssh/domain/ssh_entities.dart';
import 'package:muop_agent/features/ssh/presentation/ssh_password_dialog.dart';

/// Mở hộp thoại từ một nút, trả kết quả vào [out] khi đóng.
Future<void> _open(
  WidgetTester tester, {
  String? hint,
  required List<SshPasswordInput?> out,
}) async {
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
              onPressed: () async {
                out.add(await showSshPasswordDialog(
                  context,
                  hostName: 'Máy test',
                  address: 'john@10.0.0.5:22',
                  hint: hint,
                ));
              },
              child: const Text('mở'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('mở'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('nhập mật khẩu và chọn lưu trả về đúng giá trị', (tester) async {
    final out = <SshPasswordInput?>[];
    await _open(tester, out: out);

    expect(find.text('Nhập mật khẩu SSH'), findsOneWidget);
    expect(find.text('john@10.0.0.5:22'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'abc123');
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    await tester.tap(find.text('Kết nối'));
    await tester.pumpAndSettle();

    expect(out, hasLength(1));
    expect(out.single?.password, 'abc123');
    expect(out.single?.save, isTrue);
  });

  testWidgets('mật khẩu trống thì không cho kết nối; hủy trả về null', (tester) async {
    final out = <SshPasswordInput?>[];
    await _open(tester, out: out);

    final connect = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Kết nối'),
    );
    expect(connect.onPressed, isNull);

    await tester.tap(find.text('Hủy'));
    await tester.pumpAndSettle();

    expect(out, hasLength(1));
    expect(out.single, isNull);
  });

  testWidgets('hiển thị gợi ý (sai mật khẩu) và mặc định không lưu', (tester) async {
    final out = <SshPasswordInput?>[];
    await _open(tester, hint: 'Sai mật khẩu', out: out);

    expect(find.text('Sai mật khẩu'), findsOneWidget);
    final checkbox = tester.widget<CheckboxListTile>(find.byType(CheckboxListTile));
    expect(checkbox.value, isFalse);

    await tester.enterText(find.byType(TextField), 'x');
    await tester.pumpAndSettle(); // nút "Kết nối" bật theo nội dung ô nhập
    await tester.tap(find.text('Kết nối'));
    await tester.pumpAndSettle();
    expect(out.single?.save, isFalse);
  });

  test('SshPasswordRequest và SshExecResult đọc đúng trường từ server', () {
    final req = SshPasswordRequest.fromJson({
      'sessionId': 'ssh-1-2',
      'hostId': 7,
      'hostName': 'NAS',
      'wrong': true,
    });
    expect(req.sessionId, 'ssh-1-2');
    expect(req.hostName, 'NAS');
    expect(req.wrong, isTrue);

    final res = SshExecResult.fromJson({
      'ok': false,
      'error': 'Máy yêu cầu mật khẩu',
      'needsPassword': true,
    });
    expect(res.needsPassword, isTrue);
    expect(res.ok, isFalse);

    final plain = SshExecResult.fromJson({'ok': true});
    expect(plain.needsPassword, isFalse);
  });
}
