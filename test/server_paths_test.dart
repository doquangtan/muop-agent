import 'package:flutter_test/flutter_test.dart';

import 'package:muop_agent/core/config/server_paths.dart';
import 'package:muop_agent/features/sessions/domain/session_entities.dart';
import 'package:muop_agent/features/setup/domain/setup_entities.dart';

void main() {
  group('joinServerPath', () {
    test('ghép gốc và tên mục con', () {
      expect(joinServerPath('/srv/projects', 'app'), '/srv/projects/app');
    });

    test('bỏ dấu / cuối của gốc, không tạo //', () {
      expect(joinServerPath('/srv/projects/', 'app'), '/srv/projects/app');
    });

    test('không có gốc thì trả về tên, không đoán đường dẫn', () {
      expect(joinServerPath('', 'app'), 'app');
    });
  });

  test('ServerMeta đọc workspaceRoot và homeDir từ server', () {
    final meta = ServerMeta.fromJson({
      'projects': <dynamic>[],
      'availableModels': <dynamic>[],
      'modelLabels': <String, dynamic>{},
      'modelContextLimits': <String, dynamic>{},
      'hostname': 'may-a',
      'lanIps': <dynamic>[],
      'port': 8787,
      'workspaceRoot': '/data/projects',
      'homeDir': '/data',
    });
    expect(meta.workspaceRoot, '/data/projects');
    expect(meta.homeDir, '/data');
  });

  test('ServerMeta không có trường mới thì để rỗng, không dùng giá trị cũ', () {
    final meta = ServerMeta.fromJson({
      'hostname': 'may-a',
      'port': 8787,
    });
    expect(meta.workspaceRoot, '');
    expect(meta.homeDir, '');
  });

  test('SetupTool đọc nguồn đường dẫn và đường dẫn người dùng đã chọn', () {
    final tool = SetupTool.fromJson({
      'id': 'agy',
      'label': 'Antigravity CLI (agy)',
      'group': 'cli',
      'installed': true,
      'path': '/opt/agy/bin/agy',
      'installable': true,
      'hint': '',
      'source': 'override',
      'overridden': '/opt/agy/bin/agy',
    });
    expect(tool.source, 'override');
    expect(tool.overridden, '/opt/agy/bin/agy');
  });

  test('ConversationSession không còn project mặc định cứng', () {
    final session = ConversationSession.fromJson({'id': 'c1'});
    expect(session.projectPath, '');
    expect(session.projectName, '');
  });
}
