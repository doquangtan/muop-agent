import 'package:material_ui/material_ui.dart';

/// Trên desktop, các màn hình SSH / Docker / log mở ngay trong vùng chính bên phải (sidebar vẫn hiện).
/// Dashboard cung cấp [open] qua scope này; trên mobile không có scope và màn hình được push như cũ.
class PanelScope extends InheritedWidget {
  const PanelScope({
    super.key,
    required this.open,
    required this.close,
    required super.child,
  });

  /// Mount một trang vào vùng chính (không push route). Future hoàn thành khi trang bị đóng.
  final Future<void> Function(Widget page) open;

  /// Đóng trang đang hiện trong vùng chính, quay về trang trước đó (hoặc chat)
  final void Function() close;

  static PanelScope? maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<PanelScope>();
  }

  @override
  bool updateShouldNotify(PanelScope oldWidget) => false;
}

/// Đóng trang panel đang mở: trong vùng chính (desktop) hoặc pop màn hình (mobile).
void closePanelPage(BuildContext context) {
  final scope = PanelScope.maybeOf(context);
  if (scope != null) {
    scope.close();
    return;
  }
  Navigator.of(context).maybePop();
}

/// Mở một trang: trong vùng chính (desktop) hoặc push full-screen (mobile).
/// Future hoàn thành khi trang đóng, để caller tải lại dữ liệu.
Future<void> openPanelPage(BuildContext context, Widget page) {
  final scope = PanelScope.maybeOf(context);
  if (scope != null) return scope.open(page);
  return Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
}
