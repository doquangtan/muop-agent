import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'package:muop_agent/core/di/app_dependencies.dart';
import 'package:muop_agent/core/state/server_address_provider.dart';
import 'package:muop_agent/features/agy_auth/presentation/accounts_screen.dart';
import 'package:muop_agent/features/bridge/presentation/bridge_screen.dart';
import 'package:muop_agent/features/lsp/presentation/lsp_settings_screen.dart';
import 'package:muop_agent/features/settings/presentation/server_config_section.dart';
import 'package:muop_agent/features/settings/presentation/workspace_settings_section.dart';

/// Màn Cài đặt duy nhất: cấu hình máy chủ (đầu tiên), thư mục project, LSP, cầu nối, tài khoản.
/// Mở bằng nút bánh răng dưới sidebar.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final address = ref.watch(serverAddressProvider);
    return DefaultTabController(
      length: 5,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Cài đặt'),
          bottom: const TabBar(
            isScrollable: true,
            tabs: [
              Tab(text: 'Máy chủ'),
              Tab(text: 'Thư mục project'),
              Tab(text: 'LSP'),
              Tab(text: 'Cầu nối'),
              Tab(text: 'Tài khoản'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            const ServerConfigSection(),
            const WorkspaceSettingsSection(),
            LspSettingsScreenView(
              key: ValueKey('lsp-$address'),
              serverAddress: address,
              embedded: true,
            ),
            BridgeScreenView(
              key: ValueKey('bridge-$address'),
              serverAddress: address,
              repository: AppDependencies.bridge,
              embedded: true,
            ),
            AccountsScreenView(
              key: ValueKey('accounts-$address'),
              serverAddress: address,
              embedded: true,
            ),
          ],
        ),
      ),
    );
  }
}
