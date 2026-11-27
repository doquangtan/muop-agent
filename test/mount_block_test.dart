import 'package:flutter_test/flutter_test.dart';
import 'package:muop_agent/features/projects/domain/project_entities.dart';

ProjectWorkspace _project({required bool isMount, required bool mountLive}) {
  return ProjectWorkspace(
    id: 'p',
    name: 'Mount - muop-agent',
    path: '/home/u/.local/share/muop-agent/mounts/x',
    sessionCount: 0,
    runningCount: 0,
    isMount: isMount,
    mountLive: mountLive,
  );
}

void main() {
  test('mountBlockReason khóa khi mount đã gỡ', () {
    final reason = mountBlockReason(_project(isMount: true, mountLive: false));
    expect(reason, isNotNull);
    expect(reason, contains('máy chính'));
  });

  test('mountBlockReason không khóa khi mount còn hoạt động', () {
    expect(mountBlockReason(_project(isMount: true, mountLive: true)), isNull);
  });

  test('mountBlockReason không khóa project thường hoặc chưa chọn project', () {
    expect(mountBlockReason(_project(isMount: false, mountLive: false)), isNull);
    expect(mountBlockReason(null), isNull);
  });

  test('fromJson đọc mountLive', () {
    final live = ProjectWorkspace.fromJson({
      'id': 'a', 'name': 'a', 'path': '/a', 'isMount': true, 'mountLive': true,
    });
    final dead = ProjectWorkspace.fromJson({
      'id': 'a', 'name': 'a', 'path': '/a', 'isMount': true,
    });
    expect(live.mountLive, isTrue);
    expect(dead.mountLive, isFalse);
  });
}
