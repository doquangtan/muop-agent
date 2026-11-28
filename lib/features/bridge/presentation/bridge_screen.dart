import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'package:muop_agent/core/widgets/throttled_spinner.dart';

import 'package:muop_agent/core/di/app_dependencies.dart';
import 'package:muop_agent/core/state/server_address_provider.dart';
import 'package:muop_agent/core/theme/app_theme.dart';
import 'package:muop_agent/core/widgets/glass_scaffold.dart';
import 'package:muop_agent/features/bridge/domain/bridge_entities.dart';
import 'package:muop_agent/features/bridge/domain/bridge_repository.dart';


/// Cấu hình máy phụ (máy A): địa chỉ máy A và trạng thái kết nối.
/// Cấu hình được lưu trên server đang kết nối; đổi server thì màn được dựng lại.
class BridgeScreen extends ConsumerWidget {
  const BridgeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final serverAddress = ref.watch(serverAddressProvider);
    return BridgeScreenView(
      key: ValueKey(serverAddress),
      serverAddress: serverAddress,
      repository: AppDependencies.bridge,
    );
  }
}

class BridgeScreenView extends StatefulWidget {
  /// Nhúng vào màn khác (tab Cài đặt): chỉ trả phần thân, không có AppBar/Scaffold riêng
  final bool embedded;

  const BridgeScreenView({
    super.key,
    this.embedded = false,
    required this.serverAddress,
    required this.repository,
  });

  final String serverAddress;
  final BridgeRepository repository;

  @override
  State<BridgeScreenView> createState() => _BridgeScreenState();
}

class _BridgeScreenState extends State<BridgeScreenView> {
  BridgeStatus? _status;
  /// Trạng thái cầu nối do server đẩy (`bridge:status`) khi đổi và khi client vừa kết nối
  StreamSubscription<BridgeEvent>? _statusSub;

  final _urlCtrl = TextEditingController();

  bool _savingPeer = false;
  String? _peerMessage;

  @override
  void initState() {
    super.initState();
    _refreshStatus();
    _statusSub = widget.repository.watchEvents().listen((event) {
      if (!mounted || event.name != 'bridge:status' || event.data is! Map) return;
      _applyStatus(BridgeStatus.fromJson(Map<String, dynamic>.from(event.data as Map)));
    });
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    _urlCtrl.dispose();
    super.dispose();
  }

  /// Tải trạng thái một lần (khi mở màn); sau đó cập nhật theo sự kiện
  Future<void> _refreshStatus() async {
    final res = await widget.repository.fetchStatus(widget.serverAddress);
    if (!mounted) return;
    _applyStatus(res);
  }

  void _applyStatus(BridgeStatus res) {
    setState(() {
      _status = res;
      // Lần đầu mở màn: điền sẵn địa chỉ đã lưu trên server
      if (_urlCtrl.text.isEmpty && res.url.isNotEmpty) {
        _urlCtrl.text = res.url;
      }
    });
  }

  Future<void> _savePeer({required bool disconnect}) async {
    final url = disconnect ? '' : _urlCtrl.text.trim();
    setState(() {
      _savingPeer = true;
      _peerMessage = null;
    });
    final res = await widget.repository.setPeer(widget.serverAddress, url: url);
    if (!mounted) return;
    setState(() {
      _savingPeer = false;
      if (!res.ok) {
        _peerMessage = res.error.isEmpty
            ? 'Không lưu được địa chỉ máy A'
            : res.error;
      } else {
        _status = res;
        _urlCtrl.text = res.url;
        if (disconnect) {
          _peerMessage = 'Đã ngắt kết nối máy A';
        } else if (res.registerError.isNotEmpty) {
          _peerMessage = 'Máy phụ chưa đăng ký được: ${res.registerError}';
        } else {
          _peerMessage =
              'Đã lưu. Máy phụ đã đăng ký; đang kết nối tới máy A...';
        }
      }
    });
    // Kết nối là bất đồng bộ: hỏi lại sau một lúc để hiện trạng thái thật
    await Future<void>.delayed(const Duration(seconds: 2));
    if (mounted) _refreshStatus();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final textTheme = Theme.of(context).textTheme;

    final Widget content = ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      children: [
        Text(
          'Cấu hình máy phụ (máy A). Cấu hình lưu trên server đang kết nối '
          '(${widget.serverAddress}).',
          style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        _card(
          context,
          title: 'Kết nối tới máy A',
          children: [
            _statusRow(context),
            const SizedBox(height: 12),
            TextField(
              key: const Key('bridge-url'),
              controller: _urlCtrl,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'Địa chỉ máy A',
                hintText: 'http://IP-máy-A:8787',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            if (_peerMessage != null) ...[
              const SizedBox(height: 8),
              Text(
                _peerMessage!,
                key: const Key('bridge-peer-message'),
                style: textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  key: const Key('bridge-save'),
                  onPressed: _savingPeer
                      ? null
                      : () => _savePeer(disconnect: false),
                  icon: _savingPeer
                      ? const ThrottledSpinner(size: 16, strokeWidth: 2)
                      : const Icon(Icons.link_rounded, size: 18),
                  label: const Text('Lưu & kết nối'),
                ),
                OutlinedButton.icon(
                  key: const Key('bridge-disconnect'),
                  onPressed: _savingPeer || !(_status?.configured ?? false)
                      ? null
                      : () => _savePeer(disconnect: true),
                  icon: const Icon(Icons.link_off_rounded, size: 18),
                  label: const Text('Ngắt kết nối'),
                ),
              ],
            ),
          ],
        ),
      ],
    );
    if (widget.embedded) return content;
    return GlassScreenScaffold(
      title: 'Cấu hình máy phụ',
      actions: [
        IconButton(
          tooltip: 'Làm mới trạng thái',
          onPressed: _refreshStatus,
          icon: const Icon(Icons.refresh_rounded),
        ),
      ],
      body: content,
    );
  }

  Widget _card(
    BuildContext context, {
    required String title,
    required List<Widget> children,
  }) {
    final textTheme = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 10),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _statusRow(BuildContext context) {
    final scheme = context.scheme;
    final status = _status;
    final textTheme = Theme.of(context).textTheme;

    if (status == null) {
      return Row(
        children: [
          const ThrottledSpinner(size: 14, strokeWidth: 2),
          const SizedBox(width: 8),
          Text('Đang kiểm tra...', style: textTheme.bodyMedium),
        ],
      );
    }

    final String label;
    final IconData icon;
    final Color color;
    if (!status.ok) {
      label = status.error.isEmpty ? 'Không lấy được trạng thái' : status.error;
      icon = Icons.error_outline_rounded;
      color = scheme.error;
    } else if (!status.configured) {
      label = 'Chưa cấu hình. Nhập địa chỉ máy A rồi bấm Lưu & kết nối.';
      icon = Icons.link_off_rounded;
      color = scheme.onSurfaceVariant;
    } else if (status.connected) {
      label = 'Đã kết nối tới ${status.url}';
      icon = Icons.check_circle_rounded;
      color = context.status.success;
    } else {
      label = status.error.isEmpty
          ? 'Đang kết nối tới ${status.url}...'
          : 'Chưa kết nối tới ${status.url}: ${status.error}';
      icon = Icons.sync_problem_rounded;
      color = scheme.error;
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            label,
            key: const Key('bridge-status-text'),
            style: textTheme.bodyMedium?.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}
