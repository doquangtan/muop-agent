part of '../chat_canvas_view.dart';

String _extractSpecificThinkingDetail(
  String rawStreamText,
  String userPrompt,
  AgentStep? step,
) {
  // 1. Nếu có streaming text từ agent, lấy dòng suy nghĩ có nghĩa gần nhất
  if (rawStreamText.isNotEmpty) {
    final lines = rawStreamText
        .split('\n')
        .map((l) => l.trim())
        .where(
          (l) =>
              l.isNotEmpty &&
              !l.startsWith('```') &&
              !l.startsWith('#') &&
              !l.startsWith('<thought>') &&
              !l.startsWith('</thought>'),
        )
        .toList();
    if (lines.isNotEmpty) {
      for (int i = lines.length - 1; i >= 0; i--) {
        final line = lines[i];
        final clean = line.replaceAll(RegExp(r'^[\*\-\d\.\s\>\:]+'), '').trim();
        if (clean.length >= 8 && !clean.toLowerCase().startsWith('ok')) {
          return clean.length > 95 ? '${clean.substring(0, 95)}...' : clean;
        }
      }
    }
  }

  // 2. Nếu có step.thinking
  if (step != null && step.thinking.isNotEmpty) {
    final lines = step.thinking
        .split('\n')
        .map((l) => l.trim())
        .where(
          (l) =>
              l.isNotEmpty &&
              !l.startsWith('```') &&
              !l.startsWith('#') &&
              !l.startsWith('<thought>') &&
              !l.startsWith('</thought>'),
        )
        .toList();
    if (lines.isNotEmpty) {
      for (int i = lines.length - 1; i >= 0; i--) {
        final line = lines[i];
        final clean = line.replaceAll(RegExp(r'^[\*\-\d\.\s\>\:]+'), '').trim();
        if (clean.length >= 8) {
          return clean.length > 95 ? '${clean.substring(0, 95)}...' : clean;
        }
      }
    }
  }

  // 3. Nếu có step.toolCalls
  if (step != null && step.toolCalls.isNotEmpty) {
    final t = step.toolCalls.last;
    final summary = t.args['toolSummary']?.toString() ?? '';
    if (summary.isNotEmpty) return summary;
    final path = t.args['Path']?.toString() ?? '';
    if (path.isNotEmpty) return '${t.name}: ${path.split('/').last}';
    final cmd = t.args['CommandLine']?.toString() ?? '';
    if (cmd.isNotEmpty) return '${t.name}: $cmd';
  }

  // 4. Nếu có step.vietnameseDetail hoặc vietnameseTitle
  if (step != null && step.vietnameseDetail.isNotEmpty) {
    return step.vietnameseDetail;
  }
  if (step != null && step.vietnameseTitle.isNotEmpty) {
    return step.vietnameseTitle;
  }

  // 5. Fallback vào userPrompt
  if (userPrompt.trim().isNotEmpty) {
    final cleanPrompt = userPrompt.replaceAll('\n', ' ').trim();
    return 'Đang phân tích yêu cầu: ${cleanPrompt.length > 70 ? '${cleanPrompt.substring(0, 70)}...' : cleanPrompt}';
  }

  return 'Đang suy nghĩ và lập kế hoạch thực hiện...';
}

/// Icon con robot với animation đang xử lý (pulsing scale, breathing glow & radar effect)
class _AnimatedThinkingRobotIcon extends StatefulWidget {
  const _AnimatedThinkingRobotIcon({this.size = 18, this.color});

  final double size;
  final Color? color;

  @override
  State<_AnimatedThinkingRobotIcon> createState() =>
      _AnimatedThinkingRobotIconState();
}

class _AnimatedThinkingRobotIconState extends State<_AnimatedThinkingRobotIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scaleAnimation;
  late final Animation<double> _glowAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);

    _scaleAnimation = Tween<double>(
      begin: 0.88,
      end: 1.12,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));

    _glowAnimation = Tween<double>(
      begin: 0.25,
      end: 0.85,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final effectiveColor =
        widget.color ?? Theme.of(context).colorScheme.primary;

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Transform.scale(
          scale: _scaleAnimation.value,
          child: Container(
            width: widget.size + 8,
            height: widget.size + 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: effectiveColor.withAlpha(
                (35 * _glowAnimation.value).round(),
              ),
              boxShadow: [
                BoxShadow(
                  color: effectiveColor.withAlpha(
                    (80 * _glowAnimation.value).round(),
                  ),
                  blurRadius: 8 * _glowAnimation.value,
                  spreadRadius: 1.2 * _glowAnimation.value,
                ),
              ],
            ),
            child: Center(
              child: Icon(
                Icons.smart_toy_rounded,
                size: widget.size,
                color: effectiveColor,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Hiệu ứng đẻ ra từng từ / từng chữ kiểu AI (Streaming Typewriter with Pulsing Cursor)
/// Gõ từng chữ cho nội dung phản hồi AI.
/// Dữ liệu mới được nối tiếp vào phần đang hiện (không gõ lại từ đầu).
/// Nếu nội dung thay đổi không phải là phần nối thêm thì hiện ngay toàn bộ.
/// Lần đầu hiển thị (lịch sử cũ) cũng hiện ngay, không gõ.
class _AiResponseTypewriter extends StatefulWidget {
  const _AiResponseTypewriter({required this.text, required this.builder});

  final String text;
  final Widget Function(BuildContext context, String visibleText) builder;

  @override
  State<_AiResponseTypewriter> createState() => _AiResponseTypewriterState();
}

class _AiResponseTypewriterState extends State<_AiResponseTypewriter> {
  static const Duration _tick = Duration(milliseconds: 20);
  Timer? _timer;
  late int _visibleLength = widget.text.length;

  @override
  void didUpdateWidget(covariant _AiResponseTypewriter oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text == widget.text) return;
    if (!widget.text.startsWith(oldWidget.text)) {
      // Không phải nội dung nối thêm (vd. đổi lượt, làm lại): hiện ngay
      _timer?.cancel();
      _visibleLength = widget.text.length;
      return;
    }
    if (_visibleLength > widget.text.length) {
      _visibleLength = widget.text.length;
    }
    _ensureTimer();
  }

  void _ensureTimer() {
    if (_timer?.isActive == true) return;
    if (_visibleLength >= widget.text.length) return;
    _timer = Timer.periodic(_tick, (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      final remaining = widget.text.length - _visibleLength;
      if (remaining <= 0) {
        timer.cancel();
        return;
      }
      final step = math.max(1, (remaining / 18).ceil());
      setState(() {
        _visibleLength = math.min(_visibleLength + step, widget.text.length);
      });
      if (_visibleLength >= widget.text.length) timer.cancel();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final len = _visibleLength.clamp(0, widget.text.length);
    return widget.builder(context, widget.text.substring(0, len));
  }
}

/// Card trực quan hiển thị Robot Coordinator đang suy nghĩ & phân tích với animation
