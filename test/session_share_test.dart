import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:muop_agent/features/sessions/domain/session_share.dart';
import 'package:muop_agent/features/sessions/presentation/share_history_sheet.dart';

void main() {
  test('buildShareUrl dựng link có offset và trang', () {
    final url = buildShareUrl(
      baseUrl: 'http://10.0.0.2:8787/',
      sessionId: 'abc-1',
      fromStep: 120,
      page: 2,
    );
    expect(
      url,
      'http://10.0.0.2:8787/api/session/share?id=abc-1&from_step=120&page=2&limit=50',
    );
  });

  test('buildSharePrompt nêu link, tổng số trang và khoảng page', () {
    final prompt = buildSharePrompt(url: 'http://x/api', totalPages: 7);
    expect(prompt, contains('http://x/api'));
    expect(prompt, contains('tổng số trang là 7'));
    expect(prompt, contains('từ 0 đến 6'));
  });

  test('SessionSharePage.fromJson', () {
    final page = SessionSharePage.fromJson({
      'sessionId': 's',
      'fromStep': 3,
      'page': 0,
      'pageSize': 50,
      'totalPages': 4,
      'steps': [{}, {}],
    });
    expect(page.totalPages, 4);
    expect(page.stepCount, 2);
  });

  Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

  testWidgets('sheet gửi vào conversation có sẵn với model của nó', (
    tester,
  ) async {
    ShareSendRequest? result;
    await tester.pumpWidget(
      host(
        Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showShareHistorySheet(
                context: context,
                shareUrl: 'http://x/api/session/share?id=a',
                fromStep: 5,
                loadFirstPage: () async => const SessionSharePage(
                  sessionId: 'a',
                  fromStep: 5,
                  page: 0,
                  pageSize: 50,
                  totalPages: 3,
                  stepCount: 10,
                ),
                conversations: const [
                  ShareTargetConversation(
                    id: 'c1',
                    title: 'Việc cũ',
                    model: 'agy:gemini-4-argon-medium',
                  ),
                ],
                availableModels: const [
                  'claude-cli:claude-sonnet-5-5',
                  'agy:gemini-4-argon-medium',
                ],
                modelLabels: const {},
                effortLevels: const [],
                defaultModel: 'claude-cli:claude-sonnet-5-5',
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.textContaining('3 trang'), findsOneWidget);
    await tester.tap(find.byKey(const Key('share-send')));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.conversationId, 'c1');
    expect(result!.model, 'agy:gemini-4-argon-medium');
    expect(result!.prompt, contains('tổng số trang là 3'));
  });

  testWidgets('không có conversation cùng project thì chỉ tạo mới', (
    tester,
  ) async {
    ShareSendRequest? result;
    await tester.pumpWidget(
      host(
        Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showShareHistorySheet(
                context: context,
                shareUrl: 'http://x/u',
                fromStep: 0,
                loadFirstPage: () async => const SessionSharePage(
                  sessionId: 'a',
                  fromStep: 0,
                  page: 0,
                  pageSize: 50,
                  totalPages: 1,
                  stepCount: 1,
                ),
                conversations: const [],
                availableModels: const ['claude-cli:claude-sonnet-5-5'],
                modelLabels: const {},
                effortLevels: const [],
                defaultModel: 'claude-cli:claude-sonnet-5-5',
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('share-send')));
    await tester.pumpAndSettle();
    expect(result!.conversationId, '');
    expect(result!.model, 'claude-cli:claude-sonnet-5-5');
  });
}
