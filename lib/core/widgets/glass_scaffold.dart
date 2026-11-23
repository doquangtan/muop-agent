import 'package:flutter/rendering.dart' show RenderProxyBox;
import 'package:liquid_glass_easy/liquid_glass_easy.dart';
import 'package:material_ui/material_ui.dart';

import 'package:muop_agent/core/theme/chat_theme_painter.dart';
import 'package:muop_agent/core/widgets/desktop_panel.dart';
import 'package:muop_agent/core/widgets/liquid_glass.dart';

/// Tấm kính nổi Liquid Glass dùng chung cho thanh công cụ/modal phụ.
class GlassHeaderSurface extends StatelessWidget {
  const GlassHeaderSurface({
    super.key,
    required this.child,
    this.borderRadius = 22.0,
    this.blur = 14.0,
    this.padding,
    this.margin,
  });

  final Widget child;
  final double borderRadius;
  final double blur;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final baseTint = isDark
        ? const Color(0xFF131924)
        : const Color(0xFFF6F9FF);
    final topTint = isDark
        ? const Color(0xFF222C3D)
        : const Color(0xFFFFFFFF);
    final baseAlpha = isDark ? 0.34 : 0.46;
    final topAlpha = isDark ? 0.44 : 0.58;

    return LiquidGlassContainer(
      margin: margin,
      padding: padding,
      borderRadius: BorderRadius.circular(borderRadius),
      blur: blur,
      fillColor: baseTint.withValues(alpha: baseAlpha),
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          topTint.withValues(alpha: topAlpha),
          baseTint.withValues(alpha: baseAlpha),
        ],
      ),
      borderColor: isDark
          ? Colors.white.withValues(alpha: 0.20)
          : Colors.white.withValues(alpha: 0.72),
      borderWidth: 1.0,
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: isDark ? 0.32 : 0.10),
          blurRadius: 18,
          offset: const Offset(0, 6),
        ),
      ],
      child: child,
    );
  }
}

/// Khung màn hình đồng bộ phong cách với khung chat:
/// - Nền [ChatWallpaperSurface] xuyên suốt phía sau
/// - Thanh tiêu đề tách thành các viên kính nổi [LiquidGlassPill] (`LiquidGlassLens`)
///   gồm nút Back/leading tròn bên trái, pill tiêu đề ở giữa và pill nút thao tác bên phải
///   (kèm hàng pill [TabBar] nếu truyền [bottom]).
class GlassScreenScaffold extends StatefulWidget {
  const GlassScreenScaffold({
    super.key,
    this.title,
    this.titleWidget,
    this.leading,
    this.automaticallyImplyLeading = true,
    this.actions,
    this.bottom,
    this.titleSpacing,
    this.toolbarHeight,
    required this.body,
    this.bodyBackgroundColor,
    this.floatingActionButton,
    this.bottomNavigationBar,
    this.extendBodyBehindAppBar = false,
  });

  final String? title;
  final Widget? titleWidget;
  final Widget? leading;
  final bool automaticallyImplyLeading;
  final List<Widget>? actions;
  final PreferredSizeWidget? bottom;
  final double? titleSpacing;
  final double? toolbarHeight;
  final Widget body;
  final Color? bodyBackgroundColor;
  final Widget? floatingActionButton;
  final Widget? bottomNavigationBar;
  final bool extendBodyBehindAppBar;

  @override
  State<GlassScreenScaffold> createState() => _GlassScreenScaffoldState();
}

class _GlassScreenScaffoldState extends State<GlassScreenScaffold> {
  final LiquidGlassViewController _glassController =
      LiquidGlassViewController();
  double? _measuredHeaderHeight;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _glassController.captureOnce();
    });
  }

  @override
  void didUpdateWidget(covariant GlassScreenScaffold oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.title != widget.title ||
        oldWidget.bottom != widget.bottom ||
        oldWidget.actions?.length != widget.actions?.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _glassController.captureOnce();
      });
    }
  }

  bool get _hasAppBar =>
      widget.title != null ||
      widget.titleWidget != null ||
      widget.actions != null ||
      widget.bottom != null;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final isMobile = MediaQuery.sizeOf(context).width < 760;
    final inPanel = PanelScope.maybeOf(context) != null;
    final canPop = ModalRoute.of(context)?.canPop ?? false;
    final topInset = MediaQuery.paddingOf(context).top;

    Widget? leadingBtn = widget.leading;
    if (leadingBtn == null && widget.automaticallyImplyLeading) {
      if (canPop) {
        leadingBtn = const BackButton();
      } else if (inPanel) {
        leadingBtn = IconButton(
          tooltip: 'Quay lại',
          onPressed: () => closePanelPage(context),
          icon: const Icon(Icons.arrow_back_rounded, size: 20),
        );
      }
    }

    final estimatedHeaderHeight = !_hasAppBar
        ? 0.0
        : topInset +
            (isMobile ? 6.0 : 10.0) +
            44.0 +
            (widget.bottom != null
                ? 8.0 + widget.bottom!.preferredSize.height
                : 0.0) +
            8.0;
    final topPadding = !_hasAppBar
        ? 0.0
        : (widget.extendBodyBehindAppBar
            ? 0.0
            : (_measuredHeaderHeight ?? estimatedHeaderHeight));

    final Widget contentArea = widget.bodyBackgroundColor != null
        ? ColoredBox(color: widget.bodyBackgroundColor!, child: widget.body)
        : widget.body;

    final Widget backdropLayer = Stack(
      fit: StackFit.expand,
      children: [
        ChatWallpaperSurface(highContrast: MediaQuery.highContrastOf(context)),
        Positioned.fill(
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              if (notification is ScrollStartNotification) {
                _glassController.startRealtimeCapture();
              } else if (notification is ScrollEndNotification) {
                _glassController.stopRealtimeCapture();
              }
              return false;
            },
            child: Padding(
              padding: EdgeInsets.only(top: topPadding),
              child: contentArea,
            ),
          ),
        ),
      ],
    );

    final Widget? titleContent = widget.titleWidget ??
        (widget.title != null
            ? Text(
                widget.title!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.titleSmall?.copyWith(
                  fontSize: isMobile ? 14.5 : 15,
                  fontWeight: FontWeight.w700,
                  color: colorScheme.onSurface,
                ),
              )
            : null);

    final Widget floatingHeader = Align(
      alignment: Alignment.topCenter,
      child: _HeaderHeightMeasurer(
        onHeightChanged: (h) {
          if (!mounted) return;
          if (_measuredHeaderHeight == null ||
              (h - _measuredHeaderHeight!).abs() > 0.5) {
            setState(() => _measuredHeaderHeight = h);
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _glassController.captureOnce();
            });
          }
        },
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            isMobile ? 10 : 16,
            topInset + (isMobile ? 6 : 10),
            isMobile ? 10 : 16,
            6,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  if (leadingBtn != null) ...[
                    LiquidGlassPill(
                      cornerRadius: 21,
                      refractionWidth: 10,
                      shadowBlur: 10,
                      child: SizedBox(
                        width: 42,
                        height: 42,
                        child: Center(child: leadingBtn),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  if (titleContent != null)
                    Expanded(
                      child: LiquidGlassPill(
                        key: const Key('glass-header-title-pill'),
                        cornerRadius: 22,
                        refractionWidth: 12,
                        shadowBlur: 10,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(
                            minWidth: double.infinity,
                            minHeight: 42,
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 6,
                            ),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              heightFactor: 1.0,
                              child: DefaultTextStyle.merge(
                                style: textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  color: colorScheme.onSurface,
                                ),
                                child: titleContent,
                              ),
                            ),
                          ),
                        ),
                      ),
                    )
                  else
                    const Spacer(),
                  if (widget.actions != null && widget.actions!.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    LiquidGlassPill(
                      cornerRadius: 21,
                      refractionWidth: 10,
                      shadowBlur: 10,
                      child: SizedBox(
                        height: 42,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const SizedBox(width: 4),
                            ...widget.actions!,
                            const SizedBox(width: 4),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              if (widget.bottom != null) ...[
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: LiquidGlassPill(
                    cornerRadius: 21,
                    refractionWidth: 10,
                    shadowBlur: 10,
                    child: SizedBox(
                      height: widget.bottom!.preferredSize.height,
                      child: widget.bottom!,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );

    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: widget.floatingActionButton,
      bottomNavigationBar: widget.bottomNavigationBar,
      body: LiquidGlassView(
        controller: _glassController,
        pixelRatio: 0.75,
        realTimeCapture: false,
        useSync: true,
        refreshRate: LiquidGlassRefreshRate.high,
        backgroundWidget: backdropLayer,
        child: _hasAppBar ? floatingHeader : const SizedBox.shrink(),
      ),
    );
  }
}

class _HeaderHeightMeasurer extends SingleChildRenderObjectWidget {
  const _HeaderHeightMeasurer({required this.onHeightChanged, super.child});

  final ValueChanged<double> onHeightChanged;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderHeaderHeightMeasurer(onHeightChanged);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderHeaderHeightMeasurer renderObject,
  ) {
    renderObject.onHeightChanged = onHeightChanged;
  }
}

class _RenderHeaderHeightMeasurer extends RenderProxyBox {
  _RenderHeaderHeightMeasurer(this.onHeightChanged);

  ValueChanged<double> onHeightChanged;
  double? _lastHeight;

  @override
  void performLayout() {
    super.performLayout();
    final h = child?.size.height ?? 0.0;
    if (_lastHeight == null || (h - _lastHeight!).abs() > 0.5) {
      _lastHeight = h;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        onHeightChanged(h);
      });
    }
  }
}
