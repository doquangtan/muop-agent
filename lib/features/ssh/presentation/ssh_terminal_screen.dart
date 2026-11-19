import 'dart:async';
import 'dart:convert';
import 'package:material_ui/material_ui.dart';
import 'package:xterm/xterm.dart';

import 'package:muop_agent/core/widgets/desktop_panel.dart';
import 'package:muop_agent/core/di/app_dependencies.dart';
import 'package:muop_agent/core/theme/app_theme.dart';
import 'package:muop_agent/features/ssh/domain/ssh_entities.dart';

/// Terminal SSH tương tác: đầu ra từ server được render bằng xterm, phím gõ được gửi về PTY trên server.
class SshTerminalScreen extends StatefulWidget {
  const SshTerminalScreen({
    super.key,
    required this.hostId,
    required this.hostName,
    required this.hostAddress,
    this.sessionId,
  });
  final int hostId;
  final String hostName;
  final String hostAddress;
  /// Phiên đang chạy trên server cần gắn lại. Null = mở phiên mới.
  final String? sessionId;

  @override
  State<SshTerminalScreen> createState() => _SshTerminalScreenState();
}

class _SshTerminalScreenState extends State<SshTerminalScreen> {
  final Terminal _terminal = Terminal(maxLines: 5000);
  final List<int> _utf8Pending = [];

  StreamSubscription<SshTerminalData>? _dataSub;
  StreamSubscription<SshTerminalClosed>? _closedSub;

  String? _sessionId;
  /// Phiên sẽ gắn vào ở lần mở tiếp theo (null = mở phiên mới)
  String? _attachId;
  /// Sự kiện nhận được trước khi biết sessionId (ack `ssh:open` về chậm hơn đầu ra)
  final List<Object> _early = [];
  bool _opening = true;
  bool _closed = false;
  String? _error;
  int _cols = 100;
  int _rows = 30;

  @override
  void initState() {
    super.initState();
    _attachId = widget.sessionId;
    _dataSub = AppDependencies.ssh.sshDataStream.listen(_onData);
    _closedSub = AppDependencies.ssh.sshClosedStream.listen(_onClosed);
    _terminal.onOutput = (text) {
      final sid = _sessionId;
      if (sid != null && !_closed) {
        AppDependencies.ssh.sendSshInput(sid, utf8.encode(text));
      }
    };
    _terminal.onResize = (w, h, pixelWidth, pixelHeight) {
      _cols = w;
      _rows = h;
      final sid = _sessionId;
      if (sid != null && !_closed) {
        AppDependencies.ssh.resizeSshTerminal(sid, w, h);
      }
    };
    _open();
  }

  /// Thoát màn hình chỉ tách khỏi phiên: phiên vẫn chạy trên server và được gắn lại sau này.
  /// Chỉ nút "Kết thúc phiên" mới đóng phiên.
  @override
  void dispose() {
    _dataSub?.cancel();
    _closedSub?.cancel();
    super.dispose();
  }

  Future<void> _endSession() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Kết thúc phiên SSH?'),
        content: const Text('Tiến trình đang chạy trên máy sẽ bị ngắt.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Hủy'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Kết thúc'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final sid = _sessionId;
    if (sid != null) AppDependencies.ssh.closeSshTerminal(sid);
    if (mounted) closePanelPage(context);
  }

  Future<void> _open() async {
    setState(() {
      _opening = true;
      _closed = false;
      _error = null;
      _sessionId = null;
      _early.clear();
      _utf8Pending.clear();
    });
    final attachId = _attachId;
    final String sid;
    if (attachId != null) {
      final att = await AppDependencies.ssh.attachSshTerminal(attachId);
      if (!mounted) return;
      if (!att.ok) {
        setState(() {
          _opening = false;
          _closed = true;
          _error = att.error.isEmpty ? 'Phiên đã kết thúc' : att.error;
        });
        return;
      }
      // Vẽ lại màn hình từ đầu ra đã đệm trên server
      _writeBytes(att.buffer);
      sid = att.sessionId;
    } else {
      final res = await AppDependencies.ssh.openSshTerminal(
        widget.hostId,
        cols: _cols,
        rows: _rows,
      );
      if (!mounted) return;
      if (!res.ok) {
        setState(() {
          _opening = false;
          _closed = true;
          _error = res.error.isEmpty ? 'Không mở được phiên SSH' : res.error;
        });
        return;
      }
      sid = res.sessionId;
    }
    setState(() {
      _sessionId = sid;
      _opening = false;
    });
    // Đồng bộ kích thước hiện tại và xử lý các sự kiện đã đệm
    AppDependencies.ssh.resizeSshTerminal(sid, _cols, _rows);
    for (final ev in _early) {
      if (ev is SshTerminalData && ev.sessionId == sid) {
        _writeBytes(ev.bytes);
      } else if (ev is SshTerminalClosed && ev.sessionId == sid) {
        _onClosed(ev);
      }
    }
    _early.clear();
  }

  void _onData(SshTerminalData data) {
    if (!mounted) return;
    final sid = _sessionId;
    if (sid == null) {
      _early.add(data);
      return;
    }
    if (data.sessionId == sid) _writeBytes(data.bytes);
  }

  void _onClosed(SshTerminalClosed ev) {
    if (!mounted) return;
    final sid = _sessionId;
    if (sid == null) {
      _early.add(ev);
      return;
    }
    if (ev.sessionId != sid || _closed) return;
    setState(() => _closed = true);
    final code = ev.exitCode;
    _terminal.write(
      '\r\n\x1b[2m[phiên SSH đã kết thúc${code != null ? ', mã thoát $code' : ''}]\x1b[0m\r\n',
    );
  }

  /// Ghi byte vào terminal, giữ lại các byte UTF-8 chưa đủ ký tự để ghép với chunk sau
  void _writeBytes(List<int> bytes) {
    _utf8Pending.addAll(bytes);
    final cut = _completeUtf8Length(_utf8Pending);
    if (cut == 0) return;
    final text = utf8.decode(_utf8Pending.sublist(0, cut), allowMalformed: true);
    _utf8Pending.removeRange(0, cut);
    _terminal.write(text);
  }

  /// Độ dài phần đầu của danh sách byte đã đủ ký tự UTF-8 (cắt trước ký tự đang dở)
  static int _completeUtf8Length(List<int> bytes) {
    var i = bytes.length - 1;
    var back = 0;
    while (i >= 0 && back < 4) {
      final b = bytes[i];
      if (b & 0xC0 != 0x80) {
        // b là byte đầu của một ký tự
        final need = b >= 0xF0
            ? 4
            : b >= 0xE0
                ? 3
                : b >= 0xC0
                    ? 2
                    : 1;
        return (bytes.length - i) >= need ? bytes.length : i;
      }
      i--;
      back++;
    }
    return bytes.length;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      backgroundColor: TerminalThemes.defaultTheme.background,
      appBar: AppBar(
        backgroundColor: scheme.surface,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.hostName, style: textTheme.titleSmall),
            Text(
              widget.hostAddress,
              style: textTheme.labelSmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
        actions: [
          if (_closed && !_opening)
            IconButton(
              tooltip: 'Mở phiên mới',
              icon: const Icon(Icons.refresh_rounded),
              onPressed: () {
                _attachId = null;
                _open();
              },
            ),
          if (!_closed && _sessionId != null)
            IconButton(
              tooltip: 'Kết thúc phiên',
              icon: Icon(Icons.power_settings_new_rounded,
                  color: scheme.error),
              onPressed: _endSession,
            ),
        ],
      ),
      body: Column(
        children: [
          if (_opening)
            const LinearProgressIndicator(minHeight: 2),
          if (_error != null)
            Container(
              width: double.infinity,
              color: scheme.errorContainer,
              padding: const EdgeInsets.all(10),
              child: Text(
                _error!,
                style: textTheme.bodySmall
                    ?.copyWith(color: scheme.onErrorContainer),
              ),
            ),
          Expanded(
            child: TerminalView(
              _terminal,
              autofocus: true,
              theme: TerminalThemes.defaultTheme,
            ),
          ),
        ],
      ),
    );
  }
}
