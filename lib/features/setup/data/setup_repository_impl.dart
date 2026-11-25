import 'dart:async';

import 'package:muop_agent/core/network/socket_gateway.dart';
import 'package:muop_agent/features/setup/domain/setup_entities.dart';
import 'package:muop_agent/features/setup/domain/setup_repository.dart';

class SetupRepositoryImpl implements SetupRepository {
  SetupRepositoryImpl(this._gateway);

  final SocketGateway _gateway;

  /// Lệnh cài đặt chỉ trả về sau khi job được tạo, không chờ cài xong
  static const _commandTimeout = Duration(seconds: 20);

  @override
  Stream<SetupStatus> get updates => _gateway.on('setup:update').map(_parse);

  @override
  Future<SetupStatus> fetchStatus() => _command('setup:status');

  @override
  Future<SetupStatus> install(String tool) =>
      _command('setup:install', {'tool': tool});

  @override
  Future<SetupStatus> selectClis(List<String> clis) =>
      _command('setup:select', {'clis': clis});

  @override
  Future<SetupStatus> complete() => _command('setup:complete');

  @override
  Future<SetupStatus> setWorkspace(String path) =>
      _command('setup:workspace', {'path': path});

  @override
  Future<SetupDirListing> browseDirectories(String path) async {
    try {
      final ack = await _gateway
          .emitWithAck('setup:browse', {'path': path})
          .timeout(_commandTimeout);
      final value = ack is List ? ack.first : ack;
      return SetupDirListing.fromJson(Map<String, dynamic>.from(value as Map));
    } catch (e) {
      return SetupDirListing.failure('Không gọi được server: $e');
    }
  }

  @override
  Future<SetupStatus> setToolPath(String tool, String path) =>
      _command('setup:tool-path', {'tool': tool, 'path': path});

  @override
  Future<SetupStatus> configureSsh(String username) =>
      _command('setup:ssh:configure', {'username': username});

  @override
  Future<SetupStatus> autoSetupSsh() => _command('setup:ssh:auto');

  @override
  Future<SetupStatus> verifySsh(String publicKey) =>
      _command('setup:ssh:verify', {'publicKey': publicKey});

  Future<SetupStatus> _command(String event, [Map<String, dynamic>? data]) async {
    try {
      final ack = await _gateway
          .emitWithAck(event, data ?? <String, dynamic>{})
          .timeout(_commandTimeout);
      return _parse(ack);
    } catch (e) {
      return SetupStatus.failure('Không gọi được server: $e');
    }
  }

  static SetupStatus _parse(dynamic raw) {
    final value = raw is List ? raw.first : raw;
    return SetupStatus.fromJson(Map<String, dynamic>.from(value as Map));
  }
}
