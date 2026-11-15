import 'package:flutter/material.dart';

/// Hai vùng ngang có thanh ở giữa kéo được để chỉnh tỉ lệ.
/// Nhấp đúp vào thanh để đưa về tỉ lệ mặc định. Khi [showLeft] = false chỉ hiện vùng phải.
class ResizableSplitView extends StatefulWidget {
  const ResizableSplitView({
    super.key,
    required this.left,
    required this.right,
    this.showLeft = true,
    this.initialLeftFraction = 0.5,
    this.minLeftWidth = 280,
    this.minRightWidth = 420,
    this.dividerWidth = 8,
  });

  final Widget left;
  final Widget right;
  final bool showLeft;
  final double initialLeftFraction;
  final double minLeftWidth;
  final double minRightWidth;
  final double dividerWidth;

  @override
  State<ResizableSplitView> createState() => _ResizableSplitViewState();
}

class _ResizableSplitViewState extends State<ResizableSplitView> {
  late double _leftFraction = widget.initialLeftFraction;

  void _resetFraction() => setState(() => _leftFraction = widget.initialLeftFraction);

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    if (!widget.showLeft) return widget.right;

    return LayoutBuilder(
      builder: (context, constraints) {
        final total = constraints.maxWidth;
        final available = total - widget.dividerWidth;
        // Giới hạn tỉ lệ để cả hai bên đều không nhỏ hơn mức tối thiểu
        final minFraction = available <= 0 ? 0.0 : widget.minLeftWidth / available;
        final maxFraction = available <= 0
            ? 1.0
            : (available - widget.minRightWidth) / available;
        final lo = minFraction.clamp(0.0, 1.0);
        final hi = maxFraction.clamp(lo, 1.0);
        final fraction = _leftFraction.clamp(lo, hi);
        final leftWidth = available * fraction;

        return Row(
          children: [
            SizedBox(width: leftWidth, child: widget.left),
            MouseRegion(
              cursor: SystemMouseCursors.resizeColumn,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onDoubleTap: _resetFraction,
                onHorizontalDragUpdate: (details) {
                  if (available <= 0) return;
                  setState(() {
                    final next = (_leftFraction * available + details.delta.dx) / available;
                    _leftFraction = next.clamp(lo, hi);
                  });
                },
                child: SizedBox(
                  width: widget.dividerWidth,
                  child: Center(
                    child: Container(
                      width: 1,
                      color: colorScheme.outlineVariant,
                    ),
                  ),
                ),
              ),
            ),
            Expanded(child: widget.right),
          ],
        );
      },
    );
  }
}
