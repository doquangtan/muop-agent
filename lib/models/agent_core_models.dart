enum AgentWorkflowPhase {
  contractDiscovery(
    stepNumber: 1,
    title: 'Khảo sát & Chốt Contract',
    subtitle: 'Đọc cấu trúc code & thống nhất API / Socket.IO',
  ),
  parallelExecution(
    stepNumber: 2,
    title: 'Thực thi Song song (Server ↔ App)',
    subtitle: 'erp-server-agent & erp-app-agent đồng thời sửa code',
  ),
  crossVerification(
    stepNumber: 3,
    title: 'Đối soát & Kiểm thử Kép',
    subtitle: 'Chạy go build -v . & flutter analyze sạch lỗi 100%',
  ),
  completed(
    stepNumber: 4,
    title: 'Hoàn tất & Bàn giao',
    subtitle: 'Đồng bộ thành công cả Backend Go và Flutter App',
  );

  const AgentWorkflowPhase({
    required this.stepNumber,
    required this.title,
    required this.subtitle,
  });

  final int stepNumber;
  final String title;
  final String subtitle;

  static AgentWorkflowPhase fromName(String? name) {
    for (final v in AgentWorkflowPhase.values) {
      if (v.name == name) return v;
    }
    return AgentWorkflowPhase.contractDiscovery;
  }
}

enum AgentStatus {
  running('ĐANG CHẠY'),
  waiting('ĐANG CHỜ ĐỒNG BỘ'),
  completed('HOÀN TẤT'),
  interrupted('BỊ GIÁN ĐOẠN'),
  error('CẢNH BÁO / LỖI'),
  idle('SẴN SÀNG');

  const AgentStatus(this.label);
  final String label;

  static AgentStatus fromName(String? name) {
    if (name == 'interrupted') return AgentStatus.interrupted;
    for (final v in AgentStatus.values) {
      if (v.name == name) return v;
    }
    return AgentStatus.idle;
  }
}

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

class ChatTurnStreamState {
  const ChatTurnStreamState({
    required this.conversationId,
    required this.projectPath,
    required this.userPrompt,
    required this.streamingText,
    required this.isRunning,
    required this.activeStepType,
    required this.startedAt,
    this.error = '',
    this.thinkingText = '',
  });

  final String conversationId;
  final String projectPath;
  final String userPrompt;
  final String streamingText;
  final bool isRunning;
  final String activeStepType;
  final DateTime startedAt;
  final String error;
  final String thinkingText;

  ChatTurnStreamState copyWith({
    String? conversationId,
    String? projectPath,
    String? userPrompt,
    String? streamingText,
    bool? isRunning,
    String? activeStepType,
    DateTime? startedAt,
    String? error,
    String? thinkingText,
  }) {
    return ChatTurnStreamState(
      conversationId: conversationId ?? this.conversationId,
      projectPath: projectPath ?? this.projectPath,
      userPrompt: userPrompt ?? this.userPrompt,
      streamingText: streamingText ?? this.streamingText,
      isRunning: isRunning ?? this.isRunning,
      activeStepType: activeStepType ?? this.activeStepType,
      startedAt: startedAt ?? this.startedAt,
      error: error ?? this.error,
      thinkingText: thinkingText ?? this.thinkingText,
    );
  }

  Map<String, dynamic> toJson() => {
        'conversationId': conversationId,
        'projectPath': projectPath,
        'userPrompt': userPrompt,
        'streamingText': streamingText,
        'isRunning': isRunning,
        'activeStepType': activeStepType,
        'startedAt': startedAt.toIso8601String(),
        'error': error,
        'thinkingText': thinkingText,
      };

  factory ChatTurnStreamState.fromJson(Map<String, dynamic> json) {
    return ChatTurnStreamState(
      conversationId: '${json['conversationId'] ?? ''}',
      projectPath: '${json['projectPath'] ?? ''}',
      userPrompt: '${json['userPrompt'] ?? ''}',
      streamingText: '${json['streamingText'] ?? ''}',
      isRunning: json['isRunning'] == true,
      activeStepType: '${json['activeStepType'] ?? 'thinking'}',
      startedAt:
          DateTime.tryParse('${json['startedAt'] ?? ''}') ?? DateTime.now(),
      error: '${json['error'] ?? ''}',
      thinkingText: '${json['thinkingText'] ?? ''}',
    );
  }
}

class ToolCallInfo {
  const ToolCallInfo({
    required this.name,
    required this.args,
    required this.summaryLabel,
    this.targetPath,
    required this.repoTag,
  });

  final String name;
  final Map<String, dynamic> args;
  final String summaryLabel;
  final String? targetPath;
  final String repoTag;

  Map<String, dynamic> toJson() => {
        'name': name,
        'args': args,
        'summaryLabel': summaryLabel,
        'targetPath': targetPath,
        'repoTag': repoTag,
      };

  factory ToolCallInfo.fromJson(Map<String, dynamic> json) {
    final rawArgs = json['args'];
    final parsedArgs = <String, dynamic>{};
    if (rawArgs is Map) {
      rawArgs.forEach((k, v) => parsedArgs['$k'] = v);
    }
    return ToolCallInfo(
      name: '${json['name'] ?? ''}',
      args: parsedArgs,
      summaryLabel: '${json['summaryLabel'] ?? ''}',
      targetPath: json['targetPath'] as String?,
      repoTag: '${json['repoTag'] ?? 'system'}',
    );
  }
}

class AgentStep {
  const AgentStep({
    required this.stepIndex,
    required this.source,
    required this.type,
    required this.status,
    required this.createdAt,
    required this.content,
    required this.thinking,
    required this.toolCalls,
    required this.inputTokens,
    required this.outputTokens,
    required this.cacheReadTokens,
    required this.agentName,
    required this.phase,
    required this.vietnameseTitle,
    required this.vietnameseDetail,
    this.model = '',
  });

  final int stepIndex;
  final String source;
  final String type;
  final String status;
  final DateTime createdAt;
  final String content;
  final String thinking;
  final List<ToolCallInfo> toolCalls;
  final int inputTokens;
  final int outputTokens;
  final int cacheReadTokens;
  final String agentName;
  final AgentWorkflowPhase phase;
  final String vietnameseTitle;
  final String vietnameseDetail;

  /// Model thực tế đã trả lời (vd. `claude-haiku-5-5`), rỗng nếu không xác định
  final String model;

  Map<String, dynamic> toJson() => {
        'stepIndex': stepIndex,
        'source': source,
        'type': type,
        'status': status,
        'createdAt': createdAt.toIso8601String(),
        'content': content,
        'thinking': thinking,
        'toolCalls': toolCalls.map((e) => e.toJson()).toList(),
        'inputTokens': inputTokens,
        'outputTokens': outputTokens,
        'cacheReadTokens': cacheReadTokens,
        'agentName': agentName,
        'phase': phase.name,
        'vietnameseTitle': vietnameseTitle,
        'vietnameseDetail': vietnameseDetail,
        'model': model,
      };

  factory AgentStep.fromJson(Map<String, dynamic> json) {
    final rawTools = json['toolCalls'];
    final tools = <ToolCallInfo>[];
    if (rawTools is List) {
      for (final item in rawTools) {
        if (item is Map<String, dynamic>) {
          tools.add(ToolCallInfo.fromJson(item));
        } else if (item is Map) {
          tools.add(ToolCallInfo.fromJson(Map<String, dynamic>.from(item)));
        }
      }
    }
    return AgentStep(
      stepIndex: (json['stepIndex'] as num?)?.toInt() ?? 0,
      source: '${json['source'] ?? 'MODEL'}',
      type: '${json['type'] ?? 'GENERIC'}',
      status: '${json['status'] ?? 'DONE'}',
      createdAt:
          DateTime.tryParse('${json['createdAt'] ?? ''}') ?? DateTime.now(),
      content: '${json['content'] ?? ''}',
      thinking: '${json['thinking'] ?? ''}',
      toolCalls: tools,
      inputTokens: (json['inputTokens'] as num?)?.toInt() ?? 0,
      outputTokens: (json['outputTokens'] as num?)?.toInt() ?? 0,
      cacheReadTokens: (json['cacheReadTokens'] as num?)?.toInt() ?? 0,
      agentName: '${json['agentName'] ?? 'Coordinator'}',
      phase: AgentWorkflowPhase.fromName(json['phase'] as String?),
      vietnameseTitle: '${json['vietnameseTitle'] ?? ''}',
      vietnameseDetail: '${json['vietnameseDetail'] ?? ''}',
      model: '${json['model'] ?? ''}',
    );
  }
}

class SubagentLane {
  const SubagentLane({
    required this.id,
    required this.name,
    required this.role,
    required this.targetRepo,
    required this.status,
    required this.currentPhase,
    required this.currentStepIndex,
    required this.currentActionText,
    required this.currentToolName,
    required this.promptBrief,
    required this.steps,
    required this.progress,
    required this.filesModified,
    this.lastUpdated,
  });

  final String id;
  final String name;
  final String role;
  final String targetRepo;
  final AgentStatus status;
  final AgentWorkflowPhase currentPhase;
  final int currentStepIndex;
  final String currentActionText;
  final String currentToolName;
  final String promptBrief;
  final List<AgentStep> steps;
  final double progress;
  final List<String> filesModified;
  final DateTime? lastUpdated;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'role': role,
        'targetRepo': targetRepo,
        'status': status.name,
        'currentPhase': currentPhase.name,
        'currentStepIndex': currentStepIndex,
        'currentActionText': currentActionText,
        'currentToolName': currentToolName,
        'promptBrief': promptBrief,
        'steps': steps.map((e) => e.toJson()).toList(),
        'progress': progress,
        'filesModified': filesModified,
        'lastUpdated': lastUpdated?.toIso8601String(),
      };

  factory SubagentLane.fromJson(Map<String, dynamic> json) {
    final rawSteps = json['steps'];
    final parsedSteps = <AgentStep>[];
    if (rawSteps is List) {
      for (final item in rawSteps) {
        if (item is Map) {
          parsedSteps.add(AgentStep.fromJson(Map<String, dynamic>.from(item)));
        }
      }
    }
    final rawFiles = json['filesModified'];
    final parsedFiles = <String>[];
    if (rawFiles is List) {
      for (final f in rawFiles) {
        parsedFiles.add('$f');
      }
    }
    return SubagentLane(
      id: '${json['id'] ?? ''}',
      name: '${json['name'] ?? ''}',
      role: '${json['role'] ?? ''}',
      targetRepo: '${json['targetRepo'] ?? ''}',
      status: AgentStatus.fromName(json['status'] as String?),
      currentPhase:
          AgentWorkflowPhase.fromName(json['currentPhase'] as String?),
      currentStepIndex: (json['currentStepIndex'] as num?)?.toInt() ?? 0,
      currentActionText: '${json['currentActionText'] ?? ''}',
      currentToolName: '${json['currentToolName'] ?? 'standby'}',
      promptBrief: '${json['promptBrief'] ?? ''}',
      steps: parsedSteps,
      progress: (json['progress'] as num?)?.toDouble() ?? 0.0,
      filesModified: parsedFiles,
      lastUpdated: json['lastUpdated'] != null
          ? DateTime.tryParse('${json['lastUpdated']}')
          : null,
    );
  }
}

class FileTouchRecord {
  const FileTouchRecord({
    required this.path,
    required this.action,
    required this.repo,
    required this.agentName,
    required this.stepIndex,
    required this.timestamp,
    this.addedLines = 0,
    this.removedLines = 0,
    this.diffPreview = '',
    this.source = '',
  });

  final String path;
  final String action;
  final String repo;
  final String agentName;
  final int stepIndex;
  final DateTime timestamp;
  final int addedLines;
  final int removedLines;
  final String diffPreview;

  /// `bash` khi thay đổi được suy ra từ lệnh Bash, rỗng khi từ tool Edit/Write
  final String source;

  String get basename {
    final parts = path.split('/');
    return parts.isNotEmpty ? parts.last : path;
  }

  bool get isModifiedOrCreated =>
      action == 'EDIT' || action == 'WRITE' || addedLines > 0 || removedLines > 0;

  Map<String, dynamic> toJson() => {
        'path': path,
        'action': action,
        'repo': repo,
        'agentName': agentName,
        'stepIndex': stepIndex,
        'timestamp': timestamp.toIso8601String(),
        'addedLines': addedLines,
        'removedLines': removedLines,
        'diffPreview': diffPreview,
        'source': source,
      };

  factory FileTouchRecord.fromJson(Map<String, dynamic> json) {
    return FileTouchRecord(
      path: '${json['path'] ?? ''}',
      action: '${json['action'] ?? 'READ'}',
      repo: '${json['repo'] ?? 'system'}',
      agentName: '${json['agentName'] ?? 'Coordinator'}',
      stepIndex: (json['stepIndex'] as num?)?.toInt() ?? 0,
      timestamp:
          DateTime.tryParse('${json['timestamp'] ?? ''}') ?? DateTime.now(),
      addedLines: (json['addedLines'] as num?)?.toInt() ?? 0,
      removedLines: (json['removedLines'] as num?)?.toInt() ?? 0,
      diffPreview: '${json['diffPreview'] ?? ''}',
      source: '${json['source'] ?? ''}',
    );
  }
}

class CommandExecutionRecord {
  const CommandExecutionRecord({
    required this.commandLine,
    required this.summary,
    required this.agentName,
    required this.stepIndex,
    required this.timestamp,
    required this.outputPreview,
    required this.isSuccess,
  });

  final String commandLine;
  final String summary;
  final String agentName;
  final int stepIndex;
  final DateTime timestamp;
  final String outputPreview;
  final bool isSuccess;

  Map<String, dynamic> toJson() => {
        'commandLine': commandLine,
        'summary': summary,
        'agentName': agentName,
        'stepIndex': stepIndex,
        'timestamp': timestamp.toIso8601String(),
        'outputPreview': outputPreview,
        'isSuccess': isSuccess,
      };

  factory CommandExecutionRecord.fromJson(Map<String, dynamic> json) {
    return CommandExecutionRecord(
      commandLine: '${json['commandLine'] ?? ''}',
      summary: '${json['summary'] ?? ''}',
      agentName: '${json['agentName'] ?? 'Coordinator'}',
      stepIndex: (json['stepIndex'] as num?)?.toInt() ?? 0,
      timestamp:
          DateTime.tryParse('${json['timestamp'] ?? ''}') ?? DateTime.now(),
      outputPreview: '${json['outputPreview'] ?? ''}',
      isSuccess: json['isSuccess'] != false,
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

class ConversationSession {
  const ConversationSession({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    required this.status,
    required this.currentPhase,
    required this.steps,
    required this.subagentLanes,
    required this.filesTouched,
    required this.commandsRun,
    required this.totalInputTokens,
    required this.totalOutputTokens,
    required this.totalCacheTokens,
    this.projectName = 'muop-erp-server',
    this.projectPath = '/home/john/Documents/muop-ecosystem/muop-erp-server',
    this.isSimulated = false,
    this.pendingPlans = const [],
    this.gitSyncStatus,
    this.isInterrupted = false,
    this.interruptedReason,
    this.customAgents = const [],
    this.availableAgents = const ['Coordinator'],
    this.hasParallelFlow = false,
    this.source = 'agy',
    this.contextTokens = 0,
    this.contextModel = '',
  });

  final String id;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;
  final AgentStatus status;
  final AgentWorkflowPhase currentPhase;
  final List<AgentStep> steps;
  final List<SubagentLane> subagentLanes;
  final List<FileTouchRecord> filesTouched;
  final List<CommandExecutionRecord> commandsRun;
  final int totalInputTokens;
  final int totalOutputTokens;
  final int totalCacheTokens;
  final String projectName;
  final String projectPath;
  final bool isSimulated;
  final List<PlanArtifactInfo> pendingPlans;
  final GitSyncStatus? gitSyncStatus;
  final bool isInterrupted;
  final String? interruptedReason;
  final List<CustomAgentSpec> customAgents;
  final List<String> availableAgents;
  final bool hasParallelFlow;
  final String source;
  /// Số token context đang dùng ở lượt gọi model gần nhất (0 = chưa rõ)
  final int contextTokens;
  /// Model id (có tiền tố provider) của lượt gần nhất, dùng để tra giới hạn context
  final String contextModel;

  int get subagentCount => subagentLanes.length;

  ConversationSession copyWith({
    String? id,
    String? title,
    DateTime? createdAt,
    DateTime? updatedAt,
    AgentStatus? status,
    AgentWorkflowPhase? currentPhase,
    List<AgentStep>? steps,
    List<SubagentLane>? subagentLanes,
    List<FileTouchRecord>? filesTouched,
    List<CommandExecutionRecord>? commandsRun,
    int? totalInputTokens,
    int? totalOutputTokens,
    int? totalCacheTokens,
    String? projectName,
    String? projectPath,
    bool? isSimulated,
    List<PlanArtifactInfo>? pendingPlans,
    GitSyncStatus? gitSyncStatus,
    bool? isInterrupted,
    String? interruptedReason,
    List<CustomAgentSpec>? customAgents,
    List<String>? availableAgents,
    bool? hasParallelFlow,
    String? source,
    int? contextTokens,
    String? contextModel,
  }) {
    return ConversationSession(
      id: id ?? this.id,
      title: title ?? this.title,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      status: status ?? this.status,
      currentPhase: currentPhase ?? this.currentPhase,
      steps: steps ?? this.steps,
      subagentLanes: subagentLanes ?? this.subagentLanes,
      filesTouched: filesTouched ?? this.filesTouched,
      commandsRun: commandsRun ?? this.commandsRun,
      totalInputTokens: totalInputTokens ?? this.totalInputTokens,
      totalOutputTokens: totalOutputTokens ?? this.totalOutputTokens,
      totalCacheTokens: totalCacheTokens ?? this.totalCacheTokens,
      projectName: projectName ?? this.projectName,
      projectPath: projectPath ?? this.projectPath,
      isSimulated: isSimulated ?? this.isSimulated,
      pendingPlans: pendingPlans ?? this.pendingPlans,
      gitSyncStatus: gitSyncStatus ?? this.gitSyncStatus,
      isInterrupted: isInterrupted ?? this.isInterrupted,
      interruptedReason: interruptedReason ?? this.interruptedReason,
      customAgents: customAgents ?? this.customAgents,
      availableAgents: availableAgents ?? this.availableAgents,
      hasParallelFlow: hasParallelFlow ?? this.hasParallelFlow,
      source: source ?? this.source,
      contextTokens: contextTokens ?? this.contextTokens,
      contextModel: contextModel ?? this.contextModel,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'status': status.name,
        'currentPhase': currentPhase.name,
        'steps': steps.map((e) => e.toJson()).toList(),
        'subagentLanes': subagentLanes.map((e) => e.toJson()).toList(),
        'filesTouched': filesTouched.map((e) => e.toJson()).toList(),
        'commandsRun': commandsRun.map((e) => e.toJson()).toList(),
        'totalInputTokens': totalInputTokens,
        'totalOutputTokens': totalOutputTokens,
        'totalCacheTokens': totalCacheTokens,
        'projectName': projectName,
        'projectPath': projectPath,
        'isSimulated': isSimulated,
        'pendingPlans': pendingPlans.map((e) => e.toJson()).toList(),
        'gitSyncStatus': gitSyncStatus?.toJson(),
        'isInterrupted': isInterrupted,
        'interruptedReason': interruptedReason,
        'customAgents': customAgents.map((e) => e.toJson()).toList(),
        'availableAgents': availableAgents,
        'hasParallelFlow': hasParallelFlow,
        'source': source,
        'contextTokens': contextTokens,
        'contextModel': contextModel,
      };

  factory ConversationSession.fromJson(Map<String, dynamic> json) {
    final steps = <AgentStep>[];
    if (json['steps'] is List) {
      for (final item in json['steps'] as List) {
        if (item is Map) {
          steps.add(AgentStep.fromJson(Map<String, dynamic>.from(item)));
        }
      }
    }

    final lanes = <SubagentLane>[];
    if (json['subagentLanes'] is List) {
      for (final item in json['subagentLanes'] as List) {
        if (item is Map) {
          lanes.add(SubagentLane.fromJson(Map<String, dynamic>.from(item)));
        }
      }
    }

    final files = <FileTouchRecord>[];
    if (json['filesTouched'] is List) {
      for (final item in json['filesTouched'] as List) {
        if (item is Map) {
          files.add(FileTouchRecord.fromJson(Map<String, dynamic>.from(item)));
        }
      }
    }

    final commands = <CommandExecutionRecord>[];
    if (json['commandsRun'] is List) {
      for (final item in json['commandsRun'] as List) {
        if (item is Map) {
          commands.add(
            CommandExecutionRecord.fromJson(Map<String, dynamic>.from(item)),
          );
        }
      }
    }

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

    return ConversationSession(
      id: '${json['id'] ?? ''}',
      title: '${json['title'] ?? ''}',
      createdAt:
          DateTime.tryParse('${json['createdAt'] ?? ''}') ?? DateTime.now(),
      updatedAt:
          DateTime.tryParse('${json['updatedAt'] ?? ''}') ?? DateTime.now(),
      status: AgentStatus.fromName(json['status'] as String?),
      currentPhase:
          AgentWorkflowPhase.fromName(json['currentPhase'] as String?),
      steps: steps,
      subagentLanes: lanes,
      filesTouched: files,
      commandsRun: commands,
      totalInputTokens: (json['totalInputTokens'] as num?)?.toInt() ?? 0,
      totalOutputTokens: (json['totalOutputTokens'] as num?)?.toInt() ?? 0,
      totalCacheTokens: (json['totalCacheTokens'] as num?)?.toInt() ?? 0,
      projectName: '${json['projectName'] ?? 'muop-erp-server'}',
      projectPath:
          '${json['projectPath'] ?? '/home/john/Documents/muop-ecosystem/muop-erp-server'}',
      isSimulated: json['isSimulated'] == true,
      pendingPlans: (json['pendingPlans'] is List)
          ? (json['pendingPlans'] as List)
              .whereType<Map>()
              .map((e) => PlanArtifactInfo.fromJson(Map<String, dynamic>.from(e)))
              .toList()
          : const [],
      gitSyncStatus: json['gitSyncStatus'] is Map
          ? GitSyncStatus.fromJson(
              Map<String, dynamic>.from(json['gitSyncStatus'] as Map),
            )
          : null,
      isInterrupted: json['isInterrupted'] == true,
      interruptedReason: json['interruptedReason']?.toString(),
      customAgents: customList,
      availableAgents: availList.isNotEmpty ? availList : const ['Coordinator'],
      hasParallelFlow: json['hasParallelFlow'] == true,
      source: '${json['source'] ?? 'agy'}',
      contextTokens: (json['contextTokens'] as num?)?.toInt() ?? 0,
      contextModel: '${json['contextModel'] ?? ''}',
    );
  }
}

class PlanArtifactInfo {
  const PlanArtifactInfo({
    required this.fileName,
    required this.filePath,
    required this.title,
    required this.summary,
    required this.updatedAt,
    required this.requestFeedback,
    required this.content,
  });

  final String fileName;
  final String filePath;
  final String title;
  final String summary;
  final String updatedAt;
  final bool requestFeedback;
  final String content;

  factory PlanArtifactInfo.fromJson(Map<String, dynamic> json) {
    return PlanArtifactInfo(
      fileName: json['fileName']?.toString() ?? '',
      filePath: json['filePath']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      summary: json['summary']?.toString() ?? '',
      updatedAt: json['updatedAt']?.toString() ?? '',
      requestFeedback: json['requestFeedback'] == true,
      content: json['content']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'fileName': fileName,
        'filePath': filePath,
        'title': title,
        'summary': summary,
        'updatedAt': updatedAt,
        'requestFeedback': requestFeedback,
        'content': content,
      };
}

class ModelQuotaBucket {
  const ModelQuotaBucket({
    required this.bucketId,
    required this.displayName,
    required this.description,
    required this.window,
    required this.remainingFraction,
    required this.remainingPercent,
    required this.resetTime,
  });

  final String bucketId;
  final String displayName;
  final String description;
  final String window; // 'weekly' or '5h'
  final double remainingFraction;
  final double remainingPercent;
  final String resetTime;

  Map<String, dynamic> toJson() => {
        'bucketId': bucketId,
        'displayName': displayName,
        'description': description,
        'window': window,
        'remainingFraction': remainingFraction,
        'remainingPercent': remainingPercent,
        'resetTime': resetTime,
      };

  factory ModelQuotaBucket.fromJson(Map<String, dynamic> json) {
    final frac =
        (json['remainingFraction'] as num?)?.toDouble().clamp(0.0, 1.0) ?? 1.0;
    final pct = (json['remainingPercent'] as num?)?.toDouble() ??
        (frac * 100.0).roundToDouble();
    return ModelQuotaBucket(
      bucketId: '${json['bucketId'] ?? ''}',
      displayName: '${json['displayName'] ?? ''}',
      description: '${json['description'] ?? ''}',
      window: '${json['window'] ?? 'weekly'}',
      remainingFraction: frac,
      remainingPercent: pct,
      resetTime: '${json['resetTime'] ?? ''}',
    );
  }
}

class ModelQuotaGroup {
  const ModelQuotaGroup({
    required this.displayName,
    required this.description,
    required this.buckets,
  });

  final String displayName;
  final String description;
  final List<ModelQuotaBucket> buckets;

  ModelQuotaBucket? get weeklyBucket {
    for (final b in buckets) {
      if (b.window == 'weekly' || b.bucketId.contains('weekly')) return b;
    }
    return buckets.isNotEmpty ? buckets.first : null;
  }

  ModelQuotaBucket? get fiveHourBucket {
    for (final b in buckets) {
      if (b.window == '5h' || b.bucketId.contains('5h')) return b;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
        'displayName': displayName,
        'description': description,
        'buckets': buckets.map((e) => e.toJson()).toList(),
      };

  factory ModelQuotaGroup.fromJson(Map<String, dynamic> json) {
    final list = <ModelQuotaBucket>[];
    if (json['buckets'] is List) {
      for (final item in json['buckets'] as List) {
        if (item is Map) {
          list.add(
            ModelQuotaBucket.fromJson(Map<String, dynamic>.from(item)),
          );
        }
      }
    }
    return ModelQuotaGroup(
      displayName: '${json['displayName'] ?? ''}',
      description: '${json['description'] ?? ''}',
      buckets: list,
    );
  }
}

class AgentMonitorSnapshot {
  const AgentMonitorSnapshot({
    required this.sessions,
    required this.customAgents,
    required this.projects,
    required this.availableModels,
    required this.availableAgents,
    required this.activeStreams,
    this.modelQuotas = const [],
    this.modelLabels = const {},
    this.modelContextLimits = const {},
    required this.hostname,
    required this.lanIps,
    required this.port,
    required this.timestamp,
  });

  final List<ConversationSession> sessions;
  final List<CustomAgentSpec> customAgents;
  final List<ProjectWorkspace> projects;
  final List<String> availableModels;
  final List<String> availableAgents;
  final Map<String, ChatTurnStreamState> activeStreams;
  final List<ModelQuotaGroup> modelQuotas;
  /// Nhãn hiển thị theo id model, lấy từ `agy models`
  final Map<String, String> modelLabels;
  /// Giới hạn context theo model id (ví dụ `agy:gemini-4-argon-medium` → 256000)
  final Map<String, int> modelContextLimits;
  final String hostname;
  final List<String> lanIps;
  final int port;
  final DateTime timestamp;

  Map<String, dynamic> toJson() => {
        'sessions': sessions.map((e) => e.toJson()).toList(),
        'customAgents': customAgents.map((e) => e.toJson()).toList(),
        'projects': projects.map((e) => e.toJson()).toList(),
        'availableModels': availableModels,
        'availableAgents': availableAgents,
        'activeStreams':
            activeStreams.map((k, v) => MapEntry(k, v.toJson())),
        'modelQuotas': modelQuotas.map((e) => e.toJson()).toList(),
        'modelLabels': modelLabels,
        'modelContextLimits': modelContextLimits,
        'hostname': hostname,
        'lanIps': lanIps,
        'port': port,
        'timestamp': timestamp.toIso8601String(),
      };

  factory AgentMonitorSnapshot.fromJson(Map<String, dynamic> json) {
    final sessions = <ConversationSession>[];
    if (json['sessions'] is List) {
      for (final item in json['sessions'] as List) {
        if (item is Map) {
          sessions.add(
            ConversationSession.fromJson(Map<String, dynamic>.from(item)),
          );
        }
      }
    }
    final specs = <CustomAgentSpec>[];
    if (json['customAgents'] is List) {
      for (final item in json['customAgents'] as List) {
        if (item is Map) {
          specs.add(CustomAgentSpec.fromJson(Map<String, dynamic>.from(item)));
        }
      }
    }
    final projects = <ProjectWorkspace>[];
    if (json['projects'] is List) {
      for (final item in json['projects'] as List) {
        if (item is Map) {
          projects.add(
            ProjectWorkspace.fromJson(Map<String, dynamic>.from(item)),
          );
        }
      }
    }
    final models = <String>[];
    if (json['availableModels'] is List) {
      for (final m in json['availableModels'] as List) {
        models.add('$m');
      }
    }
    final agents = <String>[];
    if (json['availableAgents'] is List) {
      for (final a in json['availableAgents'] as List) {
        agents.add('$a');
      }
    }
    final streams = <String, ChatTurnStreamState>{};
    if (json['activeStreams'] is Map) {
      (json['activeStreams'] as Map).forEach((k, v) {
        if (v is Map) {
          streams['$k'] =
              ChatTurnStreamState.fromJson(Map<String, dynamic>.from(v));
        }
      });
    }
    final quotas = <ModelQuotaGroup>[];
    if (json['modelQuotas'] is List) {
      for (final item in json['modelQuotas'] as List) {
        if (item is Map) {
          quotas.add(
            ModelQuotaGroup.fromJson(Map<String, dynamic>.from(item)),
          );
        }
      }
    }
    final ips = <String>[];
    if (json['lanIps'] is List) {
      for (final ip in json['lanIps'] as List) {
        ips.add('$ip');
      }
    }
    final labels = <String, String>{};
    if (json['modelLabels'] is Map) {
      (json['modelLabels'] as Map).forEach((k, v) => labels['$k'] = '$v');
    }
    final contextLimits = <String, int>{};
    if (json['modelContextLimits'] is Map) {
      (json['modelContextLimits'] as Map).forEach((k, v) {
        final limit = v is num ? v.toInt() : int.tryParse('$v');
        if (limit != null && limit > 0) contextLimits['$k'] = limit;
      });
    }
    return AgentMonitorSnapshot(
      sessions: sessions,
      customAgents: specs,
      projects: projects,
      availableModels: models,
      availableAgents: agents,
      activeStreams: streams,
      modelQuotas: quotas,
      modelLabels: labels,
      modelContextLimits: contextLimits,
      hostname: '${json['hostname'] ?? 'linux-pc'}',
      lanIps: ips,
      port: (json['port'] as num?)?.toInt() ?? 8787,
      timestamp:
          DateTime.tryParse('${json['timestamp'] ?? ''}') ?? DateTime.now(),
    );
  }
}

class SessionStepsPageResult {
  const SessionStepsPageResult({
    required this.sessionId,
    required this.steps,
    required this.hasMore,
    required this.earliestStepIndex,
    required this.totalSteps,
  });

  final String sessionId;
  final List<AgentStep> steps;
  final bool hasMore;
  final int earliestStepIndex;
  final int totalSteps;

  factory SessionStepsPageResult.fromJson(Map<String, dynamic> json) {
    final rawSteps = json['steps'] as List? ?? const [];
    return SessionStepsPageResult(
      sessionId: json['sessionId']?.toString() ?? '',
      steps: rawSteps
          .whereType<Map<String, dynamic>>()
          .map(AgentStep.fromJson)
          .toList(),
      hasMore: json['hasMore'] == true,
      earliestStepIndex: (json['earliestStepIndex'] as num?)?.toInt() ?? 0,
      totalSteps: (json['totalSteps'] as num?)?.toInt() ?? 0,
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

class ClaudeQuestionOption {
  final String label;
  final String description;

  const ClaudeQuestionOption({required this.label, required this.description});

  factory ClaudeQuestionOption.fromJson(Map<String, dynamic> json) {
    return ClaudeQuestionOption(
      label: '${json['label'] ?? ''}',
      description: '${json['description'] ?? ''}',
    );
  }
}

class ClaudeQuestionItem {
  final String question;
  final String header;
  final bool multiSelect;
  final List<ClaudeQuestionOption> options;

  const ClaudeQuestionItem({
    required this.question,
    required this.header,
    required this.multiSelect,
    required this.options,
  });

  factory ClaudeQuestionItem.fromJson(Map<String, dynamic> json) {
    final rawOptions = json['options'];
    return ClaudeQuestionItem(
      question: '${json['question'] ?? ''}',
      header: '${json['header'] ?? ''}',
      multiSelect: json['multiSelect'] == true,
      options: rawOptions is List
          ? rawOptions
              .whereType<Map>()
              .map((o) => ClaudeQuestionOption.fromJson(Map<String, dynamic>.from(o)))
              .toList()
          : const [],
    );
  }
}

class PendingClaudeInteraction {
  final String conversationId;
  final String toolUseId;
  final String kind;
  final String createdAt;
  final List<ClaudeQuestionItem> questions;
  final String plan;

  const PendingClaudeInteraction({
    required this.conversationId,
    required this.toolUseId,
    required this.kind,
    required this.createdAt,
    required this.questions,
    required this.plan,
  });

  bool get isPlan => kind == 'plan';

  String get summary {
    if (!isPlan) return questions.isEmpty ? '' : questions.first.question;
    for (final line in plan.split('\n')) {
      final text = line.replaceFirst(RegExp(r'^#+\s*'), '').trim();
      if (text.isNotEmpty) return text;
    }
    return '';
  }

  factory PendingClaudeInteraction.fromJson(Map<String, dynamic> json) {
    final rawQuestions = json['questions'];
    return PendingClaudeInteraction(
      conversationId: '${json['conversationId'] ?? ''}',
      toolUseId: '${json['toolUseId'] ?? ''}',
      kind: '${json['kind'] ?? 'question'}',
      createdAt: '${json['createdAt'] ?? ''}',
      questions: rawQuestions is List
          ? rawQuestions
              .whereType<Map>()
              .map((q) => ClaudeQuestionItem.fromJson(Map<String, dynamic>.from(q)))
              .toList()
          : const [],
      plan: '${json['plan'] ?? ''}',
    );
  }
}

class AIQuestion {
  final String id;
  final String conversationId;
  final int stepIndex;
  final String question;
  final String createdAt;
  final String? answeredAt;
  final String? answer;
  final bool isPending;

  AIQuestion({
    required this.id,
    required this.conversationId,
    required this.stepIndex,
    required this.question,
    required this.createdAt,
    this.answeredAt,
    this.answer,
    required this.isPending,
  });

  factory AIQuestion.fromJson(Map<String, dynamic> json) {
    return AIQuestion(
      id: '${json['id'] ?? ''}',
      conversationId: '${json['conversationId'] ?? ''}',
      stepIndex: (json['stepIndex'] as int?) ?? 0,
      question: '${json['question'] ?? ''}',
      createdAt: '${json['createdAt'] ?? ''}',
      answeredAt: json['answeredAt']?.toString(),
      answer: json['answer']?.toString(),
      isPending: json['isPending'] == true,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'conversationId': conversationId,
      'stepIndex': stepIndex,
      'question': question,
      'createdAt': createdAt,
      'answeredAt': answeredAt,
      'answer': answer,
      'isPending': isPending,
    };
  }

  AIQuestion copyWith({
    String? id,
    String? conversationId,
    int? stepIndex,
    String? question,
    String? createdAt,
    String? answeredAt,
    String? answer,
    bool? isPending,
  }) {
    return AIQuestion(
      id: id ?? this.id,
      conversationId: conversationId ?? this.conversationId,
      stepIndex: stepIndex ?? this.stepIndex,
      question: question ?? this.question,
      createdAt: createdAt ?? this.createdAt,
      answeredAt: answeredAt ?? this.answeredAt,
      answer: answer ?? this.answer,
      isPending: isPending ?? this.isPending,
    );
  }
}
