import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:muop_agent/core/theme/app_theme.dart';
import 'package:muop_agent/features/interactions/domain/interaction_entities.dart';
import 'package:muop_agent/features/interactions/presentation/rate_retry_widgets.dart';
import 'package:muop_agent/features/interactions/presentation/retry_config_sheet.dart';

void main() {
  group('ConversationRetryConfig', () {
    test('thiếu trường thì dùng mặc định giống server', () {
      final cfg = ConversationRetryConfig.fromJson({'conversationId': 'c1'});
      expect(cfg.conversationId, 'c1');
      expect(cfg.enabled, isTrue);
      expect(cfg.prompt, isEmpty);
      expect(cfg.maxAttempts, 8);
      expect(cfg.intervalMinutes, 5);
      expect(cfg.useQuotaReset, isTrue);
    });

    test('toJson và fromJson khớp nhau', () {
      const cfg = ConversationRetryConfig(
        conversationId: 'c2',
        enabled: false,
        prompt: 'tiếp tục',
        maxAttempts: 3,
        intervalMinutes: 15,
        useQuotaReset: false,
      );
      final back = ConversationRetryConfig.fromJson(cfg.toJson());
      expect(back.conversationId, 'c2');
      expect(back.enabled, isFalse);
      expect(back.prompt, 'tiếp tục');
      expect(back.maxAttempts, 3);
      expect(back.intervalMinutes, 15);
      expect(back.useQuotaReset, isFalse);
    });
  });

  group('PendingRetry', () {
    test('đọc căn cứ chờ và thời điểm reset quota', () {
      final retry = PendingRetry.fromJson({
        'conversationId': 'c3',
        'provider': 'claude-cli',
        'reason': 'Usage limit reached',
        'retryAt': '2026-11-25T10:00:00Z',
        'attempt': 2,
        'maxAttempts': 8,
        'waitSource': 'quota',
        'waitDetail': 'Chờ reset quota · Phiên 5 giờ',
        'resetAt': '2026-11-25T09:59:00Z',
      });
      expect(retry.waitSource, 'quota');
      expect(retry.waitDetail, 'Chờ reset quota · Phiên 5 giờ');
      expect(retry.resetAt, DateTime.parse('2026-11-25T09:59:00Z'));
      expect(retry.key, 'c3#2');
    });

    test('server cũ không gửi căn cứ chờ thì để trống', () {
      final retry = PendingRetry.fromJson({
        'conversationId': 'c4',
        'retryAt': '2026-11-25T10:00:00Z',
      });
      expect(retry.waitSource, isEmpty);
      expect(retry.waitDetail, isEmpty);
      expect(retry.resetAt, isNull);
      expect(retryWaitLine(retry), isEmpty);
    });
  });

  testWidgets('bảng cấu hình gửi đúng giá trị đã sửa', (tester) async {
    ConversationRetryConfig? saved;
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
                onPressed: () => showRetryConfigSheet(
                  context: context,
                  initial: const ConversationRetryConfig(conversationId: 'c5'),
                  onSave: (cfg) async {
                    saved = cfg;
                    return (ok: true, message: 'ok');
                  },
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

    await tester.enterText(
      find.widgetWithText(TextField, 'Khoảng chờ dự phòng (phút)'),
      '12',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Số lần gửi lại tối đa'),
      '4',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Nội dung gửi lại'),
      '  làm tiếp đi  ',
    );
    await tester.tap(
      find.widgetWithText(SwitchListTile, 'Chờ đến khi quota reset'),
    );
    await tester.pump();
    await tester.tap(find.text('Lưu'));
    await tester.pumpAndSettle();

    expect(saved, isNotNull);
    expect(saved!.conversationId, 'c5');
    expect(saved!.intervalMinutes, 12);
    expect(saved!.maxAttempts, 4);
    expect(saved!.prompt, 'làm tiếp đi');
    expect(saved!.useQuotaReset, isFalse);
    expect(saved!.enabled, isTrue);
    // Lưu xong thì đóng bảng
    expect(find.text('Lưu'), findsNothing);
  });

  testWidgets('giá trị ngoài giới hạn không gọi lưu', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(
          seedColor: const Color(0xFF4C8DFF),
          brightness: Brightness.dark,
        ),
        home: Scaffold(
          body: RetryConfigSheet(
            initial: const ConversationRetryConfig(conversationId: 'c6'),
            onSave: (cfg) async {
              calls++;
              return (ok: true, message: 'ok');
            },
          ),
        ),
      ),
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Số lần gửi lại tối đa'),
      '99',
    );
    await tester.tap(find.text('Lưu'));
    await tester.pump();

    expect(calls, 0);
    expect(find.text('Số lần gửi lại từ 0 đến 20'), findsOneWidget);
  });
}
