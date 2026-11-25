import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

/// Các phím của thanh phím trong terminal SSH phải sinh đúng chuỗi điều khiển mà shell trên server đọc.
String _sequence(TerminalKey key, {bool ctrl = false}) {
  final out = StringBuffer();
  final terminal = Terminal();
  terminal.onOutput = out.write;
  terminal.keyInput(key, ctrl: ctrl);
  return out.toString();
}

void main() {
  test('mũi tên gửi chuỗi ESC chuẩn', () {
    expect(_sequence(TerminalKey.arrowUp), '\x1b[A');
    expect(_sequence(TerminalKey.arrowDown), '\x1b[B');
    expect(_sequence(TerminalKey.arrowRight), '\x1b[C');
    expect(_sequence(TerminalKey.arrowLeft), '\x1b[D');
  });

  test('Esc, Tab, Enter và Ctrl+C gửi đúng byte', () {
    expect(_sequence(TerminalKey.escape), '\x1b');
    expect(_sequence(TerminalKey.tab), '\t');
    expect(_sequence(TerminalKey.enter), '\r');
    expect(_sequence(TerminalKey.keyC, ctrl: true), '\x03');
  });
}
