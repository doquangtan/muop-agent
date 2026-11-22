
import 'package:muop_agent/features/interactions/domain/interaction_entities.dart';
import 'package:muop_agent/features/projects/domain/project_entities.dart';

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
    this.imageCount = 0,
    this.imageUrls = const [],
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

  /// Số ảnh đính kèm trong tin nhắn của người dùng (chỉ có với `USER_INPUT`)
  final int imageCount;

  /// Đường dẫn tương đối tới từng ảnh đính kèm (vd. `/api/chat/attachment?...`)
  final List<String> imageUrls;

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
        'imageCount': imageCount,
        'imageUrls': imageUrls,
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
      imageCount: (json['imageCount'] as num?)?.toInt() ?? 0,
      imageUrls: (json['imageUrls'] as List?)?.map((e) => '$e').toList() ??
          const [],
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
    this.parentId = '',
    this.spawned = false,
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

  /// Id của lane cha (sub-agent đã spawn ra lane này); rỗng nếu là con trực tiếp của conversation
  final String parentId;

  /// `true` nếu là subagent thật được gọi (hoặc coordinator); `false` nếu chỉ suy đoán từ tên agent
  final bool spawned;

  /// Lane cũ của một session đã dừng: lane còn đang chạy/chờ thì chuyển sang trạng thái kết thúc,
  /// để không hiển thị subagent "đang chạy" khi conversation đã hoàn tất hoặc bị gián đoạn.
  SubagentLane settledFor(AgentStatus sessionStatus) {
    if (status != AgentStatus.running && status != AgentStatus.waiting) return this;
    final next = sessionStatus == AgentStatus.interrupted
        ? AgentStatus.interrupted
        : AgentStatus.completed;
    return SubagentLane(
      id: id,
      name: name,
      role: role,
      targetRepo: targetRepo,
      status: next,
      currentPhase: currentPhase,
      currentStepIndex: currentStepIndex,
      currentActionText: currentActionText,
      currentToolName: 'standby',
      promptBrief: promptBrief,
      steps: steps,
      progress: 1.0,
      filesModified: filesModified,
      lastUpdated: lastUpdated,
      parentId: parentId,
      spawned: spawned,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'role': role,
        'parentId': parentId,
        'spawned': spawned,
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
      parentId: '${json['parentId'] ?? ''}',
      spawned: json['spawned'] == true,
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
    this.projectName = '',
    this.projectPath = '',
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
    this.selectedModel = '',
    this.lanesLoaded = false,
  });

  final String id;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;
  final AgentStatus status;
  final AgentWorkflowPhase currentPhase;
  final List<AgentStep> steps;
  final List<SubagentLane> subagentLanes;

  /// Server đã dựng đầy đủ lane cho lượt này (kể cả khi rỗng). `false` nghĩa là snapshot gọn,
  /// lane chưa biết, client giữ lane đã nạp trước đó.
  final bool lanesLoaded;
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
  /// Model kèm mức đã chọn cho conversation (vd. claude-cli:claude-haiku-5-5-high), rỗng nếu chưa ghi nhận
  final String selectedModel;

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
    bool? lanesLoaded,
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
    String? selectedModel,
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
      lanesLoaded: lanesLoaded ?? this.lanesLoaded,
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
      selectedModel: selectedModel ?? this.selectedModel,
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
        'lanesLoaded': lanesLoaded,
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
        'selectedModel': selectedModel,
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
      lanesLoaded: json['lanesLoaded'] == true,
      filesTouched: files,
      commandsRun: commands,
      totalInputTokens: (json['totalInputTokens'] as num?)?.toInt() ?? 0,
      totalOutputTokens: (json['totalOutputTokens'] as num?)?.toInt() ?? 0,
      totalCacheTokens: (json['totalCacheTokens'] as num?)?.toInt() ?? 0,
      projectName: '${json['projectName'] ?? ''}',
      projectPath: '${json['projectPath'] ?? ''}',
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
      selectedModel: '${json['selectedModel'] ?? ''}',
    );
  }
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

/// Metadata chung của server (`meta:update`, `GET /api/meta`): project, model, máy chủ
class ServerMeta {
  const ServerMeta({
    required this.projects,
    required this.availableModels,
    required this.modelLabels,
    required this.modelContextLimits,
    required this.hostname,
    required this.lanIps,
    required this.port,
    this.effortLevels = const [],
    this.workspaceRoot = '',
    this.homeDir = '',
  });

  final List<ProjectWorkspace> projects;
  final List<String> availableModels;
  /// Nhãn hiển thị theo id model, lấy từ `agy models`
  final Map<String, String> modelLabels;
  /// Giới hạn context theo model id (ví dụ `agy:gemini-4-argon-medium` → 256000)
  final Map<String, int> modelContextLimits;
  final String hostname;
  final List<String> lanIps;
  final int port;
  /// Mức suy nghĩ (effort) mà CLI của server hỗ trợ, theo thứ tự từ thấp đến cao; rỗng nếu không rõ
  final List<String> effortLevels;

  /// Thư mục project đã chọn trong Khởi tạo (rỗng nếu chưa chọn): gốc mặc định, không đoán trên client
  final String workspaceRoot;

  /// Thư mục home của user đang chạy server
  final String homeDir;

  factory ServerMeta.fromJson(Map<String, dynamic> json) {
    final projects = <ProjectWorkspace>[];
    if (json['projects'] is List) {
      for (final item in json['projects'] as List) {
        if (item is Map) {
          projects.add(ProjectWorkspace.fromJson(Map<String, dynamic>.from(item)));
        }
      }
    }
    final models = <String>[];
    if (json['availableModels'] is List) {
      models.addAll((json['availableModels'] as List).map((e) => '$e'));
    }
    final labels = <String, String>{};
    if (json['modelLabels'] is Map) {
      (json['modelLabels'] as Map).forEach((k, v) => labels['$k'] = '$v');
    }
    final limits = <String, int>{};
    if (json['modelContextLimits'] is Map) {
      (json['modelContextLimits'] as Map).forEach((k, v) {
        if (v is num) limits['$k'] = v.toInt();
      });
    }
    final ips = <String>[];
    if (json['lanIps'] is List) {
      ips.addAll((json['lanIps'] as List).map((e) => '$e'));
    }
    return ServerMeta(
      projects: projects,
      availableModels: models,
      modelLabels: labels,
      modelContextLimits: limits,
      hostname: '${json['hostname'] ?? ''}',
      lanIps: ips,
      port: (json['port'] as num?)?.toInt() ?? 0,
      effortLevels: [
        if (json['effortLevels'] is List)
          for (final e in json['effortLevels'] as List) '$e',
      ],
      workspaceRoot: '${json['workspaceRoot'] ?? ''}',
      homeDir: '${json['homeDir'] ?? ''}',
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
