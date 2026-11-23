import 'package:material_ui/material_ui.dart';

/// Một conversation hiển thị trên rail thu gọn (chỉ icon, tiêu đề hiện ở tooltip)
class RailConversation {
  const RailConversation({
    required this.id,
    required this.title,
    required this.projectName,
    required this.icon,
    required this.color,
  });

  final String id;
  final String title;
  final String projectName;
  final IconData icon;
  final Color color;
}

/// Rail bên trái ở trạng thái thu gọn: mỗi conversation là một icon có tooltip.
/// Khi di chuột vào, dashboard mở panel đầy đủ (xem [onHoverChanged]).
class DesktopConversationRail extends StatelessWidget {
  const DesktopConversationRail({
    super.key,
    required this.conversations,
    required this.selectedId,
    required this.onSelect,
    required this.onNewConversation,
    required this.onHoverChanged,
    required this.isPinned,
    required this.onTogglePin,
  });

  static const double collapsedWidth = 56;
  static const double expandedWidth = 280;

  final List<RailConversation> conversations;
  final String? selectedId;
  final ValueChanged<String> onSelect;
  final VoidCallback onNewConversation;
  final ValueChanged<bool> onHoverChanged;
  final bool isPinned;
  final VoidCallback onTogglePin;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return MouseRegion(
      onEnter: (_) => onHoverChanged(true),
      onExit: (_) => onHoverChanged(false),
      child: Container(
        width: collapsedWidth,
        color: Colors.transparent,
        child: Column(
          children: [
            const SizedBox(height: 6),
            _RailButton(
              tooltip: 'Cuộc trò chuyện mới',
              icon: Icons.add_rounded,
              color: colorScheme.primary,
              selected: false,
              onPressed: onNewConversation,
            ),
            _RailButton(
              tooltip: isPinned ? 'Bỏ ghim danh sách' : 'Ghim danh sách hội thoại',
              icon: isPinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
              color: colorScheme.onSurfaceVariant,
              selected: isPinned,
              onPressed: onTogglePin,
            ),
            Divider(height: 12, indent: 12, endIndent: 12, color: colorScheme.outlineVariant),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.only(bottom: 8),
                itemCount: conversations.length,
                itemBuilder: (context, index) {
                  final conv = conversations[index];
                  return _RailButton(
                    tooltip: conv.projectName.isEmpty
                        ? conv.title
                        : '${conv.title}\n${conv.projectName}',
                    icon: conv.icon,
                    color: conv.color,
                    selected: conv.id == selectedId,
                    onPressed: () => onSelect(conv.id),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RailButton extends StatelessWidget {
  const _RailButton({
    required this.tooltip,
    required this.icon,
    required this.color,
    required this.selected,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final Color color;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Tooltip(
        message: tooltip,
        waitDuration: const Duration(milliseconds: 250),
        child: Material(
          color: selected ? colorScheme.primary.withAlpha(36) : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: onPressed,
            child: SizedBox(
              width: 40,
              height: 40,
              child: Icon(icon, size: 20, color: selected ? colorScheme.primary : color),
            ),
          ),
        ),
      ),
    );
  }
}
