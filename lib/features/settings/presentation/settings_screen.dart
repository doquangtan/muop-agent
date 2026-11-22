import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'package:muop_agent/core/di/app_dependencies.dart';
import 'package:muop_agent/core/state/server_address_provider.dart';
import 'package:muop_agent/features/agy_auth/presentation/accounts_screen.dart';
import 'package:muop_agent/features/bridge/presentation/bridge_screen.dart';
import 'package:muop_agent/features/settings/presentation/server_config_section.dart';
import 'package:muop_agent/features/settings/presentation/workspace_settings_section.dart';

/// Màn Cài đặt duy nhất: thư mục project, cấu hình IP máy chủ, cầu nối, tài khoản.
/// Mở bằng nút bánh răng dưới sidebar.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final address = ref.watch(serverAddressProvider);
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Cài đặt'),
          bottom: const TabBar(
            isScrollable: true,
            tabs: [
              Tab(text: 'Thư mục project'),
              Tab(text: 'Máy chủ'),
              Tab(text: 'Cầu nối'),
              Tab(text: 'Tài khoản'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            const WorkspaceSettingsSection(),
            const ServerConfigSection(),
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
