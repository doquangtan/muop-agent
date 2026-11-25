import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'package:muop_agent/core/state/chat_theme_provider.dart';
import 'package:muop_agent/core/theme/chat_theme.dart';
import 'package:muop_agent/core/theme/chat_theme_painter.dart';

/// Mở bảng chọn Giao diện & Hình nền (6 bộ theme + tùy chỉnh widget User, AI, hình nền).
Future<void> showChatThemePickerSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    constraints: const BoxConstraints(maxWidth: 560),
    builder: (_) => const ChatThemePickerSheet(),
  );
}

class ChatThemePickerSheet extends ConsumerWidget {
  const ChatThemePickerSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(chatThemeProvider);
    final notifier = ref.read(chatThemeProvider.notifier);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final brightness = config.isDark ? Brightness.dark : Brightness.light;
    final activeAppearance = ChatAppearanceColors.resolve(config, brightness);
    final hasCustomParts =
        config.customWallpaperId != null ||
        config.customUserBubbleId != null ||
        config.customAiBubbleId != null;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(18, 2, 18, 22),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Tiêu đề + nút chuyển nhanh Dark / Light
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Giao diện & Hình nền',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Chọn 1 trong 6 bộ chủ đề hoặc tùy chỉnh từng phần.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Tooltip(
                message: config.isDark
                    ? 'Chuyển sang chế độ Sáng'
                    : 'Chuyển sang chế độ Tối',
                child: IconButton.filledTonal(
                  key: const Key('theme-picker-brightness-toggle'),
                  onPressed: notifier.toggleBrightness,
                  icon: Icon(
                    config.isDark
                        ? Icons.light_mode_rounded
                        : Icons.dark_mode_rounded,
                    size: 20,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),

          // Lưới 6 bộ theme hoàn chỉnh kiểu Telegram Browse Themes
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: kChatThemePresets.length,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
              childAspectRatio: 0.86,
            ),
            itemBuilder: (context, index) {
              final preset = kChatThemePresets[index];
              final isSelected =
                  !hasCustomParts && config.presetId == preset.id;
              final presetAppearance = ChatAppearanceColors.resolve(
                ChatThemeConfig(presetId: preset.id, isDark: config.isDark),
                brightness,
              );
              return _ThemePresetCard(
                key: Key('theme-preset-${preset.id}'),
                preset: preset,
                appearance: presetAppearance,
                selected: isSelected,
                accentColor: scheme.primary,
                onTap: () => notifier.selectPreset(preset.id),
              );
            },
          ),
          const SizedBox(height: 14),

          // Khung xem trước trực tiếp (Nền + Widget AI + Widget User)
          _LiveThemePreview(
            appearance: activeAppearance,
            isDark: config.isDark,
            outlineColor: scheme.outlineVariant,
          ),
          const SizedBox(height: 16),

          Text(
            'Tùy chỉnh từng phần',
            style: theme.textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w700,
              color: scheme.primary,
            ),
          ),
          const SizedBox(height: 10),

          // 1. Kiểu hình nền (Không nền + 6 mẫu)
          const _SectionLabel(label: 'Hình nền'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildNoWallpaperChip(
                config: config,
                scheme: scheme,
                theme: theme,
                onTap: () => notifier.setWallpaper(ChatThemeConfig.noWallpaperId),
              ),
              for (final wp in kWallpaperPresets)
                _buildWallpaperChip(
                  context,
                  wp: wp,
                  config: config,
                  activeAppearance: activeAppearance,
                  scheme: scheme,
                  theme: theme,
                  onTap: () => notifier.setWallpaper(wp.id),
                ),
            ],
          ),
          const SizedBox(height: 14),

          // 2. Màu Widget User
          const _SectionLabel(label: 'Widget tin nhắn User'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final ub in kUserBubblePresets)
                _buildUserBubbleSwatch(
                  ub: ub,
                  config: config,
                  scheme: scheme,
                  onTap: () => notifier.setUserBubble(ub.id),
                ),
            ],
          ),
          const SizedBox(height: 14),

          // 3. Màu Widget AI phản hồi
          const _SectionLabel(label: 'Widget AI phản hồi'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final ab in kAiBubblePresets)
                _buildAiBubbleChip(
                  ab: ab,
                  config: config,
                  scheme: scheme,
                  onTap: () => notifier.setAiBubble(ab.id),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildNoWallpaperChip({
    required ChatThemeConfig config,
    required ColorScheme scheme,
    required ThemeData theme,
    required VoidCallback onTap,
  }) {
    final selected =
        config.effectiveWallpaperId == ChatThemeConfig.noWallpaperId;
    return InkWell(
      key: const Key('wallpaper-option-none'),
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 72,
            height: 46,
            decoration: BoxDecoration(
              color: scheme.surfaceContainer,
              borderRadius: BorderRadius.circular(11),
              border: Border.all(
                color: selected ? scheme.primary : scheme.outlineVariant,
                width: selected ? 2.2 : 0.9,
              ),
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Center(
                  child: Icon(
                    Icons.hide_image_outlined,
                    size: 20,
                    color: selected
                        ? scheme.primary
                        : scheme.onSurfaceVariant,
                  ),
                ),
                if (selected)
                  Align(
                    alignment: Alignment.topRight,
                    child: Padding(
                      padding: const EdgeInsets.all(3),
                      child: Icon(
                        Icons.check_circle_rounded,
                        size: 14,
                        color: scheme.primary,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 3),
          Text(
            'Không nền',
            style: theme.textTheme.labelSmall?.copyWith(
              fontSize: 10.5,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              color: selected ? scheme.primary : scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWallpaperChip(
    BuildContext context, {
    required WallpaperStylePreset wp,
    required ChatThemeConfig config,
    required ChatAppearanceColors activeAppearance,
    required ColorScheme scheme,
    required ThemeData theme,
    required VoidCallback onTap,
  }) {
    final selected = config.effectiveWallpaperId == wp.id;
    final previewColors = ChatAppearanceColors(
      pattern: wp.pattern,
      wallpaperGradient: config.isDark ? wp.darkGradient : wp.lightGradient,
      wallpaperStroke: config.isDark ? wp.darkStroke : wp.lightStroke,
      userBubbleGradient: activeAppearance.userBubbleGradient,
      userBubbleBorder: activeAppearance.userBubbleBorder,
      userBubbleText: activeAppearance.userBubbleText,
      userBubbleLink: activeAppearance.userBubbleLink,
      aiBubbleBackground: activeAppearance.aiBubbleBackground,
      aiBubbleBorder: activeAppearance.aiBubbleBorder,
      aiBubbleText: activeAppearance.aiBubbleText,
      aiBubbleMutedText: activeAppearance.aiBubbleMutedText,
    );
    return InkWell(
      key: Key('wallpaper-option-${wp.id}'),
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 72,
            height: 46,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(11),
              border: Border.all(
                color: selected ? scheme.primary : scheme.outlineVariant,
                width: selected ? 2.2 : 0.9,
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              fit: StackFit.expand,
              children: [
                ChatWallpaperSurface(appearance: previewColors, tileSize: 72),
                if (selected)
                  Align(
                    alignment: Alignment.topRight,
                    child: Padding(
                      padding: const EdgeInsets.all(3),
                      child: Icon(
                        Icons.check_circle_rounded,
                        size: 14,
                        color: scheme.primary,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 3),
          Text(
            wp.name,
            style: theme.textTheme.labelSmall?.copyWith(
              fontSize: 10.5,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              color: selected ? scheme.primary : scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUserBubbleSwatch({
    required UserBubbleStylePreset ub,
    required ChatThemeConfig config,
    required ColorScheme scheme,
    required VoidCallback onTap,
  }) {
    final selected = config.effectiveUserBubbleId == ub.id;
    final grad = config.isDark ? ub.darkGradient : ub.lightGradient;
    final checkColor = config.isDark ? ub.darkText : ub.lightText;
    return Tooltip(
      message: ub.name,
      child: InkWell(
        key: Key('user-bubble-option-${ub.id}'),
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: grad,
            ),
            border: Border.all(
              color: selected
                  ? scheme.onSurface
                  : (config.isDark ? ub.darkBorder : ub.lightBorder),
              width: selected ? 2.4 : 1.0,
            ),
          ),
          child: selected
              ? Icon(Icons.check_rounded, size: 18, color: checkColor)
              : null,
        ),
      ),
    );
  }

  Widget _buildAiBubbleChip({
    required AiBubbleStylePreset ab,
    required ChatThemeConfig config,
    required ColorScheme scheme,
    required VoidCallback onTap,
  }) {
    final selected = config.effectiveAiBubbleId == ab.id;
    final bg = config.isDark ? ab.darkBackground : ab.lightBackground;
    final border = config.isDark ? ab.darkBorder : ab.lightBorder;
    final fg = config.isDark ? ab.darkText : ab.lightText;
    return InkWell(
      key: Key('ai-bubble-option-${ab.id}'),
      borderRadius: BorderRadius.circular(11),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(11),
          border: Border.all(
            color: selected ? scheme.primary : border,
            width: selected ? 2.0 : 1.0,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (selected) ...[
              Icon(Icons.check_rounded, size: 14, color: scheme.primary),
              const SizedBox(width: 4),
            ],
            Text(
              ab.name,
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: fg,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: Theme.of(context).textTheme.labelMedium?.copyWith(
        fontWeight: FontWeight.w600,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}

class _ThemePresetCard extends StatelessWidget {
  const _ThemePresetCard({
    super.key,
    required this.preset,
    required this.appearance,
    required this.selected,
    required this.accentColor,
    required this.onTap,
  });

  final ChatThemePreset preset;
  final ChatAppearanceColors appearance;
  final bool selected;
  final Color accentColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? accentColor : scheme.outlineVariant,
            width: selected ? 2.2 : 0.9,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ChatWallpaperSurface(appearance: appearance, tileSize: 96),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 9, 8, 24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Bong bóng User thu nhỏ (phải)
                  Align(
                    alignment: Alignment.centerRight,
                    child: Container(
                      width: 54,
                      height: 18,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: appearance.userBubbleGradient,
                        ),
                        borderRadius: const BorderRadius.only(
                          topLeft: Radius.circular(9),
                          topRight: Radius.circular(9),
                          bottomLeft: Radius.circular(9),
                          bottomRight: Radius.circular(3),
                        ),
                        border: Border.all(
                          color: appearance.userBubbleBorder,
                          width: 0.7,
                        ),
                      ),
                    ),
                  ),
                  // Thẻ AI phản hồi thu nhỏ (trái)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Container(
                      width: 62,
                      height: 20,
                      decoration: BoxDecoration(
                        color: appearance.aiBubbleBackground,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: appearance.aiBubbleBorder,
                          width: 0.7,
                        ),
                      ),
                    ),
                  ),
                  // Huy hiệu biểu tượng chủ đề ở giữa dưới
                  Container(
                    padding: const EdgeInsets.all(5),
                    decoration: BoxDecoration(
                      color: preset.badgeColor.withValues(alpha: 0.18),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      preset.icon,
                      size: 16,
                      color: preset.badgeColor,
                    ),
                  ),
                ],
              ),
            ),
            // Nhãn tên theme ở đáy thẻ
            Align(
              alignment: Alignment.bottomCenter,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
                color: scheme.surface.withValues(alpha: 0.65),
                child: Text(
                  preset.name,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                    color: selected ? accentColor : scheme.onSurface,
                  ),
                ),
              ),
            ),
            if (selected)
              Positioned(
                top: 5,
                left: 5,
                child: Icon(
                  Icons.check_circle_rounded,
                  size: 15,
                  color: accentColor,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _LiveThemePreview extends StatelessWidget {
  const _LiveThemePreview({
    required this.appearance,
    required this.isDark,
    required this.outlineColor,
  });

  final ChatAppearanceColors appearance;
  final bool isDark;
  final Color outlineColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('theme-live-preview'),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: outlineColor, width: 0.9),
      ),
      clipBehavior: Clip.antiAlias,
      child: ChatWallpaperSurface(
        appearance: appearance,
        tileSize: 132,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Tin nhắn AI mẫu
              Align(
                alignment: Alignment.centerLeft,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 11,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: appearance.aiBubbleBackground,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: appearance.aiBubbleBorder,
                      width: 0.8,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Mướp Agent',
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                          color: appearance.aiBubbleMutedText,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        'Giao diện ${isDark ? "Dark" : "Light"} đã sẵn sàng!',
                        style: TextStyle(
                          fontSize: 12,
                          color: appearance.aiBubbleText,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 7),
              // Tin nhắn User mẫu
              Align(
                alignment: Alignment.centerRight,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: appearance.userBubbleGradient,
                    ),
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(14),
                      topRight: Radius.circular(14),
                      bottomLeft: Radius.circular(14),
                      bottomRight: Radius.circular(4),
                    ),
                    border: Border.all(
                      color: appearance.userBubbleBorder,
                      width: 0.8,
                    ),
                  ),
                  child: Text(
                    'Đổi màu widget & hình nền rất mượt ✨',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: appearance.userBubbleText,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
