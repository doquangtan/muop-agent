import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'package:muop_agent/core/widgets/throttled_ticker.dart';

/// Icon quay liên tục khi [spinning] là true (ví dụ lịch tự gửi lại đang chờ).
///
/// Không chạy khi:
/// - hệ thống bật "giảm chuyển động" (reduced motion): icon đứng yên;
/// - cây bị tắt animation ([TickerMode] tắt, ví dụ chat nằm dưới panel): tạm dừng, tiếp tục khi bật lại.
///
/// Quay theo nhịp [fps] bằng [ThrottledTicker] (không vsync) để không buộc Flutter dựng frame mỗi vsync
/// và blur lại mọi kính phía trên.
class SpinningIcon extends StatefulWidget {
  const SpinningIcon({
    super.key,
    required this.icon,
    this.size,
    this.color,
    this.spinning = true,
    this.period = const Duration(milliseconds: 1400),
    this.fps = 12,
  });

  final IconData icon;
  final double? size;
  final Color? color;
  final bool spinning;

  /// Thời gian một vòng quay
  final Duration period;

  /// Số khung hình mỗi giây của vòng quay. Mặc định 12: icon chờ có thể hiện hàng giờ (lịch gửi lại
  /// rate limit) và nằm trong dock kính, nên mỗi khung là một lần blur lại.
  final int fps;

  @override
  State<SpinningIcon> createState() => _SpinningIconState();
}

class _SpinningIconState extends State<SpinningIcon> {
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
  void didUpdateWidget(covariant SpinningIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    _ticker.period = widget.period;
    if (!widget.spinning || _reduceMotion) {
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
    return RepaintBoundary(
      child: ValueListenableBuilder<double>(
        valueListenable: _ticker.phase,
        builder: (context, turns, icon) =>
            Transform.rotate(angle: turns * 2 * math.pi, child: icon),
        // Icon không đổi giữa các nhịp: dựng một lần, chỉ góc quay thay đổi
        child: Icon(widget.icon, size: widget.size, color: widget.color),
      ),
    );
  }
}
