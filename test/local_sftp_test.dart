import 'package:flutter_test/flutter_test.dart';
import 'package:muop_agent/features/server_files/data/server_files_repository_impl.dart';
import 'package:muop_agent/features/sftp/data/local_sftp.dart';
import 'package:muop_agent/features/sftp/data/sftp_transfers.dart';
import 'package:muop_agent/features/sftp/domain/sftp_entities.dart';
import 'package:muop_agent/features/sftp/domain/sftp_repository.dart';
import 'package:muop_agent/features/sftp/presentation/download_progress.dart';

/// Repository giả: đếm lần mở phiên, và có thể báo phiên đã mất ở lần list đầu tiên
class _FakeRepo implements SftpRepository {
  int opens = 0;
  int lists = 0;
  bool expireFirstList = false;
  List<SftpEntry> entries = const [];

  @override
  Future<SftpReply> openLocal(String address) async {
    opens++;
    return SftpReply(
      ok: true,
      error: '',
      session: SftpSession(
        sessionId: 'local-$opens',
        hostId: 0,
        hostName: 'Máy này',
        home: '/home/john',
      ),
    );
  }

  @override
  Future<SftpReply> list(String address, String sessionId, String path) async {
    lists++;
    if (expireFirstList && lists == 1) {
      return const SftpReply(ok: false, error: 'mất phiên', sessionGone: true);
    }
    return SftpReply(ok: true, error: '', entries: entries);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('không dùng trong test');
}

SftpEntry _entry(String name, {bool isDir = false, int? unix}) => SftpEntry(
      name: name,
      path: '/home/john/$name',
      isDir: isDir,
      isLink: false,
      size: 12,
      modified: 'Nov 25 10:00',
      mode: isDir ? 'drwxr-xr-x' : '-rw-r--r--',
      modifiedUnix: unix,
    );

void main() {
  test('phiên "Máy này" mở một lần rồi dùng lại cho mọi thao tác', () async {
    final repo = _FakeRepo();
    final local = LocalSftp(repo);
    for (var i = 0; i < 3; i++) {
      await local.run('http://x', (sid) => repo.list('http://x', sid, '/'));
    }
    expect(repo.opens, 1);
    expect(repo.lists, 3);
  });

  test('phiên mất trên server thì mở lại và chạy lại đúng một lần', () async {
    final repo = _FakeRepo()..expireFirstList = true;
    final local = LocalSftp(repo);
    final reply = await local.run(
      'http://x',
      (sid) => repo.list('http://x', sid, '/'),
    );
    expect(reply.ok, isTrue);
    expect(repo.opens, 2);
    expect(repo.lists, 2);
  });

  test('danh sách thư mục: ánh xạ entry, ẩn file ẩn, cha của thư mục', () async {
    final repo = _FakeRepo()
      ..entries = [
        _entry('.bashrc'),
        _entry('notes.txt', unix: 1764064800),
        _entry('projects', isDir: true),
      ];
    final repoImpl = ServerFilesRepositoryImpl(
      LocalSftp(repo),
      SftpTransfers(repo),
    );

    final hidden = await repoImpl.fetchServerDirectory(
      address: 'http://x',
      path: '/home/john/src',
    );
    expect(hidden.ok, isTrue);
    expect(hidden.parentPath, '/home/john');
    expect(hidden.entries.map((e) => e.name), ['notes.txt', 'projects']);
    expect(hidden.entries.first.permissions, '-rw-r--r--');
    expect(hidden.entries.first.modifiedAt.millisecondsSinceEpoch, 1764064800 * 1000);

    final all = await repoImpl.fetchServerDirectory(
      address: 'http://x',
      path: '/home/john/src',
      showHidden: true,
    );
    expect(all.entries.length, 3);
  });

  test('SftpEntry đọc modifiedUnix (null với máy SSH)', () {
    expect(
      SftpEntry.fromJson({'name': 'a', 'modifiedUnix': 1700000000}).modifiedUnix,
      1700000000,
    );
    expect(SftpEntry.fromJson({'name': 'a'}).modifiedUnix, isNull);
  });

  test('tiến trình tải: phần trăm và dung lượng gọn', () {
    expect(const DownloadProgress(50, 200).fraction, 0.25);
    expect(const DownloadProgress(0, -1).fraction, isNull);
    expect(const DownloadProgress(300, 200).fraction, 1.0);
    expect(formatDownloadSize(512), '512 B');
    expect(formatDownloadSize(2048), '2.0 KB');
    expect(formatDownloadSize(3 * 1024 * 1024), '3.0 MB');
  });
}
