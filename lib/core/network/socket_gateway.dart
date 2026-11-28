import 'dart:async';
import 'package:socket_io_client/socket_io_client.dart' as io;

/// Thời gian tối đa chờ ack của một lệnh socket. Nếu socket đứt giữa chừng,
/// ack sẽ không bao giờ tới, nên phải có giới hạn để giao diện không quay mãi.
const Duration sshAckTimeout = Duration(seconds: 10);

/// Kết nối Socket.IO duy nhất tới Rust Server.
/// Các feature đăng ký event qua [on]; gateway không biết nghiệp vụ của từng event.
class SocketGateway {
  io.Socket? _socket;
  String _connectedBaseUrl = '';
  bool _connected = false;

  final StreamController<bool> _statusController =
      StreamController<bool>.broadcast();
  /// Phát khi vừa kết nối, hoặc khi được yêu cầu đồng bộ lại trên kết nối đang có
  final StreamController<void> _connectController =
      StreamController<void>.broadcast();
  final Map<String, StreamController<dynamic>> _events = {};

  String get connectedBaseUrl => _connectedBaseUrl;
  bool get connected => _connected;
  Stream<bool> get statusStream => _statusController.stream;
  Stream<void> get connectEvents => _connectController.stream;

  /// Luồng dữ liệu của một event Socket.IO (đăng ký trước hoặc sau khi kết nối đều được)
  Stream<dynamic> on(String event) {
    final existing = _events[event];
    if (existing != null) return existing.stream;
    final controller = StreamController<dynamic>.broadcast();
    _events[event] = controller;
    _attach(event);
    return controller.stream;
  }

  void _attach(String event) {
    final socket = _socket;
    if (socket == null) return;
    socket.on(event, (data) {
      final controller = _events[event];
      if (controller != null && !controller.isClosed) controller.add(data);
    });
  }

  /// Kết nối tới [baseUrl]. Nếu đã kết nối tới cùng địa chỉ thì chỉ yêu cầu đồng bộ lại.
  void connect(String baseUrl) {
    final existing = _socket;
    if (existing != null && _connectedBaseUrl == baseUrl) {
      if (!existing.connected) {
        existing.connect();
      } else {
        _connectController.add(null);
      }
      return;
    }

    disconnect();
    _connectedBaseUrl = baseUrl;

    final socket = io.io(
      baseUrl,
      io.OptionBuilder()
          // Chỉ WebSocket: không dùng long-polling (transport=polling). Server hỗ trợ WebSocket cho mọi client
          .setTransports(['websocket'])
          .enableAutoConnect()
          .enableReconnection()
          .setReconnectionDelay(1000)
          .setReconnectionDelayMax(3500)
          .build(),
    );
    _socket = socket;

    socket.onConnect((_) {
      _connected = true;
      _emitStatus(true);
      _connectController.add(null);
    });
    socket.onDisconnect((_) {
      _connected = false;
      _emitStatus(false);
    });
    socket.onConnectError((_) {
      _connected = false;
      _emitStatus(false);
    });

    for (final event in _events.keys) {
      _attach(event);
    }
    socket.connect();
  }

  void _emitStatus(bool connected) {
    if (!_statusController.isClosed) _statusController.add(connected);
  }

  /// Gửi event tới server (không kèm đối số nếu [data] là null)
  void emit(String event, [dynamic data]) {
    final socket = _socket;
    if (socket == null || !socket.connected) return;
    if (data == null) {
      socket.emit(event);
    } else {
      socket.emit(event, data);
    }
  }

  /// Gửi event và chờ ack. Ném lỗi nếu chưa kết nối.
  Future<dynamic> emitWithAck(String event, dynamic data) {
    final socket = _socket;
    if (socket == null || !socket.connected) {
      return Future.error('Chưa kết nối tới server');
    }
    return socket.emitWithAckAsync(event, data);
  }

  void disconnect() {
    _connected = false;
    try {
      _socket?.dispose();
    } catch (_) {}
    _socket = null;
    _connectedBaseUrl = '';
  }
}
