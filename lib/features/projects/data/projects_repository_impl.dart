import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:muop_agent/core/config/server_config.dart';
import 'package:muop_agent/core/network/socket_gateway.dart';
import 'package:muop_agent/features/projects/domain/project_entities.dart';
import 'package:muop_agent/features/projects/domain/projects_repository.dart';

class ProjectsRepositoryImpl implements ProjectsRepository {
  final SocketGateway _gateway;
  ProjectsRepositoryImpl(this._gateway) {
    _gateway.on('projects:update').listen((data) {
      if (_projectsUpdateController.isClosed || data == null) return;
      try {
        List? list;
        if (data is List) {
          list = data;
        } else if (data is String) {
          list = jsonDecode(data) as List?;
        }
        if (list != null) {
          final projects = list
              .map((item) => ProjectWorkspace.fromJson(item is Map<String, dynamic>
                  ? item
                  : Map<String, dynamic>.from(item as Map)))
              .toList();
          _projectsUpdateController.add(projects);
        }
      } catch (_) {}
    });
  }

  final StreamController<List<ProjectWorkspace>> _projectsUpdateController =
      StreamController<List<ProjectWorkspace>>.broadcast();

  @override
  Stream<List<ProjectWorkspace>> get projectsUpdateStream =>
      _projectsUpdateController.stream;

  /// Tạo project mới trên Rust Server (`/api/project/create`)
  @override
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
  @override
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

  /// Lấy skill, agent và command của Claude Code CLI theo dự án (`/api/claude/extensions`)
  @override
  Future<List<CustomAgentSpec>?> fetchClaudeExtensions({
    required String address,
    String? projectPath,
  }) async {
    final baseUrl = normalizeBaseUrl(address);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 4);
    try {
      final queryParams = <String, String>{};
      if (projectPath != null && projectPath.trim().isNotEmpty) {
        queryParams['path'] = projectPath.trim();
      }
      final uri = Uri.parse('$baseUrl/api/claude/extensions').replace(
        queryParameters: queryParams.isNotEmpty ? queryParams : null,
      );
      final req = await client.getUrl(uri);
      final resp = await req.close().timeout(const Duration(seconds: 6));
      if (resp.statusCode == HttpStatus.ok) {
        final body = await resp.transform(utf8.decoder).join();
        final map = jsonDecode(body) as Map<String, dynamic>;
        final raw = map['items'];
        if (raw is! List) return const [];
        return raw
            .whereType<Map>()
            .map((e) => CustomAgentSpec.fromJson(Map<String, dynamic>.from(e)))
            .toList();
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// Đẩy commits lên máy chủ từ xa remote git repository (`/api/git/push`)
  @override
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

  /// Lấy toàn bộ lịch sử Git commits & Git tree của dự án (`/api/git/history`)
  @override
  Future<GitHistoryResponse> fetchGitHistory({
    required String address,
    required String projectPath,
    String? branch,
    int limit = 100,
  }) async {
    final baseUrl = normalizeBaseUrl(address);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8);
    try {
      final uri = Uri.parse('$baseUrl/api/git/history').replace(
        queryParameters: {
          'project_path': projectPath.trim(),
          if (branch != null && branch.trim().isNotEmpty)
            'branch': branch.trim(),
          'limit': limit.toString(),
        },
      );
      final req = await client.getUrl(uri);
      final resp = await req.close().timeout(const Duration(seconds: 12));
      final body = await resp.transform(utf8.decoder).join();
      final map = jsonDecode(body) as Map<String, dynamic>;
      return GitHistoryResponse.fromJson(map);
    } catch (e) {
      return GitHistoryResponse(
        ok: false,
        projectPath: projectPath,
        projectName: projectPath.split('/').last,
        currentBranch: '',
        branches: const [],
        totalCommits: 0,
        commits: const [],
        error: '$e',
      );
    } finally {
      client.close(force: true);
    }
  }

  /// Lấy chi tiết một commit kèm danh sách file thay đổi và unified diff (`/api/git/commit`)
  @override
  Future<GitCommitDetailResponse> fetchGitCommitDetail({
    required String address,
    required String projectPath,
    required String hash,
  }) async {
    final baseUrl = normalizeBaseUrl(address);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final uri = Uri.parse('$baseUrl/api/git/commit').replace(
        queryParameters: {
          'project_path': projectPath.trim(),
          'hash': hash.trim(),
        },
      );
      final req = await client.getUrl(uri);
      final resp = await req.close().timeout(const Duration(seconds: 15));
      final body = await resp.transform(utf8.decoder).join();
      final map = jsonDecode(body) as Map<String, dynamic>;
      return GitCommitDetailResponse.fromJson(map);
    } catch (e) {
      return GitCommitDetailResponse(
        ok: false,
        projectPath: projectPath,
        hash: hash,
        shortHash: hash.length >= 7 ? hash.substring(0, 7) : hash,
        authorName: '',
        authorEmail: '',
        committedAt: '',
        relativeTime: '',
        subject: '',
        body: '',
        parentHashes: const [],
        refs: const [],
        files: const [],
        diff: '',
        error: '$e',
      );
    } finally {
      client.close(force: true);
    }
  }
}
