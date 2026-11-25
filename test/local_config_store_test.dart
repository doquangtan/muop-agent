import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muop_agent/core/network/socket_gateway.dart';
import 'package:muop_agent/core/state/chat_theme_provider.dart';
import 'package:muop_agent/core/storage/local_config_store.dart';
import 'package:muop_agent/core/theme/chat_theme.dart';
import 'package:muop_agent/features/connection/data/connection_repository_impl.dart';

void main() {
  late Directory tempConfigDir;

  setUp(() async {
    tempConfigDir = await Directory.systemTemp.createTemp(
      'muop_local_cfg_test_',
    );
    LocalConfigStore.resetForTest();
    LocalConfigStore.testDirectoryOverride = tempConfigDir;
  });

  tearDown(() async {
    LocalConfigStore.resetForTest();
    if (await tempConfigDir.exists()) {
      await tempConfigDir.delete(recursive: true);
    }
  });

  test('lưu và nạp lại cấu hình theme đầy đủ từ thư mục bền vững', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final notifier = container.read(chatThemeProvider.notifier);
    notifier.selectPreset('crystal_rose');
    notifier.setWallpaper('math_emerald');
    notifier.setUserBubble('aqua_teal');
    notifier.setAiBubble('pure_neutral');
    notifier.setDarkMode(false);

    // Chờ thao tác ghi bất đồng bộ hoàn tất
    await Future<void>.delayed(const Duration(milliseconds: 80));

    final reloaded = await ChatThemeNotifier.loadSavedConfig();
    expect(
      reloaded,
      const ChatThemeConfig(
        presetId: 'crystal_rose',
        customWallpaperId: 'math_emerald',
        customUserBubbleId: 'aqua_teal',
        customAiBubbleId: 'pure_neutral',
        isDark: false,
      ),
    );
  });

  test('tên máy (hostname) được nhớ theo từng địa chỉ và bỏ theo khi xóa máy', () async {
    final repo = ConnectionRepositoryImpl(SocketGateway());
    await repo.saveServerAddress('192.168.31.149:8787');
    await repo.saveServerAddress('10.0.0.5:8787');
    await repo.saveServerName('192.168.31.149:8787', 'Johns-Mac-Mini.local');
    // Ghi tên không được làm mất danh sách và địa chỉ đang dùng
    expect(await repo.loadSavedServerAddress(), '10.0.0.5:8787');
    expect(await repo.loadSavedServers(), containsAll(['10.0.0.5:8787', '192.168.31.149:8787']));
    expect(await repo.loadServerNames(), {'192.168.31.149:8787': 'Johns-Mac-Mini.local'});

    await repo.removeSavedServer('192.168.31.149:8787');
    expect(await repo.loadServerNames(), isEmpty);
  });

  test('lưu và nạp lại địa chỉ server cùng danh sách máy đã kết nối', () async {
    final repo = ConnectionRepositoryImpl(SocketGateway());
    await repo.saveServerAddress('192.168.1.99:8787');
    await repo.saveServerAddress('10.0.0.5:8787');

    expect(await repo.loadSavedServerAddress(), '10.0.0.5:8787');
    final servers = await repo.loadSavedServers();
    expect(servers, containsAll(['10.0.0.5:8787', '192.168.1.99:8787']));
  });

  test('tự động di chuyển (migrate) cấu hình cũ từ systemTemp sang thư mục mới', () async {
    const fileName = 'muop_agent_migrate_check.json';
    final legacyFile = File('${Directory.systemTemp.path}/$fileName');
    addTearDown(() async {
      if (await legacyFile.exists()) await legacyFile.delete();
    });
    await legacyFile.writeAsString(jsonEncode({'serverAddress': '172.16.0.8'}));

    final migrated = await LocalConfigStore.readJson(fileName);
    expect(migrated['serverAddress'], '172.16.0.8');

    final persistedFile = File('${tempConfigDir.path}/$fileName');
    expect(await persistedFile.exists(), isTrue);
  });
}
