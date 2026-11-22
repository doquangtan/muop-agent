import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:muop_agent/core/theme/app_theme.dart';
import 'package:muop_agent/features/bridge/domain/bridge_entities.dart';
import 'package:muop_agent/features/bridge/domain/bridge_repository.dart';
import 'package:muop_agent/features/bridge/presentation/bridge_screen.dart';
import 'package:muop_agent/features/interactions/domain/interaction_entities.dart';

/// Repository giả: trả kết quả định sẵn, ghi lại lời gọi, và cho phát sự kiện như socket
class _FakeBridgeRepository implements BridgeRepository {
  _FakeBridgeRepository({
    this.status = const BridgeStatus(url: '', connected: false, error: ''),
  });

  BridgeStatus status;
  final sendResult = const BridgeSendResult(
    ok: true,
    error: '',
    conversationId: 'cid-new-1',
    source: 'claude-cli',
  );
  final calls = <String>[];
  final sentPrompts = <String>[];
  final peerUrls = <String>[];
  final pendingLookups = <String>[];
  final responses = <String>[];

  /// Tương tác đang chờ theo conversation (không có = không có việc chờ)
  final Map<String, PendingClaudeInteraction> pendingByCid = {};

  final _events = StreamController<BridgeEvent>.broadcast();

  /// Giả lập sự kiện `bridge:*` do server chuyển tiếp từ máy A
  void emit(String name, Map<String, dynamic> data) {
    _events.add(BridgeEvent(name: name, data: data));
  }

  @override
  Stream<BridgeEvent> watchEvents() => _events.stream;

  @override
  Future<BridgeStatus> fetchStatus(String address) async {
    calls.add('status:$address');
    return status;
  }

  @override
  Future<BridgeStatus> setPeer(String address, {required String url}) async {
    peerUrls.add(url);
    status = BridgeStatus(url: url, connected: url.isNotEmpty, error: '');
    return status;
  }

  @override
  Future<BridgeSendResult> sendPrompt(
    String address, {
    required String prompt,
    required String projectPath,
    String conversationId = '',
    String model = '',
    List<Map<String, dynamic>> images = const [],
  }) async {
    sentPrompts.add('$projectPath|$conversationId|$model|$prompt');
    return sendResult;
  }

  @override
  Future<BridgeSendResult> stopTurn(
    String address, {
    required String conversationId,
  }) async {
    calls.add('stop:$conversationId');
    return const BridgeSendResult(ok: true, error: '');
  }

  @override
  Future<PeerMeta> fetchPeerMeta(String address) async => PeerMeta.failure('Không có máy phụ trong test');

  @override
  Future<List<Map<String, dynamic>>> fetchPeerSessions(String address) async => const [];

  @override
  Future<Map<String, dynamic>?> fetchPeerSession(String address, {required String id}) async => null;

  @override
  Future<({PendingClaudeInteraction? interaction, String error})> fetchPendingInteraction(
    String address, {
    required String conversationId,
  }) async {
    pendingLookups.add(conversationId);
    return (interaction: pendingByCid[conversationId], error: '');
  }

  @override
  Future<String?> respondInteraction(
    String address, {
    required String conversationId,
    required String toolUseId,
    required String projectPath,
    required String model,
    required String decision,
    List<Map<String, String>> answers = const [],
    String feedback = '',
  }) async {
    responses.add(
      '$conversationId|$toolUseId|$projectPath|$model|$decision|${answers.length}|$feedback',
    );
    return null;
  }
}

PendingClaudeInteraction _plan(String cid) => PendingClaudeInteraction.fromJson({
      'conversationId': cid,
      'toolUseId': 'tu-plan-1',
      'kind': 'plan',
      'createdAt': '',
      'questions': <dynamic>[],
      'plan': '# Kế hoạch sửa login\n- Bước 1: sửa form',
    });

Future<void> _pump(WidgetTester tester, BridgeRepository repo) async {
  // ListView dựng lười: viewport đủ cao để mọi ô nhập và nút có trong cây widget
  tester.view.physicalSize = const Size(900, 2600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(
        seedColor: const Color(0xFF00897B),
        brightness: Brightness.light,
      ),
      home: BridgeScreenView(
        serverAddress: 'http://192.168.31.216:8787',
        repository: repo,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Cuộn tới widget rồi bấm (nút nằm dưới đáy viewport của test)
Future<void> _tap(WidgetTester tester, Key key) async {
  await tester.ensureVisible(find.byKey(key));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(key));
}

void main() {
  testWidgets('shows "not configured" and fills nothing when no peer is saved', (tester) async {
    final repo = _FakeBridgeRepository();
    await _pump(tester, repo);

    expect(find.textContaining('Chưa cấu hình'), findsOneWidget);
    expect(repo.calls, contains('status:http://192.168.31.216:8787'));
    expect(tester.widget<TextField>(find.byKey(const Key('bridge-url'))).controller!.text, '');

    // Hủy timer làm mới để test không để lại timer treo
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('shows connected status and pre-fills the saved peer address', (tester) async {
    final repo = _FakeBridgeRepository(
      status: const BridgeStatus(url: 'http://192.168.31.96:8787', connected: true, error: ''),
    );
    await _pump(tester, repo);

    expect(find.textContaining('Đã kết nối tới http://192.168.31.96:8787'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byKey(const Key('bridge-url'))).controller!.text,
      'http://192.168.31.96:8787',
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('saving a peer address calls the repository with the trimmed url', (tester) async {
    final repo = _FakeBridgeRepository();
    await _pump(tester, repo);

    await tester.enterText(find.byKey(const Key('bridge-url')), '  http://192.168.31.96:8787  ');
    await _tap(tester, const Key('bridge-save'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));

    expect(repo.peerUrls, ['http://192.168.31.96:8787']);
    expect(find.textContaining('Đã kết nối tới http://192.168.31.96:8787'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a rejected address shows the server error', (tester) async {
    // Server từ chối địa chỉ sai: trả ok=false kèm lý do
    await _pump(tester, _RejectingRepository());

    await tester.enterText(find.byKey(const Key('bridge-url')), 'https://x.y');
    await _tap(tester, const Key('bridge-save'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));

    expect(find.textContaining('chưa hỗ trợ https'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('sending a prompt passes project, conversation and model, then fills the conversation id',
      (tester) async {
    final repo = _FakeBridgeRepository();
    await _pump(tester, repo);

    await tester.enterText(find.byKey(const Key('bridge-project')), '/tmp/du-an');
    await tester.enterText(find.byKey(const Key('bridge-prompt')), 'Sửa lỗi login');
    await _tap(tester, const Key('bridge-send'));
    await tester.pump();
    await tester.pump();

    expect(repo.sentPrompts, ['/tmp/du-an||claude-cli:claude-sonnet-5-5|Sửa lỗi login']);
    expect(find.textContaining('Conversation: cid-new-1'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byKey(const Key('bridge-conversation'))).controller!.text,
      'cid-new-1',
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('sending without project or prompt is refused locally', (tester) async {
    final repo = _FakeBridgeRepository();
    await _pump(tester, repo);

    await _tap(tester, const Key('bridge-send'));
    await tester.pump();

    expect(repo.sentPrompts, isEmpty);
    expect(find.textContaining('Cần nhập thư mục project'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('stop is disabled until a conversation id exists, then calls the repository',
      (tester) async {
    final repo = _FakeBridgeRepository();
    await _pump(tester, repo);

    final stopBefore = tester.widget<OutlinedButton>(find.byKey(const Key('bridge-stop')));
    expect(stopBefore.onPressed, isNull);

    await tester.enterText(find.byKey(const Key('bridge-conversation')), 'cid-abc');
    await tester.pump();
    await _tap(tester, const Key('bridge-stop'));
    await tester.pump();
    await tester.pump();

    expect(repo.calls, contains('stop:cid-abc'));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a conversation updated on the peer appears in the list and selecting it checks for pending work',
      (tester) async {
    final repo = _FakeBridgeRepository();
    await _pump(tester, repo);

    repo.emit('bridge:session:update', {'id': 'cid-9', 'title': 'Sửa login', 'status': 'completed'});
    await tester.pumpAndSettle();
    expect(find.text('Sửa login'), findsOneWidget);

    await _tap(tester, const Key('bridge-session-cid-9'));
    await tester.pumpAndSettle();

    expect(
      tester.widget<TextField>(find.byKey(const Key('bridge-conversation'))).controller!.text,
      'cid-9',
    );
    expect(repo.pendingLookups, contains('cid-9'));
    expect(find.text('Không có tương tác đang chờ trong conversation này.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a running turn on the peer shows its streaming text and disappears when it ends',
      (tester) async {
    final repo = _FakeBridgeRepository();
    await _pump(tester, repo);

    repo.emit('bridge:chat:stream', {
      'conversationId': 'cid-7',
      'projectPath': '/tmp/du-an',
      'userPrompt': 'Dọn code',
      'streamingText': 'Đang sửa file a.dart',
      'isRunning': true,
      'activeStepType': 'tool_use',
    });
    await tester.pumpAndSettle();
    expect(find.text('Đang chạy: Dọn code'), findsOneWidget);
    expect(find.text('Đang sửa file a.dart'), findsOneWidget);

    repo.emit('bridge:chat:stream', {
      'conversationId': 'cid-7',
      'projectPath': '/tmp/du-an',
      'userPrompt': 'Dọn code',
      'streamingText': 'Xong',
      'isRunning': false,
      'activeStepType': '',
    });
    await tester.pumpAndSettle();
    expect(find.text('Đang chạy: Dọn code'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a pending plan from Claude can be approved and the approval reaches the peer with the project',
      (tester) async {
    final repo = _FakeBridgeRepository()..pendingByCid['cid-p'] = _plan('cid-p');
    await _pump(tester, repo);

    await tester.enterText(find.byKey(const Key('bridge-conversation')), 'cid-p');
    await tester.enterText(find.byKey(const Key('bridge-project')), '/tmp/du-an');
    await tester.pump();
    await _tap(tester, const Key('bridge-check-pending'));
    await tester.pumpAndSettle();

    expect(find.text('Claude đã trình kế hoạch, chờ bạn duyệt'), findsOneWidget);

    await tester.tap(find.text('Xem & duyệt'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Duyệt kế hoạch'));
    await tester.pumpAndSettle();

    expect(repo.responses, ['cid-p|tu-plan-1|/tmp/du-an|claude-cli:claude-sonnet-5-5|approve|0|']);
    // Đã duyệt: tương tác biến mất khỏi màn
    expect(find.text('Claude đã trình kế hoạch, chờ bạn duyệt'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}

/// Server từ chối địa chỉ: trả lỗi khi đặt peer
class _RejectingRepository extends _FakeBridgeRepository {
  @override
  Future<BridgeStatus> setPeer(String address, {required String url}) async {
    return const BridgeStatus(
      url: '',
      connected: false,
      error: 'Địa chỉ máy A phải dạng http://IP:8787 (chưa hỗ trợ https)',
      ok: false,
    );
  }
}
