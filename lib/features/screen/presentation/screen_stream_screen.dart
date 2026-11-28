import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'package:muop_agent/core/widgets/throttled_spinner.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:muop_agent/core/di/app_dependencies.dart';
import 'package:muop_agent/core/widgets/glass_scaffold.dart';
import 'package:muop_agent/features/screen/domain/screen_entities.dart';

/// Màn hình máy chủ đang được quay. Khung JPEG lấy theo long-poll (chạy được trên web, desktop và mobile).
class ScreenStreamScreen extends StatefulWidget {
  const ScreenStreamScreen({super.key});

  @override
  State<ScreenStreamScreen> createState() => _ScreenStreamScreenState();
}

class _ScreenStreamScreenState extends State<ScreenStreamScreen> {
  late ScreenStatus _status;
  StreamSubscription<ScreenStatus>? _statusSub;
  StreamSubscription<ScreenFrame>? _frameSub;

  /// Khung đang hiển thị (JPEG). Khung mới thay khung cũ, không giữ lịch sử.
  Uint8List? _frame;

  /// Đang xem toàn màn hình (khung chiếm cả màn hình, có zoom)
  bool _zoomed = false;

  @override
  void initState() {
    super.initState();
    final repo = AppDependencies.screen;
    _status = repo.current;
    repo.refresh();
    _statusSub = repo.statusStream.listen((s) {
      if (!mounted) return;
      setState(() => _status = s);
      _syncPlayback();
    });
    _syncPlayback();
  }

  @override
  void dispose() {
    // Rời màn hình luôn trả về chiều dọc, kể cả khi đang không phóng to
    _applyOrientation(false);
    _statusSub?.cancel();
    _frameSub?.cancel();
    super.dispose();
  }

  bool get _live => _status.streaming;

  /// Nhận khung khi server đang quay; dừng khi server tắt
  void _syncPlayback() {
    if (!_live) {
      if (_zoomed) _applyOrientation(false);
      _zoomed = false;
      _stopFrames();
      if (mounted) setState(() {});
      return;
    }
    if (_frameSub != null) return;
    _frameSub = AppDependencies.screen.watchFrames().listen((frame) {
      if (!mounted) return;
      setState(() => _frame = frame.jpeg);
    });
    if (mounted) setState(() {});
  }

  void _stopFrames() {
    _frameSub?.cancel();
    _frameSub = null;
    _frame = null;
  }

  Future<void> _openViewer(String url) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
    if (!ok) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Không mở được trình duyệt.')),
      );
    }
  }

  Future<void> _copyUrl(String url) async {
    await Clipboard.setData(ClipboardData(text: url));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Đã sao chép địa chỉ xem màn hình')));
  }

  /// Bật/tắt chế độ phóng to, kèm xoay màn hình
  void _setZoomed(bool zoomed) {
    setState(() => _zoomed = zoomed);
    _applyOrientation(zoomed);
  }

  /// Phóng to: xoay ngang và ẩn thanh hệ thống. Thu nhỏ/rời màn hình: khoá về chiều dọc và hiện lại thanh hệ thống.
  /// Chỉ áp dụng trên điện thoại; desktop và web không có xoay màn hình.
  void _applyOrientation(bool landscape) {
    if (kIsWeb) return;
    if (defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS) {
      return;
    }
    if (landscape) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }

  /// Khung hình: giữ khung cũ khi khung mới chưa giải mã xong (gaplessPlayback) để không nháy
  Widget _buildFrame(ColorScheme colorScheme, TextTheme textTheme, {required bool fill}) {
    final frame = _frame;
    final child = frame == null
        ? Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const ThrottledSpinner(size: 36, strokeWidth: 2),
              const SizedBox(height: 12),
              Text(
                'Đang nhận khung hình đầu tiên…',
                style: textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
              ),
            ],
          )
        : Image.memory(
            frame,
            gaplessPlayback: true,
            fit: BoxFit.contain,
            filterQuality: FilterQuality.medium,
          );
    final framed = ColoredBox(
      color: colorScheme.scrim,
      child: Center(child: child),
    );
    if (fill) return framed;
    return AspectRatio(aspectRatio: 16 / 9, child: framed);
  }

  /// Khung toàn màn hình: kéo hai ngón để phóng to/thu nhỏ, nút góc trên để thoát
  Widget _buildZoomed(ColorScheme colorScheme, TextTheme textTheme) {
    return ColoredBox(
      color: colorScheme.scrim,
      child: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: InteractiveViewer(
                minScale: 1,
                maxScale: 5,
                child: _buildFrame(colorScheme, textTheme, fill: true),
              ),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: IconButton.filledTonal(
                tooltip: 'Thu nhỏ',
                onPressed: () => _setZoomed(false),
                icon: const Icon(Icons.fullscreen_exit_rounded),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final url = AppDependencies.screen.viewerUrl(_status.viewerUrl);

    final String message;
    final IconData icon;
    if (_live) {
      icon = Icons.cast_connected_rounded;
      message = 'Đang phát trực tiếp ${_status.height}p.';
    } else if (_status.starting) {
      icon = Icons.hourglass_top_rounded;
      message = 'Đang chờ xác nhận chia sẻ màn hình trên máy chủ.';
    } else if (_status.error.isNotEmpty) {
      icon = Icons.error_outline_rounded;
      message = _status.error;
    } else {
      icon = Icons.cast_rounded;
      message = 'Chưa bật quay màn hình. Bật bằng checkbox "Stream màn hình" trên khay hệ thống của máy chủ.';
    }

    final showZoomed = _zoomed && _live;
    return PopScope(
      canPop: !showZoomed,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && showZoomed) _setZoomed(false);
      },
      child: showZoomed
          ? Scaffold(body: _buildZoomed(colorScheme, textTheme))
          : GlassScreenScaffold(
              title: 'Màn hình máy chủ',
              body: _buildPanel(colorScheme, textTheme, url, icon, message),
            ),
    );
  }

  Widget _buildPanel(
    ColorScheme colorScheme,
    TextTheme textTheme,
    String url,
    IconData icon,
    String message,
  ) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_live) ...[
          _buildFrame(colorScheme, textTheme, fill: false),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: () => _setZoomed(true),
            icon: const Icon(Icons.fullscreen_rounded),
            label: const Text('Phóng to'),
          ),
          const SizedBox(height: 12),
        ],
        Icon(icon, size: 40, color: colorScheme.onSurfaceVariant),
        const SizedBox(height: 8),
        Text(
          message,
          textAlign: TextAlign.center,
          style: textTheme.bodyMedium?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
        if (_live && url.isNotEmpty) ...[
          const SizedBox(height: 16),
          SelectableText(
            url,
            textAlign: TextAlign.center,
            style: textTheme.bodySmall?.copyWith(
              fontFamily: 'monospace',
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => _openViewer(url),
            icon: const Icon(Icons.open_in_new_rounded),
            label: const Text('Mở trang xem trong trình duyệt'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => _copyUrl(url),
            icon: const Icon(Icons.copy_rounded),
            label: const Text('Sao chép địa chỉ xem'),
          ),
        ],
      ],
    );
  }
}
