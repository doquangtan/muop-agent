import 'package:flutter_test/flutter_test.dart';
import 'package:muop_agent/features/setup/domain/setup_entities.dart';

SetupStatus _status({required String root, required bool completed}) {
  return SetupStatus.fromJson({
    'ok': true,
    'error': '',
    'completed': completed,
    'selectedClis': ['agy'],
    'workspaceRoot': root,
    'workspaceReady': completed && root.isNotEmpty,
    'tools': [
      {'id': 'git', 'label': 'Git', 'group': 'base', 'installed': true, 'path': '/usr/bin/git', 'installable': false, 'hint': ''},
      {'id': 'agy', 'label': 'agy', 'group': 'cli', 'installed': true, 'path': '/x/agy', 'installable': true, 'hint': ''},
    ],
    'job': null,
  });
}

void main() {
  test('chưa chọn thư mục project thì phải mở wizard, dù đã khởi tạo xong', () {
    final s = _status(root: '', completed: true);
    expect(s.workspaceRoot, '');
    expect(s.workspaceReady, isFalse);
    expect(s.needsSetup, isTrue);
  });

  test('đã khởi tạo xong và có thư mục project: đang quét, không mở wizard', () {
    final s = _status(root: '/home/tester/project', completed: true);
    expect(s.workspaceReady, isTrue);
    expect(s.needsSetup, isFalse);
  });

  test('có thư mục nhưng chưa khởi tạo xong: chưa quét', () {
    final s = _status(root: '/home/tester/project', completed: false);
    expect(s.workspaceReady, isFalse);
    expect(s.needsSetup, isTrue);
  });
}
