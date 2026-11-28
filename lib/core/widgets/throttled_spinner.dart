import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'package:muop_agent/core/widgets/throttled_ticker.dart';

/// Vòng xoay "đang xử lý" thay cho [CircularProgressIndicator] trong khu vực chat.
///
/// `CircularProgressIndicator` chạy theo vsync (60 khung/giây). Mỗi khung đó buộc Flutter dựng lại
/// và dựng lại mọi lớp phía trên, nên một spinner nhỏ trong dock cũng làm
/// GPU tăng đáng kể. Widget này quay theo nhịp [fps] bằng [ThrottledTicker], và chỉ repaint painter của chính nó.
/// Giảm chuyển động (reduced motion) thì đứng yên; cây bị tắt animation (TickerMode tắt) thì tạm dừng.
class ThrottledSpinner extends StatefulWidget {
  const ThrottledSpinner({
    super.key,
    this.size = 14,
    this.strokeWidth = 2,
    this.color,
    this.fps = 30,
    this.period = const Duration(milliseconds: 900),
  });

  final double size;
  final double strokeWidth;
  final Color? color;
  final int fps;

  /// Thời gian một vòng quay
  final Duration period;

  @override
  State<ThrottledSpinner> createState() => _ThrottledSpinnerState();
}

class _ThrottledSpinnerState extends State<ThrottledSpinner> {
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
  void didUpdateWidget(covariant ThrottledSpinner oldWidget) {
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
      _ticker.start(interval: _interval);
    } else {
      _ticker.stop();
    }
  }

  Duration get _interval =>
      Duration(microseconds: (1000000 / math.max(1, widget.fps)).round());

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? Theme.of(context).colorScheme.primary;
    return RepaintBoundary(
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: CustomPaint(
          painter: _SpinnerPainter(
            turns: _ticker.phase,
            color: color,
            strokeWidth: widget.strokeWidth,
          ),
        ),
      ),
    );
  }
}

class _SpinnerPainter extends CustomPainter {
  _SpinnerPainter({
    required this.turns,
    required this.color,
    required this.strokeWidth,
  }) : super(repaint: turns);

  final ValueNotifier<double> turns;
  final Color color;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(strokeWidth / 2);
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..color = color.withValues(alpha: 0.18);
    canvas.drawArc(rect, 0, math.pi * 2, false, track);

    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..color = color;
    final start = turns.value * math.pi * 2 - math.pi / 2;
    canvas.drawArc(rect, start, math.pi * 0.75, false, arc);
  }

  @override
  bool shouldRepaint(covariant _SpinnerPainter old) =>
      old.color != color ||
      old.strokeWidth != strokeWidth ||
      old.turns != turns;
}
