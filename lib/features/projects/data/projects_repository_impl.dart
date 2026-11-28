import 'dart:async';
import 'dart:convert';

import 'package:muop_agent/core/config/server_config.dart';
import 'package:muop_agent/core/network/rest_client.dart';
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
    try {
      final reply = await httpRequest(
        'POST',
        Uri.parse('$baseUrl/api/project/create'),
        json: {
          'name': name.trim(),
          'template': template,
          'description': description.trim(),
        },
        timeout: const Duration(seconds: 10),
      );
      final map = jsonDecode(reply.text) as Map<String, dynamic>;
      return CreateProjectResult.fromJson(map);
    } catch (e) {
      return CreateProjectResult(
        ok: false,
        message: 'Lỗi kết nối tới Rust Server: $e',
        error: '$e',
      );
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
      final reply = await httpRequest('GET', uri, timeout: const Duration(seconds: 6));
      if (reply.status == 200) {
        final map = jsonDecode(reply.text) as Map<String, dynamic>;
        return ProjectAgentsResponse.fromJson(map);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Lấy skill, agent và command của Claude Code CLI theo dự án (`/api/claude/extensions`)
  @override
  Future<List<CustomAgentSpec>?> fetchClaudeExtensions({
    required String address,
    String? projectPath,
  }) async {
    final baseUrl = normalizeBaseUrl(address);
    try {
      final queryParams = <String, String>{};
      if (projectPath != null && projectPath.trim().isNotEmpty) {
        queryParams['path'] = projectPath.trim();
      }
      final uri = Uri.parse('$baseUrl/api/claude/extensions').replace(
        queryParameters: queryParams.isNotEmpty ? queryParams : null,
      );
      final reply = await httpRequest('GET', uri, timeout: const Duration(seconds: 6));
      if (reply.status == 200) {
        final map = jsonDecode(reply.text) as Map<String, dynamic>;
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
    try {
      final reply = await httpRequest(
        'POST',
        Uri.parse('$baseUrl/api/git/push'),
        json: {
          'projectPath': projectPath.trim(),
          'branch': branch.trim(),
        },
        timeout: const Duration(seconds: 35),
      );
      final map = jsonDecode(reply.text) as Map<String, dynamic>;
      return GitPushResponse.fromJson(map);
    } catch (e) {
      return GitPushResponse(
        ok: false,
        message: 'Lỗi kết nối khi git push: $e',
        error: '$e',
      );
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
    try {
      final uri = Uri.parse('$baseUrl/api/git/history').replace(
        queryParameters: {
          'project_path': projectPath.trim(),
          if (branch != null && branch.trim().isNotEmpty)
            'branch': branch.trim(),
          'limit': limit.toString(),
        },
      );
      final reply = await httpRequest('GET', uri, timeout: const Duration(seconds: 12));
      final map = jsonDecode(reply.text) as Map<String, dynamic>;
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
    try {
      final uri = Uri.parse('$baseUrl/api/git/commit').replace(
        queryParameters: {
          'project_path': projectPath.trim(),
          'hash': hash.trim(),
        },
      );
      final reply = await httpRequest('GET', uri, timeout: const Duration(seconds: 15));
      final map = jsonDecode(reply.text) as Map<String, dynamic>;
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
    }
  }
}
