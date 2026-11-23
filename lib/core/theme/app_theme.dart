import 'package:material_ui/material_ui.dart';

import 'package:muop_agent/core/theme/chat_theme.dart';


/// Màu trạng thái không có trong `ColorScheme` của Material 3 (thành công, cảnh báo).
/// Lỗi, AI/thinking và thông tin dùng token của `ColorScheme` (`error`, `tertiary`, `secondary`).
@immutable
class AppStatusColors extends ThemeExtension<AppStatusColors> {
  const AppStatusColors({required this.success, required this.warning});

  final Color success;
  final Color warning;

  static const AppStatusColors light = AppStatusColors(
    success: Color(0xFF0F7A5A),
    warning: Color(0xFF9A5B00),
  );

  static const AppStatusColors dark = AppStatusColors(
    success: Color(0xFF6DD5B0),
    warning: Color(0xFFFFB86B),
  );

  @override
  AppStatusColors copyWith({Color? success, Color? warning}) => AppStatusColors(
        success: success ?? this.success,
        warning: warning ?? this.warning,
      );

  @override
  AppStatusColors lerp(ThemeExtension<AppStatusColors>? other, double t) {
    if (other is! AppStatusColors) return this;
    return AppStatusColors(
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
    );
  }
}

/// Các màu gợi ý làm màu chủ đạo (seed) để M3 sinh bảng màu sáng/tối
const List<({String name, Color color})> kThemeSeedPresets = [
  (name: 'Xcode Deep Graphite', color: Color(0xFF1E2028)),
  (name: 'Apple Space Gray', color: Color(0xFF2C2D35)),
  (name: 'Tahoe Indigo', color: Color(0xFF2E5CB8)),
  (name: 'Xcode Blue', color: Color(0xFF0A84FF)),
  (name: 'Studio Purple', color: Color(0xFF7D57C1)),
  (name: 'Cupertino Teal', color: Color(0xFF30B0C7)),
  (name: 'Emerald Mint', color: Color(0xFF34C759)),
  (name: 'Amber Orange', color: Color(0xFFFF9500)),
  (name: 'Sunset Rose', color: Color(0xFFFF2D55)),
];

/// Màu chủ đạo mặc định của app: Xcode Dark Pro (Tông than chì xanh sâu sắc, chuẩn studio IDE)
const Color kDefaultThemeSeed = Color(0xFF252932);

/// Dựng `ThemeData` Material 3 từ một màu seed cho chế độ sáng hoặc tối theo phong cách Apple Studio / Xcode 26
ThemeData buildAppTheme({
  required Color seedColor,
  required Brightness brightness,
  ChatThemeConfig? chatTheme,
}) {
  final isDark = brightness == Brightness.dark;
  final cardTint = isDark
      ? const Color(0xFF161D28).withValues(alpha: 0.72)
      : const Color(0xFFF6F9FF).withValues(alpha: 0.80);
  final cardBorder = isDark
      ? Colors.white.withValues(alpha: 0.14)
      : Colors.black.withValues(alpha: 0.08);
  final effectiveConfig = chatTheme ?? ChatThemeConfig.defaults;
  final chatColors = ChatAppearanceColors.resolve(effectiveConfig, brightness);
  final effectiveSeed = chatTheme != null
      ? (isDark ? chatTheme.preset.accentDark : chatTheme.preset.accentLight)
      : seedColor;
  var scheme = ColorScheme.fromSeed(
    seedColor: effectiveSeed,
    brightness: brightness,
  );

  if (isDark) {
    final primaryAccent = chatTheme != null
        ? chatTheme.preset.accentDark
        : const Color(0xFF4C8DFF);
    // Phong cách Apple Xcode Dark: nền than chì sâu (không bị xám nhờ nhờ), surface layers phân tầng rõ nét
    scheme = scheme.copyWith(
      surface: const Color(0xFF141519), // Nền tổng thể cửa sổ
      surfaceContainerLowest: const Color(0xFF0E0F12),
      surfaceContainerLow: const Color(0xFF181A1F), // Nền Sidebar / Drawer
      surfaceContainer: const Color(0xFF1F2228), // Nền Editor / Panels / Chat Canvas
      surfaceContainerHigh: const Color(0xFF262A32), // Nền Cards / Composer Floating Bar
      surfaceContainerHighest: const Color(0xFF30343E), // Pills, Chips, Input backgrounds
      outline: const Color(0xFF3D424E),
      outlineVariant: const Color(0xFF2B2F38), // Viền hairline siêu mỏng 0.8px
      primary: primaryAccent, // Accent theo bộ theme, sáng rõ trên nền tối
      onPrimary: const Color(0xFFFFFFFF),
      onSurface: const Color(0xFFF0F2F5),
      onSurfaceVariant: const Color(0xFFA1A8B6),
    );
  }

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    extensions: [
      isDark ? AppStatusColors.dark : AppStatusColors.light,
      chatColors,
    ],
    // Thành phần M3: bo góc và thẻ kính mờ đồng bộ với giao diện chính
    cardTheme: CardThemeData(
      color: cardTint,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: cardBorder, width: 0.85),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surfaceContainerHigh,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHighest.withAlpha(140),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: scheme.outlineVariant, width: 0.8),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: scheme.outlineVariant, width: 0.8),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: scheme.primary, width: 1.2),
      ),
    ),
  );
}

extension AppThemeContext on BuildContext {
  /// Bảng màu M3 hiện hành (theo seed và chế độ sáng/tối)
  ColorScheme get scheme => Theme.of(this).colorScheme;

  /// Màu thành công / cảnh báo của theme hiện hành
  AppStatusColors get status =>
      Theme.of(this).extension<AppStatusColors>() ??
      AppStatusColors.light;

  /// Bảng màu giao diện widget User, AI và hình nền chat hiện hành
  ChatAppearanceColors get chatTheme =>
      Theme.of(this).extension<ChatAppearanceColors>() ??
      ChatAppearanceColors.resolve(
        ChatThemeConfig.defaults,
        Theme.of(this).brightness,
      );

  /// Nền thẻ mờ đồng bộ Content Layer trên nền chat
  Color get glassCardColor {
    if (MediaQuery.highContrastOf(this)) return scheme.surfaceContainerHigh;
    final isDark = Theme.of(this).brightness == Brightness.dark;
    return isDark
        ? const Color(0xFF161D28).withValues(alpha: 0.72)
        : const Color(0xFFF6F9FF).withValues(alpha: 0.80);
  }

  /// Viền phản chiếu mảnh cho thẻ và hộp thoại
  Color get glassCardBorder {
    final isDark = Theme.of(this).brightness == Brightness.dark;
    return isDark
        ? Colors.white.withValues(alpha: 0.14)
        : Colors.black.withValues(alpha: 0.08);
  }

  /// Nền chip/ô nhập mờ nhẹ thích ứng Dark/Light
  Color get glassSubtleFill {
    final isDark = Theme.of(this).brightness == Brightness.dark;
    return scheme.onSurface.withValues(alpha: isDark ? 0.06 : 0.045);
  }
}
