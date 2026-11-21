import 'dart:async';

import 'package:muop_agent/core/network/socket_gateway.dart';
import 'package:muop_agent/features/claude_auth/domain/claude_auth_entities.dart';
import 'package:muop_agent/features/claude_auth/domain/claude_auth_repository.dart';

class ClaudeAuthRepositoryImpl implements ClaudeAuthRepository {
  ClaudeAuthRepositoryImpl(this._gateway);

  final SocketGateway _gateway;

  static const _commandTimeout = Duration(seconds: 150);

  @override
  Stream<ClaudeAuthState> get updates =>
      _gateway.on('claude:auth:update').map(_parse);

  @override
  Future<ClaudeAuthState> fetchStatus() => _command('claude:auth:status');

  @override
  Future<ClaudeAuthState> logout() => _command('claude:auth:logout');

  @override
  Future<ClaudeAuthState> startLogin() => _command('claude:auth:start');

  @override
  Future<ClaudeAuthState> submitCode(String code) =>
      _command('claude:auth:submit', {'code': code});

  @override
  Future<ClaudeAuthState> cancelLogin() => _command('claude:auth:cancel');

  Future<ClaudeAuthState> _command(String event,
      [Map<String, dynamic>? data]) async {
    try {
      final ack = await _gateway
          .emitWithAck(event, data ?? <String, dynamic>{})
          .timeout(_commandTimeout);
      return _parse(ack);
    } catch (e) {
      return ClaudeAuthState.failure('Không gọi được server: $e');
    }
  }

  static ClaudeAuthState _parse(dynamic raw) {
    final value = raw is List ? raw.first : raw;
    return ClaudeAuthState.fromJson(Map<String, dynamic>.from(value as Map));
  }
}
