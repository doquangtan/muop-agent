import 'dart:async';

import 'package:muop_agent/features/docker/domain/docker_entities.dart';

/// Interface (domain) của feature docker. Presentation chỉ phụ thuộc interface này.
abstract class DockerRepository {
  Stream<DockerLogsChunk> get dockerLogsStream;

  Stream<DockerLogsEnd> get dockerLogsEndStream;

  Future<DockerSessionResult> openDockerSession(
    String address, {
    required int hostId,
  });

  Future<DockerSessionResult> scanDockerSession(
    String address,
    String sessionId,
  );

  /// Trạng thái phiên Docker do server đẩy khi đang xem (`docker:session:update`), thay cho quét định kỳ.
  /// Nghe luồng này thì server bắt đầu quét; hủy đăng ký thì server ngừng quét khi không còn người xem.
  Stream<DockerSessionResult> watchDockerSession(String sessionId);

  Future<DockerSessionResult> dockerContainerAction(
    String address, {
    required String sessionId,
    required String action,
    required List<String> containerIds,
  });

  Future<bool> closeDockerSession(String address, String sessionId);

  Future<List<DockerSession>> listDockerSessions(String address);

  Future<DockerLogsOpenResult> openDockerLogs({
    required String sessionId,
    required String containerId,
    int tail = 300,
  });

  void pingDockerLogs(String streamId);

  void closeDockerLogs(String streamId);
}
