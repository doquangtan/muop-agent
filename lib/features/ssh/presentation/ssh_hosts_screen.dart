import 'package:material_ui/material_ui.dart';

import 'package:muop_agent/core/di/app_dependencies.dart';
import 'package:muop_agent/core/theme/app_theme.dart';
import 'package:muop_agent/core/widgets/desktop_panel.dart';
import 'package:muop_agent/features/ssh/domain/ssh_entities.dart';
import 'package:muop_agent/features/ssh/presentation/ssh_terminal_screen.dart';

/// Màn hình quản lý các máy SSH đã lưu (lưu trên Rust Server).
/// Mật khẩu và private key được gửi lên server và không bao giờ trả về client.
class SshHostsScreen extends StatefulWidget {
  const SshHostsScreen({
    super.key,
    required this.serverAddress,
  });
  final String serverAddress;

  @override
  State<SshHostsScreen> createState() => _SshHostsScreenState();
}

class _SshHostsScreenState extends State<SshHostsScreen> {
  List<SshHost> _hosts = const [];
  /// Phiên terminal đang chạy trên server
  List<SshTerminalSession> _sessions = const [];
  bool _loading = true;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    // Chỉ hiện spinner toàn màn hình khi chưa có dữ liệu; làm mới thì giữ danh sách
    setState(() {
      _loading = _hosts.isEmpty;
      _loadError = null;
    });
    try {
      // Hai yêu cầu REST chạy song song; phiên đang chạy lỗi thì vẫn hiện danh sách máy
      final results = await Future.wait([
        AppDependencies.ssh.fetchSshHosts(widget.serverAddress),
        AppDependencies.ssh.listSshTerminalSessions(widget.serverAddress),
      ]);
      if (!mounted) return;
      setState(() {
        _hosts = results[0] as List<SshHost>;
        _sessions = results[1] as List<SshTerminalSession>;
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

  Future<void> _openForm([SshHost? host]) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _SshHostForm(
        serverAddress: widget.serverAddress,
        host: host,
      ),
    );
    if (saved == true) _reload();
  }

  SshTerminalSession? _runningSessionFor(SshHost host) {
    for (final s in _sessions) {
      if (s.hostId == host.id) return s;
    }
    return null;
  }

  /// Mở terminal của máy. Nếu máy đang có phiên chạy (trên server, có thể do máy khác mở)
  /// thì gắn vào phiên đó để mọi máy cùng xem một màn hình. Chỉ mở phiên mới khi [forceNew].
  Future<void> _openTerminal(SshHost host, {bool forceNew = false}) async {
    String? attachId;
    if (!forceNew) {
      // Tải lại danh sách phiên ngay trước khi quyết định, tránh dùng dữ liệu cũ
      final sessions = await AppDependencies.ssh.listSshTerminalSessions(
        widget.serverAddress,
      );
      if (!mounted) return;
      setState(() => _sessions = sessions);
      final running = sessions.where((s) => s.hostId == host.id).toList();
      if (running.isNotEmpty) attachId = running.first.sessionId;
    }
    if (!mounted) return;
    await openPanelPage(
      context,
      SshTerminalScreen(
          hostId: host.id,
          hostName: host.name,
          hostAddress: host.address,
          sessionId: attachId,
        ),
    );
    if (mounted) _reload();
  }

  Future<void> _openExec(SshHost host) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _SshExecSheet(
        serverAddress: widget.serverAddress,
        host: host,
      ),
    );
  }

  Future<void> _confirmDelete(SshHost host) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Xóa máy SSH?'),
        content: Text('Xóa "${host.name}" (${host.address}) khỏi server.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Hủy'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Xóa'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final deleted =
        await AppDependencies.ssh.deleteSshHost(widget.serverAddress, host.id);
    if (!mounted) return;
    if (!deleted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Không xóa được máy SSH')),
      );
    }
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Máy SSH'),
        actions: [
          IconButton(
            tooltip: 'Tải lại',
            onPressed: _loading ? null : _reload,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openForm(),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Thêm máy'),
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
                        'Chưa có máy SSH nào.\nBấm "Thêm máy" để lưu máy đầu tiên.',
                        textAlign: TextAlign.center,
                        style: textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
                      itemCount: _hosts.length,
                      separatorBuilder: (context, index) => const SizedBox(height: 8),
                      itemBuilder: (context, i) {
                        final host = _hosts[i];
                        final isKey = host.authType == 'key';
                        return Material(
                          color: scheme.surfaceContainerLow,
                          borderRadius: BorderRadius.circular(12),
                          child: ListTile(
                            onTap: () => _openTerminal(host),
                            onLongPress: () => _openTerminal(host, forceNew: true),
                            leading: CircleAvatar(
                              backgroundColor: scheme.primaryContainer,
                              child: Icon(
                                isKey
                                    ? Icons.vpn_key_rounded
                                    : Icons.password_rounded,
                                size: 18,
                                color: scheme.onPrimaryContainer,
                              ),
                            ),
                            title: Text(host.name,
                                style: textTheme.titleSmall
                                    ?.copyWith(fontWeight: FontWeight.w600)),
                            subtitle: Text(
                              '${host.address} · ${isKey ? 'SSH key' : 'mật khẩu'}'
                              '${_runningSessionFor(host) != null ? ' · đang có phiên chạy' : ''}',
                              style: textTheme.bodySmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  tooltip: 'Chạy lệnh',
                                  icon: const Icon(Icons.bolt_rounded),
                                  onPressed: () => _openExec(host),
                                ),
                                IconButton(
                                  tooltip: 'Sửa',
                                  icon: const Icon(Icons.edit_outlined),
                                  onPressed: () => _openForm(host),
                                ),
                                IconButton(
                                  tooltip: 'Xóa',
                                  icon: Icon(Icons.delete_outline_rounded,
                                      color: scheme.error),
                                  onPressed: () => _confirmDelete(host),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
    );
  }
}

/// Form thêm/sửa máy SSH
class _SshHostForm extends StatefulWidget {
  const _SshHostForm({
    required this.serverAddress,
    this.host,
  });
  final String serverAddress;
  final SshHost? host;

  @override
  State<_SshHostForm> createState() => _SshHostFormState();
}

class _SshHostFormState extends State<_SshHostForm> {
  late final TextEditingController _name;
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _user;
  final _password = TextEditingController();
  final _privateKey = TextEditingController();
  late String _authType;
  bool _obscure = true;
  bool _saving = false;
  String? _error;

  bool get _editing => widget.host != null;

  @override
  void initState() {
    super.initState();
    final h = widget.host;
    _name = TextEditingController(text: h?.name ?? '');
    _host = TextEditingController(text: h?.host ?? '');
    _port = TextEditingController(text: '${h?.port ?? 22}');
    _user = TextEditingController(text: h?.username ?? '');
    _authType = h?.authType ?? 'password';
  }

  @override
  void dispose() {
    super.dispose();
  }

  Future<void> _save() async {
    final port = int.tryParse(_port.text.trim());
    if (port == null || port < 1 || port > 65535) {
      setState(() => _error = 'Port phải từ 1 đến 65535');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final err = await AppDependencies.ssh.saveSshHost(
      widget.serverAddress,
      id: widget.host?.id ?? 0,
      name: _name.text.trim(),
      host: _host.text.trim(),
      port: port,
      username: _user.text.trim(),
      authType: _authType,
      password: _authType == 'password' ? _password.text : '',
      privateKey: _authType == 'key' ? _privateKey.text : '',
    );
    if (!mounted) return;
    if (err == null) {
      Navigator.pop(context, true);
    } else {
      setState(() {
        _saving = false;
        _error = err;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final textTheme = Theme.of(context).textTheme;
    final keyHint = _editing && (widget.host?.hasKey ?? false)
        ? 'Để trống = giữ key đã lưu'
        : null;
    final passHint = _editing && (widget.host?.hasPassword ?? false)
        ? 'Để trống = giữ mật khẩu đã lưu'
        : null;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        16,
        16,
        16 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              _editing ? 'Sửa máy SSH' : 'Thêm máy SSH',
              style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: 'Tên hiển thị',
                hintText: 'Mặc định là địa chỉ host',
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: _host,
                    decoration: const InputDecoration(
                      labelText: 'IP / Host',
                      hintText: '192.168.1.10',
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _port,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Port'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _user,
              decoration: const InputDecoration(labelText: 'Username'),
            ),
            const SizedBox(height: 14),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(
                  value: 'password',
                  icon: Icon(Icons.password_rounded),
                  label: Text('Mật khẩu'),
                ),
                ButtonSegment(
                  value: 'key',
                  icon: Icon(Icons.vpn_key_rounded),
                  label: Text('SSH key'),
                ),
              ],
              selected: {_authType},
              onSelectionChanged: (s) => setState(() => _authType = s.first),
            ),
            const SizedBox(height: 12),
            if (_authType == 'password')
              TextField(
                controller: _password,
                obscureText: _obscure,
                decoration: InputDecoration(
                  labelText: 'Mật khẩu',
                  helperText: passHint,
                  suffixIcon: IconButton(
                    icon: Icon(_obscure
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
              )
            else
              TextField(
                controller: _privateKey,
                minLines: 4,
                maxLines: 8,
                style: textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
                decoration: InputDecoration(
                  labelText: 'Private key',
                  hintText: '-----BEGIN OPENSSH PRIVATE KEY-----',
                  helperText: keyHint,
                  alignLabelWithHint: true,
                ),
              ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!, style: TextStyle(color: scheme.error)),
            ],
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _saving ? null : () => Navigator.pop(context),
                  child: const Text('Hủy'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _saving ? null : _save,
                  child: _saving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Lưu'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Panel chạy lệnh trên một máy SSH. Kết quả hiển thị ngay dưới ô lệnh.
class _SshExecSheet extends StatefulWidget {
  const _SshExecSheet({
    required this.serverAddress,
    required this.host,
  });
  final String serverAddress;
  final SshHost host;

  @override
  State<_SshExecSheet> createState() => _SshExecSheetState();
}

class _SshExecSheetState extends State<_SshExecSheet> {
  final _command = TextEditingController();
  bool _running = false;
  SshExecResult? _result;

  @override
  void dispose() {
    super.dispose();
  }

  Future<void> _run() async {
    final cmd = _command.text.trim();
    if (cmd.isEmpty || _running) return;
    setState(() {
      _running = true;
      _result = null;
    });
    final res = await AppDependencies.ssh.execSshCommand(
      widget.serverAddress,
      hostId: widget.host.id,
      command: cmd,
    );
    if (!mounted) return;
    setState(() {
      _running = false;
      _result = res;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final textTheme = Theme.of(context).textTheme;
    final res = _result;
    final mono = textTheme.bodySmall?.copyWith(
      fontFamily: 'monospace',
      color: scheme.onSurface,
    );

    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        16,
        16,
        16 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.host.name,
            style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          Text(
            widget.host.address,
            style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _command,
                  enabled: !_running,
                  style: mono,
                  onSubmitted: (_) => _run(),
                  decoration: const InputDecoration(
                    labelText: 'Lệnh',
                    hintText: 'uptime',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _running ? null : _run,
                child: _running
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Chạy'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (res != null) ...[
            Text(
              res.ok
                  ? 'Thành công (exit ${res.exitCode ?? 0})'
                  : (res.error.isNotEmpty ? res.error : 'Lỗi'),
              style: textTheme.labelMedium?.copyWith(
                color: res.ok ? context.status.success : scheme.error,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Container(
              constraints: const BoxConstraints(maxHeight: 320),
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withAlpha(140),
                borderRadius: BorderRadius.circular(10),
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  [
                    if (res.stdout.isNotEmpty) res.stdout,
                    if (res.stderr.isNotEmpty) res.stderr,
                    if (res.stdout.isEmpty && res.stderr.isEmpty)
                      '(không có đầu ra)',
                  ].join('\n'),
                  style: mono,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
