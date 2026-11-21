import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:muop_agent/core/theme/app_theme.dart';

/// Link đăng nhập Google lấy từ terminal agy. Link xuống dòng đầy đủ (không bị cắt như trong terminal),
/// chọn được và có nút sao chép / mở để đăng nhập.
class AgyLoginUrlBox extends StatelessWidget {
  const AgyLoginUrlBox({super.key, required this.url});

  final String url;

  Future<void> _open(BuildContext context) async {
    final uri = Uri.tryParse(url);
    final opened = uri != null &&
        await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Không mở được trình duyệt. Hãy sao chép link rồi mở thủ công.'),
        ),
      );
    }
  }

  void _copy(BuildContext context) {
    Clipboard.setData(ClipboardData(text: url));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Đã sao chép link')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final textTheme = Theme.of(context).textTheme;

    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Link đăng nhập Google', style: textTheme.labelLarge),
            const SizedBox(height: 6),
            SelectableText(
              url,
              style: textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                FilledButton.tonalIcon(
                  onPressed: () => _open(context),
                  icon: const Icon(Icons.open_in_new_rounded, size: 18),
                  label: const Text('Mở link'),
                ),
                OutlinedButton.icon(
                  onPressed: () => _copy(context),
                  icon: const Icon(Icons.copy_rounded, size: 18),
                  label: const Text('Sao chép'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
