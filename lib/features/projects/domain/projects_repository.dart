import 'dart:async';

import 'package:muop_agent/features/projects/domain/project_entities.dart';

/// Interface (domain) của feature projects. Presentation chỉ phụ thuộc interface này.
abstract class ProjectsRepository {
  Stream<List<ProjectWorkspace>> get projectsUpdateStream;

  Future<CreateProjectResult> createProject({
    required String address,
    required String name,
    String template = 'standard',
    String description = '',
  });

  Future<ProjectAgentsResponse?> fetchProjectAgents({
    required String address,
    String? projectPath,
    String? projectName,
  });

  Future<List<CustomAgentSpec>?> fetchClaudeExtensions({
    required String address,
    String? projectPath,
  });

  Future<GitPushResponse> gitPush({
    required String address,
    required String projectPath,
    String branch = '',
  });

  Future<GitHistoryResponse> fetchGitHistory({
    required String address,
    required String projectPath,
    String? branch,
    int limit = 100,
  });

  Future<GitCommitDetailResponse> fetchGitCommitDetail({
    required String address,
    required String projectPath,
    required String hash,
  });
}
