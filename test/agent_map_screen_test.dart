import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muop_agent/features/agent_map/presentation/agent_map_screen.dart';
import 'package:muop_agent/features/sessions/domain/session_entities.dart';

SubagentLane _lane(
  String id,
  String name, {
  String parent = 'Coordinator',
  AgentStatus status = AgentStatus.running,
  bool spawned = true,
}) {
  return SubagentLane(
    id: id,
    name: name,
    role: 'role $name',
    targetRepo: 'muop-erp-server',
    status: status,
    currentPhase: AgentWorkflowPhase.contractDiscovery,
    currentStepIndex: 0,
    currentActionText: '',
    currentToolName: '',
    promptBrief: 'Làm $name',
    steps: const [],
    progress: 0.4,
    filesModified: const [],
    parentId: parent,
    spawned: spawned,
  );
}

ConversationSession _session(List<SubagentLane> lanes) {
  return ConversationSession(
    id: 'conv-1',
    title: 'Knowledge base cấp tổ chức',
    createdAt: DateTime(2026, 11, 20),
    updatedAt: DateTime(2026, 11, 20),
    status: AgentStatus.running,
    currentPhase: AgentWorkflowPhase.contractDiscovery,
    steps: const [],
    subagentLanes: lanes,
    filesTouched: const [],
    commandsRun: const [],
    totalInputTokens: 0,
    totalOutputTokens: 0,
    totalCacheTokens: 0,
    contextTokens: 471200,
    contextModel: 'claude-cli:claude-opus-5-5',
  );
}

/// Nút đang chạy có animation lặp vô hạn, nên không dùng pumpAndSettle (sẽ không bao giờ xong)
Future<void> settleFrames(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('sơ đồ vẽ nhánh lồng nhau theo parentId mà không lỗi layout', (
    tester,
  ) async {
    final lanes = [
      _lane('Coordinator', 'Coordinator', parent: ''),
      _lane('a', 'Android KB assets parity'),
      _lane('b', 'Build KB assets web UI', status: AgentStatus.completed),
      _lane(
        'c',
        'Build Settings Knowledge section',
        parent: 'b',
        status: AgentStatus.completed,
      ),
      _lane('d', 'Build PDF pipeline'),
      _lane('h', 'Chỉ suy đoán', spawned: false),
    ];
    await tester.pumpWidget(
      MaterialApp(home: AgentMapScreen(sessionReader: () => _session(lanes))),
    );
    await tester.pump();

    expect(find.text('Coordinator'), findsOneWidget);
    expect(find.text('Knowledge base cấp tổ chức'), findsNothing);
    expect(find.text('Chỉ suy đoán'), findsNothing);
    expect(find.text('Android KB assets parity'), findsOneWidget);
    expect(find.text('Build KB assets web UI'), findsOneWidget);
    expect(find.text('Build Settings Knowledge section'), findsOneWidget);
    expect(find.text('Build PDF pipeline'), findsOneWidget);
    expect(find.text('Coordinator'), findsOneWidget);
    expect(find.textContaining('tác vụ nền đang chạy'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'bấm một agent mở chi tiết; màn hình không có session vẫn render',
    (tester) async {
      final lanes = [_lane('a', 'Agent A')];
      await tester.pumpWidget(
        MaterialApp(home: AgentMapScreen(sessionReader: () => _session(lanes))),
      );
      await tester.pump();
      await tester.tap(find.text('Agent A'));
      await settleFrames(tester);
      expect(find.text('Nhiệm vụ'), findsOneWidget);

      await tester.pumpWidget(
        MaterialApp(home: AgentMapScreen(sessionReader: () => null)),
      );
      await tester.pump();
      expect(find.textContaining('Chưa có conversation'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'zoom ra rồi zoom vào: nút Vừa màn hình đưa đủ cả cây về khung nhìn',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 700);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      final lanes = [
        _lane('Coordinator', 'Coordinator', parent: ''),
        _lane('a', 'Agent A'),
        _lane('b', 'Agent B', parent: 'a'),
        _lane('c', 'Agent C', parent: 'b'),
        _lane('d', 'Agent D', parent: 'c'),
        _lane('e', 'Agent E'),
      ];
      await tester.pumpWidget(
        MaterialApp(home: AgentMapScreen(sessionReader: () => _session(lanes))),
      );
      await settleFrames(tester);

      const titles = [
        'Coordinator',
        'Agent A',
        'Agent B',
        'Agent C',
        'Agent D',
        'Agent E',
      ];
      void expectAllVisible(String label) {
        final view = tester.getRect(find.byType(InteractiveViewer));
        for (final title in titles) {
          final rect = tester.getRect(find.text(title));
          expect(
            view.contains(rect.topLeft) && view.contains(rect.bottomRight),
            isTrue,
            reason:
                '$label: "$title" nằm ngoài khung nhìn ($rect so với $view)',
          );
        }
      }

      expectAllVisible('khi mở');

      final controller = tester
          .widget<InteractiveViewer>(find.byType(InteractiveViewer))
          .transformationController!;
      // Zoom ra thật xa, rồi zoom vào và lệch sang một góc
      controller.value = Matrix4.identity()
        ..translateByDouble(900, 500, 0, 1)
        ..scaleByDouble(0.3, 0.3, 1, 1);
      await tester.pump();
      controller.value = Matrix4.identity()
        ..translateByDouble(-700, -400, 0, 1)
        ..scaleByDouble(2.0, 2.0, 1, 1);
      await tester.pump();

      await tester.tap(find.byIcon(Icons.fit_screen_outlined));
      await settleFrames(tester);
      expectAllVisible('sau nút Vừa màn hình');
    },
  );

  testWidgets('subagent mới xuất hiện sau khi mở vẫn nằm trong khung nhìn', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1100, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    final coordinator = _lane('Coordinator', 'Coordinator', parent: '');
    final l1 = _lane('l1', 'L1', parent: 'Coordinator');
    final l2 = _lane('l2', 'L2', parent: 'l1');
    final l3 = _lane('l3', 'L3', parent: 'l2');
    final l4 = _lane('l4', 'L4', parent: 'l3');
    var lanes = [coordinator, l1, l2];
    await tester.pumpWidget(
      MaterialApp(home: AgentMapScreen(sessionReader: () => _session(lanes))),
    );
    await settleFrames(tester);

    // Session đang chạy: L3 và L4 được spawn sau khi màn hình đã vừa khung nhìn
    lanes = [coordinator, l1, l2, l3, l4];
    await tester.pump(const Duration(seconds: 1));
    await settleFrames(tester);

    final view = tester.getRect(find.byType(InteractiveViewer));
    for (final title in ['Coordinator', 'L1', 'L2', 'L3', 'L4']) {
      final rect = tester.getRect(find.text(title));
      expect(
        view.contains(rect.topLeft) && view.contains(rect.bottomRight),
        isTrue,
        reason: '"$title" nằm ngoài khung nhìn ($rect so với $view)',
      );
    }
  });

  testWidgets(
    'bấm được nút Coordinator gốc, nút đang chạy có animation và đủ chip',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 700);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      final lanes = [
        _lane(
          'Coordinator',
          'Coordinator',
          parent: '',
          status: AgentStatus.running,
        ),
        _lane('a', 'Agent A', status: AgentStatus.running),
      ];
      await tester.pumpWidget(
        MaterialApp(home: AgentMapScreen(sessionReader: () => _session(lanes))),
      );
      await settleFrames(tester);

      // Nút đang chạy có animation liên tục: pump nhiều khung hình không được lỗi
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }
      expect(tester.takeException(), isNull);
      expect(find.textContaining('công cụ'), findsNWidgets(2));
      expect(find.textContaining('tệp thay đổi'), findsNWidgets(2));
      expect(find.textContaining('Đang khởi động'), findsWidgets);

      // Bấm nút Coordinator (gốc) phải mở được chi tiết
      await tester.tap(find.text('Coordinator'));
      await settleFrames(tester);
      expect(find.text('Công cụ đã gọi (0)'), findsOneWidget);
      expect(find.text('Tệp đã thay đổi (0)'), findsOneWidget);
    },
  );
}
