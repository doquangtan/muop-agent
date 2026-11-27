
class GitSyncStatus {
  const GitSyncStatus({
    required this.projectPath,
    required this.projectName,
    required this.branch,
    required this.aheadCount,
    required this.lastCommitHash,
    required this.lastCommitMessage,
    required this.lastCommitAuthor,
    required this.lastCommitAt,
    required this.isAhead,
  });

  final String projectPath;
  final String projectName;
  final String branch;
  final int aheadCount;
  final String lastCommitHash;
  final String lastCommitMessage;
  final String lastCommitAuthor;
  final String lastCommitAt;
  final bool isAhead;

  Map<String, dynamic> toJson() => {
        'projectPath': projectPath,
        'projectName': projectName,
        'branch': branch,
        'aheadCount': aheadCount,
        'lastCommitHash': lastCommitHash,
        'lastCommitMessage': lastCommitMessage,
        'lastCommitAuthor': lastCommitAuthor,
        'lastCommitAt': lastCommitAt,
        'isAhead': isAhead,
      };

  factory GitSyncStatus.fromJson(Map<String, dynamic> json) {
    return GitSyncStatus(
      projectPath: '${json['projectPath'] ?? ''}',
      projectName: '${json['projectName'] ?? ''}',
      branch: '${json['branch'] ?? ''}',
      aheadCount: (json['aheadCount'] as num?)?.toInt() ?? 0,
      lastCommitHash: '${json['lastCommitHash'] ?? ''}',
      lastCommitMessage: '${json['lastCommitMessage'] ?? ''}',
      lastCommitAuthor: '${json['lastCommitAuthor'] ?? ''}',
      lastCommitAt: '${json['lastCommitAt'] ?? ''}',
      isAhead: json['isAhead'] == true,
    );
  }
}

class GitPushResponse {
  const GitPushResponse({
    required this.ok,
    required this.message,
    this.output = '',
    this.error,
  });

  final bool ok;
  final String message;
  final String output;
  final String? error;

  factory GitPushResponse.fromJson(Map<String, dynamic> json) {
    return GitPushResponse(
      ok: json['ok'] == true,
      message: json['message']?.toString() ?? '',
      output: json['output']?.toString() ?? '',
      error: json['error']?.toString(),
    );
  }
}

class ProjectWorkspace {
  const ProjectWorkspace({
    required this.id,
    required this.name,
    required this.path,
    required this.sessionCount,
    required this.runningCount,
    this.lastActiveAt,
    this.gitSyncStatus,
    this.customAgents = const [],
    this.availableAgents = const ['Coordinator'],
    this.isMount = false,
    this.mountLive = false,
  });

  final String id;
  final String name;
  final String path;
  final int sessionCount;
  final int runningCount;
  final DateTime? lastActiveAt;
  final GitSyncStatus? gitSyncStatus;
  final List<CustomAgentSpec> customAgents;
  final List<String> availableAgents;

  /// Project là thư mục mount từ máy khác (hiện icon đám mây)
  final bool isMount;

  /// Điểm mount còn là FUSE đang hoạt động (chỉ có nghĩa khi [isMount]). false = đã gỡ: khóa khung chat
  final bool mountLive;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'path': path,
        'sessionCount': sessionCount,
        'runningCount': runningCount,
        'lastActiveAt': lastActiveAt?.toIso8601String(),
        'gitSyncStatus': gitSyncStatus?.toJson(),
        'customAgents': customAgents.map((e) => e.toJson()).toList(),
        'availableAgents': availableAgents,
      };

  factory ProjectWorkspace.fromJson(Map<String, dynamic> json) {
    final customList = <CustomAgentSpec>[];
    if (json['customAgents'] is List) {
      for (final item in json['customAgents'] as List) {
        if (item is Map) {
          customList.add(
            CustomAgentSpec.fromJson(Map<String, dynamic>.from(item)),
          );
        }
      }
    }
    final availList = <String>[];
    if (json['availableAgents'] is List) {
      for (final a in json['availableAgents'] as List) {
        availList.add('$a');
      }
    }
    return ProjectWorkspace(
      id: '${json['id'] ?? ''}',
      name: '${json['name'] ?? ''}',
      path: '${json['path'] ?? ''}',
      isMount: json['isMount'] == true,
      mountLive: json['mountLive'] == true,
      sessionCount: (json['sessionCount'] as num?)?.toInt() ?? 0,
      runningCount: (json['runningCount'] as num?)?.toInt() ?? 0,
      lastActiveAt: json['lastActiveAt'] != null
          ? DateTime.tryParse('${json['lastActiveAt']}')
          : null,
      gitSyncStatus: json['gitSyncStatus'] is Map
          ? GitSyncStatus.fromJson(
              Map<String, dynamic>.from(json['gitSyncStatus'] as Map),
            )
          : null,
      customAgents: customList,
      availableAgents: availList.isNotEmpty ? availList : const ['Coordinator'],
    );
  }
}

class CustomAgentSpec {
  const CustomAgentSpec({
    required this.name,
    required this.description,
    required this.kind,
    required this.filePath,
    required this.bodyContent,
  });

  final String name;
  final String description;
  final String kind;
  final String filePath;
  final String bodyContent;

  Map<String, dynamic> toJson() => {
        'name': name,
        'description': description,
        'kind': kind,
        'filePath': filePath,
        'bodyContent': bodyContent,
      };

  factory CustomAgentSpec.fromJson(Map<String, dynamic> json) {
    return CustomAgentSpec(
      name: '${json['name'] ?? ''}',
      description: '${json['description'] ?? ''}',
      kind: '${json['kind'] ?? 'agent'}',
      filePath: '${json['filePath'] ?? ''}',
      bodyContent: '${json['bodyContent'] ?? ''}',
    );
  }
}

class CreateProjectResult {
  const CreateProjectResult({
    required this.ok,
    required this.message,
    this.project,
    this.error,
  });

  final bool ok;
  final String message;
  final ProjectWorkspace? project;
  final String? error;

  factory CreateProjectResult.fromJson(Map<String, dynamic> json) {
    return CreateProjectResult(
      ok: json['ok'] == true,
      message: json['message']?.toString() ?? '',
      project: json['project'] is Map
          ? ProjectWorkspace.fromJson(
              Map<String, dynamic>.from(json['project'] as Map),
            )
          : null,
      error: json['error']?.toString(),
    );
  }
}

class ProjectAgentsResponse {
  const ProjectAgentsResponse({
    required this.ok,
    required this.projectPath,
    required this.projectName,
    required this.availableAgents,
    required this.customAgents,
    required this.skills,
    required this.rules,
    this.error,
  });

  final bool ok;
  final String projectPath;
  final String projectName;
  final List<String> availableAgents;
  final List<CustomAgentSpec> customAgents;
  final List<CustomAgentSpec> skills;
  final List<CustomAgentSpec> rules;
  final String? error;

  factory ProjectAgentsResponse.fromJson(Map<String, dynamic> json) {
    final available = <String>[];
    if (json['availableAgents'] is List) {
      for (final a in json['availableAgents'] as List) {
        available.add('$a');
      }
    }

    List<CustomAgentSpec> parseList(dynamic raw) {
      final list = <CustomAgentSpec>[];
      if (raw is List) {
        for (final item in raw) {
          if (item is Map) {
            list.add(CustomAgentSpec.fromJson(Map<String, dynamic>.from(item)));
          }
        }
      }
      return list;
    }

    return ProjectAgentsResponse(
      ok: json['ok'] == true,
      projectPath: '${json['projectPath'] ?? ''}',
      projectName: '${json['projectName'] ?? ''}',
      availableAgents: available,
      customAgents: parseList(json['customAgents']),
      skills: parseList(json['skills']),
      rules: parseList(json['rules']),
      error: json['error']?.toString(),
    );
  }
}

class GitCommitSummary {
  const GitCommitSummary({
    required this.hash,
    required this.shortHash,
    required this.authorName,
    required this.authorEmail,
    required this.committedAt,
    required this.relativeTime,
    required this.subject,
    required this.body,
    required this.parentHashes,
    required this.refs,
    required this.isHead,
    this.filesCount = 0,
  });

  final String hash;
  final String shortHash;
  final String authorName;
  final String authorEmail;
  final String committedAt;
  final String relativeTime;
  final String subject;
  final String body;
  final List<String> parentHashes;
  final List<String> refs;
  final bool isHead;
  final int filesCount;

  factory GitCommitSummary.fromJson(Map<String, dynamic> json) {
    return GitCommitSummary(
      hash: '${json['hash'] ?? ''}',
      shortHash: '${json['shortHash'] ?? ''}',
      authorName: '${json['authorName'] ?? ''}',
      authorEmail: '${json['authorEmail'] ?? ''}',
      committedAt: '${json['committedAt'] ?? ''}',
      relativeTime: '${json['relativeTime'] ?? ''}',
      subject: '${json['subject'] ?? ''}',
      body: '${json['body'] ?? ''}',
      parentHashes: (json['parentHashes'] as List?)?.map((e) => '$e').toList() ?? const [],
      refs: (json['refs'] as List?)?.map((e) => '$e').toList() ?? const [],
      isHead: json['isHead'] == true,
      filesCount: (json['filesCount'] as num?)?.toInt() ?? 0,
    );
  }
}

class GitHistoryResponse {
  const GitHistoryResponse({
    required this.ok,
    required this.projectPath,
    required this.projectName,
    required this.currentBranch,
    required this.branches,
    required this.totalCommits,
    required this.commits,
    this.error,
  });

  final bool ok;
  final String projectPath;
  final String projectName;
  final String currentBranch;
  final List<String> branches;
  final int totalCommits;
  final List<GitCommitSummary> commits;
  final String? error;

  factory GitHistoryResponse.fromJson(Map<String, dynamic> json) {
    final commitList = <GitCommitSummary>[];
    if (json['commits'] is List) {
      for (final item in json['commits'] as List) {
        if (item is Map) {
          commitList.add(GitCommitSummary.fromJson(Map<String, dynamic>.from(item)));
        }
      }
    }

    final branchList = (json['branches'] as List?)?.map((e) => '$e').toList() ?? const <String>[];

    return GitHistoryResponse(
      ok: json['ok'] == true,
      projectPath: '${json['projectPath'] ?? ''}',
      projectName: '${json['projectName'] ?? ''}',
      currentBranch: '${json['currentBranch'] ?? ''}',
      branches: branchList,
      totalCommits: (json['totalCommits'] as num?)?.toInt() ?? commitList.length,
      commits: commitList,
      error: json['error']?.toString(),
    );
  }
}

class GitCommitFileChange {
  const GitCommitFileChange({
    required this.path,
    required this.status,
    required this.additions,
    required this.deletions,
  });

  final String path;
  final String status;
  final int additions;
  final int deletions;

  factory GitCommitFileChange.fromJson(Map<String, dynamic> json) {
    return GitCommitFileChange(
      path: '${json['path'] ?? ''}',
      status: '${json['status'] ?? 'M'}',
      additions: (json['additions'] as num?)?.toInt() ?? 0,
      deletions: (json['deletions'] as num?)?.toInt() ?? 0,
    );
  }
}

class GitCommitDetailResponse {
  const GitCommitDetailResponse({
    required this.ok,
    required this.projectPath,
    required this.hash,
    required this.shortHash,
    required this.authorName,
    required this.authorEmail,
    required this.committedAt,
    required this.relativeTime,
    required this.subject,
    required this.body,
    required this.parentHashes,
    required this.refs,
    required this.files,
    required this.diff,
    this.error,
  });

  final bool ok;
  final String projectPath;
  final String hash;
  final String shortHash;
  final String authorName;
  final String authorEmail;
  final String committedAt;
  final String relativeTime;
  final String subject;
  final String body;
  final List<String> parentHashes;
  final List<String> refs;
  final List<GitCommitFileChange> files;
  final String diff;
  final String? error;

  factory GitCommitDetailResponse.fromJson(Map<String, dynamic> json) {
    final fileList = <GitCommitFileChange>[];
    if (json['files'] is List) {
      for (final item in json['files'] as List) {
        if (item is Map) {
          fileList.add(GitCommitFileChange.fromJson(Map<String, dynamic>.from(item)));
        }
      }
    }

    return GitCommitDetailResponse(
      ok: json['ok'] == true,
      projectPath: '${json['projectPath'] ?? ''}',
      hash: '${json['hash'] ?? ''}',
      shortHash: '${json['shortHash'] ?? ''}',
      authorName: '${json['authorName'] ?? ''}',
      authorEmail: '${json['authorEmail'] ?? ''}',
      committedAt: '${json['committedAt'] ?? ''}',
      relativeTime: '${json['relativeTime'] ?? ''}',
      subject: '${json['subject'] ?? ''}',
      body: '${json['body'] ?? ''}',
      parentHashes: (json['parentHashes'] as List?)?.map((e) => '$e').toList() ?? const [],
      refs: (json['refs'] as List?)?.map((e) => '$e').toList() ?? const [],
      files: fileList,
      diff: '${json['diff'] ?? ''}',
      error: json['error']?.toString(),
    );
  }
}

/// Lý do khóa khung chat vì project mount đã gỡ (FUSE không còn gắn), null nếu được phép gửi.
/// Chỉ máy chính gọi lượt chat qua cầu nối mới mount lại; khung chat mở lại khi mount hoạt động.
String? mountBlockReason(ProjectWorkspace? project) {
  if (project == null || !project.isMount || project.mountLive) return null;
  return 'Project đang mount từ máy khác đã ngắt. Khung chat bị khóa cho đến khi máy chính gửi lệnh để mount lại.';
}
