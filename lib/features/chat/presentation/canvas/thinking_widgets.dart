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

class _AnimatedThinkingRobotIconState extends State<_AnimatedThinkingRobotIcon> {
  /// Một chu kỳ phóng to/thu nhỏ (đi rồi về)
  static const Duration _cycle = Duration(milliseconds: 1400);

  /// Nhịp cập nhật: 20 khung/giây thay vì 60 (vsync). Đủ mượt cho nhịp đập chậm, và mỗi khung
  /// Flutter phải blur lại mọi kính phía trên nên giảm số khung là giảm GPU trực tiếp.
  static const Duration _tick = Duration(milliseconds: 50);

  // Ghi chú: giảm chuyển động (reduce motion) thì icon đứng ở tư thế nghỉ; chat bị ẩn thì tạm dừng.

  /// Pha 0 → 1 → 0 trong một chu kỳ đi rồi về (2 × [_cycle])
  final ThrottledTicker _ticker = ThrottledTicker();
  bool _reduceMotion = false;
  bool _tickerOn = true;

  @override
  void initState() {
    super.initState();
    _ticker.period = _cycle * 2;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = reduceMotionOf(context);
    _tickerOn = tickerEnabledOf(context);
    if (_reduceMotion) {
      _ticker.reset(); // tư thế nghỉ, không đập
    } else if (_tickerOn) {
      _ticker.start(interval: _tick);
    } else {
      _ticker.stop(); // chat nằm dưới panel: tạm dừng
    }
  }

  /// Độ cong 0 → 1 → 0 của pha (đi nửa đầu, về nửa sau) có easing
  static double _easedOf(double phase) {
    final tri = phase <= 0.5 ? phase * 2 : (1 - phase) * 2;
    return Curves.easeInOut.transform(tri);
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final effectiveColor =
        widget.color ?? Theme.of(context).colorScheme.primary;

    // Chỉ phần vòng sáng rebuild theo nhịp; icon và phần còn lại không đổi.
    return RepaintBoundary(
      child: ValueListenableBuilder<double>(
        valueListenable: _ticker.phase,
        builder: (context, phase, _) {
          final p = _easedOf(phase);
          final scale = 0.88 + 0.24 * p;
          final glow = 0.25 + 0.6 * p;
          return Transform.scale(
            scale: scale,
            child: Container(
              width: widget.size + 8,
              height: widget.size + 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                // Vầng sáng bằng gradient, KHÔNG dùng BoxShadow có blur: blur phải tính lại mỗi nhịp
                gradient: RadialGradient(
                  colors: [
                    effectiveColor.withAlpha((70 * glow).round()),
                    effectiveColor.withAlpha(0),
                  ],
                  stops: const [0.55, 1.0],
                ),
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
      ),
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
  /// 16 nhịp/giây (thay 50): mỗi nhịp dựng lại markdown của cả thẻ, nên giảm nhịp là giảm CPU/GPU
  static const Duration _tick = Duration(milliseconds: 60);
  Timer? _timer;
  late int _visibleLength = widget.text.length;
  bool _tickerOn = true;
  bool _reduceMotion = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = reduceMotionOf(context);
    final on = tickerEnabledOf(context);
    if (on == _tickerOn) return;
    _tickerOn = on;
    if (on) {
      _ensureTimer(); // bật lại: gõ tiếp từ chỗ đang dở
    } else {
      _timer?.cancel(); // bị ẩn (chat nằm dưới panel): tạm dừng, không dựng lại markdown
      _timer = null;
    }
  }

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
    // Giảm chuyển động: hiện ngay toàn bộ, không gõ
    if (_reduceMotion) {
      _visibleLength = widget.text.length;
      return;
    }
    if (!_tickerOn) return; // đang bị ẩn: chờ didChangeDependencies bật lại
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
      // Bước lớn hơn bù cho nhịp thưa, tốc độ gõ cảm nhận gần như không đổi
      final step = math.max(2, (remaining / 9).ceil());
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
