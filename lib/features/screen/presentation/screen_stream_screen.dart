import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:muop_agent/core/di/app_dependencies.dart';
import 'package:muop_agent/core/widgets/glass_scaffold.dart';
import 'package:muop_agent/features/screen/domain/screen_entities.dart';

/// Thử lại khi luồng RTSP lỗi (server vừa khởi động lại, mạng chập chờn...)
const _retryDelay = Duration(seconds: 3);
const _maxRetries = 20;

/// Màn hình máy chủ đang được quay. Phát luồng RTSP ngay trong app.
class ScreenStreamScreen extends StatefulWidget {
  const ScreenStreamScreen({super.key});

  @override
  State<ScreenStreamScreen> createState() => _ScreenStreamScreenState();
}

class _ScreenStreamScreenState extends State<ScreenStreamScreen> {
  late ScreenStatus _status;
  StreamSubscription<ScreenStatus>? _statusSub;

  Player? _player;
  VideoController? _video;
  final List<StreamSubscription<dynamic>> _playerSubs = [];
  String _playingUrl = '';
  bool _buffering = true;
  String _playError = '';
  /// Vài dòng log cảnh báo/lỗi gần nhất của libmpv, hiện dưới thông báo để chẩn đoán
  final List<String> _recentLogs = [];
  int _retries = 0;
  Timer? _retryTimer;

  /// Đang xem toàn màn hình (video chiếm cả màn hình, có zoom)
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
    _retryTimer?.cancel();
    _disposePlayer();
    super.dispose();
  }

  bool get _live => _status.streaming && _status.rtspUrl.isNotEmpty;

  /// Mở luồng khi server đang phát; dừng khi server tắt hoặc đổi địa chỉ
  void _syncPlayback() {
    if (!_live) {
      _retryTimer?.cancel();
      _retries = 0;
      if (_zoomed) _applyOrientation(false);
      _zoomed = false;
      _disposePlayer();
      if (mounted) setState(() {});
      return;
    }
    final url = AppDependencies.screen.playbackUrl(_status.rtspUrl);
    if (_player != null && _playingUrl == url) return;
    unawaited(_openStream(url));
  }

  /// Số thứ tự lần mở luồng gần nhất: lần mở cũ (đang chờ thuộc tính) bị bỏ khi đã có lần mới
  int _openGen = 0;

  Future<void> _openStream(String url) async {
    _disposePlayer();
    final gen = ++_openGen;
    final player = Player(
      configuration: const PlayerConfiguration(logLevel: MPVLogLevel.info),
    );
    _player = player;
    _playingUrl = url;
    _buffering = true;
    _playError = '';
    _recentLogs.clear();

    // RÀNG BUỘC (đừng sửa thứ tự này):
    // 1. Thuộc tính libmpv phải đặt XONG (await) trước khi tạo VideoController. VideoController tạo render
    //    context của mpv trên luồng nền; đổi cấu hình (ví dụ `profile`) trong lúc đó làm mpv assert
    //    (m_config_cache_from_shadow).
    // 2. KHÔNG đưa VideoController lên trước các setProperty ở trên.
    // 3. Trên Android, hwdec chỉ đặt được qua VideoControllerConfiguration (xem chú thích bên dưới), KHÔNG
    //    đặt bằng setProperty: VideoController tự ghi đè `hwdec` khi khởi tạo.
    // 4. Lần mở cũ (gen) đang chờ thuộc tính phải bị bỏ, không được gắn video vào player cũ.
    final native = player.platform;
    if (native is NativePlayer) {
      // RTSP qua TCP (server chỉ hỗ trợ TCP) và giảm độ trễ
      await native.setProperty('rtsp-transport', 'tcp');
      await native.setProperty('profile', 'low-latency');
      await native.setProperty('cache', 'no');
      await native.setProperty('network-timeout', '10');
      // Luồng live không seek được: cho phép seek thử để mpv không báo lỗi "Cannot seek" làm luồng bị đóng
      await native.setProperty('force-seekable', 'yes');
    }
    if (gen != _openGen || !mounted) {
      // Đã có lần mở mới (đã tự hủy player này) hoặc rời màn hình trong lúc chờ: chỉ hủy nếu còn là player hiện tại
      if (identical(_player, player)) _disposePlayer();
      return;
    }
    // Android: giải mã phần cứng (MediaCodec) mở trước khi biết kích thước khung, vì SDP không có
    // width/height nên cấu hình với 0x0 và bị từ chối ("Could not open codec", lặp lại mỗi vài giây).
    // Đã kiểm chứng: `hwdec=no` đặt bằng setProperty bị media_kit_video 2.0.1 ghi đè
    // (android_video_controller/real.dart, setProperties 'hwdec'). Phải truyền qua
    // VideoControllerConfiguration. Luồng RTSP trên Android giải mã bằng phần mềm; các nền tảng khác
    // giữ mặc định của media_kit.
    final video = VideoController(
      player,
      configuration: defaultTargetPlatform == TargetPlatform.android
          ? const VideoControllerConfiguration(hwdec: 'no')
          : const VideoControllerConfiguration(),
    );
    _video = video;

    _playerSubs.add(
      player.stream.log.listen((log) {
        final text = log.text.trim();
        debugPrint('[screen/mpv] ${log.level}: $text');
        if (!mounted || text.isEmpty) return;
        if (log.level != 'warn' && log.level != 'error' && log.level != 'fatal') {
          return;
        }
        setState(() {
          _recentLogs.add('${log.level}: $text');
          if (_recentLogs.length > 3) _recentLogs.removeAt(0);
        });
      }),
    );
    _playerSubs.add(
      player.stream.buffering.listen((b) {
        if (mounted) setState(() => _buffering = b);
      }),
    );
    _playerSubs.add(
      player.stream.playing.listen((playing) {
        if (playing) _retries = 0;
      }),
    );
    _playerSubs.add(
      player.stream.error.listen((err) {
        debugPrint('[screen/mpv] error: $err');
        if (err.isEmpty || !mounted) return;
        setState(() => _playError = err);
        _scheduleRetry();
      }),
    );

    unawaited(player.open(Media(url), play: true));
    if (mounted) setState(() {});
  }

  void _scheduleRetry() {
    if (!_live || _retries >= _maxRetries) return;
    _retryTimer?.cancel();
    _retryTimer = Timer(_retryDelay, () {
      if (!mounted || !_live) return;
      _retries++;
      unawaited(_openStream(AppDependencies.screen.playbackUrl(_status.rtspUrl)));
    });
  }

  void _disposePlayer() {
    for (final s in _playerSubs) {
      s.cancel();
    }
    _playerSubs.clear();
    final player = _player;
    _player = null;
    _video = null;
    _playingUrl = '';
    player?.dispose();
  }

  Future<void> _openInPlayer(String url) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
    if (!ok) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Không tìm thấy ứng dụng mở RTSP. Hãy cài VLC hoặc mpv rồi thử lại.',
          ),
        ),
      );
    }
  }

  Future<void> _copyUrl(String url) async {
    await Clipboard.setData(ClipboardData(text: url));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Đã sao chép địa chỉ RTSP')));
  }

  Widget _buildVideo(ColorScheme colorScheme, TextTheme textTheme) {
    final video = _video!;
    return Stack(
      alignment: Alignment.center,
      children: [
        AspectRatio(
          aspectRatio: 16 / 9,
          child: ColoredBox(
            color: colorScheme.scrim,
            child: Video(controller: video, controls: NoVideoControls),
          ),
        ),
        if (_buffering) const CircularProgressIndicator(strokeWidth: 2),
        if (_playError.isNotEmpty)
          Positioned(
            left: 12,
            right: 12,
            bottom: 12,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _retries < _maxRetries
                      ? 'Mất kết nối, đang thử lại…'
                      : 'Không phát được luồng',
                  textAlign: TextAlign.center,
                  style: textTheme.bodySmall?.copyWith(color: colorScheme.error),
                ),
                // Lỗi gốc và log gần nhất của libmpv, để biết nguyên nhân khi báo lại
                for (final line in [_playError, ..._recentLogs])
                  Text(
                    line,
                    textAlign: TextAlign.center,
                    style: textTheme.labelSmall?.copyWith(
                      color: colorScheme.error.withValues(alpha: 0.8),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  /// Bật/tắt chế độ phóng to, kèm xoay màn hình
  void _setZoomed(bool zoomed) {
    setState(() => _zoomed = zoomed);
    _applyOrientation(zoomed);
  }

  /// Phóng to: xoay ngang và ẩn thanh hệ thống. Thu nhỏ/rời màn hình: khoá về chiều dọc và hiện lại thanh hệ thống.
  /// Chỉ áp dụng trên điện thoại; Linux desktop không có xoay màn hình.
  void _applyOrientation(bool landscape) {
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

  /// Video toàn màn hình: kéo hai ngón để phóng to/thu nhỏ, nút góc trên để thoát
  Widget _buildZoomed(ColorScheme colorScheme) {
    return ColoredBox(
      color: colorScheme.scrim,
      child: SafeArea(
        child: Stack(
          children: [
            Center(
              child: InteractiveViewer(
                minScale: 1,
                maxScale: 5,
                child: Video(controller: _video!, controls: NoVideoControls),
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
    final url = AppDependencies.screen.playbackUrl(_status.rtspUrl);

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

    final showZoomed = _zoomed && _live && _video != null;
    return PopScope(
      canPop: !showZoomed,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && showZoomed) _setZoomed(false);
      },
      child: showZoomed
          ? Scaffold(body: _buildZoomed(colorScheme))
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
        if (_live && _video != null) ...[
          _buildVideo(colorScheme, textTheme),
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
        if (_live) ...[
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
            onPressed: () => _openInPlayer(url),
            icon: const Icon(Icons.open_in_new_rounded),
            label: const Text('Mở bằng ứng dụng khác'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => _copyUrl(url),
            icon: const Icon(Icons.copy_rounded),
            label: const Text('Sao chép địa chỉ RTSP'),
          ),
        ],
      ],
    );
  }
}
