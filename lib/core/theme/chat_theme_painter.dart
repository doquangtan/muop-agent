import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'package:muop_agent/core/theme/app_theme.dart';
import 'package:muop_agent/core/theme/chat_theme.dart';

/// Vùng nền gradient + hoa văn doodle lặp kiểu Telegram, cô lập bằng [RepaintBoundary]
/// để tái sử dụng đồng nhất giữa khung chat chính và lưới xem trước theme.
class ChatWallpaperSurface extends StatelessWidget {
  const ChatWallpaperSurface({
    super.key,
    this.appearance,
    this.tileSize = 220.0,
    this.highContrast = false,
    this.child,
  });

  final ChatAppearanceColors? appearance;
  final double tileSize;
  final bool highContrast;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final resolved = appearance ?? context.chatTheme;

    if (highContrast || !resolved.hasWallpaper) {
      return ColoredBox(
        color: Theme.of(context).colorScheme.surface,
        child: child,
      );
    }

    return RepaintBoundary(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            stops: _evenStops(resolved.wallpaperGradient.length),
            colors: resolved.wallpaperGradient,
          ),
        ),
        child: CustomPaint(
          painter: TelegramDoodlePainter(
            pattern: resolved.pattern,
            strokeColor: resolved.wallpaperStroke,
            tileSize: tileSize,
          ),
          isComplex: true,
          child: child,
        ),
      ),
    );
  }

  static List<double>? _evenStops(int count) {
    if (count == 4) return const [0.0, 0.38, 0.72, 1.0];
    return null;
  }
}

/// Họa tiết doodle vector cho 6 chủ đề nền chat, không cấp phát lại khi không đổi màu/pattern.
class TelegramDoodlePainter extends CustomPainter {
  const TelegramDoodlePainter({
    required this.pattern,
    required this.strokeColor,
    this.tileSize = 220.0,
  });

  final ChatWallpaperPattern pattern;
  final Color strokeColor;
  final double tileSize;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    canvas.save();
    canvas.clipRect(Offset.zero & size);

    final scale = tileSize / 220.0;
    final strokePaint = Paint()
      ..color = strokeColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = (1.35 * scale).clamp(0.9, 1.6)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final fillPaint = Paint()
      ..color = strokeColor
      ..style = PaintingStyle.fill;

    final cols = (size.width / tileSize).ceil();
    final rows = (size.height / tileSize).ceil();

    for (var row = 0; row < rows; row++) {
      for (var col = 0; col < cols; col++) {
        canvas.save();
        canvas.translate(col * tileSize, row * tileSize);
        if (scale != 1.0) canvas.scale(scale, scale);
        _paintPatternTile(canvas, strokePaint, fillPaint);
        canvas.restore();
      }
    }

    canvas.restore();
  }

  void _paintPatternTile(Canvas canvas, Paint stroke, Paint fill) {
    switch (pattern) {
      case ChatWallpaperPattern.telegramClassic:
        _paintTelegramClassic(canvas, stroke, fill);
      case ChatWallpaperPattern.geometricCrystal:
        _paintGeometricCrystal(canvas, stroke, fill);
      case ChatWallpaperPattern.mathLab:
        _paintMathLab(canvas, stroke, fill);
      case ChatWallpaperPattern.sakuraBlossom:
        _paintSakuraBlossom(canvas, stroke, fill);
      case ChatWallpaperPattern.auroraDream:
        _paintAuroraDream(canvas, stroke, fill);
      case ChatWallpaperPattern.retroArcade:
        _paintRetroArcade(canvas, stroke, fill);
    }
    _paintCommonMicroAccents(canvas, stroke, fill);
  }

  void _paintCommonMicroAccents(Canvas canvas, Paint stroke, Paint fill) {
    canvas.drawCircle(const Offset(66, 46), 1.4, fill);
    canvas.drawCircle(const Offset(194, 24), 1.2, fill);
    canvas.drawCircle(const Offset(16, 88), 1.3, fill);
    canvas.drawCircle(const Offset(158, 98), 1.2, fill);
    canvas.drawCircle(const Offset(70, 158), 1.4, fill);
    canvas.drawCircle(const Offset(174, 206), 1.2, fill);
    _drawPlus(canvas, const Offset(132, 46), stroke);
    _drawPlus(canvas, const Offset(16, 166), stroke);
  }

  void _paintTelegramClassic(Canvas canvas, Paint stroke, Paint fill) {
    _drawAt(canvas, 30, 30, -0.25, () => _drawCrescent(canvas, stroke));
    _drawAt(canvas, 96, 26, 0.12, () => _drawChatBubble(canvas, stroke, fill));
    _drawAt(canvas, 162, 34, -0.10, () => _drawTerminalBox(canvas, stroke));
    _drawAt(canvas, 200, 76, 0.15, () => _drawFourPointSpark(canvas, stroke));
    _drawAt(canvas, 54, 82, 0.08, () => _drawCodeBrackets(canvas, stroke));
    _drawAt(canvas, 126, 78, -0.06, () => _drawCloud(canvas, stroke));
    _drawAt(canvas, 178, 128, -0.28, () => _drawRingPlanet(canvas, stroke));
    _drawAt(canvas, 34, 134, -0.18, () => _drawPaperPlane(canvas, stroke));
    _drawAt(canvas, 102, 130, 0.14, () => _drawCoffeeCup(canvas, stroke));
    _drawAt(canvas, 148, 178, 0.10, () => _drawFacetDiamond(canvas, stroke));
    _drawAt(canvas, 200, 184, -0.14, () => _drawCurlyBraces(canvas, stroke));
    _drawAt(canvas, 44, 188, -0.08, () => _drawBotHead(canvas, stroke, fill));
    _drawAt(canvas, 98, 188, 0.22, () => _drawBolt(canvas, stroke));
  }

  void _paintGeometricCrystal(Canvas canvas, Paint stroke, Paint fill) {
    _drawAt(canvas, 34, 34, -0.18, () => _drawFacetDiamond(canvas, stroke));
    _drawAt(canvas, 98, 28, 0.25, () => _drawKey(canvas, stroke));
    _drawAt(canvas, 166, 36, -0.12, () => _drawHexagon(canvas, stroke));
    _drawAt(canvas, 56, 88, 0.14, () => _drawFiveStar(canvas, stroke));
    _drawAt(canvas, 132, 82, 0.0, () => _drawConcentricRings(canvas, stroke));
    _drawAt(canvas, 198, 86, 0.22, () => _drawHourglass(canvas, stroke));
    _drawAt(canvas, 32, 142, -0.24, () => _drawPrismTriangle(canvas, stroke));
    _drawAt(canvas, 102, 136, 0.16, () => _drawFacetDiamond(canvas, stroke));
    _drawAt(canvas, 176, 138, -0.18, () => _drawCompassRose(canvas, stroke));
    _drawAt(canvas, 52, 190, 0.10, () => _drawHexagon(canvas, stroke));
    _drawAt(canvas, 128, 184, -0.20, () => _drawKey(canvas, stroke));
    _drawAt(canvas, 196, 186, 0.12, () => _drawFiveStar(canvas, stroke));
  }

  void _paintMathLab(Canvas canvas, Paint stroke, Paint fill) {
    _drawAt(canvas, 32, 32, -0.14, () => _drawPi(canvas, stroke));
    _drawAt(canvas, 96, 28, 0.10, () => _drawSigma(canvas, stroke));
    _drawAt(canvas, 164, 34, -0.16, () => _drawInfinity(canvas, stroke));
    _drawAt(canvas, 52, 84, 0.08, () => _drawRadical(canvas, stroke));
    _drawAt(canvas, 128, 80, -0.06, () => _drawAxesParabola(canvas, stroke));
    _drawAt(canvas, 198, 82, 0.18, () => _drawDelta(canvas, stroke));
    _drawAt(canvas, 34, 140, -0.12, () => _drawRightTriangle(canvas, stroke));
    _drawAt(canvas, 102, 134, 0.06, () => _drawSineWave(canvas, stroke));
    _drawAt(canvas, 174, 134, -0.20, () => _drawCircleChord(canvas, stroke));
    _drawAt(canvas, 46, 190, 0.14, () => _drawPercent(canvas, stroke, fill));
    _drawAt(canvas, 122, 186, -0.08, () => _drawPi(canvas, stroke));
    _drawAt(canvas, 194, 188, 0.16, () => _drawSigma(canvas, stroke));
  }

  void _paintSakuraBlossom(Canvas canvas, Paint stroke, Paint fill) {
    _drawAt(canvas, 36, 34, -0.18, () => _drawBlossom(canvas, stroke, fill));
    _drawAt(canvas, 100, 28, 0.12, () => _drawCrystalShard(canvas, stroke));
    _drawAt(canvas, 168, 36, -0.22, () => _drawCrescent(canvas, stroke));
    _drawAt(canvas, 56, 86, 0.24, () => _drawTwinLeaves(canvas, stroke));
    _drawAt(canvas, 130, 82, 0.08, () => _drawFiveStar(canvas, stroke));
    _drawAt(canvas, 198, 84, -0.14, () => _drawBlossom(canvas, stroke, fill));
    _drawAt(canvas, 34, 140, 0.16, () => _drawFourPointSpark(canvas, stroke));
    _drawAt(canvas, 104, 136, -0.10, () => _drawCrystalCluster(canvas, stroke));
    _drawAt(canvas, 178, 138, 0.20, () => _drawTwinLeaves(canvas, stroke));
    _drawAt(canvas, 50, 190, -0.12, () => _drawCrystalShard(canvas, stroke));
    _drawAt(canvas, 126, 186, 0.14, () => _drawBlossom(canvas, stroke, fill));
    _drawAt(canvas, 196, 186, -0.18, () => _drawFourPointSpark(canvas, stroke));
  }

  void _paintAuroraDream(Canvas canvas, Paint stroke, Paint fill) {
    _drawAt(canvas, 34, 34, -0.14, () => _drawFacetHeart(canvas, stroke));
    _drawAt(canvas, 100, 28, 0.16, () => _drawMusicNote(canvas, stroke, fill));
    _drawAt(canvas, 166, 36, -0.08, () => _drawCloud(canvas, stroke));
    _drawAt(canvas, 56, 86, 0.18, () => _drawFiveStar(canvas, stroke));
    _drawAt(canvas, 130, 82, -0.12, () => _drawAuroraRibbon(canvas, stroke));
    _drawAt(canvas, 198, 84, 0.22, () => _drawKiteDiamond(canvas, stroke));
    _drawAt(canvas, 34, 140, -0.20, () => _drawCrescent(canvas, stroke));
    _drawAt(canvas, 104, 136, 0.10, () => _drawFacetHeart(canvas, stroke));
    _drawAt(canvas, 176, 136, -0.14, () => _drawRingPlanet(canvas, stroke));
    _drawAt(canvas, 50, 190, 0.06, () => _drawAuroraRibbon(canvas, stroke));
    _drawAt(canvas, 126, 186, -0.18, () => _drawMusicNote(canvas, stroke, fill));
    _drawAt(canvas, 196, 186, 0.14, () => _drawFourPointSpark(canvas, stroke));
  }

  void _paintRetroArcade(Canvas canvas, Paint stroke, Paint fill) {
    _drawAt(canvas, 38, 34, -0.14, () => _drawGamepad(canvas, stroke, fill));
    _drawAt(canvas, 104, 30, 0.10, () => _drawCassette(canvas, stroke, fill));
    _drawAt(canvas, 170, 36, -0.12, () => _drawTrophy(canvas, stroke));
    _drawAt(canvas, 54, 86, 0.18, () => _drawBolt(canvas, stroke));
    _drawAt(canvas, 130, 82, -0.08, () => _drawArcadeCabinet(canvas, stroke));
    _drawAt(canvas, 198, 86, 0.15, () => _drawPixelCrown(canvas, stroke));
    _drawAt(canvas, 34, 142, -0.22, () => _drawPixelHeart(canvas, stroke));
    _drawAt(canvas, 104, 136, 0.12, () => _drawGamepad(canvas, stroke, fill));
    _drawAt(canvas, 176, 138, -0.16, () => _drawFourPointSpark(canvas, stroke));
    _drawAt(canvas, 52, 190, 0.08, () => _drawCassette(canvas, stroke, fill));
    _drawAt(canvas, 128, 186, -0.14, () => _drawTrophy(canvas, stroke));
    _drawAt(canvas, 196, 186, 0.18, () => _drawBolt(canvas, stroke));
  }

  // --- Hình vector đơn lẻ ---

  void _drawCrescent(Canvas canvas, Paint stroke) {
    final path = Path()
      ..moveTo(4, -8)
      ..arcToPoint(const Offset(4, 8), radius: const Radius.circular(8.5), clockwise: false)
      ..arcToPoint(const Offset(4, -8), radius: const Radius.circular(6.0));
    canvas.drawPath(path, stroke);
  }

  void _drawChatBubble(Canvas canvas, Paint stroke, Paint fill) {
    final path = Path()
      ..moveTo(-9, -6)
      ..lineTo(9, -6)
      ..quadraticBezierTo(11, -6, 11, -4)
      ..lineTo(11, 4)
      ..quadraticBezierTo(11, 6, 9, 6)
      ..lineTo(-2, 6)
      ..lineTo(-7, 10)
      ..lineTo(-6, 6)
      ..lineTo(-9, 6)
      ..quadraticBezierTo(-11, 6, -11, 4)
      ..lineTo(-11, -4)
      ..quadraticBezierTo(-11, -6, -9, -6)
      ..close();
    canvas.drawPath(path, stroke);
    canvas.drawCircle(const Offset(-4, 0), 1.0, fill);
    canvas.drawCircle(const Offset(0, 0), 1.0, fill);
    canvas.drawCircle(const Offset(4, 0), 1.0, fill);
  }

  void _drawTerminalBox(Canvas canvas, Paint stroke) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(const Rect.fromLTWH(-11, -8, 22, 16), const Radius.circular(3.5)),
      stroke,
    );
    final prompt = Path()
      ..moveTo(-6, -3)
      ..lineTo(-2, 0)
      ..lineTo(-6, 3)
      ..moveTo(0, 3)
      ..lineTo(6, 3);
    canvas.drawPath(prompt, stroke);
  }

  void _drawFourPointSpark(Canvas canvas, Paint stroke) {
    final spark = Path()
      ..moveTo(0, -10)
      ..quadraticBezierTo(1.8, -1.8, 10, 0)
      ..quadraticBezierTo(1.8, 1.8, 0, 10)
      ..quadraticBezierTo(-1.8, 1.8, -10, 0)
      ..quadraticBezierTo(-1.8, -1.8, 0, -10)
      ..close();
    canvas.drawPath(spark, stroke);
  }

  void _drawCodeBrackets(Canvas canvas, Paint stroke) {
    final code = Path()
      ..moveTo(-4, -6)
      ..lineTo(-10, 0)
      ..lineTo(-4, 6)
      ..moveTo(4, -6)
      ..lineTo(10, 0)
      ..lineTo(4, 6)
      ..moveTo(2, -7)
      ..lineTo(-2, 7);
    canvas.drawPath(code, stroke);
  }

  void _drawCloud(Canvas canvas, Paint stroke) {
    final cloud = Path()
      ..moveTo(-7, 5)
      ..lineTo(7, 5)
      ..arcToPoint(const Offset(8, -2), radius: const Radius.circular(4), clockwise: false)
      ..arcToPoint(const Offset(-2, -6), radius: const Radius.circular(5.5), clockwise: false)
      ..arcToPoint(const Offset(-9, 0), radius: const Radius.circular(4.2), clockwise: false)
      ..arcToPoint(const Offset(-7, 5), radius: const Radius.circular(3.0), clockwise: false);
    canvas.drawPath(cloud, stroke);
  }

  void _drawRingPlanet(Canvas canvas, Paint stroke) {
    canvas.drawCircle(Offset.zero, 6.2, stroke);
    canvas.drawArc(
      const Rect.fromLTRB(-13, -3.2, 13, 3.2),
      -0.35,
      math.pi + 0.70,
      false,
      stroke,
    );
  }

  void _drawPaperPlane(Canvas canvas, Paint stroke) {
    final plane = Path()
      ..moveTo(10, -7)
      ..lineTo(-10, -1)
      ..lineTo(-3, 2)
      ..lineTo(10, -7)
      ..moveTo(-3, 2)
      ..lineTo(-1, 8)
      ..lineTo(3, 4)
      ..moveTo(-3, 2)
      ..lineTo(4, 7)
      ..lineTo(10, -7);
    canvas.drawPath(plane, stroke);
  }

  void _drawCoffeeCup(Canvas canvas, Paint stroke) {
    final cup = Path()
      ..moveTo(-7, -3)
      ..lineTo(5, -3)
      ..lineTo(4, 5)
      ..quadraticBezierTo(4, 7, 1, 7)
      ..lineTo(-3, 7)
      ..quadraticBezierTo(-6, 7, -6, 5)
      ..close()
      ..moveTo(5, -1)
      ..quadraticBezierTo(9, -1, 9, 2)
      ..quadraticBezierTo(9, 4, 5, 4)
      ..moveTo(-3, -6)
      ..lineTo(-2, -9)
      ..moveTo(1, -6)
      ..lineTo(2, -9);
    canvas.drawPath(cup, stroke);
  }

  void _drawFacetDiamond(Canvas canvas, Paint stroke) {
    final gem = Path()
      ..moveTo(-6, -6)
      ..lineTo(6, -6)
      ..lineTo(10, -1)
      ..lineTo(0, 9)
      ..lineTo(-10, -1)
      ..close()
      ..moveTo(-10, -1)
      ..lineTo(10, -1)
      ..moveTo(-4, -6)
      ..lineTo(-2, -1)
      ..lineTo(0, 9)
      ..lineTo(2, -1)
      ..lineTo(4, -6);
    canvas.drawPath(gem, stroke);
  }

  void _drawCurlyBraces(Canvas canvas, Paint stroke) {
    final braces = Path()
      ..moveTo(-3, -7)
      ..quadraticBezierTo(-6, -7, -6, -4)
      ..lineTo(-6, -1)
      ..lineTo(-8, 0)
      ..lineTo(-6, 1)
      ..lineTo(-6, 4)
      ..quadraticBezierTo(-6, 7, -3, 7)
      ..moveTo(3, -7)
      ..quadraticBezierTo(6, -7, 6, -4)
      ..lineTo(6, -1)
      ..lineTo(8, 0)
      ..lineTo(6, 1)
      ..lineTo(6, 4)
      ..quadraticBezierTo(6, 7, 3, 7);
    canvas.drawPath(braces, stroke);
  }

  void _drawBotHead(Canvas canvas, Paint stroke, Paint fill) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(const Rect.fromLTWH(-9, -6, 18, 13), const Radius.circular(4)),
      stroke,
    );
    canvas.drawLine(const Offset(0, -6), const Offset(0, -10), stroke);
    canvas.drawCircle(const Offset(0, -10.5), 1.3, fill);
    canvas.drawCircle(const Offset(-3.5, 0), 1.2, fill);
    canvas.drawCircle(const Offset(3.5, 0), 1.2, fill);
  }

  void _drawBolt(Canvas canvas, Paint stroke) {
    final bolt = Path()
      ..moveTo(2, -9)
      ..lineTo(-5, 0)
      ..lineTo(0, 0)
      ..lineTo(-2, 9)
      ..lineTo(5, 0)
      ..lineTo(0, 0)
      ..close();
    canvas.drawPath(bolt, stroke);
  }

  void _drawKey(Canvas canvas, Paint stroke) {
    canvas.drawCircle(const Offset(-5, 0), 4.2, stroke);
    final shaft = Path()
      ..moveTo(-0.8, 0)
      ..lineTo(10, 0)
      ..moveTo(6, 0)
      ..lineTo(6, 3.5)
      ..moveTo(9, 0)
      ..lineTo(9, 4.5);
    canvas.drawPath(shaft, stroke);
  }

  void _drawHexagon(Canvas canvas, Paint stroke) {
    final hex = Path();
    for (var i = 0; i < 6; i++) {
      final a = (math.pi / 3) * i;
      final pt = Offset(math.cos(a) * 9, math.sin(a) * 9);
      if (i == 0) {
        hex.moveTo(pt.dx, pt.dy);
      } else {
        hex.lineTo(pt.dx, pt.dy);
      }
    }
    hex.close();
    canvas.drawPath(hex, stroke);
  }

  void _drawFiveStar(Canvas canvas, Paint stroke) {
    final star = Path();
    for (var i = 0; i < 10; i++) {
      final r = i.isEven ? 9.5 : 4.2;
      final a = -math.pi / 2 + (math.pi / 5) * i;
      final pt = Offset(math.cos(a) * r, math.sin(a) * r);
      if (i == 0) {
        star.moveTo(pt.dx, pt.dy);
      } else {
        star.lineTo(pt.dx, pt.dy);
      }
    }
    star.close();
    canvas.drawPath(star, stroke);
  }

  void _drawConcentricRings(Canvas canvas, Paint stroke) {
    canvas.drawCircle(Offset.zero, 9.0, stroke);
    canvas.drawCircle(Offset.zero, 4.2, stroke);
  }

  void _drawHourglass(Canvas canvas, Paint stroke) {
    final hg = Path()
      ..moveTo(-6, -8)
      ..lineTo(6, -8)
      ..lineTo(-6, 8)
      ..lineTo(6, 8)
      ..close();
    canvas.drawPath(hg, stroke);
  }

  void _drawPrismTriangle(Canvas canvas, Paint stroke) {
    final tri = Path()
      ..moveTo(0, -9)
      ..lineTo(9, 7)
      ..lineTo(-9, 7)
      ..close()
      ..moveTo(0, -9)
      ..lineTo(1.5, 7);
    canvas.drawPath(tri, stroke);
  }

  void _drawCompassRose(Canvas canvas, Paint stroke) {
    final p = Path()
      ..moveTo(0, -10)
      ..lineTo(2.8, -2.8)
      ..lineTo(10, 0)
      ..lineTo(2.8, 2.8)
      ..lineTo(0, 10)
      ..lineTo(-2.8, 2.8)
      ..lineTo(-10, 0)
      ..lineTo(-2.8, -2.8)
      ..close();
    canvas.drawPath(p, stroke);
  }

  void _drawPi(Canvas canvas, Paint stroke) {
    final pi = Path()
      ..moveTo(-8, -5)
      ..quadraticBezierTo(-4, -7, 8, -6)
      ..moveTo(-4, -6)
      ..lineTo(-5, 7)
      ..moveTo(3, -6)
      ..quadraticBezierTo(3, 5, 6, 7);
    canvas.drawPath(pi, stroke);
  }

  void _drawSigma(Canvas canvas, Paint stroke) {
    final s = Path()
      ..moveTo(6, -7)
      ..lineTo(-6, -7)
      ..lineTo(1, 0)
      ..lineTo(-6, 7)
      ..lineTo(6, 7);
    canvas.drawPath(s, stroke);
  }

  void _drawInfinity(Canvas canvas, Paint stroke) {
    final inf = Path()
      ..moveTo(0, 0)
      ..cubicTo(4, -7, 11, -5, 10, 0)
      ..cubicTo(9, 5, 4, 7, 0, 0)
      ..cubicTo(-4, -7, -11, -5, -10, 0)
      ..cubicTo(-9, 5, -4, 7, 0, 0);
    canvas.drawPath(inf, stroke);
  }

  void _drawRadical(Canvas canvas, Paint stroke) {
    final rad = Path()
      ..moveTo(-10, 1)
      ..lineTo(-7, 1)
      ..lineTo(-3, 8)
      ..lineTo(2, -7)
      ..lineTo(10, -7);
    canvas.drawPath(rad, stroke);
  }

  void _drawAxesParabola(Canvas canvas, Paint stroke) {
    final p = Path()
      ..moveTo(-9, 6)
      ..lineTo(9, 6)
      ..moveTo(0, -9)
      ..lineTo(0, 8)
      ..moveTo(-7, -5)
      ..quadraticBezierTo(0, 9, 7, -5);
    canvas.drawPath(p, stroke);
  }

  void _drawDelta(Canvas canvas, Paint stroke) {
    final tri = Path()
      ..moveTo(0, -8)
      ..lineTo(8, 7)
      ..lineTo(-8, 7)
      ..close();
    canvas.drawPath(tri, stroke);
  }

  void _drawRightTriangle(Canvas canvas, Paint stroke) {
    final p = Path()
      ..moveTo(-8, -8)
      ..lineTo(-8, 7)
      ..lineTo(9, 7)
      ..close()
      ..moveTo(-8, 3)
      ..lineTo(-4, 3)
      ..lineTo(-4, 7);
    canvas.drawPath(p, stroke);
  }

  void _drawSineWave(Canvas canvas, Paint stroke) {
    final wave = Path()
      ..moveTo(-11, 0)
      ..quadraticBezierTo(-5.5, -9, 0, 0)
      ..quadraticBezierTo(5.5, 9, 11, 0);
    canvas.drawPath(wave, stroke);
  }

  void _drawCircleChord(Canvas canvas, Paint stroke) {
    canvas.drawCircle(Offset.zero, 8, stroke);
    canvas.drawLine(const Offset(-8, 0), const Offset(8, 0), stroke);
    canvas.drawLine(const Offset(0, -8), const Offset(0, 8), stroke);
  }

  void _drawPercent(Canvas canvas, Paint stroke, Paint fill) {
    canvas.drawLine(const Offset(-6, 7), const Offset(6, -7), stroke);
    canvas.drawCircle(const Offset(-5, -5), 2.3, stroke);
    canvas.drawCircle(const Offset(5, 5), 2.3, stroke);
    canvas.drawCircle(Offset.zero, 0.8, fill);
  }

  void _drawBlossom(Canvas canvas, Paint stroke, Paint fill) {
    for (var i = 0; i < 5; i++) {
      final a = -math.pi / 2 + (2 * math.pi / 5) * i;
      canvas.save();
      canvas.rotate(a);
      final petal = Path()
        ..moveTo(0, -2.5)
        ..cubicTo(-4.5, -5.5, -4, -10.5, 0, -10.5)
        ..cubicTo(4, -10.5, 4.5, -5.5, 0, -2.5);
      canvas.drawPath(petal, stroke);
      canvas.restore();
    }
    canvas.drawCircle(Offset.zero, 2.0, fill);
  }

  void _drawCrystalShard(Canvas canvas, Paint stroke) {
    final p = Path()
      ..moveTo(0, -11)
      ..lineTo(5, -4)
      ..lineTo(4, 8)
      ..lineTo(0, 11)
      ..lineTo(-4, 8)
      ..lineTo(-5, -4)
      ..close()
      ..moveTo(0, -11)
      ..lineTo(0, 11);
    canvas.drawPath(p, stroke);
  }

  void _drawCrystalCluster(Canvas canvas, Paint stroke) {
    final p = Path()
      ..moveTo(-2, -10)
      ..lineTo(3, -5)
      ..lineTo(3, 8)
      ..lineTo(-5, 8)
      ..lineTo(-5, -5)
      ..close()
      ..moveTo(3, -1)
      ..lineTo(8, -4)
      ..lineTo(9, 8)
      ..lineTo(3, 8);
    canvas.drawPath(p, stroke);
  }

  void _drawTwinLeaves(Canvas canvas, Paint stroke) {
    final p = Path()
      ..moveTo(-1, 8)
      ..quadraticBezierTo(-1, -4, 8, -8)
      ..quadraticBezierTo(6, 4, -1, 8)
      ..moveTo(-1, 8)
      ..quadraticBezierTo(-9, 1, -8, -7)
      ..quadraticBezierTo(0, -2, -1, 8);
    canvas.drawPath(p, stroke);
  }

  void _drawFacetHeart(Canvas canvas, Paint stroke) {
    final heart = Path()
      ..moveTo(0, 9)
      ..lineTo(-9, -1)
      ..lineTo(-5, -7)
      ..lineTo(0, -4)
      ..lineTo(5, -7)
      ..lineTo(9, -1)
      ..close()
      ..moveTo(-9, -1)
      ..lineTo(9, -1)
      ..moveTo(0, -4)
      ..lineTo(0, 9);
    canvas.drawPath(heart, stroke);
  }

  void _drawMusicNote(Canvas canvas, Paint stroke, Paint fill) {
    canvas.drawCircle(const Offset(-4, 6), 3.0, stroke);
    canvas.drawCircle(const Offset(5, 4), 3.0, stroke);
    final stem = Path()
      ..moveTo(-1, 6)
      ..lineTo(-1, -7)
      ..lineTo(8, -9)
      ..lineTo(8, 4);
    canvas.drawPath(stem, stroke);
    canvas.drawCircle(const Offset(-4, 6), 1.0, fill);
  }

  void _drawAuroraRibbon(Canvas canvas, Paint stroke) {
    final ribbon = Path()
      ..moveTo(-11, 3)
      ..cubicTo(-4, -7, 4, 7, 11, -3)
      ..moveTo(-9, 7)
      ..cubicTo(-2, -3, 5, 9, 10, 1);
    canvas.drawPath(ribbon, stroke);
  }

  void _drawKiteDiamond(Canvas canvas, Paint stroke) {
    final p = Path()
      ..moveTo(0, -10)
      ..lineTo(7, -1)
      ..lineTo(0, 10)
      ..lineTo(-7, -1)
      ..close()
      ..moveTo(-7, -1)
      ..lineTo(7, -1);
    canvas.drawPath(p, stroke);
  }

  void _drawGamepad(Canvas canvas, Paint stroke, Paint fill) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(const Rect.fromLTWH(-11, -6, 22, 13), const Radius.circular(6)),
      stroke,
    );
    canvas.drawLine(const Offset(-7, 0.5), const Offset(-3, 0.5), stroke);
    canvas.drawLine(const Offset(-5, -1.5), const Offset(-5, 2.5), stroke);
    canvas.drawCircle(const Offset(4.5, -1.2), 1.2, fill);
    canvas.drawCircle(const Offset(6.8, 1.5), 1.2, fill);
  }

  void _drawCassette(Canvas canvas, Paint stroke, Paint fill) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(const Rect.fromLTWH(-11, -7, 22, 14), const Radius.circular(2.5)),
      stroke,
    );
    canvas.drawCircle(const Offset(-4.5, -1), 2.3, stroke);
    canvas.drawCircle(const Offset(4.5, -1), 2.3, stroke);
    canvas.drawLine(const Offset(-6, 5), const Offset(6, 5), stroke);
    canvas.drawCircle(const Offset(-4.5, -1), 0.7, fill);
    canvas.drawCircle(const Offset(4.5, -1), 0.7, fill);
  }

  void _drawTrophy(Canvas canvas, Paint stroke) {
    final p = Path()
      ..moveTo(-6, -7)
      ..lineTo(6, -7)
      ..lineTo(4, 1)
      ..quadraticBezierTo(0, 4, -4, 1)
      ..close()
      ..moveTo(0, 3)
      ..lineTo(0, 8)
      ..moveTo(-5, 8)
      ..lineTo(5, 8)
      ..moveTo(-6, -5)
      ..quadraticBezierTo(-10, -5, -9, -1)
      ..quadraticBezierTo(-8, 1, -5, 0)
      ..moveTo(6, -5)
      ..quadraticBezierTo(10, -5, 9, -1)
      ..quadraticBezierTo(8, 1, 5, 0);
    canvas.drawPath(p, stroke);
  }

  void _drawArcadeCabinet(Canvas canvas, Paint stroke) {
    final cab = Path()
      ..moveTo(-6, 9)
      ..lineTo(-6, -3)
      ..lineTo(-8, -9)
      ..lineTo(7, -9)
      ..lineTo(7, 9)
      ..close()
      ..moveTo(-4, -6)
      ..lineTo(4, -6)
      ..lineTo(4, -1)
      ..lineTo(-4, -1)
      ..close();
    canvas.drawPath(cab, stroke);
  }

  void _drawPixelCrown(Canvas canvas, Paint stroke) {
    final crown = Path()
      ..moveTo(-8, 6)
      ..lineTo(-9, -4)
      ..lineTo(-4, 1)
      ..lineTo(0, -6)
      ..lineTo(4, 1)
      ..lineTo(9, -4)
      ..lineTo(8, 6)
      ..close();
    canvas.drawPath(crown, stroke);
  }

  void _drawPixelHeart(Canvas canvas, Paint stroke) {
    final p = Path()
      ..moveTo(0, 8)
      ..lineTo(-8, 0)
      ..lineTo(-8, -4)
      ..lineTo(-4, -7)
      ..lineTo(0, -3)
      ..lineTo(4, -7)
      ..lineTo(8, -4)
      ..lineTo(8, 0)
      ..close();
    canvas.drawPath(p, stroke);
  }

  void _drawPlus(Canvas canvas, Offset center, Paint stroke) {
    canvas.drawLine(Offset(center.dx - 3, center.dy), Offset(center.dx + 3, center.dy), stroke);
    canvas.drawLine(Offset(center.dx, center.dy - 3), Offset(center.dx, center.dy + 3), stroke);
  }

  void _drawAt(Canvas canvas, double cx, double cy, double angle, VoidCallback draw) {
    canvas.save();
    canvas.translate(cx, cy);
    canvas.rotate(angle);
    draw();
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant TelegramDoodlePainter oldDelegate) =>
      oldDelegate.pattern != pattern ||
      oldDelegate.strokeColor != strokeColor ||
      oldDelegate.tileSize != tileSize;
}
