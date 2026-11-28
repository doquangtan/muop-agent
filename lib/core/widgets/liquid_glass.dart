import 'package:material_ui/material_ui.dart';

/// Chất liệu kính "liquid glass" thuần Flutter, KHÔNG blur.
///
/// Không `BackdropFilter`, không `ImageFilter.blur`, không shader, không chụp nền. Lý do: để blur nền
/// phía sau, Flutter phải render nền vào buffer offscreen rồi làm mờ, và phải làm lại mỗi khung mà
/// nền có thay đổi (chat cuộn, animation). Đó là chi phí GPU lớn nhất của app và là nguyên nhân giật.
///
/// Cấu trúc mỗi tấm kính (từ ngoài vào trong):
/// 1. Bóng đổ mềm (vẽ bên ngoài, không bị cắt).
/// 2. Lớp tint gradient ĐỦ ĐỤC (alpha cao) để chữ nổi trên nền mà không cần mờ.
/// 3. Ánh sáng phản chiếu mỏng ở nửa trên (sheen) và viền hairline gradient (rim).
///
/// Bật tăng tương phản (`highContrast`) thì dùng nền đặc, cùng cách như trước.
/// Độ phủ của lớp tint kính: 95%, một màu phẳng (không gradient).
const double kGlassTintOpacity = 0.95;

/// Hộp kính tổng quát.
class LiquidGlassContainer extends StatelessWidget {
  const LiquidGlassContainer({
    super.key,
    required this.child,
    this.borderRadius,
    this.fillColor,
    this.gradient,
    this.borderColor,
    this.borderWidth = 1.0,
    this.padding,
    this.margin,
    this.boxShadow,
  });

  final Widget child;
  final BorderRadiusGeometry? borderRadius;
  final Color? fillColor;
  final Gradient? gradient;
  final Color? borderColor;
  final double borderWidth;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final List<BoxShadow>? boxShadow;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final radius = (borderRadius ?? BorderRadius.circular(16)).resolve(
      TextDirection.ltr,
    );

    if (MediaQuery.highContrastOf(context)) {
      return Container(
        margin: margin,
        padding: padding,
        decoration: BoxDecoration(
          color:
              fillColor ??
              (isDark ? colorScheme.surfaceContainerHigh : colorScheme.surface),
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

    final shadows = boxShadow ?? glassShadow(isDark: isDark, blur: 18);
    // Không gradient mặc định: chỉ dùng khi caller truyền gradient rõ ràng
    final tint = gradient;
    final rim =
        borderColor ??
        (isDark
            ? Colors.white.withValues(alpha: 0.22)
            : Colors.white.withValues(alpha: 0.70));

    final content = padding != null
        ? Padding(padding: padding!, child: child)
        : child;

    return Container(
      margin: margin,
      // Bóng nằm ngoài ClipRRect nên không bị cắt
      decoration: BoxDecoration(borderRadius: radius, boxShadow: shadows),
      child: RepaintBoundary(
        child: ClipRRect(
          borderRadius: radius,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: tint == null ? glassTintColor(isDark, fillColor) : null,
              gradient: tint,
            ),
            child: CustomPaint(
              painter: _GlassSheenPainter(
                radius: radius,
                strength: isDark ? 0.04 : 0.22,
              ),
              foregroundPainter: _GlassRimPainter(
                radius: radius,
                width: borderWidth,
                color: rim,
              ),
              child: content,
            ),
          ),
        ),
      ),
    );
  }
}

/// Viên kính nổi cho header, thanh ghim, nút tròn nổi và composer.
class LiquidGlassPill extends StatelessWidget {
  const LiquidGlassPill({
    super.key,
    required this.child,
    this.cornerRadius = 24.0,
    this.shadowBlur = 12.0,
  });

  final Widget child;
  final double cornerRadius;
  final double shadowBlur;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return LiquidGlassContainer(
      borderRadius: BorderRadius.circular(cornerRadius),
      boxShadow: glassShadow(isDark: isDark, blur: shadowBlur),
      child: child,
    );
  }
}

/// Bóng đổ mềm của tấm kính. Dark đậm hơn light để nổi trên nền tối.
List<BoxShadow> glassShadow({required bool isDark, double blur = 16}) {
  return [
    BoxShadow(
      color: Colors.black.withValues(alpha: isDark ? 0.22 : 0.08),
      blurRadius: blur,
      offset: Offset(0, blur * 0.35),
    ),
  ];
}

/// Màu tint phẳng mặc định (khi không truyền gradient), phủ [kGlassTintOpacity].
Color glassTintColor(bool isDark, Color? override) {
  if (override != null) return override;
  return isDark
      ? const Color(0xFF0E1218).withValues(alpha: kGlassTintOpacity)
      : Colors.white.withValues(alpha: kGlassTintOpacity);
}

/// Ánh sáng phản chiếu ở nửa trên: làm mờ dần xuống, vẽ trước nội dung.
class _GlassSheenPainter extends CustomPainter {
  const _GlassSheenPainter({required this.radius, required this.strength});

  final BorderRadius radius;
  final double strength;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || strength <= 0) return;
    final rrect = radius.toRRect(Offset.zero & size);
    final band = Rect.fromLTWH(0, 0, size.width, size.height * 0.55);
    final paint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Colors.white.withValues(alpha: strength),
          Colors.white.withValues(alpha: 0),
        ],
      ).createShader(band);
    canvas.save();
    canvas.clipRRect(rrect);
    canvas.drawRect(band, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_GlassSheenPainter old) =>
      old.strength != strength || old.radius != radius;
}

/// Viền hairline gradient: sáng ở góc trên-trái, mờ ở giữa, sáng nhẹ lại ở dưới-phải.
class _GlassRimPainter extends CustomPainter {
  const _GlassRimPainter({
    required this.radius,
    required this.width,
    required this.color,
  });

  final BorderRadius radius;
  final double width;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || width <= 0) return;
    final rect = Offset.zero & size;
    final rrect = radius.toRRect(rect).deflate(width / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          color,
          color.withValues(alpha: color.a * 0.18),
          color.withValues(alpha: color.a * 0.55),
        ],
        stops: const [0.0, 0.55, 1.0],
      ).createShader(rect);
    canvas.drawRRect(rrect, paint);
  }

  @override
  bool shouldRepaint(_GlassRimPainter old) =>
      old.width != width || old.color != color || old.radius != radius;
}
