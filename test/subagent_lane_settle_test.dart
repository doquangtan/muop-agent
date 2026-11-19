import 'package:flutter_test/flutter_test.dart';
import 'package:muop_agent/features/sessions/domain/session_entities.dart';

SubagentLane _lane(AgentStatus status) => SubagentLane(
      id: 'lane-1',
      name: 'erp-server-agent',
      role: 'Backend',
      targetRepo: 'muop-erp-server',
      status: status,
      currentPhase: AgentWorkflowPhase.contractDiscovery,
      currentStepIndex: 3,
      currentActionText: 'Đang chạy go test',
      currentToolName: 'run_command',
      promptBrief: 'brief',
      steps: const [],
      progress: 0.5,
      filesModified: const [],
    );

void main() {
  test('lane đang chạy của session đã hoàn tất chuyển sang hoàn tất', () {
    final settled = _lane(AgentStatus.running).settledFor(AgentStatus.completed);
    expect(settled.status, AgentStatus.completed);
    expect(settled.progress, 1.0);
    expect(settled.currentToolName, 'standby');
  });

  test('lane đang chờ của session bị gián đoạn chuyển sang gián đoạn', () {
    final settled = _lane(AgentStatus.waiting).settledFor(AgentStatus.interrupted);
    expect(settled.status, AgentStatus.interrupted);
  });

  test('lane đã hoàn tất giữ nguyên', () {
    final lane = _lane(AgentStatus.completed);
    expect(identical(lane.settledFor(AgentStatus.completed), lane), isTrue);
  });
}
