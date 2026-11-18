import 'dart:async';

import 'package:muop_agent/features/ssh/domain/ssh_entities.dart';

/// Interface (domain) của feature ssh. Presentation chỉ phụ thuộc interface này.
abstract class SshRepository {
  Stream<SshTerminalData> get sshDataStream;

  Stream<SshTerminalClosed> get sshClosedStream;

  Future<List<SshHost>> fetchSshHosts(String address);

  Future<String?> saveSshHost(
    String address, {
    required int id,
    required String name,
    required String host,
    required int port,
    required String username,
    required String authType,
    required String password,
    required String privateKey,
  });

  Future<bool> deleteSshHost(String address, int id);

  Future<SshExecResult> execSshCommand(
    String address, {
    required int hostId,
    required String command,
    int timeoutSecs = 30,
  });

  Future<SshTerminalOpenResult> openSshTerminal(
    int hostId, {
    int cols = 100,
    int rows = 30,
  });

  Future<List<SshTerminalSession>> listSshTerminalSessions(
    String address,
  );

  Future<SshTerminalAttachResult> attachSshTerminal(String sessionId);

  void sendSshInput(String sessionId, List<int> bytes);

  void resizeSshTerminal(String sessionId, int cols, int rows);

  void closeSshTerminal(String sessionId);
}
