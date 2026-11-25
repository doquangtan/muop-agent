import 'package:flutter_test/flutter_test.dart';

import 'package:muop_agent/features/setup/domain/setup_entities.dart';

void main() {
  test('parses setup status from server payload', () {
    final status = SetupStatus.fromJson({
      'ok': true,
      'error': '',
      'completed': false,
      'workspaceRoot': '/home/tester/project',
      'selectedClis': ['agy'],
      'tools': [
        {
          'id': 'git',
          'label': 'Git',
          'group': 'base',
          'installed': true,
          'path': '/usr/bin/git',
          'installable': false,
          'hint': 'sudo apt install git',
        },
        {
          'id': 'claude',
          'label': 'Claude Code CLI',
          'group': 'cli',
          'installed': false,
          'path': '',
          'installable': true,
          'hint': '',
        },
      ],
      'job': {
        'tool': 'claude',
        'state': 'running',
        'log': ['Downloading…', 'Installing…'],
        'error': '',
        'startedAt': '2026-11-20T07:00:00Z',
        'finishedAt': '',
      },
    });

    expect(status.ok, isTrue);
    expect(status.completed, isFalse);
    expect(status.selectedClis, ['agy']);
    expect(status.isInstalled('git'), isTrue);
    expect(status.isInstalled('claude'), isFalse);
    expect(status.tool('claude')?.installable, isTrue);
    expect(status.tool('missing'), isNull);
    expect(status.job?.running, isTrue);
    expect(status.job?.log.last, 'Installing…');
  });

  test('failure keeps the error and marks status as not ok', () {
    final status = SetupStatus.failure('Không gọi được server');
    expect(status.ok, isFalse);
    expect(status.completed, isFalse);
    expect(status.tools, isEmpty);
    expect(status.error, 'Không gọi được server');
  });

  test('ssh not ready does not keep the setup wizard open', () {
    Map<String, dynamic> payload(bool sshReady) => {
          'ok': true,
          'error': '',
          'completed': true,
          'workspaceRoot': '/home/tester/project',
          'selectedClis': ['agy'],
          'tools': [
            {'id': 'git', 'label': 'Git', 'group': 'base', 'installed': true, 'path': '/usr/bin/git', 'installable': false, 'hint': ''},
            {'id': 'agy', 'label': 'agy', 'group': 'cli', 'installed': true, 'path': '/x/agy', 'installable': true, 'hint': ''},
          ],
          'job': null,
          'ssh': {
            'client': true,
            'sshdRunning': sshReady,
            'username': 'john',
            'keyPath': '/k',
            'keyExists': sshReady,
            'publicKey': 'ssh-ed25519 AAAA',
            'keyAuthorized': sshReady,
            'loginOk': sshReady,
            'ready': sshReady,
          },
        };

    final ready = SetupStatus.fromJson(payload(true));
    expect(ready.ssh.ready, isTrue);
    expect(ready.needsSetup, isFalse);

    final notReady = SetupStatus.fromJson(payload(false));
    expect(notReady.ssh.sshdRunning, isFalse);
    expect(notReady.ssh.publicKey, 'ssh-ed25519 AAAA');
    expect(notReady.needsSetup, isFalse);
  });

  test('finished job is not running', () {
    final job = SetupJob.fromJson({'tool': 'agy', 'state': 'done'});
    expect(job.running, isFalse);
    expect(job.log, isEmpty);
  });

  test('reads platform from server and defaults to linux when absent', () {
    final mac = SetupStatus.fromJson({
      'ok': true,
      'platform': 'macos',
      'aptPackages': [],
    });
    expect(mac.platform, 'macos');
    expect(mac.isMacOS, isTrue);

    final legacy = SetupStatus.fromJson({'ok': true});
    expect(legacy.platform, 'linux');
    expect(legacy.isMacOS, isFalse);
  });
}
