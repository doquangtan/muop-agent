import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

/// Hệ thống có yêu cầu giảm chuyển động (reduce motion) hay không.
bool reduceMotionOf(BuildContext context) =>
    MediaQuery.maybeOf(context)?.disableAnimations ?? false;

/// Cây hiện tại có đang được bật animation không ([TickerMode]). Tắt khi route/panel phía trên che nó.
/// `TickerMode.of` đã deprecated từ Flutter 3.50 nên dùng `valuesOf`. Hàm này đăng ký phụ thuộc:
/// khi TickerMode đổi, `didChangeDependencies` của widget được gọi lại.
bool tickerEnabledOf(BuildContext context) =>
    TickerMode.valuesOf(context).enabled;

/// App có đang hiển thị cho người dùng không.
///
/// Khi app ra nền (`paused`, `hidden`, `detached`), không có khung nào được vẽ, nhưng `Timer` vẫn chạy và
/// đánh thức CPU. [ThrottledTicker] nghe giá trị này để dừng Timer. `inactive` (cửa sổ mất focus nhưng vẫn
/// nhìn thấy, ví dụ desktop) vẫn tính là đang hiển thị.
class AppActivity {
  AppActivity._();

  static final ValueNotifier<bool> foreground = ValueNotifier<bool>(true);
}

/// Đăng ký một lần trong `main()` để cập nhật [AppActivity.foreground] theo vòng đời app.
class AppActivityObserver with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    AppActivity.foreground.value = switch (state) {
      AppLifecycleState.paused ||
      AppLifecycleState.hidden ||
      AppLifecycleState.detached => false,
      AppLifecycleState.resumed || AppLifecycleState.inactive => true,
    };
  }
}

/// Nguồn pha chu kỳ 0..1 cho các animation lặp không dùng vsync.
///
/// `AnimationController` (và `CircularProgressIndicator`) chạy theo vsync, tức 60 khung/giây, và mỗi khung
/// buộc Flutter dựng lại cả cây phía trên, và các lớp phía trên. Đồng hồ này chỉ phát
/// [interval] một lần bằng `Timer`, còn pha tính từ thời gian cộng dồn nên tốc độ quay không đổi.
///
/// Timer chỉ chạy khi có yêu cầu ([start]) VÀ app đang hiển thị ([AppActivity.foreground]).
///
/// Dùng [phase] với `ValueListenableBuilder` hoặc `CustomPainter(repaint: ...)` để chỉ phần đó dựng lại.
class ThrottledTicker {
  ThrottledTicker() {
    AppActivity.foreground.addListener(_onActivityChanged);
  }

  /// Thời gian một chu kỳ; có thể đổi trước khi gọi [start]
  Duration period = const Duration(seconds: 1);

  /// Pha hiện tại trong [0, 1)
  final ValueNotifier<double> phase = ValueNotifier<double>(0);

  Timer? _timer;
  Duration _interval = Duration.zero;
  bool _wanted = false;
  int _elapsedUs = 0;

  bool get isRunning => _timer != null;

  /// Yêu cầu chạy với nhịp [interval]. Nếu đang chạy đúng nhịp đó thì giữ nguyên, không khởi động lại.
  void start({required Duration interval}) {
    if (_wanted && _interval == interval) return;
    _wanted = true;
    if (_interval != interval) _disarm(); // đổi nhịp: Timer cũ phải dừng trước
    _interval = interval;
    _arm();
  }

  /// Tạm dừng và giữ nguyên pha, để lần [start] sau tiếp tục mượt từ chỗ đang dở.
  void stop() {
    _wanted = false;
    _disarm();
  }

  /// Dừng và đưa về pha 0 (icon đứng ở tư thế nghỉ).
  void reset() {
    stop();
    _elapsedUs = 0;
    phase.value = 0;
  }

  void dispose() {
    AppActivity.foreground.removeListener(_onActivityChanged);
    _disarm();
    phase.dispose();
  }

  void _onActivityChanged() => _arm();

  /// Bật Timer nếu được yêu cầu và app đang hiển thị; tắt trong trường hợp ngược lại.
  void _arm() {
    if (!_wanted || !AppActivity.foreground.value) {
      _disarm();
      return;
    }
    if (_timer != null && _timer!.isActive) return;
    _timer = Timer.periodic(_interval, (_) {
      _elapsedUs += _interval.inMicroseconds;
      final periodUs = math.max(1, period.inMicroseconds);
      phase.value = (_elapsedUs % periodUs) / periodUs;
    });
  }

  void _disarm() {
    _timer?.cancel();
    _timer = null;
  }
}
