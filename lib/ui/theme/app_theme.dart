import 'package:flutter/material.dart';

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
  (name: 'Xanh dương', color: Color(0xFF0B57D0)),
  (name: 'Xanh lá', color: Color(0xFF2E7D32)),
  (name: 'Tím', color: Color(0xFF6750A4)),
  (name: 'Đỏ', color: Color(0xFFB3261E)),
  (name: 'Cam', color: Color(0xFFE65100)),
  (name: 'Xanh ngọc', color: Color(0xFF00796B)),
  (name: 'Hồng', color: Color(0xFFB0306A)),
  (name: 'Chàm', color: Color(0xFF3949AB)),
  (name: 'Nâu', color: Color(0xFF795548)),
  (name: 'Xanh biển', color: Color(0xFF0097A7)),
];

/// Màu chủ đạo mặc định của app
const Color kDefaultThemeSeed = Color(0xFF0B57D0);

/// Dựng `ThemeData` Material 3 từ một màu seed cho chế độ sáng hoặc tối
ThemeData buildAppTheme({
  required Color seedColor,
  required Brightness brightness,
}) {
  final isDark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: seedColor,
    brightness: brightness,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    extensions: [isDark ? AppStatusColors.dark : AppStatusColors.light],
    // Thành phần M3: bo góc và nền theo token surface, dùng chung cho toàn app
    cardTheme: CardThemeData(
      color: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: scheme.outlineVariant.withAlpha(140), width: 0.8),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surfaceContainerHigh,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHighest.withAlpha(120),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: scheme.primary, width: 1.5),
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
}
