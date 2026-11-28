import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'package:muop_agent/core/widgets/throttled_ticker.dart';

/// Thanh tiến trình KHÔNG xác định (không có `value`), thay cho `LinearProgressIndicator()`.
///
/// `LinearProgressIndicator` không có giá trị chạy theo vsync (60 khung/giây). Widget này trượt một đoạn
/// sáng theo nhịp [fps] bằng [ThrottledTicker], chỉ repaint chính nó. Giảm chuyển động thì hiện đoạn
/// sáng ở giữa và đứng yên; cây bị tắt animation thì tạm dừng.
class ThrottledLinearProgress extends StatefulWidget {
  const ThrottledLinearProgress({
    super.key,
    this.minHeight = 4,
    this.color,
    this.fps = 20,
    this.period = const Duration(milliseconds: 1600),
  });

  final double minHeight;
  final Color? color;
  final int fps;

  /// Thời gian đoạn sáng đi hết một lượt thanh
  final Duration period;

  @override
  State<ThrottledLinearProgress> createState() =>
      _ThrottledLinearProgressState();
}

class _ThrottledLinearProgressState extends State<ThrottledLinearProgress> {
  final ThrottledTicker _ticker = ThrottledTicker();
  bool _reduceMotion = false;
  bool _tickerOn = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = reduceMotionOf(context);
    _tickerOn = tickerEnabledOf(context);
    _sync();
  }

  @override
  void didUpdateWidget(covariant ThrottledLinearProgress oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    _ticker.period = widget.period;
    if (_reduceMotion) {
      _ticker.reset();
      return;
    }
    if (_tickerOn) {
      _ticker.start(
        interval: Duration(microseconds: (1000000 / math.max(1, widget.fps)).round()),
      );
    } else {
      _ticker.stop();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? Theme.of(context).colorScheme.primary;
    return SizedBox(
      width: double.infinity,
      height: widget.minHeight,
      child: RepaintBoundary(
        child: CustomPaint(
          painter: _LinearProgressPainter(
            phase: _ticker.phase,
            color: color,
            reduceMotion: _reduceMotion,
          ),
        ),
      ),
    );
  }
}

class _LinearProgressPainter extends CustomPainter {
  _LinearProgressPainter({
    required this.phase,
    required this.color,
    required this.reduceMotion,
  }) : super(repaint: phase);

  final ValueNotifier<double> phase;
  final Color color;
  final bool reduceMotion;

  /// Độ rộng đoạn sáng, tính theo tỉ lệ chiều dài thanh
  static const double _segment = 0.3;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final track = Paint()..color = color.withValues(alpha: 0.18);
    canvas.drawRect(Offset.zero & size, track);

    final segW = size.width * _segment;
    // Pha 0 → 1: đoạn sáng đi từ trái ra ngoài phải (bắt đầu và kết thúc ngoài khung)
    final left = reduceMotion
        ? (size.width - segW) / 2
        : (-segW) + (size.width + segW) * phase.value;
    final bar = Paint()..color = color;
    canvas.save();
    canvas.clipRect(Offset.zero & size); // đoạn sáng đi ngoài mép thì bị cắt
    canvas.drawRect(Rect.fromLTWH(left, 0, segW, size.height), bar);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _LinearProgressPainter old) =>
      old.color != color ||
      old.reduceMotion != reduceMotion ||
      old.phase != phase;
}
