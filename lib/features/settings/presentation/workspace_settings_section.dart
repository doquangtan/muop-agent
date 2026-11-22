import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'package:muop_agent/core/di/app_dependencies.dart';
import 'package:muop_agent/core/theme/app_theme.dart';
import 'package:muop_agent/features/setup/domain/setup_entities.dart';
import 'package:muop_agent/features/setup/presentation/workspace_root_field.dart';

/// Thư mục project trong màn Cài đặt. Không có đường dẫn mặc định: người dùng chọn thư mục.
class WorkspaceSettingsSection extends ConsumerStatefulWidget {
  const WorkspaceSettingsSection({super.key});

  @override
  ConsumerState<WorkspaceSettingsSection> createState() =>
      _WorkspaceSettingsSectionState();
}

class _WorkspaceSettingsSectionState
    extends ConsumerState<WorkspaceSettingsSection> {
  SetupStatus _status = SetupStatus.empty;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final s = await AppDependencies.setup.fetchStatus();
    if (!mounted) return;
    setState(() {
      _status = s;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final scheme = context.scheme;
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final root = _status.workspaceRoot;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        Text('Thư mục project', style: textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'Thư mục chứa các project muop quét và sửa. Các project này chỉ được quét khi đã khởi tạo xong; '
          'đổi thư mục sẽ quét lại theo thư mục mới.',
          style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        WorkspaceRootField(
          repository: AppDependencies.setup,
          current: root,
          onSaved: (s) => setState(() => _status = s),
        ),
        const SizedBox(height: 8),
        Text(
          _status.workspaceReady
              ? 'Đang quét project.'
              : 'Chưa quét: chưa hoàn tất khởi tạo.',
          style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}
