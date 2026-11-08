import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

import '../models/agent_core_models.dart';

class RemotePingResult {
  const RemotePingResult({
    required this.isOnline,
    required this.latencyMs,
    this.hostname = '',
    this.engine = '',
    this.lanIps = const [],
    this.errorMessage = '',
  });

  final bool isOnline;
  final int latencyMs;
  final String hostname;
  final String engine;
  final List<String> lanIps;
  final String errorMessage;
}

class ChatSendResult {
  const ChatSendResult({
    required this.ok,
    required this.conversationId,
    required this.projectPath,
    this.error = '',
  });

  final bool ok;
  final String conversationId;
  final String projectPath;
  final String error;
}

class ServerFileEntry {
  const ServerFileEntry({
    required this.name,
    required this.path,
    required this.isDir,
    required this.size,
    required this.modifiedAt,
    this.permissions = '',
  });

  final String name;
  final String path;
  final bool isDir;
  final int size;
  final DateTime modifiedAt;
  final String permissions;

  String get formattedSize {
    if (isDir) return 'DIR';
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) {
      return '${(size / 1024).toStringAsFixed(1)} KB';
    }
    return '${(size / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  factory ServerFileEntry.fromJson(Map<String, dynamic> json) {
    return ServerFileEntry(
      name: '${json['name'] ?? ''}',
      path: '${json['path'] ?? ''}',
      isDir: json['isDir'] == true,
      size: (json['size'] as num?)?.toInt() ?? 0,
      modifiedAt:
          DateTime.tryParse('${json['modifiedAt'] ?? ''}') ?? DateTime.now(),
      permissions: '${json['permissions'] ?? (json['isDir'] == true ? 'drwxr-xr-x' : '-rw-r--r--')}',
    );
  }
}

class ServerFileReadResponse {
  const ServerFileReadResponse({
    required this.ok,
    required this.path,
    required this.name,
    required this.size,
    required this.isBinary,
    required this.content,
    required this.gitDiff,
    this.error = '',
  });

  final bool ok;
  final String path;
  final String name;
  final int size;
  final bool isBinary;
  final String content;
  final String gitDiff;
  final String error;

  factory ServerFileReadResponse.fromJson(Map<String, dynamic> json) {
    return ServerFileReadResponse(
      ok: json['ok'] == true,
      path: '${json['path'] ?? ''}',
      name: '${json['name'] ?? ''}',
      size: (json['size'] as num?)?.toInt() ?? 0,
      isBinary: json['isBinary'] == true,
      content: '${json['content'] ?? ''}',
      gitDiff: '${json['gitDiff'] ?? ''}',
      error: '${json['error'] ?? ''}',
    );
  }
}

class ServerDirListResponse {
  const ServerDirListResponse({
    required this.ok,
    required this.currentPath,
    required this.parentPath,
    required this.entries,
    this.error = '',
  });

  final bool ok;
  final String currentPath;
  final String parentPath;
  final List<ServerFileEntry> entries;
  final String error;

  factory ServerDirListResponse.fromJson(Map<String, dynamic> json) {
    final list = <ServerFileEntry>[];
    if (json['entries'] is List) {
      for (final item in json['entries'] as List) {
        if (item is Map) {
          list.add(ServerFileEntry.fromJson(Map<String, dynamic>.from(item)));
        }
      }
    }
    return ServerDirListResponse(
      ok: json['ok'] == true,
      currentPath: '${json['currentPath'] ?? ''}',
      parentPath: '${json['parentPath'] ?? ''}',
      entries: list,
      error: '${json['error'] ?? ''}',
    );
  }
}

class FileDownloadResult {
  const FileDownloadResult({
    required this.ok,
    required this.savedPath,
    required this.sizeBytes,
    this.error = '',
  });

  final bool ok;
  final String savedPath;
  final int sizeBytes;
  final String error;
}

/// Pure UI Client Service kết nối tới Mướp Agent Rust Server qua Socket.IO v4 & HTTP REST.
/// Toàn bộ việc quét file, đọc SQLite và chạy tiến trình `agy` đều do Rust Server đảm nhiệm.
class BrainScannerService {
  BrainScannerService();

  static const String defaultHostAddress = '192.168.31.96:8787';
  static const int defaultBridgePort = 8787;

  static const List<String> defaultModels = [
    'gemini-3.8-flash-high',
    'gemini-3.8-flash-medium',
    'claude-sonnet-5-5-high',
    'claude-opus-5-5-high',
    'gemini-4-argon-high',
    'gemini-4-argon-medium',
  ];

  static const List<String> defaultAgents = [
    'Coordinator',
    'erp-server-agent',
    'erp-app-agent',
    'erp-contract-verifier',
  ];

  io.Socket? _socket;
  String _connectedBaseUrl = '';
  bool _isSocketConnected = false;

  final StreamController<AgentMonitorSnapshot> _snapshotController =
      StreamController<AgentMonitorSnapshot>.broadcast();
  final StreamController<ChatTurnStreamState> _chatStreamController =
      StreamController<ChatTurnStreamState>.broadcast();
  final StreamController<bool> _socketStatusController =
      StreamController<bool>.broadcast();

  Stream<AgentMonitorSnapshot> get snapshotStream => _snapshotController.stream;
  Stream<ChatTurnStreamState> get chatStream => _chatStreamController.stream;
  Stream<bool> get socketConnectionStream => _socketStatusController.stream;
  bool get isSocketConnected => _isSocketConnected;

  File get _configFile =>
      File('${Directory.systemTemp.path}/muop_agent_remote_config.json');

  String normalizeBaseUrl(String input) {
    var trimmed = input.trim();
    if (trimmed.isEmpty) {
      trimmed = defaultHostAddress;
    }
    if (!trimmed.startsWith('http://') && !trimmed.startsWith('https://')) {
      trimmed = 'http://$trimmed';
    }
    if (trimmed.endsWith('/')) {
      trimmed = trimmed.substring(0, trimmed.length - 1);
    }
    final uri = Uri.tryParse(trimmed);
    if (uri != null && !uri.hasPort) {
      return '${uri.scheme}://${uri.host}:$defaultBridgePort';
    }
    return trimmed;
  }

  Future<String> loadSavedServerAddress() async {
    try {
      if (await _configFile.exists()) {
        final content = await _configFile.readAsString();
        final map = jsonDecode(content) as Map<String, dynamic>;
        final saved = '${map['serverAddress'] ?? ''}'.trim();
        if (saved.isNotEmpty) return saved;
      }
    } catch (_) {}
    return defaultHostAddress;
  }

  Future<void> saveServerAddress(String address) async {
    try {
      final clean =
          address.trim().isEmpty ? defaultHostAddress : address.trim();
      await _configFile.writeAsString(
        jsonEncode({
          'serverAddress': clean,
          'updatedAt': DateTime.now().toIso8601String(),
        }),
      );
    } catch (_) {}
  }

  /// Khởi tạo kết nối Socket.IO Realtime tới Rust Server
  void connectSocket(String address) {
    final baseUrl = normalizeBaseUrl(address);
    if (_socket != null && _connectedBaseUrl == baseUrl) {
      if (!(_socket!.connected)) {
        _socket!.connect();
      } else {
        _socket!.emit('request-snapshot');
      }
      return;
    }

    disconnectSocket();
    _connectedBaseUrl = baseUrl;

    final socket = io.io(
      baseUrl,
      io.OptionBuilder()
          .setTransports(['websocket', 'polling'])
          .enableAutoConnect()
          .enableReconnection()
          .setReconnectionDelay(1000)
          .setReconnectionDelayMax(3500)
          .build(),
    );

    socket.onConnect((_) {
      _isSocketConnected = true;
      if (!_socketStatusController.isClosed) {
        _socketStatusController.add(true);
      }
      socket.emit('request-snapshot');
    });

    socket.onDisconnect((_) {
      _isSocketConnected = false;
      if (!_socketStatusController.isClosed) {
        _socketStatusController.add(false);
      }
    });

    socket.onConnectError((_) {
      _isSocketConnected = false;
      if (!_socketStatusController.isClosed) {
        _socketStatusController.add(false);
      }
    });

    socket.on('snapshot:update', (data) {
      if (_snapshotController.isClosed || data == null) return;
      try {
        Map<String, dynamic>? map;
        if (data is Map<String, dynamic>) {
          map = data;
        } else if (data is Map) {
          map = Map<String, dynamic>.from(data);
        } else if (data is String) {
          map = jsonDecode(data) as Map<String, dynamic>;
        }
        if (map != null) {
          final snapshot = AgentMonitorSnapshot.fromJson(map);
          _snapshotController.add(snapshot);
        }
      } catch (_) {}
    });

    socket.on('chat:stream', (data) {
      if (_chatStreamController.isClosed || data == null) return;
      try {
        Map<String, dynamic>? map;
        if (data is Map<String, dynamic>) {
          map = data;
        } else if (data is Map) {
          map = Map<String, dynamic>.from(data);
        } else if (data is String) {
          map = jsonDecode(data) as Map<String, dynamic>;
        }
        if (map != null) {
          final streamState = ChatTurnStreamState.fromJson(map);
          _chatStreamController.add(streamState);
        }
      } catch (_) {}
    });

    _socket = socket;
    socket.connect();
  }

  void requestRealtimeSnapshot() {
    if (_socket != null && _socket!.connected) {
      _socket!.emit('request-snapshot');
    }
  }

  void disconnectSocket() {
    _isSocketConnected = false;
    try {
      _socket?.dispose();
    } catch (_) {}
    _socket = null;
    _connectedBaseUrl = '';
  }

  void dispose() {
    disconnectSocket();
    _snapshotController.close();
    _chatStreamController.close();
    _socketStatusController.close();
  }

  /// Kiểm tra kết nối tới Rust Server qua HTTP `/api/ping`
  Future<RemotePingResult> pingRemoteServer(String address) async {
    final baseUrl = normalizeBaseUrl(address);
    final sw = Stopwatch()..start();
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 3);
    try {
      final uri = Uri.parse('$baseUrl/api/ping');
      final req = await client.getUrl(uri);
      final resp = await req.close().timeout(const Duration(seconds: 4));
      sw.stop();
      if (resp.statusCode == 200) {
        final body = await resp.transform(utf8.decoder).join();
        final map = jsonDecode(body) as Map<String, dynamic>;
        final ips = <String>[];
        if (map['ips'] is List) {
          for (final item in map['ips'] as List) {
            ips.add('$item');
          }
        }
        return RemotePingResult(
          isOnline: true,
          latencyMs: sw.elapsedMilliseconds,
          hostname: '${map['hostname'] ?? 'Linux PC'}',
          engine: '${map['engine'] ?? 'rust-axum-socketio'}',
          lanIps: ips,
        );
      }
      return RemotePingResult(
        isOnline: false,
        latencyMs: sw.elapsedMilliseconds,
        errorMessage: 'HTTP ${resp.statusCode}',
      );
    } catch (e) {
      sw.stop();
      return RemotePingResult(
        isOnline: false,
        latencyMs: sw.elapsedMilliseconds,
        errorMessage: '$e',
      );
    } finally {
      client.close(force: true);
    }
  }

  /// Lấy Snapshot từ Rust Server qua HTTP `/api/snapshot`
  Future<AgentMonitorSnapshot?> fetchRemoteSnapshot(String address) async {
    final baseUrl = normalizeBaseUrl(address);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 4);
    try {
      final uri = Uri.parse('$baseUrl/api/snapshot');
      final req = await client.getUrl(uri);
      final resp = await req.close().timeout(const Duration(seconds: 6));
      if (resp.statusCode == 200) {
        final body = await resp.transform(utf8.decoder).join();
        final map = jsonDecode(body) as Map<String, dynamic>;
        return AgentMonitorSnapshot.fromJson(map);
      }
    } catch (_) {
    } finally {
      client.close(force: true);
    }
    return null;
  }

  /// Lấy chi tiết toàn bộ các steps của một session cụ thể qua HTTP `/api/session?id=...`
  Future<ConversationSession?> fetchSessionDetail({
    required String address,
    required String sessionId,
  }) async {
    final baseUrl = normalizeBaseUrl(address);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 4);
    try {
      final uri = Uri.parse('$baseUrl/api/session?id=$sessionId');
      final req = await client.getUrl(uri);
      final resp = await req.close().timeout(const Duration(seconds: 6));
      if (resp.statusCode == 200) {
        final body = await resp.transform(utf8.decoder).join();
        final map = jsonDecode(body) as Map<String, dynamic>;
        return ConversationSession.fromJson(map);
      }
    } catch (_) {
    } finally {
      client.close(force: true);
    }
    return null;
  }

  /// Nạp một trang các bước cũ (AgentStep) phục vụ cuộn phân trang mượt mà
  Future<SessionStepsPageResult?> fetchSessionStepsPage({
    required String address,
    required String sessionId,
    int? beforeStepIndex,
    int limit = 30,
  }) async {
    final baseUrl = normalizeBaseUrl(address);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 4);
    try {
      final uri = Uri.parse('$baseUrl/api/session/steps').replace(
        queryParameters: {
          'id': sessionId.trim(),
          if (beforeStepIndex != null && beforeStepIndex > 0)
            'beforeStep': beforeStepIndex.toString(),
          'limit': limit.toString(),
        },
      );
      final req = await client.getUrl(uri);
      final resp = await req.close().timeout(const Duration(seconds: 6));
      if (resp.statusCode == 200) {
        final body = await resp.transform(utf8.decoder).join();
        final map = jsonDecode(body) as Map<String, dynamic>;
        return SessionStepsPageResult.fromJson(map);
      }
    } catch (_) {
    } finally {
      client.close(force: true);
    }
    return null;
  }

  /// Gửi tin nhắn trò chuyện với Agent tới Rust Server
  Future<ChatSendResult> sendRemoteChatPrompt({
    required String address,
    required String prompt,
    required String projectPath,
    String? conversationId,
    String? agentName,
    String? model,
  }) async {
    final baseUrl = normalizeBaseUrl(address);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 6);
    try {
      final uri = Uri.parse('$baseUrl/api/chat/send');
      final req = await client.postUrl(uri);
      req.headers.contentType = ContentType.json;
      req.write(
        jsonEncode({
          'prompt': prompt,
          'projectPath': projectPath,
          'conversationId': conversationId ?? '',
          'agentName': agentName ?? '',
          'model': model ?? '',
        }),
      );
      final resp = await req.close().timeout(const Duration(seconds: 15));
      final body = await resp.transform(utf8.decoder).join();
      final map = jsonDecode(body) as Map<String, dynamic>;
      if (resp.statusCode == 200 && map['ok'] == true) {
        return ChatSendResult(
          ok: true,
          conversationId: '${map['conversationId'] ?? ''}',
          projectPath: '${map['projectPath'] ?? projectPath}',
        );
      }
      return ChatSendResult(
        ok: false,
        conversationId: '',
        projectPath: projectPath,
        error: '${map['error'] ?? 'HTTP ${resp.statusCode}'}',
      );
    } catch (e) {
      return ChatSendResult(
        ok: false,
        conversationId: '',
        projectPath: projectPath,
        error: '$e',
      );
    } finally {
      client.close(force: true);
    }
  }

  /// Dừng lượt chạy Agent qua Rust Server
  Future<bool> stopRemoteChatTurn({
    required String address,
    required String conversationId,
  }) async {
    final baseUrl = normalizeBaseUrl(address);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 4);
    try {
      final uri = Uri.parse('$baseUrl/api/chat/stop');
      final req = await client.postUrl(uri);
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({'conversationId': conversationId}));
      final resp = await req.close().timeout(const Duration(seconds: 4));
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  /// Tạo project mới trên Rust Server (`/api/project/create`)
  Future<CreateProjectResult> createProject({
    required String address,
    required String name,
    String template = 'standard',
    String description = '',
  }) async {
    final baseUrl = normalizeBaseUrl(address);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 6);
    try {
      final uri = Uri.parse('$baseUrl/api/project/create');
      final req = await client.postUrl(uri);
      req.headers.contentType = ContentType.json;
      req.write(
        jsonEncode({
          'name': name.trim(),
          'template': template,
          'description': description.trim(),
        }),
      );
      final resp = await req.close().timeout(const Duration(seconds: 10));
      final body = await resp.transform(utf8.decoder).join();
      final map = jsonDecode(body) as Map<String, dynamic>;
      return CreateProjectResult.fromJson(map);
    } catch (e) {
      return CreateProjectResult(
        ok: false,
        message: 'Lỗi kết nối tới Rust Server: $e',
        error: '$e',
      );
    } finally {
      client.close(force: true);
    }
  }

  /// Lấy thông tin agents và skills của dự án (`/api/project/agents`)
  Future<ProjectAgentsResponse?> fetchProjectAgents({
    required String address,
    String? projectPath,
    String? projectName,
  }) async {
    final baseUrl = normalizeBaseUrl(address);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 4);
    try {
      final queryParams = <String, String>{};
      if (projectPath != null && projectPath.trim().isNotEmpty) {
        queryParams['path'] = projectPath.trim();
      }
      if (projectName != null && projectName.trim().isNotEmpty) {
        queryParams['name'] = projectName.trim();
      }
      final uri = Uri.parse('$baseUrl/api/project/agents').replace(
        queryParameters: queryParams.isNotEmpty ? queryParams : null,
      );
      final req = await client.getUrl(uri);
      final resp = await req.close().timeout(const Duration(seconds: 6));
      if (resp.statusCode == HttpStatus.ok) {
        final body = await resp.transform(utf8.decoder).join();
        final map = jsonDecode(body) as Map<String, dynamic>;
        return ProjectAgentsResponse.fromJson(map);
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// Lấy danh sách kế hoạch đang chờ duyệt (`/api/plan/pending`)
  Future<List<PlanArtifactInfo>> fetchPendingPlans({
    required String address,
    required String conversationId,
  }) async {
    final baseUrl = normalizeBaseUrl(address);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 4);
    try {
      final uri = Uri.parse('$baseUrl/api/plan/pending').replace(
        queryParameters: {'conversationId': conversationId},
      );
      final req = await client.getUrl(uri);
      final resp = await req.close().timeout(const Duration(seconds: 4));
      if (resp.statusCode != 200) return const [];
      final body = await resp.transform(utf8.decoder).join();
      final data = jsonDecode(body);
      if (data is Map && data['plans'] is List) {
        return (data['plans'] as List)
            .whereType<Map>()
            .map((e) => PlanArtifactInfo.fromJson(Map<String, dynamic>.from(e)))
            .toList();
      }
      return const [];
    } catch (_) {
      return const [];
    } finally {
      client.close(force: true);
    }
  }

  /// Gửi quyết định phê duyệt hoặc yêu cầu chỉnh sửa Kế hoạch (`/api/plan/action`)
  Future<({bool ok, String message})> submitPlanAction({
    required String address,
    required String conversationId,
    required String fileName,
    required String action, // 'approve' | 'reject'
    String feedback = '',
    String model = '',
  }) async {
    final baseUrl = normalizeBaseUrl(address);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 6);
    try {
      final uri = Uri.parse('$baseUrl/api/plan/action');
      final req = await client.postUrl(uri);
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({
        'conversationId': conversationId,
        'fileName': fileName,
        'action': action,
        'feedback': feedback,
        'model': model,
      }));
      final resp = await req.close().timeout(const Duration(seconds: 6));
      final body = await resp.transform(utf8.decoder).join();
      final data = jsonDecode(body);
      if (resp.statusCode == 200 && data is Map && data['ok'] == true) {
        return (
          ok: true,
          message: data['message']?.toString() ?? 'Thành công',
        );
      }
      final err = (data is Map && data['error'] != null)
          ? data['error'].toString()
          : 'Không thể xử lý kế hoạch';
      return (ok: false, message: err);
    } catch (e) {
      return (ok: false, message: e.toString());
    } finally {
      client.close(force: true);
    }
  }

  /// Đẩy commits lên máy chủ từ xa remote git repository (`/api/git/push`)
  Future<GitPushResponse> gitPush({
    required String address,
    required String projectPath,
    String branch = '',
  }) async {
    final baseUrl = normalizeBaseUrl(address);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final uri = Uri.parse('$baseUrl/api/git/push');
      final req = await client.postUrl(uri);
      req.headers.contentType = ContentType.json;
      req.write(
        jsonEncode({
          'projectPath': projectPath.trim(),
          'branch': branch.trim(),
        }),
      );
      final resp = await req.close().timeout(const Duration(seconds: 35));
      final body = await resp.transform(utf8.decoder).join();
      final map = jsonDecode(body) as Map<String, dynamic>;
      return GitPushResponse.fromJson(map);
    } catch (e) {
      return GitPushResponse(
        ok: false,
        message: 'Lỗi kết nối khi git push: $e',
        error: '$e',
      );
    } finally {
      client.close(force: true);
    }
  }

  /// Duyệt danh sách file và thư mục trên Rust Server (`/api/files/list`)
  Future<ServerDirListResponse> fetchServerDirectory({
    required String address,
    required String path,
    bool showHidden = false,
  }) async {
    final baseUrl = normalizeBaseUrl(address);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 4);
    try {
      final uri = Uri.parse('$baseUrl/api/files/list').replace(
        queryParameters: {
          'path': path,
          'showHidden': showHidden ? 'true' : 'false',
        },
      );
      final req = await client.getUrl(uri);
      final resp = await req.close().timeout(const Duration(seconds: 6));
      final body = await resp.transform(utf8.decoder).join();
      final map = jsonDecode(body) as Map<String, dynamic>;
      return ServerDirListResponse.fromJson(map);
    } catch (e) {
      return ServerDirListResponse(
        ok: false,
        currentPath: path,
        parentPath: '',
        entries: const [],
        error: '$e',
      );
    } finally {
      client.close(force: true);
    }
  }

  /// Đọc nội dung tệp và Git Diff trên Rust Server (`/api/files/read`)
  Future<ServerFileReadResponse> readServerFile({
    required String address,
    required String path,
  }) async {
    final baseUrl = normalizeBaseUrl(address);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 5);
    try {
      final uri = Uri.parse('$baseUrl/api/files/read').replace(
        queryParameters: {'path': path},
      );
      final req = await client.getUrl(uri);
      final resp = await req.close().timeout(const Duration(seconds: 8));
      final body = await resp.transform(utf8.decoder).join();
      final map = jsonDecode(body) as Map<String, dynamic>;
      return ServerFileReadResponse.fromJson(map);
    } catch (e) {
      return ServerFileReadResponse(
        ok: false,
        path: path,
        name: path.split('/').last,
        size: 0,
        isBinary: false,
        content: '',
        gitDiff: '',
        error: '$e',
      );
    } finally {
      client.close(force: true);
    }
  }

  /// Tải file từ Rust Server (`/api/files/download`) về thư mục Downloads trên thiết bị
  Future<FileDownloadResult> downloadFileFromServer({
    required String address,
    required String remotePath,
    void Function(int receivedBytes, int totalBytes)? onProgress,
  }) async {
    final baseUrl = normalizeBaseUrl(address);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8);
    try {
      final uri = Uri.parse('$baseUrl/api/files/download').replace(
        queryParameters: {'path': remotePath},
      );
      final req = await client.getUrl(uri);
      final resp = await req.close();

      if (resp.statusCode != 200) {
        final errBody = await resp.transform(utf8.decoder).join();
        return FileDownloadResult(
          ok: false,
          savedPath: '',
          sizeBytes: 0,
          error: 'HTTP ${resp.statusCode}: $errBody',
        );
      }

      final filename = remotePath
          .split('/')
          .where((s) => s.isNotEmpty)
          .lastOrNull ??
          'downloaded_file';

      Directory targetDir = Directory.systemTemp;
      if (Platform.isAndroid) {
        final androidDownload = Directory('/storage/emulated/0/Download');
        if (await androidDownload.exists()) {
          targetDir = androidDownload;
        }
      } else {
        final home = Platform.environment['HOME'] ?? '';
        if (home.isNotEmpty) {
          final desktopDownload = Directory('$home/Downloads');
          if (await desktopDownload.exists()) {
            targetDir = desktopDownload;
          }
        }
      }

      File outFile = File('${targetDir.path}/$filename');
      IOSink? sink;
      try {
        sink = outFile.openWrite();
      } catch (_) {
        outFile = File('${Directory.systemTemp.path}/$filename');
        sink = outFile.openWrite();
      }

      final totalBytes = resp.contentLength;
      int received = 0;

      await for (final chunk in resp) {
        sink.add(chunk);
        received += chunk.length;
        if (onProgress != null) {
          onProgress(received, totalBytes);
        }
      }
      await sink.flush();
      await sink.close();

      return FileDownloadResult(
        ok: true,
        savedPath: outFile.path,
        sizeBytes: received,
      );
    } catch (e) {
      return FileDownloadResult(
        ok: false,
        savedPath: '',
        sizeBytes: 0,
        error: '$e',
      );
    } finally {
      client.close(force: true);
    }
  }

  static const MethodChannel _fileOpenerChannel =
      MethodChannel('vn.muop.muop_agent/file_opener');

  /// Mở trực tiếp tệp vừa tải về trên thiết bị (Android FileProvider Intent hoặc Linux xdg-open)
  Future<({bool ok, String error})> openDownloadedFile(String savedPath) async {
    final cleanPath = savedPath.trim();
    if (cleanPath.isEmpty) {
      return (ok: false, error: 'Đường dẫn tệp trống');
    }
    try {
      final f = File(cleanPath);
      if (!await f.exists()) {
        return (ok: false, error: 'Tệp không tồn tại tại: $cleanPath');
      }

      if (Platform.isAndroid) {
        await _fileOpenerChannel.invokeMethod<bool>(
          'openFile',
          {'path': cleanPath},
        );
        return (ok: true, error: '');
      } else if (Platform.isLinux) {
        final res = await Process.run('xdg-open', [cleanPath]);
        if (res.exitCode == 0) {
          return (ok: true, error: '');
        }
        return (ok: false, error: '${res.stderr}'.trim());
      } else if (Platform.isMacOS) {
        await Process.run('open', [cleanPath]);
        return (ok: true, error: '');
      } else if (Platform.isWindows) {
        await Process.run('explorer', [cleanPath]);
        return (ok: true, error: '');
      }
      return (ok: false, error: 'Nền tảng chưa hỗ trợ mở tệp trực tiếp');
    } catch (e) {
      return (ok: false, error: '$e');
    }
  }

  /// Tạo dữ liệu mô phỏng trực quan trên UI khi người dùng bấm nút "Mô phỏng"
  ConversationSession buildSimulatedParallelSession(int tick) {
    final now = DateTime.now();
    final stage = tick.clamp(0, 10);

    final AgentWorkflowPhase currentPhase;
    final AgentStatus overallStatus;
    if (stage <= 2) {
      currentPhase = AgentWorkflowPhase.contractDiscovery;
      overallStatus = AgentStatus.running;
    } else if (stage <= 6) {
      currentPhase = AgentWorkflowPhase.parallelExecution;
      overallStatus = AgentStatus.running;
    } else if (stage <= 9) {
      currentPhase = AgentWorkflowPhase.crossVerification;
      overallStatus = AgentStatus.running;
    } else {
      currentPhase = AgentWorkflowPhase.completed;
      overallStatus = AgentStatus.completed;
    }

    final serverProgress = stage <= 2
        ? 0.1
        : stage >= 8
            ? 1.0
            : ((stage - 2) / 6.0).clamp(0.2, 0.95);
    final appProgress = stage <= 2
        ? 0.1
        : stage >= 9
            ? 1.0
            : ((stage - 2) / 7.0).clamp(0.15, 0.95);
    final verifierProgress = stage < 7
        ? 0.0
        : stage >= 10
            ? 1.0
            : ((stage - 6) / 4.0).clamp(0.25, 0.9);

    String serverAction;
    String serverTool;
    AgentStatus serverStatus;
    if (stage <= 2) {
      serverAction = 'Đang nhận Shared API Contract từ Coordinator...';
      serverTool = 'standby';
      serverStatus = AgentStatus.waiting;
    } else if (stage == 3) {
      serverAction =
          'Đang cập nhật Entity & DTO trong api/v1/internal/core/order/domain/order.go';
      serverTool = 'edit_file';
      serverStatus = AgentStatus.running;
    } else if (stage == 4) {
      serverAction =
          'Đang bổ sung MongoDB Isolated Collection query & MarshalBSON UTC';
      serverTool = 'edit_file';
      serverStatus = AgentStatus.running;
    } else if (stage == 5) {
      serverAction =
          'Đang cập nhật Fiber Handler /api/v1/order + emit Socket.IO "order-update"';
      serverTool = 'edit_file';
      serverStatus = AgentStatus.running;
    } else if (stage == 6) {
      serverAction = 'Đang đồng bộ tài liệu docs/order-api-reference.md';
      serverTool = 'edit_file';
      serverStatus = AgentStatus.running;
    } else if (stage == 7) {
      serverAction = 'Đang chạy kiểm tra biên dịch: go build -v .';
      serverTool = 'run_command';
      serverStatus = AgentStatus.running;
    } else {
      serverAction = 'Hoàn tất: go build -v . CLEAN (exit code 0)';
      serverTool = 'done';
      serverStatus = AgentStatus.completed;
    }

    String appAction;
    String appTool;
    AgentStatus appStatus;
    if (stage <= 2) {
      appAction = 'Đang nhận Shared API Contract từ Coordinator...';
      appTool = 'standby';
      appStatus = AgentStatus.waiting;
    } else if (stage == 3) {
      appAction =
          'Đang đồng bộ Model Order (fromJson/toJson, num.tryParse) tại lib/models/order.dart';
      appTool = 'edit_file';
      appStatus = AgentStatus.running;
    } else if (stage == 4) {
      appAction =
          'Đang tích hợp executeRequest(/order) kèm X-Merchant-Id & X-Branch-Id';
      appTool = 'edit_file';
      appStatus = AgentStatus.running;
    } else if (stage == 5) {
      appAction =
          'Đang cập nhật Riverpod Provider & lắng nghe Socket.IO room {merchantId}-order';
      appTool = 'edit_file';
      appStatus = AgentStatus.running;
    } else if (stage == 6) {
      appAction =
          'Đang dựng giao diện Material 3 Dynamic Theming (colorScheme) & Responsive Dialog';
      appTool = 'edit_file';
      appStatus = AgentStatus.running;
    } else if (stage == 7) {
      appAction =
          'Đang thêm khóa dịch đa ngôn ngữ vào assets/i18n/vi.json & en.json';
      appTool = 'edit_file';
      appStatus = AgentStatus.running;
    } else if (stage == 8) {
      appAction =
          'Đang chạy kiểm tra tĩnh: flutter analyze lib/features/retail/order';
      appTool = 'run_command';
      appStatus = AgentStatus.running;
    } else {
      appAction = 'Hoàn tất: flutter analyze CLEAN (No issues found!)';
      appTool = 'done';
      appStatus = AgentStatus.completed;
    }

    String verifierAction;
    AgentStatus verifierStatus;
    if (stage < 7) {
      verifierAction =
          'Đang chờ erp-server-agent và erp-app-agent hoàn tất code...';
      verifierStatus = AgentStatus.waiting;
    } else if (stage <= 9) {
      verifierAction =
          'Đang đối soát chéo JSON tags (Go) ↔ fromJson (Dart), RBAC & Socket.IO event...';
      verifierStatus = AgentStatus.running;
    } else {
      verifierAction =
          'Đối soát khớp 100%: Endpoint, Header X-Merchant-Id/X-Branch-Id, i18n & Build CLEAN';
      verifierStatus = AgentStatus.completed;
    }

    final allSimSteps = <AgentStep>[
      AgentStep(
        stepIndex: 0,
        source: 'USER_EXPLICIT',
        type: 'USER_INPUT',
        status: 'DONE',
        createdAt: now.subtract(const Duration(seconds: 40)),
        content:
            '/erp-parallel-sync Thêm trường deliveryNote & phí vận chuyển vào đơn hàng Order trên erp-server và đồng bộ sang màn hình POS/Order trên erp-app',
        thinking: '',
        toolCalls: const [],
        inputTokens: 1250,
        outputTokens: 0,
        cacheReadTokens: 0,
        agentName: 'User',
        phase: AgentWorkflowPhase.contractDiscovery,
        vietnameseTitle: 'Yêu cầu đồng bộ tính năng Order (Server ↔ App)',
        vietnameseDetail:
            'Thêm trường deliveryNote & shippingFee vào API Order và đồng bộ giao diện POS Flutter',
      ),
      AgentStep(
        stepIndex: 1,
        source: 'MODEL',
        type: 'PLANNER_RESPONSE',
        status: 'DONE',
        createdAt: now.subtract(const Duration(seconds: 36)),
        content:
            'Khảo sát cấu trúc Order trên cả 2 kho lưu trữ và chốt Shared Contract.',
        thinking:
            'Đọc domain/order.go bên muop-erp-server và lib/models/order.dart bên muop-erp-app để thống nhất JSON schema trước khi gọi song song 2 subagents.',
        toolCalls: const [
          ToolCallInfo(
            name: 'read_file',
            args: {
              'Path':
                  '/home/john/Documents/muop-ecosystem/muop-erp-server/api/v1/internal/core/order/domain/order.go',
            },
            summaryLabel: 'Đọc tệp order.go (Server)',
            targetPath:
                '/home/john/Documents/muop-ecosystem/muop-erp-server/api/v1/internal/core/order/domain/order.go',
            repoTag: 'muop-erp-server',
          ),
          ToolCallInfo(
            name: 'read_file',
            args: {
              'Path':
                  '/home/john/Documents/muop-ecosystem/muop-erp-app/lib/models/order.dart',
            },
            summaryLabel: 'Đọc tệp order.dart (App)',
            targetPath:
                '/home/john/Documents/muop-ecosystem/muop-erp-app/lib/models/order.dart',
            repoTag: 'muop-erp-app',
          ),
        ],
        inputTokens: 8400,
        outputTokens: 410,
        cacheReadTokens: 12000,
        agentName: 'Coordinator',
        phase: AgentWorkflowPhase.contractDiscovery,
        vietnameseTitle:
            'Khảo sát & Chốt Shared API Contract (order.go ↔ order.dart)',
        vietnameseDetail:
            'Xác định Canonical Endpoint POST/PUT /api/v1/order, JSON fields deliveryNote, shippingFee và Socket room {merchantId}-order',
      ),
      if (stage >= 2)
        AgentStep(
          stepIndex: 2,
          source: 'MODEL',
          type: 'PLANNER_RESPONSE',
          status: 'DONE',
          createdAt: now.subtract(const Duration(seconds: 30)),
          content:
              'Khởi chạy song song erp-server-agent và erp-app-agent trong cùng 1 lượt.',
          thinking:
              'Shared Contract đã sẵn sàng. Gọi invoke_subagent đồng thời cho erp-server-agent và erp-app-agent.',
          toolCalls: const [
            ToolCallInfo(
              name: 'invoke_subagent',
              args: {
                'TypeName': 'erp-server-agent',
                'Role': 'ERP Server Backend Engineer',
              },
              summaryLabel: 'Khởi chạy Subagent: erp-server-agent',
              repoTag: 'muop-erp-server',
            ),
            ToolCallInfo(
              name: 'invoke_subagent',
              args: {
                'TypeName': 'erp-app-agent',
                'Role': 'ERP App Flutter Engineer',
              },
              summaryLabel: 'Khởi chạy Subagent: erp-app-agent',
              repoTag: 'muop-erp-app',
            ),
          ],
          inputTokens: 9200,
          outputTokens: 890,
          cacheReadTokens: 18500,
          agentName: 'Coordinator',
          phase: AgentWorkflowPhase.parallelExecution,
          vietnameseTitle:
              'Fan-out Song song: Khởi chạy đồng thời erp-server-agent & erp-app-agent',
          vietnameseDetail:
              'Hai Subagents bắt đầu chỉnh sửa độc lập trên muop-erp-server và muop-erp-app theo Shared Contract',
        ),
      if (stage >= 4)
        AgentStep(
          stepIndex: 3,
          source: 'MODEL',
          type: 'PLANNER_RESPONSE',
          status: stage == 4 ? 'RUNNING' : 'DONE',
          createdAt: now.subtract(const Duration(seconds: 22)),
          content:
              'Cập nhật tầng Domain, Usecase, Handler trên Go Server và cập nhật Model, executeRequest trên Flutter App.',
          thinking:
              'erp-server-agent sửa order.go & order_handler.go; erp-app-agent sửa order.dart & sale.dart.',
          toolCalls: const [
            ToolCallInfo(
              name: 'edit_file',
              args: {
                'Path':
                    '/home/john/Documents/muop-ecosystem/muop-erp-server/api/v1/internal/core/order/delivery/http/order_handler.go',
              },
              summaryLabel: 'Chỉnh sửa order_handler.go',
              targetPath:
                  '/home/john/Documents/muop-ecosystem/muop-erp-server/api/v1/internal/core/order/delivery/http/order_handler.go',
              repoTag: 'muop-erp-server',
            ),
            ToolCallInfo(
              name: 'edit_file',
              args: {
                'Path':
                    '/home/john/Documents/muop-ecosystem/muop-erp-app/lib/features/retail/order/sale.dart',
              },
              summaryLabel: 'Chỉnh sửa sale.dart',
              targetPath:
                  '/home/john/Documents/muop-ecosystem/muop-erp-app/lib/features/retail/order/sale.dart',
              repoTag: 'muop-erp-app',
            ),
          ],
          inputTokens: 14300,
          outputTokens: 1620,
          cacheReadTokens: 28000,
          agentName: 'erp-server-agent & erp-app-agent',
          phase: AgentWorkflowPhase.parallelExecution,
          vietnameseTitle:
              'Thực thi Song song: Sửa Handler Go + Cập nhật Màn hình POS Flutter (M3 & i18n)',
          vietnameseDetail:
              'Đồng bộ cả logic backend, docs/order-api-reference.md và giao diện Material 3 + assets/i18n/{vi,en}.json',
        ),
      if (stage >= 7)
        AgentStep(
          stepIndex: 4,
          source: 'MODEL',
          type: 'PLANNER_RESPONSE',
          status: stage < 10 ? 'RUNNING' : 'DONE',
          createdAt: now.subtract(const Duration(seconds: 10)),
          content:
              'Chạy kiểm tra biên dịch Go và phân tích tĩnh Flutter Analyzer.',
          thinking:
              'Bắt buộc xác nhận go build -v . và flutter analyze sạch lỗi 100% trước khi bàn giao.',
          toolCalls: const [
            ToolCallInfo(
              name: 'run_command',
              args: {
                'CommandLine': 'go build -v .',
                'toolSummary': 'Kiểm tra biên dịch Go Server',
              },
              summaryLabel: 'Chạy: go build -v .',
              repoTag: 'muop-erp-server',
            ),
            ToolCallInfo(
              name: 'run_command',
              args: {
                'CommandLine': 'flutter analyze lib/features/retail/order',
                'toolSummary': 'Kiểm tra Flutter Analyzer trên App',
              },
              summaryLabel: 'Chạy: flutter analyze',
              repoTag: 'muop-erp-app',
            ),
          ],
          inputTokens: 11200,
          outputTokens: 540,
          cacheReadTokens: 35000,
          agentName: 'erp-contract-verifier',
          phase: AgentWorkflowPhase.crossVerification,
          vietnameseTitle:
              'Nghiệm thu Kép: Chạy go build -v . (Server) & flutter analyze (App)',
          vietnameseDetail:
              'Kiểm tra chéo hợp đồng API/Socket.IO và xác nhận 0 lỗi biên dịch trên cả 2 dự án',
        ),
      if (stage >= 10)
        AgentStep(
          stepIndex: 5,
          source: 'MODEL',
          type: 'PLANNER_RESPONSE',
          status: 'DONE',
          createdAt: now,
          content:
              'Đã hoàn tất đồng bộ song song tính năng Order giữa muop-erp-server và muop-erp-app. Go Build: CLEAN, Flutter Analyze: CLEAN (No issues found!).',
          thinking: 'Tất cả kiểm thử đã vượt qua 100%.',
          toolCalls: const [],
          inputTokens: 6400,
          outputTokens: 720,
          cacheReadTokens: 42000,
          agentName: 'Coordinator',
          phase: AgentWorkflowPhase.completed,
          vietnameseTitle:
              'Hoàn tất & Bàn giao: Đồng bộ thành công muop-erp-server ↔ muop-erp-app',
          vietnameseDetail:
              'Go Build Status: CLEAN (0) • Flutter Analyze Status: CLEAN (No issues found!)',
        ),
    ];

    return ConversationSession(
      id: 'sim-parallel-erp-sync',
      title:
          '[MÔ PHỎNG TRỰC TIẾP] Đồng bộ tính năng Order (muop-erp-server ↔ muop-erp-app)',
      createdAt: now.subtract(const Duration(seconds: 40)),
      updatedAt: now,
      status: overallStatus,
      currentPhase: currentPhase,
      steps: allSimSteps,
      subagentLanes: [
        SubagentLane(
          id: 'sim-server-agent',
          name: 'erp-server-agent',
          role: 'ERP Server Backend Specialist (Go 1.25 / Fiber v3)',
          targetRepo: 'muop-erp-server',
          status: serverStatus,
          currentPhase: currentPhase,
          currentStepIndex: stage,
          currentActionText: serverAction,
          currentToolName: serverTool,
          promptBrief:
              'Cập nhật Order Entity, MongoDB Repository, Usecase, HTTP Handler, Socket.IO room {merchantId}-order và docs/order-api-reference.md',
          steps: allSimSteps,
          progress: serverProgress,
          filesModified: const [
            '/home/john/Documents/muop-ecosystem/muop-erp-server/api/v1/internal/core/order/domain/order.go',
            '/home/john/Documents/muop-ecosystem/muop-erp-server/api/v1/internal/core/order/delivery/http/order_handler.go',
            '/home/john/Documents/muop-ecosystem/muop-erp-server/docs/order-api-reference.md',
          ],
          lastUpdated: now,
        ),
        SubagentLane(
          id: 'sim-app-agent',
          name: 'erp-app-agent',
          role: 'ERP App Flutter Specialist (Riverpod / M3 / i18n)',
          targetRepo: 'muop-erp-app',
          status: appStatus,
          currentPhase: currentPhase,
          currentStepIndex: stage,
          currentActionText: appAction,
          currentToolName: appTool,
          promptBrief:
              'Đồng bộ Order Model, executeRequest(/order), Riverpod Notifier, Socket.IO listener, giao diện POS Material 3 Dynamic Theming và vi.json/en.json',
          steps: allSimSteps,
          progress: appProgress,
          filesModified: const [
            '/home/john/Documents/muop-ecosystem/muop-erp-app/lib/models/order.dart',
            '/home/john/Documents/muop-ecosystem/muop-erp-app/lib/features/retail/order/sale.dart',
            '/home/john/Documents/muop-ecosystem/muop-erp-app/assets/i18n/vi.json',
            '/home/john/Documents/muop-ecosystem/muop-erp-app/assets/i18n/en.json',
          ],
          lastUpdated: now,
        ),
        SubagentLane(
          id: 'sim-verifier-agent',
          name: 'erp-contract-verifier',
          role: 'Cross-Repo Contract & QA Verifier',
          targetRepo: 'muop-erp-server ↔ muop-erp-app',
          status: verifierStatus,
          currentPhase: currentPhase,
          currentStepIndex: stage,
          currentActionText: verifierAction,
          currentToolName: stage >= 7 && stage < 10 ? 'run_command' : 'verify',
          promptBrief:
              'Đối soát chéo Canonical Endpoint /api/v1/order, Header X-Merchant-Id & X-Branch-Id, JSON schema, go build -v . và flutter analyze',
          steps: allSimSteps,
          progress: verifierProgress,
          filesModified: const [],
          lastUpdated: now,
        ),
      ],
      filesTouched: [
        FileTouchRecord(
          path:
              '/home/john/Documents/muop-ecosystem/muop-erp-server/api/v1/internal/core/order/domain/order.go',
          action: 'EDIT',
          repo: 'muop-erp-server',
          agentName: 'erp-server-agent',
          stepIndex: 3,
          timestamp: now,
          addedLines: 14,
          removedLines: 2,
          diffPreview:
              '- \tTotalAmount float64 `bson:"totalAmount" json:"totalAmount"`\n+ \tTotalAmount  float64 `bson:"totalAmount" json:"totalAmount"`\n+ \tShippingFee  float64 `bson:"shippingFee" json:"shippingFee"`\n+ \tDeliveryNote string  `bson:"deliveryNote" json:"deliveryNote"`',
        ),
        FileTouchRecord(
          path:
              '/home/john/Documents/muop-ecosystem/muop-erp-server/api/v1/internal/core/order/delivery/http/order_handler.go',
          action: 'EDIT',
          repo: 'muop-erp-server',
          agentName: 'erp-server-agent',
          stepIndex: 3,
          timestamp: now,
          addedLines: 22,
          removedLines: 4,
          diffPreview:
              '+ \t// Emit realtime Socket.IO room {merchantId}-order\n+ \tsocket.EmitToRoom(merchantId.Hex()+"-order", "order-update", orderResp)',
        ),
        FileTouchRecord(
          path:
              '/home/john/Documents/muop-ecosystem/muop-erp-server/docs/order-api-reference.md',
          action: 'EDIT',
          repo: 'muop-erp-server',
          agentName: 'erp-server-agent',
          stepIndex: 3,
          timestamp: now,
          addedLines: 18,
          removedLines: 0,
          diffPreview:
              '+ | `shippingFee` | `number` | Phí vận chuyển đơn hàng |\n+ | `deliveryNote` | `string` | Ghi chú giao hàng |',
        ),
        FileTouchRecord(
          path:
              '/home/john/Documents/muop-ecosystem/muop-erp-app/lib/models/order.dart',
          action: 'EDIT',
          repo: 'muop-erp-app',
          agentName: 'erp-app-agent',
          stepIndex: 3,
          timestamp: now,
          addedLines: 16,
          removedLines: 3,
          diffPreview:
              '+ final double shippingFee;\n+ final String deliveryNote;\n+ shippingFee: num.tryParse("\${json[\'shippingFee\'] ?? 0}")?.toDouble() ?? 0.0,',
        ),
        FileTouchRecord(
          path:
              '/home/john/Documents/muop-ecosystem/muop-erp-app/lib/features/retail/order/sale.dart',
          action: 'EDIT',
          repo: 'muop-erp-app',
          agentName: 'erp-app-agent',
          stepIndex: 3,
          timestamp: now,
          addedLines: 34,
          removedLines: 6,
          diffPreview:
              '+ TextField(controller: _deliveryNoteCtrl, decoration: InputDecoration(labelText: context.tr("order.delivery_note")))',
        ),
        FileTouchRecord(
          path:
              '/home/john/Documents/muop-ecosystem/muop-erp-app/assets/i18n/vi.json',
          action: 'EDIT',
          repo: 'muop-erp-app',
          agentName: 'erp-app-agent',
          stepIndex: 3,
          timestamp: now,
          addedLines: 4,
          removedLines: 0,
          diffPreview:
              '+ "shipping_fee": "Phí vận chuyển",\n+ "delivery_note": "Ghi chú giao hàng"',
        ),
      ],
      commandsRun: [
        CommandExecutionRecord(
          commandLine:
              'cd /home/john/Documents/muop-ecosystem/muop-erp-server && go build -v .',
          summary: 'Kiểm tra biên dịch Go Backend (erp-server-agent)',
          agentName: 'erp-server-agent',
          stepIndex: 4,
          timestamp: now,
          outputPreview: 'Go Build Status: CLEAN (exit code 0)',
          isSuccess: true,
        ),
        CommandExecutionRecord(
          commandLine:
              'cd /home/john/Documents/muop-ecosystem/muop-erp-app && flutter analyze lib/features/retail/order',
          summary: 'Phân tích mã nguồn Flutter (erp-app-agent)',
          agentName: 'erp-app-agent',
          stepIndex: 4,
          timestamp: now,
          outputPreview: 'Analyzing order... No issues found!',
          isSuccess: true,
        ),
      ],
      totalInputTokens: 50750,
      totalOutputTokens: 4180,
      totalCacheTokens: 135500,
      projectName: 'muop-erp-server',
      projectPath: '/home/john/Documents/muop-ecosystem/muop-erp-server',
      isSimulated: true,
    );
  }
}
