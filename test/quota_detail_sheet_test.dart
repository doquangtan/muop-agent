import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:muop_agent/core/theme/app_theme.dart';
import 'package:muop_agent/features/chat/presentation/quota_detail_sheet.dart';
import 'package:muop_agent/features/sessions/domain/session_entities.dart';

List<ModelQuotaGroup> _groups(int count) => [
      for (var i = 1; i <= count; i++)
        ModelQuotaGroup(
          displayName: 'Nhóm $i',
          description:
              'Mô tả nhóm $i dài để kiểm tra việc xuống dòng trên màn hình điện thoại nhỏ',
          buckets: [
            ModelQuotaBucket(
              bucketId: 'weekly-$i',
              displayName: 'Model $i Pro Preview',
              description:
                  'Giới hạn tuần của model $i, mô tả có thể dài hơn một dòng trên màn hình hẹp',
              window: 'weekly',
              remainingFraction: 0.42,
              remainingPercent: 42,
              resetTime: '',
            ),
            ModelQuotaBucket(
              bucketId: '5h-$i',
              displayName: '5h',
              description: '',
              window: '5h',
              remainingFraction: 0.9,
              remainingPercent: 90,
              resetTime: '',
            ),
          ],
        ),
    ];

Future<void> _openSheet(
  WidgetTester tester,
  List<ModelQuotaGroup> groups,
) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(
        seedColor: const Color(0xFF00897B),
        brightness: Brightness.light,
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => showQuotaDetailSheet(context, groups),
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

void _usePhoneViewport(WidgetTester tester, Size logicalSize) {
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = logicalSize * 2;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  group('formatQuotaResetCompact', () {
    final now = DateTime(2026, 11, 19, 7, 0);

    test('cùng ngày: chỉ giờ; khác ngày: ngày/tháng và giờ', () {
      expect(
        formatQuotaResetCompact(
            DateTime(2026, 11, 19, 8, 30).toUtc().toIso8601String(),
            now: now),
        '08:30',
      );
      expect(
        formatQuotaResetCompact(
            DateTime(2026, 11, 20, 13, 0).toUtc().toIso8601String(),
            now: now),
        '20/11 13:00',
      );
    });

    test('không có hoặc đã qua thời điểm reset thì trả về null', () {
      expect(formatQuotaResetCompact('', now: now), isNull);
      expect(
        formatQuotaResetCompact(
            DateTime(2026, 11, 19, 6, 0).toUtc().toIso8601String(),
            now: now),
        isNull,
      );
    });
  });

  group('formatQuotaReset', () {
    // Thời điểm giả lập theo giờ địa phương để kết quả không phụ thuộc máy chạy test
    final now = DateTime(2026, 11, 19, 7, 0);

    test('reset trong ngày: hiển thị giờ và thời gian còn lại', () {
      final reset = DateTime(2026, 11, 19, 8, 30).toUtc().toIso8601String();
      expect(formatQuotaReset(reset, now: now),
          'Reset 08:30 hôm nay · còn 1g 30p');
    });

    test('reset sang ngày khác: hiển thị ngày/tháng và số ngày', () {
      final reset = DateTime(2026, 11, 20, 13, 0).toUtc().toIso8601String();
      expect(formatQuotaReset(reset, now: now),
          'Reset 13:00 20/11 · còn 1n 6g');
    });

    test('chưa đến 1 giờ: chỉ hiện phút', () {
      final reset = DateTime(2026, 11, 19, 7, 42).toUtc().toIso8601String();
      expect(formatQuotaReset(reset, now: now), 'Reset 07:42 hôm nay · còn 42p');
    });

    test('đã qua thời điểm reset và chuỗi rỗng/sai định dạng', () {
      final past = DateTime(2026, 11, 19, 6, 0).toUtc().toIso8601String();
      expect(formatQuotaReset(past, now: now), 'Đã reset');
      expect(formatQuotaReset('', now: now), isNull);
      expect(formatQuotaReset('không phải ngày', now: now), isNull);
    });

    test('đọc được chuỗi RFC3339 có micro-giây và offset', () {
      expect(
        formatQuotaReset('2026-11-19T01:30:00.452087+00:00',
            now: DateTime.utc(2026, 11, 19, 0, 0)),
        isNotNull,
      );
    });
  });

  for (final size in const [Size(360, 640), Size(320, 568)]) {
    testWidgets(
        'bảng quota nhiều nhóm cuộn được trên ${size.width.toInt()}x${size.height.toInt()}',
        (tester) async {
      _usePhoneViewport(tester, size);
      await _openSheet(tester, _groups(8));

      expect(tester.takeException(), isNull, reason: 'không được tràn layout');

      // Bảng không vượt quá 80% chiều cao màn hình
      final sheet = tester.getRect(find.byType(QuotaDetailSheet));
      expect(sheet.height, lessThanOrEqualTo(size.height * 0.8 + 1));
      expect(sheet.bottom, lessThanOrEqualTo(size.height));

      // Nhóm cuối phải cuộn tới được
      final scrollable = find.descendant(
        of: find.byType(ListView),
        matching: find.byType(Scrollable),
      );
      await tester.scrollUntilVisible(
        find.text('Nhóm 8'),
        200,
        scrollable: scrollable,
      );
      await tester.pumpAndSettle();
      expect(find.text('Nhóm 8'), findsOneWidget);
      final last = tester.getRect(find.text('Nhóm 8'));
      expect(last.bottom, lessThanOrEqualTo(size.height));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('hiển thị thông báo khi chưa có dữ liệu quota', (tester) async {
    _usePhoneViewport(tester, const Size(360, 640));
    await _openSheet(tester, const []);

    expect(find.text('Chưa có dữ liệu quota'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
