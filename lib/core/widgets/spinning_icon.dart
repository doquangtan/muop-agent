import 'package:material_ui/material_ui.dart';

/// Icon quay liên tục khi [spinning] là true (ví dụ lịch tự gửi lại đang chờ).
/// Khi hệ thống bật "giảm chuyển động" (reduced motion), icon đứng yên.
class SpinningIcon extends StatefulWidget {
  const SpinningIcon({
    super.key,
    required this.icon,
    this.size,
    this.color,
    this.spinning = true,
    this.period = const Duration(milliseconds: 1400),
  });

  final IconData icon;
  final double? size;
  final Color? color;
  final bool spinning;

  /// Thời gian một vòng quay
  final Duration period;

  @override
  State<SpinningIcon> createState() => _SpinningIconState();
}

class _SpinningIconState extends State<SpinningIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.period,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(covariant SpinningIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.period != widget.period) {
      _controller.duration = widget.period;
    }
    _sync();
  }

  void _sync() {
    final reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (widget.spinning && !reduceMotion) {
      if (!_controller.isAnimating) _controller.repeat();
    } else {
      _controller.stop();
      _controller.value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RotationTransition(
      turns: _controller,
      child: Icon(widget.icon, size: widget.size, color: widget.color),
    );
  }
}
