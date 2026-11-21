import 'dart:async';
import 'package:material_ui/material_ui.dart';

import 'package:muop_agent/core/di/app_dependencies.dart';
import 'package:muop_agent/core/theme/app_theme.dart';
import 'package:muop_agent/core/widgets/desktop_panel.dart';
import 'package:muop_agent/features/docker/domain/docker_entities.dart';
import 'package:muop_agent/features/ssh/domain/ssh_entities.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:muop_agent/core/state/server_address_provider.dart';

/// Tự quét lại container khi màn hình đang mở
const _autoRefresh = Duration(seconds: 10);

String _clock(String iso) {
  final t = DateTime.tryParse(iso)?.toLocal();
  if (t == null) return '';
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}

void _snack(BuildContext context, String text) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
}

/// Màn hình Docker: chọn máy SSH đã lưu để mở phiên Docker của máy đó.
/// Mỗi máy có một phiên Docker riêng (không dùng chung với phiên terminal SSH).
/// Màn gắn với server đang kết nối: đổi địa chỉ (provider toàn cục) thì dựng lại và tải lại dữ liệu
class DockerHostsScreen extends ConsumerWidget {
  const DockerHostsScreen({
    super.key,
  });


  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final serverAddress = ref.watch(serverAddressProvider);
    return DockerHostsScreenView(
      key: ValueKey(serverAddress),
      serverAddress: serverAddress,
    );
  }
}

class DockerHostsScreenView extends StatefulWidget {
  const DockerHostsScreenView({
    super.key,
    required this.serverAddress,
  });
  final String serverAddress;

  @override
  State<DockerHostsScreenView> createState() => _DockerHostsScreenState();
}

class _DockerHostsScreenState extends State<DockerHostsScreenView> {
  List<SshHost> _hosts = const [];
  /// Phiên Docker đang chạy trên server
  List<DockerSession> _sessions = const [];
  bool _loading = true;
  String? _loadError;
  int? _openingHostId;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() {
      _loading = _hosts.isEmpty;
      _loadError = null;
    });
    try {
      final results = await Future.wait([
        AppDependencies.ssh.fetchSshHosts(widget.serverAddress),
        AppDependencies.docker.listDockerSessions(widget.serverAddress),
      ]);
      if (!mounted) return;
      setState(() {
        _hosts = results[0] as List<SshHost>;
        _sessions = results[1] as List<DockerSession>;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = '$e';
      });
    }
  }

  DockerSession? _sessionFor(SshHost host) {
    for (final s in _sessions) {
      if (s.hostId == host.id) return s;
    }
    return null;
  }

  /// Mở phiên Docker của máy (hoặc gắn vào phiên đang chạy), rồi vào màn hình phiên
  Future<void> _openHost(SshHost host) async {
    if (_openingHostId != null) return;
    setState(() => _openingHostId = host.id);
    final res = await AppDependencies.docker.openDockerSession(
      widget.serverAddress,
      hostId: host.id,
    );
    if (!mounted) return;
    setState(() => _openingHostId = null);
    final session = res.session;
    if (session == null) {
      _snack(context, res.error.isEmpty ? 'Không mở được phiên Docker' : res.error);
      return;
    }
    await openPanelPage(
      context,
      DockerSessionScreen(
          hostName: host.name,
          hostAddress: host.address,
          initial: session,
        ),
    );
    if (mounted) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Docker'),
        actions: [
          IconButton(
            tooltip: 'Tải lại',
            onPressed: _loading ? null : _reload,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _loadError != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.cloud_off_rounded,
                            size: 40, color: scheme.error),
                        const SizedBox(height: 12),
                        Text(_loadError!,
                            textAlign: TextAlign.center,
                            style: textTheme.bodyMedium),
                        const SizedBox(height: 12),
                        OutlinedButton(
                          onPressed: _reload,
                          child: const Text('Thử lại'),
                        ),
                      ],
                    ),
                  ),
                )
              : _hosts.isEmpty
                  ? Center(
                      child: Text(
                        'Chưa có máy SSH nào.\nThêm máy trong màn hình SSH trước.',
                        textAlign: TextAlign.center,
                        style: textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
                      itemCount: _hosts.length + 1,
                      separatorBuilder: (context, index) =>
                          const SizedBox(height: 8),
                      itemBuilder: (context, i) {
                        if (i == 0) {
                          return Text(
                            'Mở một máy để quản lý container đang chạy trên đó. '
                            'Đóng màn hình không ngắt phiên; chỉ "Kết thúc phiên" mới ngắt kết nối.',
                            style: textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          );
                        }
                        final host = _hosts[i - 1];
                        final live = _sessionFor(host);
                        final opening = _openingHostId == host.id;
                        final subtitle = live == null
                            ? '${host.address} · chưa có phiên'
                            : '${host.address} · phiên đang chạy · '
                                '${live.containers.length} container';
                        return Material(
                          color: scheme.surfaceContainerLow,
                          borderRadius: BorderRadius.circular(12),
                          child: ListTile(
                            onTap: opening ? null : () => _openHost(host),
                            leading: CircleAvatar(
                              backgroundColor: scheme.primaryContainer,
                              child: Icon(Icons.view_in_ar_rounded,
                                  size: 18,
                                  color: scheme.onPrimaryContainer),
                            ),
                            title: Text(host.name,
                                style: textTheme.titleSmall
                                    ?.copyWith(fontWeight: FontWeight.w600)),
                            subtitle: Text(
                              subtitle,
                              style: textTheme.bodySmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                            trailing: opening
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2),
                                  )
                                : const Icon(Icons.chevron_right_rounded),
                          ),
                        );
                      },
                    ),
    );
  }
}

/// Màn hình một phiên Docker: danh sách container đang chạy, nhóm theo compose project.
/// Đóng màn hình không ngắt phiên trên server.
/// Màn gắn với server đang kết nối: đổi địa chỉ (provider toàn cục) thì dựng lại và tải lại dữ liệu
class DockerSessionScreen extends ConsumerWidget {
  const DockerSessionScreen({
    super.key,
    required this.hostName,
    required this.hostAddress,
    required this.initial,
  });

  final String hostName;
  final String hostAddress;
  final DockerSession initial;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final serverAddress = ref.watch(serverAddressProvider);
    return DockerSessionScreenView(
      key: ValueKey(serverAddress),
      serverAddress: serverAddress,
      hostName: hostName,
      hostAddress: hostAddress,
      initial: initial,
    );
  }
}

class DockerSessionScreenView extends StatefulWidget {
  const DockerSessionScreenView({
    super.key,
    required this.serverAddress,
    required this.hostName,
    required this.hostAddress,
    required this.initial,
  });
  final String serverAddress;
  final String hostName;
  final String hostAddress;
  /// Trạng thái phiên lúc mở (đã quét sẵn)
  final DockerSession initial;

  @override
  State<DockerSessionScreenView> createState() => _DockerSessionScreenState();
}

class _DockerSessionScreenState extends State<DockerSessionScreenView> {
  late DockerSession _session;
  Timer? _timer;
  /// Đang có thao tác hoặc quét thủ công
  bool _working = false;
  /// Phiên đã bị kết thúc trên server
  bool _ended = false;
  /// Lỗi kết nối tới server (không liên quan đến docker)
  String? _linkError;

  @override
  void initState() {
    super.initState();
    _session = widget.initial;
    _timer = Timer.periodic(_autoRefresh, (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _apply(DockerSessionResult res) {
    _ended = res.ended;
    if (res.session != null) {
      _session = res.session!;
      _linkError = null;
    } else {
      _linkError = res.error.isEmpty ? 'Không gọi được server' : res.error;
    }
  }

  Future<void> _refresh({bool manual = false}) async {
    if (_working || _ended) return;
    if (manual) setState(() => _working = true);
    final res = await AppDependencies.docker.scanDockerSession(
      widget.serverAddress,
      _session.sessionId,
    );
    if (!mounted) return;
    setState(() {
      _working = false;
      _apply(res);
    });
  }

  /// Mở lại phiên mới sau khi phiên cũ đã kết thúc
  Future<void> _reopen() async {
    setState(() => _working = true);
    final res = await AppDependencies.docker.openDockerSession(
      widget.serverAddress,
      hostId: _session.hostId,
    );
    if (!mounted) return;
    setState(() {
      _working = false;
      if (res.session != null) {
        _session = res.session!;
        _ended = false;
        _linkError = null;
      } else {
        _linkError = res.error;
      }
    });
  }

  Future<bool> _confirm({
    required String title,
    required String message,
    required String ok,
    bool destructive = false,
  }) async {
    final scheme = context.scheme;
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Hủy'),
          ),
          FilledButton(
            style: destructive
                ? FilledButton.styleFrom(backgroundColor: scheme.error)
                : null,
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(ok),
          ),
        ],
      ),
    );
    return result == true;
  }

  /// Dừng hoặc khởi động lại một nhóm container (một container hoặc cả project)
  Future<void> _act({
    required String action,
    required List<DockerContainer> targets,
    required String title,
  }) async {
    if (_working || targets.isEmpty) return;
    final verb = action == 'stop' ? 'Dừng' : 'Khởi động lại';
    final many = targets.length > 1;
    if (action == 'stop' || many) {
      final names = targets.map((c) => c.name).join(', ');
      final ok = await _confirm(
        title: '$verb ${many ? '${targets.length} container' : title}?',
        message: many
            ? 'Áp dụng cho: $names'
            : 'Container "${targets.first.name}" sẽ được $verb.',
        ok: verb,
        destructive: action == 'stop',
      );
      if (!ok || !mounted) return;
    }

    setState(() => _working = true);
    final res = await AppDependencies.docker.dockerContainerAction(
      widget.serverAddress,
      sessionId: _session.sessionId,
      action: action,
      containerIds: targets.map((c) => c.id).toList(),
    );
    if (!mounted) return;
    setState(() {
      _working = false;
      _apply(res);
    });
    if (res.ok) {
      _snack(context, '$verb xong ${targets.length} container');
    } else {
      _snack(context, res.error.isEmpty ? 'Thao tác thất bại' : res.error);
    }
  }

  /// Kết thúc phiên trên server. Lần mở sau sẽ kết nối lại.
  Future<void> _endSession() async {
    final ok = await _confirm(
      title: 'Kết thúc phiên Docker?',
      message:
          'Kết nối tới ${widget.hostName} sẽ bị ngắt. Lần mở sau sẽ kết nối lại.',
      ok: 'Kết thúc',
      destructive: true,
    );
    if (!ok || !mounted) return;
    setState(() => _working = true);
    await AppDependencies.docker.closeDockerSession(
      widget.serverAddress,
      _session.sessionId,
    );
    if (!mounted) return;
    closePanelPage(context);
  }

  /// Mở màn hình log của container (mở luồng SSH riêng trên server)
  void _openLogs(DockerContainer c) {
    openPanelPage(
      context,
      DockerLogsScreen(
          sessionId: _session.sessionId,
          hostName: widget.hostName,
          container: c,
        ),
    );
  }

  Map<String, List<DockerContainer>> _groups() {
    final groups = <String, List<DockerContainer>>{};
    for (final c in _session.containers) {
      groups.putIfAbsent(c.project, () => []).add(c);
    }
    return groups;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final textTheme = Theme.of(context).textTheme;
    final error = _linkError ??
        (_session.error.isNotEmpty ? _session.error : null);

    return Scaffold(
      appBar: AppBar(
        backgroundColor: scheme.surface,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Docker · ${widget.hostName}', style: textTheme.titleSmall),
            Text(
              widget.hostAddress,
              style: textTheme.labelSmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Quét lại',
            onPressed: _working || _ended ? null : () => _refresh(manual: true),
            icon: const Icon(Icons.refresh_rounded),
          ),
          if (!_ended)
            IconButton(
              tooltip: 'Kết thúc phiên',
              onPressed: _working ? null : _endSession,
              icon: Icon(Icons.power_settings_new_rounded, color: scheme.error),
            ),
        ],
      ),
      body: Column(
        children: [
          if (_working) const LinearProgressIndicator(minHeight: 2),
          _StatusBar(
            connected: _session.connected && !_ended,
            scannedAt: _clock(_session.scannedAt),
            count: _session.containers.length,
          ),
          if (error != null && !_ended)
            Container(
              width: double.infinity,
              color: scheme.errorContainer,
              padding: const EdgeInsets.all(10),
              child: Text(
                error,
                style: textTheme.bodySmall
                    ?.copyWith(color: scheme.onErrorContainer),
              ),
            ),
          Expanded(
            child: _ended
                ? _EndedView(working: _working, onReopen: _reopen)
                : _buildList(textTheme),
          ),
        ],
      ),
    );
  }

  Widget _buildList(TextTheme textTheme) {
    final groups = _groups();
    final projects = groups.keys.where((k) => k.isNotEmpty).toList()..sort();
    final scheme = context.scheme;

    if (_session.containers.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _session.error.isNotEmpty || _linkError != null
                ? 'Không có dữ liệu. Bấm quét lại sau khi kiểm tra lỗi phía trên.'
                : 'Không có container nào đang chạy.',
            textAlign: TextAlign.center,
            style: textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
      );
    }

    final children = <Widget>[];
    for (final project in projects) {
      final items = groups[project]!;
      children.add(_ProjectHeader(
        project: project,
        count: items.length,
        disabled: _working,
        onRestart: () => _act(
          action: 'restart',
          targets: items,
          title: project,
        ),
        onStop: () => _act(
          action: 'stop',
          targets: items,
          title: project,
        ),
      ));
      for (final c in items) {
        children.add(_ContainerTile(
          container: c,
          onLogs: () => _openLogs(c),
          disabled: _working,
          onRestart: () => _act(
            action: 'restart',
            targets: [c],
            title: c.name,
          ),
          onStop: () => _act(
            action: 'stop',
            targets: [c],
            title: c.name,
          ),
        ));
      }
    }
    final loose = groups[''] ?? const <DockerContainer>[];
    if (loose.isNotEmpty) {
      children.add(_SectionLabel(
        label: 'Không thuộc compose project',
        count: loose.length,
      ));
      for (final c in loose) {
        children.add(_ContainerTile(
          container: c,
          onLogs: () => _openLogs(c),
          disabled: _working,
          onRestart: () => _act(
            action: 'restart',
            targets: [c],
            title: c.name,
          ),
          onStop: () => _act(
            action: 'stop',
            targets: [c],
            title: c.name,
          ),
        ));
      }
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      children: children,
    );
  }
}

class _StatusBar extends StatelessWidget {
  const _StatusBar({
    required this.connected,
    required this.scannedAt,
    required this.count,
  });

  final bool connected;
  final String scannedAt;
  final int count;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final status = context.status;
    final textTheme = Theme.of(context).textTheme;
    final color = connected ? status.success : scheme.error;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: Row(
        children: [
          Icon(Icons.circle, size: 9, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${connected ? 'Đã kết nối' : 'Mất kết nối'} · $count container đang chạy'
              '${scannedAt.isEmpty ? '' : ' · quét lúc $scannedAt'}',
              style: textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

class _EndedView extends StatelessWidget {
  const _EndedView({required this.working, required this.onReopen});

  final bool working;
  final VoidCallback onReopen;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final textTheme = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.link_off_rounded, size: 40, color: scheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(
              'Phiên Docker đã kết thúc.\nCó thể do đóng từ app khác hoặc server đã khởi động lại.',
              textAlign: TextAlign.center,
              style: textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: working ? null : onReopen,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Mở phiên mới'),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.label, required this.count});

  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 14, 4, 6),
      child: Text(
        '$label · $count',
        style: textTheme.labelLarge?.copyWith(
          color: scheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _ProjectHeader extends StatelessWidget {
  const _ProjectHeader({
    required this.project,
    required this.count,
    required this.disabled,
    required this.onRestart,
    required this.onStop,
  });

  final String project;
  final int count;
  final bool disabled;
  final VoidCallback onRestart;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 14, 4, 6),
      child: Row(
        children: [
          Icon(Icons.inventory_2_outlined, size: 18, color: scheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '$project · $count container',
              style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton.icon(
            onPressed: disabled ? null : onRestart,
            icon: const Icon(Icons.restart_alt_rounded, size: 18),
            label: const Text('Khởi động lại'),
          ),
          TextButton.icon(
            onPressed: disabled ? null : onStop,
            style: TextButton.styleFrom(foregroundColor: scheme.error),
            icon: const Icon(Icons.stop_circle_outlined, size: 18),
            label: const Text('Dừng'),
          ),
        ],
      ),
    );
  }
}

class _ContainerTile extends StatelessWidget {
  const _ContainerTile({
    required this.container,
    required this.disabled,
    required this.onLogs,
    required this.onRestart,
    required this.onStop,
  });

  final DockerContainer container;
  final bool disabled;
  final VoidCallback onLogs;
  final VoidCallback onRestart;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final textTheme = Theme.of(context).textTheme;
    final c = container;
    final detail = [
      c.image,
      if (c.status.isNotEmpty) c.status,
    ].where((e) => e.isNotEmpty).join(' · ');
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 4, 8),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      c.service.isNotEmpty ? '${c.name} (${c.service})' : c.name,
                      style: textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      detail,
                      style: textTheme.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (c.ports.isNotEmpty)
                      Text(
                        c.ports,
                        style: textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          fontFamily: 'monospace',
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Xem logs',
                onPressed: onLogs,
                icon: const Icon(Icons.article_outlined),
              ),
              IconButton(
                tooltip: 'Khởi động lại',
                onPressed: disabled ? null : onRestart,
                icon: const Icon(Icons.restart_alt_rounded),
              ),
              IconButton(
                tooltip: 'Dừng',
                onPressed: disabled ? null : onStop,
                icon: Icon(Icons.stop_circle_outlined, color: scheme.error),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Ping định kỳ để server biết app còn xem luồng log
const _logPingEvery = Duration(seconds: 10);
/// Giới hạn số dòng giữ trên màn hình (dòng cũ bị bỏ)
const _maxLogLines = 5000;

final _ansiPattern = RegExp(r'\x1B\[[0-9;?]*[ -/]*[@-~]');

/// Tách timestamp docker (RFC3339 nano, ở đầu dòng) để hiển thị gọn: HH:mm:ss
({String time, String text}) _splitLogLine(String raw) {
  final clean = raw.replaceAll(_ansiPattern, '');
  final sp = clean.indexOf(' ');
  if (sp > 0) {
    final t = DateTime.tryParse(clean.substring(0, sp))?.toLocal();
    if (t != null) {
      String two(int v) => v.toString().padLeft(2, '0');
      return (
        time: '${two(t.hour)}:${two(t.minute)}:${two(t.second)}',
        text: clean.substring(sp + 1),
      );
    }
  }
  return (time: '', text: clean);
}

/// Xem log một container: mở một kênh SSH `docker logs -f` trên server.
/// Thoát màn hình sẽ đóng luồng (và kênh SSH) trên server.
class DockerLogsScreen extends StatefulWidget {
  const DockerLogsScreen({
    super.key,
    required this.sessionId,
    required this.hostName,
    required this.container,
  });
  final String sessionId;
  final String hostName;
  final DockerContainer container;

  @override
  State<DockerLogsScreen> createState() => _DockerLogsScreenState();
}

class _DockerLogsScreenState extends State<DockerLogsScreen> {
  final List<String> _lines = [];
  final ScrollController _scroll = ScrollController();
  StreamSubscription<DockerLogsChunk>? _dataSub;
  StreamSubscription<DockerLogsEnd>? _endSub;
  Timer? _pingTimer;
  /// Lô nhận được trước khi biết streamId (ack của `docker:logs:open` về chậm hơn)
  final List<DockerLogsChunk> _early = [];
  String? _streamId;
  bool _opening = true;
  bool _ended = false;
  bool _follow = true;
  String? _error;
  int? _exitCode;

  @override
  void initState() {
    super.initState();
    _dataSub = AppDependencies.docker.dockerLogsStream.listen(_onChunk);
    _endSub = AppDependencies.docker.dockerLogsEndStream.listen(_onEnd);
    _open();
  }

  @override
  void dispose() {
    _pingTimer?.cancel();
    _dataSub?.cancel();
    _endSub?.cancel();
    // Thoát màn hình: đóng luồng và kênh SSH trên server
    final id = _streamId;
    if (id != null && !_ended) AppDependencies.docker.closeDockerLogs(id);
    super.dispose();
  }

  Future<void> _open() async {
    final res = await AppDependencies.docker.openDockerLogs(
      sessionId: widget.sessionId,
      containerId: widget.container.id,
    );
    if (!mounted) return;
    if (!res.ok) {
      setState(() {
        _opening = false;
        _ended = true;
        _error = res.error.isEmpty ? 'Không mở được log' : res.error;
      });
      return;
    }
    setState(() {
      _opening = false;
      _streamId = res.streamId;
    });
    _pingTimer = Timer.periodic(_logPingEvery, (_) {
      final id = _streamId;
      if (id != null && !_ended) AppDependencies.docker.pingDockerLogs(id);
    });
    // Xử lý lô đã đệm trước khi biết streamId
    for (final chunk in _early) {
      if (chunk.streamId == res.streamId) _append(chunk.lines);
    }
    _early.clear();
  }

  void _onChunk(DockerLogsChunk chunk) {
    if (!mounted) return;
    final id = _streamId;
    if (id == null) {
      _early.add(chunk);
      return;
    }
    if (chunk.streamId == id) _append(chunk.lines);
  }

  void _onEnd(DockerLogsEnd end) {
    if (!mounted) return;
    final id = _streamId;
    if (id == null || end.streamId != id || _ended) return;
    setState(() {
      _ended = true;
      _exitCode = end.exitCode;
    });
    _pingTimer?.cancel();
  }

  void _append(List<String> lines) {
    if (lines.isEmpty) return;
    setState(() {
      _lines.addAll(lines);
      if (_lines.length > _maxLogLines) {
        _lines.removeRange(0, _lines.length - _maxLogLines);
      }
    });
    if (_follow) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scroll.hasClients) return;
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final status = context.status;
    final textTheme = Theme.of(context).textTheme;
    final mono = textTheme.bodySmall?.copyWith(
      fontFamily: 'monospace',
      color: scheme.onSurface,
    );

    final String statusText;
    final Color statusColor;
    if (_opening) {
      statusText = 'Đang mở log…';
      statusColor = scheme.onSurfaceVariant;
    } else if (_error != null) {
      statusText = _error!;
      statusColor = scheme.error;
    } else if (_ended) {
      statusText = _exitCode == null
          ? 'Luồng log đã dừng'
          : 'Luồng log đã dừng (mã thoát $_exitCode)';
      statusColor = scheme.onSurfaceVariant;
    } else {
      statusText = 'Đang xem trực tiếp · ${_lines.length} dòng';
      statusColor = status.success;
    }

    return Scaffold(
      appBar: AppBar(
        backgroundColor: scheme.surface,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Logs · ${widget.container.name}', style: textTheme.titleSmall),
            Text(
              '${widget.hostName} · ${widget.container.image}',
              style: textTheme.labelSmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: _follow ? 'Đang bám theo dòng mới' : 'Bám theo dòng mới',
            onPressed: () => setState(() => _follow = !_follow),
            icon: Icon(
              Icons.vertical_align_bottom_rounded,
              color: _follow ? scheme.primary : null,
            ),
          ),
          IconButton(
            tooltip: 'Xóa màn hình',
            onPressed: () => setState(_lines.clear),
            icon: const Icon(Icons.cleaning_services_outlined),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_opening) const LinearProgressIndicator(minHeight: 2),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
            child: Text(
              statusText,
              style: textTheme.labelMedium?.copyWith(color: statusColor),
            ),
          ),
          Expanded(
            child: Container(
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerLowest,
                borderRadius: BorderRadius.circular(10),
              ),
              child: _lines.isEmpty
                  ? Center(
                      child: Text(
                        _ended || _error != null
                            ? 'Không có dòng log nào.'
                            : 'Chờ dòng log đầu tiên…',
                        style: textTheme.bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    )
                  : ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.all(10),
                      itemCount: _lines.length,
                      itemBuilder: (context, i) {
                        final parts = _splitLogLine(_lines[i]);
                        return Text.rich(
                          TextSpan(
                            style: mono,
                            children: [
                              if (parts.time.isNotEmpty)
                                TextSpan(
                                  text: '${parts.time}  ',
                                  style: TextStyle(
                                      color: scheme.onSurfaceVariant),
                                ),
                              TextSpan(text: parts.text),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
