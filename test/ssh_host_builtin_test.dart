import 'package:flutter_test/flutter_test.dart';
import 'package:muop_agent/features/ssh/domain/ssh_entities.dart';

void main() {
  test('máy mặc định được đánh dấu builtin, máy thường thì không', () {
    final local = SshHost.fromJson({
      'id': 7,
      'name': 'Máy này (muop-agent)',
      'host': '127.0.0.1',
      'port': 22,
      'username': 'john',
      'authType': 'local',
      'hasPassword': false,
      'hasKey': false,
      'builtin': true,
    });
    expect(local.builtin, isTrue);
    expect(local.authType, 'local');

    final remote = SshHost.fromJson({
      'id': 6,
      'name': 'Laptop',
      'host': '192.168.31.216',
      'port': 22,
      'username': 'john',
      'authType': 'password',
      'hasPassword': true,
      'hasKey': false,
    });
    expect(remote.builtin, isFalse);
  });
}
