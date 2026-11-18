
import 'package:muop_agent/features/sessions/domain/session_entities.dart';

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