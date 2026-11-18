import 'dart:async';

import 'package:muop_agent/features/connection/domain/connection_entities.dart';

/// Interface (domain) của feature connection. Presentation chỉ phụ thuộc interface này.
abstract class ConnectionRepository {
  Future<String> loadSavedServerAddress();

  Future<void> saveServerAddress(String address);

  Future<RemotePingResult> pingRemoteServer(String address);

  void connectSocket(String address);

  void disconnectSocket();

  bool get isSocketConnected;

  Stream<bool> get socketConnectionStream;
}
