import 'dart:ui';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';
import 'package:material_ui/material_ui.dart';

/// Hộp chứa hiệu ứng Liquid Glass theo chuẩn Apple macOS / iOS HIG:
/// - Lớp mờ hậu cảnh (BackdropFilter blur 20-30px)
/// - Lớp phủ màu mờ (tint translucent fill)
/// - Đường viền phản chiếu ánh sáng nhẹ (hairline specular border)
/// - Phản hồi khi người dùng bật High Contrast (tự động chuyển sang nền đục)
class LiquidGlassContainer extends StatelessWidget {
  const LiquidGlassContainer({
    super.key,
    required this.child,
    this.borderRadius,
    this.blur = 24.0,
    this.fillColor,
    this.gradient,
    this.borderColor,
    this.borderWidth = 0.8,
    this.padding,
    this.margin,
    this.boxShadow,
  });

  final Widget child;
  final BorderRadiusGeometry? borderRadius;
  final double blur;
  final Color? fillColor;
  final Gradient? gradient;
  final Color? borderColor;
  final double borderWidth;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final List<BoxShadow>? boxShadow;

  @override
  Widget build(BuildContext context) {
    final highContrast = MediaQuery.of(context).highContrast;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    final radius = borderRadius ?? BorderRadius.circular(16);

    // Khi người dùng bật tính năng tăng tương phản hoặc không hỗ trợ blur:
    if (highContrast) {
      return Container(
        margin: margin,
        padding: padding,
        decoration: BoxDecoration(
          color: fillColor ?? (isDark ? colorScheme.surfaceContainerHigh : colorScheme.surface),
          borderRadius: radius,
          border: Border.all(
            color: borderColor ?? colorScheme.outline,
            width: borderWidth,
          ),
          boxShadow: boxShadow,
        ),
        child: child,
      );
    }

    final effectiveFill = fillColor ??
        (isDark
            ? const Color(0xFF1E222A).withValues(alpha: 0.65)
            : const Color(0xFFF5F7FA).withValues(alpha: 0.72));

    final effectiveBorder = borderColor ??
        (isDark
            ? Colors.white.withValues(alpha: 0.12)
            : Colors.black.withValues(alpha: 0.08));

    Widget content = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: gradient == null ? effectiveFill : null,
        gradient: gradient,
        borderRadius: radius,
        border: Border.all(
          color: effectiveBorder,
          width: borderWidth,
        ),
      ),
      child: child,
    );

    return Container(
      margin: margin,
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: boxShadow ??
            [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.06),
                blurRadius: 20,
                offset: const Offset(0, 6),
              ),
            ],
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: content,
        ),
      ),
    );
  }
}

/// Tạo [LiquidGlassStyle] đồng nhất cho các đảo và nút nổi Liquid Glass (Header, Pinned, Composer, FAB).
LiquidGlassStyle buildChatLiquidGlassStyle(
  BuildContext context, {
  double cornerRadius = 24.0,
  double refractionWidth = 16.0,
  double shadowBlur = 12.0,
}) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  final highContrast = MediaQuery.highContrastOf(context);
  return LiquidGlassStyle(
    shape: LiquidGlassShape.continuousRoundedRectangle(
      cornerRadius: cornerRadius,
    ),
    specular: LiquidGlassLight.specular(
      thickness: 4.0,
      sharpness: 0.62,
      angle: 39,
      spread: 0.92,
      intensity: isDark ? 1.25 : 1.40,
    ),
    glow: LiquidGlassLight.glow(
      thickness: 9.0,
      angle: 90,
      spread: 0.55,
      intensity: isDark ? 0.55 : 0.70,
    ),
    refractionIndex: 1.06,
    refractionWidth: refractionWidth,
    magnification: 1.02,
    dispersion: 1.8,
    saturation: 1.15,
    blur: 14.0,
    color: isDark
        ? const Color(0xFF1E2432).withValues(alpha: 0.34)
        : Colors.white.withValues(alpha: 0.42),
    shadow: LiquidGlassShadow(
      blur: shadowBlur,
      opacity: isDark ? 0.42 : 0.16,
      insideGlass: false,
    ),
    liteGlass: highContrast,
  );
}

/// Viên kính nổi dùng `LiquidGlassLens` cho header, thanh ghim và nút tròn nổi.
class LiquidGlassPill extends StatelessWidget {
  const LiquidGlassPill({
    super.key,
    required this.child,
    this.cornerRadius = 24.0,
    this.refractionWidth = 14.0,
    this.shadowBlur = 10.0,
  });

  final Widget child;
  final double cornerRadius;
  final double refractionWidth;
  final double shadowBlur;

  @override
  Widget build(BuildContext context) {
    return LiquidGlassLens(
      style: buildChatLiquidGlassStyle(
        context,
        cornerRadius: cornerRadius,
        refractionWidth: refractionWidth,
        shadowBlur: shadowBlur,
      ),
      child: child,
    );
  }
}
