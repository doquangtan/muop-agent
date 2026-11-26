import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:muop_agent/core/theme/app_theme.dart';
import 'package:muop_agent/features/sftp/data/sftp_transfers.dart';
import 'package:muop_agent/features/sftp/domain/sftp_entities.dart';
import 'package:muop_agent/features/sftp/domain/sftp_repository.dart';
import 'package:muop_agent/features/sftp/presentation/sftp_browser_screen.dart';

/// Repository giả: ghi lại lệnh và trả về kịch bản định sẵn
class _FakeSftp implements SftpRepository {
  final List<String> calls = [];
  final List<String> openPasswords = [];
  bool needPasswordFirst = false;
  Map<String, List<SftpEntry>> tree = {};

  @override
  Future<SftpReply> open(
    String address,
    int hostId, {
    String password = '',
    bool savePassword = false,
  }) async {
    calls.add('open');
    openPasswords.add(password);
    if (needPasswordFirst && password.isEmpty) {
      needPasswordFirst = false;
      return const SftpReply(
        ok: false,
        error: 'Máy yêu cầu mật khẩu',
        needsPassword: true,
      );
    }
    return const SftpReply(
      ok: true,
      error: '',
      session: SftpSession(
        sessionId: 's1',
        hostId: 1,
        hostName: 'NAS',
        home: '/home/john',
      ),
    );
  }

  @override
  Future<void> close(String address, String sessionId) async {}

  @override
  Future<SftpReply> list(String address, String sessionId, String path) async {
    calls.add('list:$path');
    return SftpReply(ok: true, error: '', entries: tree[path] ?? const []);
  }

  @override
  Future<SftpReply> mkdir(String a, String s, String p) async =>
      const SftpReply(ok: true, error: '');

  @override
  Future<SftpReply> rename(String a, String s, String f, String t) async =>
      const SftpReply(ok: true, error: '');

  @override
  Future<SftpReply> delete(
    String a,
    String s,
    String path, {
    required bool isDir,
  }) async {
    calls.add('delete:$path:$isDir');
    return const SftpReply(ok: true, error: '');
  }

  @override
  Future<SftpReply> upload(
    String a,
    String s,
    String p,
    Uint8List bytes, {
    bool overwrite = false,
  }) async => const SftpReply(ok: true, error: '');

  @override
  Future<SftpReply> read(String a, String s, String p) async =>
      const SftpReply(ok: true, error: '', content: 'x');

  @override
  Future<SftpReply> prepareDownload(
    String a,
    String s,
    List<String> paths,
  ) async {
    calls.add('prepare:${paths.join('|')}');
    return const SftpReply(
      ok: true,
      error: '',
      downloadId: 'dl-1',
      downloadName: 'muop-download.zip',
      size: 3,
    );
  }

  @override
  Future<SftpReply> openLocal(String address) async => const SftpReply(
        ok: true,
        error: '',
        session: SftpSession(
          sessionId: 'local',
          hostId: 0,
          hostName: 'Máy này',
          home: '/home/john',
        ),
      );

  @override
  Future<void> downloadToPath(
    String address,
    String downloadId,
    String destPath, {
    void Function(int received, int total)? onProgress,
  }) async {
    throw UnimplementedError('không dùng trong test: _FakeTransfers thay thế');
  }
}

/// Luồng tải giả: không ghi đĩa, trả về file tạm 3 byte
class _FakeTransfers extends SftpTransfers {
  _FakeTransfers(this.fake) : super(fake);

  final _FakeSftp fake;

  @override
  Future<void> discard(DownloadedFile file) async {}

  @override
  Future<DownloadedFile> fetchToTemp({
    required String address,
    required String downloadId,
    required String name,
    int expectedSize = -1,
    void Function(int received, int total)? onProgress,
  }) async {
    fake.calls.add('fetch:$downloadId');
    onProgress?.call(3, 3);
    return DownloadedFile(tempPath: '/fake/$name', name: name, size: 3);
  }
}

/// Bơm frame theo thời gian: thanh tiến trình vô hạn không bao giờ "settle"
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 15; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _pump(
  WidgetTester tester,
  _FakeSftp fake, {
  Future<bool> Function(DownloadedFile file)? saveFile,
  SftpTransfers? transfers,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(
        seedColor: const Color(0xFF4C8DFF),
        brightness: Brightness.dark,
      ),
      home: SftpBrowserScreenView(
        serverAddress: 'http://127.0.0.1:8787',
        hostId: 1,
        hostName: 'NAS',
        hostAddress: 'john@nas:22',
        repository: fake,
        saveFile: saveFile,
        transfers: transfers ?? _FakeTransfers(fake),
      ),
    ),
  );
  await _settle(tester);
}

void main() {
  test('đường dẫn cha và nối tên', () {
    expect(sftpParentOf('/home/john/a'), '/home/john');
    expect(sftpParentOf('/home/john/'), '/home');
    expect(sftpParentOf('/home'), '/');
    expect(sftpParentOf('/'), '/');
    expect(sftpJoin('/', 'a'), '/a');
    expect(sftpJoin('/home', 'a b'), '/home/a b');
  });

  test('SftpReply đọc đúng phiên, mục và cờ lỗi', () {
    final r = SftpReply.fromJson({
      'ok': true,
      'session': {
        'sessionId': 'x',
        'hostId': 3,
        'hostName': 'NAS',
        'home': '/home/john',
      },
      'entries': [
        {
          'name': 'd',
          'path': '/d',
          'isDir': true,
          'isLink': false,
          'size': 0,
          'modified': 'Nov 1 10:00',
          'mode': 'drwx',
        },
      ],
    });
    expect(r.session?.home, '/home/john');
    expect(r.entries.single.isDir, isTrue);

    final f = SftpReply.fromJson({
      'ok': false,
      'needsPassword': true,
      'passwordWrong': true,
    });
    expect(f.needsPassword && f.passwordWrong, isTrue);
  });

  testWidgets('liệt kê: thư mục trước, bấm thư mục để đi vào', (tester) async {
    final fake = _FakeSftp()
      ..tree = {
        '/home/john': [
          fakeFile('/home/john/notes.txt', 'notes.txt', 12),
          fakeDir('/home/john/projects', 'projects'),
        ],
        '/home/john/projects': [
          fakeFile('/home/john/projects/a.md', 'a.md', 3),
        ],
      };
    await _pump(tester, fake);

    expect(find.text('projects'), findsOneWidget);
    expect(find.text('notes.txt'), findsOneWidget);
    expect(fake.calls, contains('list:/home/john'));

    await tester.tap(find.text('projects'));
    await _settle(tester);
    expect(fake.calls.last, 'list:/home/john/projects');
    expect(find.text('a.md'), findsOneWidget);
  });

  testWidgets('máy yêu cầu mật khẩu: hỏi, rồi mở lại với mật khẩu nhập vào', (
    tester,
  ) async {
    final fake = _FakeSftp()..needPasswordFirst = true;
    await _pump(tester, fake);

    expect(find.text('Nhập mật khẩu SSH'), findsOneWidget);
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      'pw-1',
    );
    await _settle(tester); // nút "Kết nối" bật theo nội dung ô nhập
    await tester.tap(find.text('Kết nối'));
    await _settle(tester);

    expect(fake.openPasswords, ['', 'pw-1']);
    expect(fake.calls, contains('list:/home/john'));
  });

  testWidgets('xóa file: hỏi xác nhận rồi gọi xóa', (tester) async {
    final fake = _FakeSftp()
      ..tree = {
        '/home/john': [fakeFile('/home/john/old.txt', 'old.txt', 1)],
      };
    await _pump(tester, fake);

    await tester.tap(find.byType(PopupMenuButton<String>));
    await _settle(tester);
    await tester.tap(find.text('Xóa'));
    await _settle(tester);
    expect(find.text('Xóa file?'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Xóa'));
    await _settle(tester);
    expect(fake.calls, contains('delete:/home/john/old.txt:false'));
  });

  testWidgets('chọn nhiều mục rồi tải xuống: một gói, lưu bằng hộp thoại', (
    tester,
  ) async {
    final fake = _FakeSftp();
    _twoFiles(fake);
    final saved = <String>[];
    int? savedSize;
    await _pump(
      tester,
      fake,
      saveFile: (file) async {
        saved.add(file.name);
        savedSize = file.size;
        return true;
      },
    );

    await tester.tap(find.byType(Checkbox).at(0));
    await _settle(tester);
    await tester.tap(find.byType(Checkbox).at(1));
    await _settle(tester);
    expect(find.text('Đã chọn 2'), findsOneWidget);

    await tester.tap(find.byTooltip('Tải xuống mục đã chọn'));
    await _settle(tester);
    expect(fake.calls, contains('prepare:/home/john/a.txt|/home/john/b.txt'));
    expect(saved, ['muop-download.zip']);
    expect(savedSize, 3);
    expect(fake.calls, contains('fetch:dl-1'));
  });

  testWidgets('chọn nhiều mục rồi xóa: hỏi xác nhận rồi xóa từng mục', (
    tester,
  ) async {
    final fake = _FakeSftp();
    _twoFiles(fake);
    await _pump(tester, fake);

    await tester.tap(find.byType(Checkbox).at(0));
    await _settle(tester);
    await tester.tap(find.byType(Checkbox).at(1));
    await _settle(tester);

    await tester.tap(find.byIcon(Icons.delete_outline_rounded));
    await _settle(tester);
    expect(find.text('Xóa 2 mục?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Xóa'));
    await _settle(tester);

    expect(
      fake.calls,
      containsAll([
        'delete:/home/john/a.txt:false',
        'delete:/home/john/b.txt:false',
      ]),
    );
    expect(find.text('Đã chọn 2'), findsNothing);
  });

  testWidgets('file ẩn bị ẩn cho tới khi bật chip Ẩn; ô tìm lọc theo tên', (
    tester,
  ) async {
    final fake = _FakeSftp()
      ..tree = {
        '/home/john': [
          fakeFile('/home/john/.bashrc', '.bashrc', 10),
          fakeFile('/home/john/notes.txt', 'notes.txt', 12),
          fakeDir('/home/john/projects', 'projects'),
        ],
      };
    await _pump(tester, fake);

    expect(find.text('.bashrc'), findsNothing);
    expect(find.text('notes.txt'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilterChip, 'Ẩn'));
    await _settle(tester);
    expect(find.text('.bashrc'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'proj');
    await _settle(tester);
    expect(find.text('projects'), findsOneWidget);
    expect(find.text('notes.txt'), findsNothing);
    expect(find.text('.bashrc'), findsNothing);
  });

  testWidgets('màn hẹp (360px): dòng gọn không tràn, Tải về trên từng dòng, menu Thêm', (tester) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fake = _FakeSftp()
      ..tree = {
        '/home/john': [
          fakeDir('/home/john/projects', 'projects'),
          fakeFile(
            '/home/john/a-very-long-file-name-for-overflow-check.txt',
            'a-very-long-file-name-for-overflow-check.txt',
            2048,
          ),
        ],
      };
    await _pump(tester, fake, saveFile: (file) async => true);

    // Mỗi dòng có một nút tải về (thư mục và file); thanh tiêu đề không còn nút tải file lên
    expect(find.byTooltip('Tải về'), findsNWidgets(2));
    expect(find.byIcon(Icons.upload_file_rounded), findsNothing);

    await tester.tap(find.byTooltip('Tải về').first);
    await _settle(tester);
    expect(fake.calls, contains('prepare:/home/john/projects'));

    await tester.tap(find.byTooltip('Thêm'));
    await _settle(tester);
    expect(find.text('Thư mục mới'), findsOneWidget);
    expect(find.text('Tải file lên'), findsOneWidget);
  });
}

void _twoFiles(_FakeSftp fake) {
  fake.tree = {
    '/home/john': [
      fakeFile('/home/john/a.txt', 'a.txt', 1),
      fakeFile('/home/john/b.txt', 'b.txt', 2),
    ],
  };
}

SftpEntry fakeFile(String path, String name, int size) => SftpEntry(
  name: name,
  path: path,
  isDir: false,
  isLink: false,
  size: size,
  modified: 'Nov 25 10:00',
  mode: '-rw-r--r--',
);

SftpEntry fakeDir(String path, String name) => SftpEntry(
  name: name,
  path: path,
  isDir: true,
  isLink: false,
  size: 0,
  modified: 'Nov 25 10:00',
  mode: 'drwxr-xr-x',
);
