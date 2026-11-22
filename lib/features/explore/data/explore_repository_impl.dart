import 'dart:async';

import 'package:muop_agent/core/network/socket_gateway.dart';
import 'package:muop_agent/features/explore/domain/explore_repository.dart';

/// Đếm số UI đang xem từng thư mục ở phía client. Chỉ gửi `explore:watch` khi có người xem đầu tiên
/// và `explore:unwatch` khi hết người xem, nên nhiều explorer trong cùng app không tranh nhau.
/// Khi socket kết nối lại, server đã quên các room, nên đăng ký lại mọi thư mục đang xem.
class ExploreRepositoryImpl implements ExploreRepository {
  ExploreRepositoryImpl(this._gateway) {
    _gateway.on('explore:update').listen((data) {
      final room = _asMap(data)['room'];
      if (room is String && room.isNotEmpty && !_changed.isClosed) {
        _changed.add(room);
      }
    });
    _gateway.connectEvents.listen((_) => _resyncAll());
    _gateway.statusStream.listen((connected) {
      if (!connected) _rooms.clear();
    });
  }

  final SocketGateway _gateway;

  /// Số UI đang xem từng thư mục
  final Map<String, int> _refs = {};

  /// Room của từng thư mục sau khi server nhận yêu cầu
  final Map<String, String> _rooms = {};

  final StreamController<String> _changed = StreamController<String>.broadcast();

  @override
  Stream<String> get changedRooms => _changed.stream;

  @override
  String? roomOf(String path) => _rooms[path];

  @override
  void watch(String path) {
    final count = _refs[path] ?? 0;
    _refs[path] = count + 1;
    if (count == 0) _send(path);
  }

  @override
  void unwatch(String path) {
    final count = _refs[path] ?? 0;
    if (count <= 1) {
      _refs.remove(path);
      final room = _rooms.remove(path);
      if (room != null) _gateway.emit('explore:unwatch', {'room': room});
    } else {
      _refs[path] = count - 1;
    }
  }

  Future<void> _send(String path) async {
    if (!_gateway.connected) return;
    try {
      final ack = await _gateway
          .emitWithAck('explore:watch', {'path': path})
          .timeout(sshAckTimeout);
      final map = _asMap(ack);
      final room = map['room'];
      if (map['ok'] != true || room is! String || room.isEmpty) return;
      if ((_refs[path] ?? 0) == 0) {
        // Đã có người bỏ xem trong lúc chờ ack: gỡ room ngay
        _gateway.emit('explore:unwatch', {'room': room});
        return;
      }
      _rooms[path] = room;
    } catch (_) {
      // Mất kết nối hoặc hết thời gian chờ: sẽ đăng ký lại khi kết nối lại
    }
  }

  void _resyncAll() {
    _rooms.clear();
    for (final path in _refs.keys.toList()) {
      _send(path);
    }
  }

  Map<String, dynamic> _asMap(dynamic data) {
    if (data is Map) return Map<String, dynamic>.from(data);
    if (data is List && data.isNotEmpty && data.first is Map) {
      return Map<String, dynamic>.from(data.first as Map);
    }
    return const {};
  }
}
