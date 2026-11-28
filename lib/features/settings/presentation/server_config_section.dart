import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'package:muop_agent/core/widgets/throttled_spinner.dart';

import 'package:muop_agent/core/config/server_config.dart';
import 'package:muop_agent/core/di/app_dependencies.dart';
import 'package:muop_agent/core/state/server_address_provider.dart';
import 'package:muop_agent/core/state/setup_check_provider.dart';
import 'package:muop_agent/core/theme/app_theme.dart';
import 'package:muop_agent/features/connection/domain/connection_entities.dart';
import 'package:muop_agent/features/connection/domain/connection_repository.dart';
import 'package:muop_agent/features/connection/domain/lan_scan.dart';
import 'package:muop_agent/features/setup/presentation/setup_flow.dart';

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
  /// Tên máy (hostname) của từng địa chỉ đã lưu, hiện ngay dưới IP
  Map<String, String> serverNames = {};
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

  /// Các server đã kết nối trước đây (mới nhất đứng đầu) kèm tên máy đã nhớ
  Future<void> _loadSaved() async {
    final list = List<String>.of(await _connectionRepo.loadSavedServers());
    final names = await _connectionRepo.loadServerNames();
    if (mounted) {
      setState(() {
        saved = list;
        serverNames = names;
      });
    }
    // Máy đã lưu từ trước khi có tên: hỏi hostname một lần rồi ghi lại
    await Future.wait([
      for (final addr in list)
        if (!names.containsKey(addr)) _rememberName(addr),
    ]);
  }

  String _cleanAddress(String addr) =>
      addr.trim().isEmpty ? defaultHostAddress : addr.trim();

  /// Dòng phụ của máy đã lưu: tên máy dưới IP, kèm "Đang dùng" nếu là máy hiện tại
  Widget? _savedSubtitle(String addr, String current) {
    final name = serverNames[addr] ?? '';
    final parts = [
      if (name.isNotEmpty) name,
      if (addr == current) 'Đang dùng',
    ];
    if (parts.isEmpty) return null;
    return Text(parts.join(' · '));
  }

  /// Hỏi hostname của [addr] và nhớ lại khi máy trả lời; máy offline thì bỏ qua
  Future<void> _rememberName(String addr) async {
    final res = await _connectionRepo.pingRemoteServer(addr);
    if (!res.isOnline || res.hostname.trim().isEmpty) return;
    await _connectionRepo.saveServerName(addr, res.hostname);
    if (mounted) {
      setState(() => serverNames = {...serverNames, addr: res.hostname.trim()});
    }
  }

  /// Kết nối tới [addr] (từ lịch sử, máy tìm được hoặc ô IP). Nếu máy trả lời trạng thái thì đổi máy chủ
  /// và mở luồng kiểm tra cài đặt (splash, wizard nếu cần) ngay, không chờ người dùng bấm quay lại.
  /// Máy không trả lời thì chỉ lưu địa chỉ và báo lỗi.
  Future<void> _connect(String addr) async {
    final clean = _cleanAddress(addr);
    // Chụp Navigator GỐC trước các await. Trên desktop màn này nằm trong Navigator của vùng panel
    // (lồng trong dashboard); đổi máy chủ làm dashboard dựng lại và hủy Navigator đó, push splash sẽ hụt.
    final navigator = Navigator.of(context, rootNavigator: true);
    final messenger = ScaffoldMessenger.of(context);
    final ping = await _connectionRepo.pingRemoteServer(clean);
    await _connectionRepo.saveServerAddress(clean);
    // Nối socket tới máy mới ngay, trước khi splash gửi setup:status. Nếu không, lệnh đi qua socket
    // của máy cũ (có thể đã chết, không có ack) và splash đứng ở "1/15" đến khi hết thời gian chờ.
    _connectionRepo.connectSocket(clean);
    if (ping.isOnline) {
      // Đánh dấu trước khi đổi để dashboard dựng lại không mở splash lần thứ hai
      ref.read(setupCheckedAddressProvider.notifier).mark(clean);
    }
    ref.read(serverAddressProvider.notifier).change(clean);
    // Tên máy lấy nền, không chặn việc đổi kết nối
    unawaited(_rememberName(clean));
    if (mounted) await _loadSaved();

    if (!ping.isOnline) {
      final reason = ping.errorMessage.isEmpty ? '' : ' (${ping.errorMessage})';
      messenger.showSnackBar(
        SnackBar(content: Text('Chưa lấy được trạng thái từ $clean$reason')),
      );
      return;
    }
    final ran = await runSetupFlow(navigator, clean);
    if (!ran) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Đang kiểm tra một máy chủ khác, thử lại sau')),
      );
      return;
    }
    // Xong splash/wizard: nếu màn Cài đặt vẫn mở (điện thoại) thì đóng để về dashboard
    if (mounted) await Navigator.of(context).maybePop();
  }

    Future<void> testPing() async {
      setState(() {
        isPinging = true;
        pingResult = null;
      });
      final res = await _connectionRepo.pingRemoteServer(ipController.text);
      if (res.isOnline && res.hostname.trim().isNotEmpty) {
        await _connectionRepo.saveServerName(
          _cleanAddress(ipController.text),
          res.hostname,
        );
      }
      if (!mounted) return;
      setState(() {
        isPinging = false;
        pingResult = res;
      });
      await _loadSaved();
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
                'Máy chủ Rust (Socket.IO). Đang dùng: $serverAddress'
                '${(serverNames[serverAddress] ?? '').isEmpty ? '' : ' (${serverNames[serverAddress]})'}',
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
                          subtitle: _savedSubtitle(addr, serverAddress),
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
                            ? const ThrottledSpinner(size: 14, strokeWidth: 2)
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
                            ? const ThrottledSpinner(size: 14, strokeWidth: 2)
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
