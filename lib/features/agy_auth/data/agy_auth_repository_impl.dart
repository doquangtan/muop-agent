import 'dart:async';

import 'package:muop_agent/core/network/socket_gateway.dart';
import 'package:muop_agent/features/agy_auth/domain/agy_auth_entities.dart';
import 'package:muop_agent/features/agy_auth/domain/agy_auth_repository.dart';

class AgyAuthRepositoryImpl implements AgyAuthRepository {
  AgyAuthRepositoryImpl(this._gateway);

  final SocketGateway _gateway;

  /// Lệnh start chỉ mở terminal SSH (có thể mất vài giây); các lệnh khác trả về gần như ngay
  static const _commandTimeout = Duration(seconds: 150);

  @override
  Stream<AgyAuthState> get updates =>
      _gateway.on('agy:auth:update').map(_parse);

  @override
  /// Trạng thái trả về ngay; timeout ngắn để thẻ không quay mãi khi socket chưa sẵn sàng
  Future<AgyAuthState> fetchStatus() =>
      _command('agy:auth:status', null, const Duration(seconds: 20));

  @override
  /// Check mở SSH chạy agy và chờ màn hình (tối đa ~40 giây), nên timeout dài hơn status
  Future<AgyAuthState> checkStatus() =>
      _command('agy:auth:check', null, const Duration(seconds: 60));

  @override
  Future<AccountsStatus> fetchAccounts() async {
    try {
      final ack = await _gateway
          .emitWithAck('accounts:status', <String, dynamic>{})
          .timeout(const Duration(seconds: 30));
      final value = ack is List ? ack.first : ack;
      return AccountsStatus.fromJson(Map<String, dynamic>.from(value as Map));
    } catch (_) {
      return AccountsStatus.empty;
    }
  }

  @override
  Future<AgyAuthState> logout() => _command('agy:auth:logout');

  @override
  Future<AgyAuthState> startLogin() => _command('agy:auth:start');

  @override
  Future<AgyAuthState> submitCode(String code) =>
      _command('agy:auth:submit', {'code': code});

  @override
  Future<AgyAuthState> cancelLogin() => _command('agy:auth:cancel');

  Future<AgyAuthState> _command(
    String event, [
    Map<String, dynamic>? data,
    Duration timeout = _commandTimeout,
  ]) async {
    try {
      final ack = await _gateway
          .emitWithAck(event, data ?? <String, dynamic>{})
          .timeout(timeout);
      return _parse(ack);
    } catch (e) {
      return AgyAuthState.failure('Không gọi được server: $e');
    }
  }

  static AgyAuthState _parse(dynamic raw) {
    final value = raw is List ? raw.first : raw;
    return AgyAuthState.fromJson(Map<String, dynamic>.from(value as Map));
  }
}
