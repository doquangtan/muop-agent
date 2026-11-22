import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'package:muop_agent/core/config/server_config.dart';
import 'package:muop_agent/core/di/app_dependencies.dart';
import 'package:muop_agent/core/state/server_address_provider.dart';
import 'package:muop_agent/core/theme/app_theme.dart';
import 'package:muop_agent/features/connection/domain/connection_entities.dart';
import 'package:muop_agent/features/connection/domain/connection_repository.dart';
import 'package:muop_agent/features/connection/domain/lan_scan.dart';

/// Cấu hình IP máy chủ trong màn Cài đặt: địa chỉ đang dùng, kiểm tra kết nối, quét LAN,
/// danh sách máy đã kết nối trước đây. Đổi địa chỉ thì toàn app tải lại dữ liệu từ máy đó.
class ServerConfigSection extends ConsumerStatefulWidget {
  const ServerConfigSection({super.key});

  @override
  ConsumerState<ServerConfigSection> createState() => _ServerConfigSectionState();
}

class _ServerConfigSectionState extends ConsumerState<ServerConfigSection> {
  final ConnectionRepository _connectionRepo = AppDependencies.connection;
  final TextEditingController ipController = TextEditingController();
  RemotePingResult? pingResult;
  bool isPinging = false;
  bool isScanning = false;
  bool scanned = false;
  int scanDone = 0;
  int scanTotal = 0;
  List<LanServer> lanServers = const [];
  List<String> saved = [];
  bool _socketLive = false;
  StreamSubscription<bool>? _liveSub;

  @override
  void initState() {
    super.initState();
    ipController.text = ref.read(serverAddressProvider);
    _socketLive = _connectionRepo.isSocketConnected;
    _liveSub = _connectionRepo.socketConnectionStream.listen((connected) {
      if (mounted) setState(() => _socketLive = connected);
    });
    _loadSaved();
  }

  @override
  void dispose() {
    _liveSub?.cancel();
    ipController.dispose();
    super.dispose();
  }

  /// Các server đã kết nối trước đây (mới nhất đứng đầu)
  Future<void> _loadSaved() async {
    final list = List<String>.of(await _connectionRepo.loadSavedServers());
    if (mounted) setState(() => saved = list);
  }

  /// Kết nối tới [addr]: ghi nhận vào danh sách đã lưu và đổi địa chỉ toàn cục
  Future<void> _connect(String addr) async {
    final clean = addr.trim().isEmpty ? defaultHostAddress : addr.trim();
    await _connectionRepo.saveServerAddress(clean);
    if (!mounted) return;
    ref.read(serverAddressProvider.notifier).change(clean);
    await _loadSaved();
  }

    Future<void> testPing() async {
      setState(() {
        isPinging = true;
        pingResult = null;
      });
      final res = await _connectionRepo.pingRemoteServer(ipController.text);
      setState(() {
        isPinging = false;
        pingResult = res;
      });
    }

    Future<void> scanLan() async {
      setState(() {
        isScanning = true;
        scanned = false;
        scanDone = 0;
        scanTotal = 0;
        lanServers = const [];
      });
      final found = await _connectionRepo.scanLanServers(
        onProgress: (done, total) {
                    if (!mounted) return;
          setState(() {
            scanDone = done;
            scanTotal = total;
          });
        },
      );
      if (!mounted) return;
      setState(() {
        isScanning = false;
        scanned = true;
        lanServers = found;
      });
    }


  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final serverAddress = ref.watch(serverAddressProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            children: [
              Text(
                'Máy chủ Rust (Socket.IO). Đang dùng: $serverAddress',
                style: textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: (_socketLive ? context.status.success : context.status.warning)
                            .withAlpha(25),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: (_socketLive ? context.status.success : context.status.warning)
                              .withAlpha(120),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                _socketLive
                                    ? Icons.sensors_rounded
                                    : Icons.sync_problem_rounded,
                                size: 16,
                                color:
                                    _socketLive ? context.status.success : context.status.warning,
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  _socketLive
                                      ? 'Socket.IO Realtime đang kết nối!'
                                      : 'Đang chờ kết nối Socket.IO...',
                                  style: textTheme.labelMedium?.copyWith(
                                    fontWeight: FontWeight.w800,
                                    color: _socketLive
                                        ? context.status.success
                                        : context.status.warning,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    if (saved.isNotEmpty) ...[
                      const SizedBox(height: 14),
                      Text(
                        'Đã kết nối trước đây',
                        style: textTheme.labelLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      for (final addr in saved)
                        ListTile(
                          dense: true,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                          leading: Icon(
                            addr == serverAddress
                                ? Icons.check_circle_rounded
                                : Icons.dns_outlined,
                            size: 20,
                            color: addr == serverAddress
                                ? context.status.success
                                : colorScheme.onSurfaceVariant,
                          ),
                          title: Text(
                            addr,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          subtitle: addr == serverAddress
                              ? const Text('Đang dùng')
                              : null,
                          onTap: () {
                            unawaited(_connect(addr));
                          },
                          trailing: IconButton(
                            tooltip: 'Xóa khỏi danh sách',
                            icon: Icon(
                              Icons.delete_outline_rounded,
                              size: 18,
                              color: colorScheme.error,
                            ),
                            onPressed: () async {
                              await _connectionRepo.removeSavedServer(addr);
                              setState(() {
                                saved.remove(addr);
                              });
                            },
                          ),
                        ),
                      const Divider(height: 20),
                    ] else
                      const SizedBox(height: 14),
                    TextField(
                      controller: ipController,
                      keyboardType: TextInputType.url,
                      decoration: InputDecoration(
                        labelText: 'Địa chỉ IP máy chủ (cổng 8787)',
                        hintText: 'localhost',
                        prefixIcon: const Icon(Icons.dns_rounded),
                        suffixIcon: IconButton(
                          icon: const Icon(Icons.clear_rounded, size: 18),
                          onPressed: () => ipController.clear(),
                        ),
                        filled: true,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: isPinging ? null : testPing,
                        icon: isPinging
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.network_check_rounded, size: 17),
                        label: Text(
                          isPinging ? 'Đang kiểm tra...' : 'Kiểm tra kết nối',
                        ),
                      ),
                    ),
                    if (pingResult != null) ...[
                      const SizedBox(height: 10),
                      Text(
                        pingResult!.isOnline
                            ? '✓ Kết nối thành công tới ${pingResult!.hostname} (${pingResult!.latencyMs}ms)'
                            : '✕ Lỗi kết nối: ${pingResult!.errorMessage}',
                        style: textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: pingResult!.isOnline
                              ? context.status.success
                              : context.scheme.error,
                        ),
                      ),
                    ],
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: isScanning ? null : scanLan,
                        icon: isScanning
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.wifi_find_rounded, size: 17),
                        label: Text(
                          isScanning
                              ? (scanTotal == 0
                                  ? 'Đang quét…'
                                  : 'Đang quét $scanDone/$scanTotal…')
                              : 'Quét mạng LAN tìm máy chủ',
                        ),
                      ),
                    ),
                    if (scanned) ...[
                      const SizedBox(height: 8),
                      if (lanServers.isEmpty)
                        Text(
                          'Không tìm thấy máy chủ muop-agent nào trên mạng LAN (cổng 8787).',
                          style: textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        )
                      else ...[
                        Text(
                          'Tìm thấy ${lanServers.length} máy chủ (bấm để kết nối)',
                          style: textTheme.labelLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        for (final server in lanServers)
                          ListTile(
                            dense: true,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                            leading: Icon(
                              Icons.dns_rounded,
                              size: 20,
                              color: colorScheme.primary,
                            ),
                            title: Text(
                              server.ip,
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            subtitle: server.hostname.isEmpty
                                ? null
                                : Text(server.hostname),
                            onTap: () {
                              unawaited(_connect(server.ip));
                            },
                          ),
                      ],
                    ],
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              onPressed: () => _connect(ipController.text),
              child: const Text('Kết nối'),
            ),
          ),
        ),
      ],
    );
  }
}
