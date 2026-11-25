import 'dart:async';
import 'dart:convert';
import 'package:material_ui/material_ui.dart';
import 'package:xterm/xterm.dart';

import 'package:muop_agent/core/di/app_dependencies.dart';
import 'package:muop_agent/core/theme/app_theme.dart';
import 'package:muop_agent/features/ssh/domain/ssh_entities.dart';

/// Terminal SSH tương tác dùng chung: đầu ra từ server được render bằng xterm, phím gõ gửi về PTY trên server.
/// Dùng làm màn hình đầy đủ (`SshTerminalScreen`) hoặc khung nhỏ nhúng trong màn khác (wizard đồng ý điều khoản).
///
/// - Thoát khung chỉ tách khỏi phiên: phiên vẫn chạy trên server và gắn lại được bằng `sessionId`.
/// - Chỉ nút "Kết thúc" đóng phiên. Ctrl+C được gửi vào tiến trình trong terminal (không đóng khung).
class SshTerminalPanel extends StatefulWidget {
  const SshTerminalPanel({
    super.key,
    required this.hostId,
    required this.hostName,
    required this.hostAddress,
    this.sessionId,
    this.height,
    this.hint,
    this.onHide,
    this.onEnded,
    this.onClosed,
    this.onRestart,
    this.initialCommand,
  });

  final int hostId;
  final String hostName;
  final String hostAddress;

  /// Phiên đang chạy trên server cần gắn lại. Null = mở phiên shell mới.
  final String? sessionId;

  /// Chiều cao cố định (khung nhúng). Null = lấp đầy chỗ của widget cha.
  final double? height;

  /// Ghi chú hiển thị phía trên terminal (ví dụ hướng dẫn đồng ý điều khoản)
  final String? hint;

  /// Ẩn khung nhưng không đóng phiên
  final VoidCallback? onHide;

  /// Người dùng bấm "Kết thúc" (phiên đã đóng)
  final VoidCallback? onEnded;

  /// Phiên đóng từ phía server (tiến trình trong terminal đã thoát)
  final VoidCallback? onClosed;

  /// Bấm "Mở lại" khi phiên đã đóng. Null = mở phiên shell mới trên máy.
  final VoidCallback? onRestart;

  /// Lệnh gõ vào shell ngay khi mở phiên mới (không áp dụng khi gắn lại phiên đang chạy)
  final String? initialCommand;

  @override
  State<SshTerminalPanel> createState() => _SshTerminalPanelState();
}

class _SshTerminalPanelState extends State<SshTerminalPanel> {
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
    widget.onEnded?.call();
  }

  void _restart() {
    if (widget.onRestart != null) {
      widget.onRestart!();
      return;
    }
    _attachId = null;
    _open();
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
      final cmd = widget.initialCommand;
      if (cmd != null && cmd.trim().isNotEmpty) {
        // PTY đệm đầu vào nên gửi sớm vẫn được shell đọc khi sẵn sàng
        AppDependencies.ssh.sendSshInput(sid, utf8.encode('${cmd.trimRight()}\r'));
      }
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
    widget.onClosed?.call();
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
    final hint = widget.hint;

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          color: scheme.surface,
          padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.hostName,
                  style: textTheme.labelLarge,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (_closed && !_opening)
                TextButton.icon(
                  onPressed: _restart,
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: const Text('Mở lại'),
                ),
              if (!_closed && _sessionId != null)
                IconButton(
                  tooltip: 'Kết thúc phiên',
                  icon: Icon(Icons.power_settings_new_rounded, color: scheme.error),
                  onPressed: _endSession,
                ),
              if (widget.onHide != null)
                IconButton(
                  tooltip: 'Thu gọn (phiên vẫn chạy)',
                  icon: const Icon(Icons.expand_more_rounded),
                  onPressed: widget.onHide,
                ),
            ],
          ),
        ),
        if (hint != null)
          Container(
            width: double.infinity,
            color: scheme.surfaceContainerHighest,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Text(
              hint,
              style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        if (_opening) const LinearProgressIndicator(minHeight: 2),
        if (_error != null)
          Container(
            width: double.infinity,
            color: scheme.errorContainer,
            padding: const EdgeInsets.all(10),
            child: Text(
              _error!,
              style: textTheme.bodySmall?.copyWith(color: scheme.onErrorContainer),
            ),
          ),
        Expanded(child: _terminalView()),
        _keyBar(scheme),
      ],
    );

    final framed = widget.height == null
        ? content
        : SizedBox(height: widget.height, child: content);
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.height == null ? 0 : 10),
      child: ColoredBox(color: TerminalThemes.defaultTheme.background, child: framed),
    );
  }

  Widget _terminalView() => TerminalView(
        _terminal,
        autofocus: true,
        theme: TerminalThemes.defaultTheme,
      );

  /// Phím điều hướng và phím điều khiển không có trên bàn phím điện thoại (mũi tên, Esc, Tab, Ctrl+C).
  /// Gửi qua `keyInput` của terminal nên đi tới server đúng như phím thật.
  static const _keyBarItems = <(String, TerminalKey, bool)>[
    ('Esc', TerminalKey.escape, false),
    ('Tab', TerminalKey.tab, false),
    ('Ctrl+C', TerminalKey.keyC, true),
    ('↑', TerminalKey.arrowUp, false),
    ('↓', TerminalKey.arrowDown, false),
    ('←', TerminalKey.arrowLeft, false),
    ('→', TerminalKey.arrowRight, false),
    ('Enter', TerminalKey.enter, false),
  ];

  Widget _keyBar(ColorScheme scheme) {
    final enabled = _sessionId != null && !_closed;
    return Container(
      color: scheme.surfaceContainerHigh,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final (label, key, ctrl) in _keyBarItems)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                // Không nhận focus: bấm phím không làm mất bàn phím ảo đang mở
                child: Focus(
                  canRequestFocus: false,
                  child: OutlinedButton(
                    onPressed: enabled ? () => _terminal.keyInput(key, ctrl: ctrl) : null,
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(44, 36),
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                    ),
                    child: Text(label, style: const TextStyle(fontFamily: 'monospace')),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
