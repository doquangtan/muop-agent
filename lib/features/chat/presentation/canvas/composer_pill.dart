part of '../chat_canvas_view.dart';

class _ComposerPill extends StatelessWidget {
  const _ComposerPill({
    required this.icon,
    required this.label,
    required this.colorScheme,
    this.hasDropdown = false,
  });

  final IconData icon;
  final String label;
  final ColorScheme colorScheme;
  final bool hasDropdown;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.08)
            : Colors.black.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.12)
              : Colors.black.withValues(alpha: 0.08),
          width: 0.6,
        ),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 118),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12.5, color: colorScheme.onSurfaceVariant),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.1,
                  color: colorScheme.onSurface,
                ),
              ),
            ),
            if (hasDropdown) ...[
              const SizedBox(width: 2),
              Icon(
                Icons.keyboard_arrow_down_rounded,
                size: 13.5,
                color: colorScheme.onSurfaceVariant.withAlpha(200),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
