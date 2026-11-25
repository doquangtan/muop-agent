import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:muop_agent/features/setup/domain/setup_entities.dart';
import 'package:muop_agent/features/setup/domain/setup_repository.dart';
import 'package:muop_agent/features/setup/presentation/workspace_folder_picker.dart';

/// Repository giả: duyệt cây thư mục từ một bảng cố định, không gọi socket
class _TreeRepository implements SetupRepository {
  static const _tree = <String, List<String>>{
    '/home/tester': ['projects', 'notes'],
    '/home/tester/projects': ['app-a'],
    '/home/tester/projects/app-a': [],
  };

  final List<String> requested = [];

  @override
  Future<SetupDirListing> browseDirectories(String path) async {
    final target = path.isEmpty ? '/home/tester' : path;
    requested.add(target);
    final children = _tree[target];
    if (children == null) {
      return SetupDirListing.failure('Không mở được thư mục');
    }
    final parent = target == '/' ? '' : target.substring(0, target.lastIndexOf('/'));
    return SetupDirListing(
      ok: true,
      error: '',
      path: target,
      parent: parent,
      home: '/home/tester',
      dirs: [
        for (final name in children)
          SetupDirEntry(name: name, path: '$target/$name'),
      ],
    );
  }

  @override
  Stream<SetupStatus> get updates => const Stream.empty();
  @override
  Future<SetupStatus> fetchStatus() => throw UnimplementedError();
  @override
  Future<SetupStatus> install(String tool) => throw UnimplementedError();
  @override
  Future<SetupStatus> selectClis(List<String> clis) => throw UnimplementedError();
  @override
  Future<SetupStatus> complete() => throw UnimplementedError();
  @override
  Future<SetupStatus> setWorkspace(String path) => throw UnimplementedError();
  @override
  Future<SetupStatus> setToolPath(String tool, String path) => throw UnimplementedError();
  @override
  Future<SetupStatus> configureSsh(String username) => throw UnimplementedError();
  @override
  Future<SetupStatus> autoSetupSsh() => throw UnimplementedError();
  @override
  Future<SetupStatus> verifySsh(String publicKey) => throw UnimplementedError();
}

void main() {
  testWidgets('bấm vào thư mục để đi sâu, rồi chọn thư mục đang xem', (tester) async {
    final repo = _TreeRepository();
    String? picked;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  picked = await showWorkspaceFolderPicker(
                    context,
                    repository: repo,
                  );
                },
                child: const Text('mở'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('mở'));
    await tester.pumpAndSettle();
    // Mở đầu ở home của server
    expect(find.text('projects'), findsOneWidget);
    expect(find.text('notes'), findsOneWidget);

    await tester.tap(find.text('projects'));
    await tester.pumpAndSettle();
    expect(find.text('app-a'), findsOneWidget);
    expect(find.text('notes'), findsNothing);

    await tester.tap(find.widgetWithText(FilledButton, 'Chọn thư mục này'));
    await tester.pumpAndSettle();
    expect(picked, '/home/tester/projects');
    expect(repo.requested, ['/home/tester', '/home/tester/projects']);
  });

  testWidgets('thư mục không đọc được: báo lỗi và không cho chọn', (tester) async {
    final repo = _TreeRepository();
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: WorkspaceFolderPicker(repository: repo, start: '/khong/co'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Không mở được thư mục'), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Chọn thư mục này'),
    );
    expect(button.onPressed, isNull);
  });
}
