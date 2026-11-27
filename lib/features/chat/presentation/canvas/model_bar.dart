part of '../chat_canvas_view.dart';

extension _CanvasExtModelBar on _ChatCanvasViewState {
  /// Model thuộc Claude Code CLI (id dạng `claude-cli:<alias>`), còn lại là Antigravity (`agy:<model>`).
  /// Model máy phụ (`peer:` + id) được xét theo id gốc trên máy đó.
  bool _isClaudeCliModel(String modelId) =>
      remoteModelId(modelId).startsWith('claude-cli:');

  /// Thứ tự khối trong menu: Claude máy chính, Antigravity máy chính, Claude máy phụ, Antigravity máy phụ
  int _sectionRank(ModelGroup group) {
    final peer = isPeerModel(group.id);
    final claude = _isClaudeCliModel(group.id);
    return (peer ? 2 : 0) + (claude ? 0 : 1);
  }

  String _formatModelLabel(String modelId) {
    // Nhãn do server gửi (model Claude suy ra từ id, model agy lấy từ `agy models`)
    final fromServer = widget.modelLabels[modelId];
    if (fromServer != null && fromServer.isNotEmpty) return fromServer;
    // Thiếu nhãn: bỏ hậu tố mức rồi bỏ tiền tố provider
    final base = remoteModelId(
      parseModelId(modelId, levels: resolveEffortLevels(widget.effortLevels))
          .groupId,
    );
    if (base.startsWith('agy:')) return base.substring('agy:'.length);
    if (base.startsWith('claude-cli:')) {
      return base.substring('claude-cli:'.length);
    }
    return base;
  }

  /// Nhãn cho việc gom nhóm: Claude dùng bảng cố định, Antigravity dùng nhãn của server
  Map<String, String> _labelMapFor(Iterable<String> models) {
    return {
      for (final m in models)
        m: _isClaudeCliModel(m)
            ? _formatModelLabel(m)
            : (widget.modelLabels[m] ?? ''),
    };
  }

  /// Nhóm model đang chọn (theo id đầy đủ), null nếu không nằm trong danh sách đã lọc
  ModelGroup? _groupOfSelected(List<ModelGroup> groups) {
    for (final g in groups) {
      if (g.options.any((o) => o.id == widget.selectedModel)) return g;
    }
    return null;
  }

  /// Bộ chọn model: menu nhóm theo tên (ví dụ "Gemini 4 Argon") và menu mức (Low/Medium/High/XHigh) bên cạnh.
  /// Chuyển nhóm giữ nguyên mức đang chọn nếu nhóm mới có, không thì dùng Medium.
  Widget _buildModelSelector(
    ColorScheme colorScheme,
    TextTheme textTheme,
    bool isMobile,
  ) {
    final rawGroups = groupModels(
      _getFilteredModelsForSession(),
      _labelMapFor(_getFilteredModelsForSession()),
      effortLevels: resolveEffortLevels(widget.effortLevels),
    );
    // Gom theo khối: mỗi khối (provider × máy) là một đoạn liên tiếp trong menu
    final groups = [
      for (var rank = 0; rank < 4; rank++)
        ...rawGroups.where((g) => _sectionRank(g) == rank),
    ];
    final current = _groupOfSelected(groups);
    final effort = groups
        .expand((g) => g.options)
        .where((o) => o.id == widget.selectedModel)
        .map((o) => o.effort)
        .firstOrNull;
    final groupLabel =
        current?.label ?? _formatModelLabel(widget.selectedModel);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        PopupMenuButton<String>(
          tooltip:
              'Chọn model: Claude Code CLI (claude) hoặc Antigravity (agy)',
          onSelected: (groupId) {
            final group = groups.firstWhere((g) => g.id == groupId);
            widget.onSelectModel(
              group.preferredOption(currentEffort: effort).id,
            );
          },
          itemBuilder: (ctx) => [
            for (var i = 0; i < groups.length; i++) ...[
              if (i == 0 ||
                  _sectionRank(groups[i]) != _sectionRank(groups[i - 1]))
                ..._providerHeaderEntries(
                  groups[i].id,
                  colorScheme,
                  showDivider: i > 0,
                ),
              PopupMenuItem<String>(
                value: groups[i].id,
                child: Row(
                  children: [
                    Icon(
                      Icons.auto_awesome_rounded,
                      size: 15,
                      color: isPeerModel(groups[i].id)
                          ? colorScheme.tertiary
                          : identical(groups[i], current)
                              ? colorScheme.primary
                              : colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      groups[i].label,
                      style: TextStyle(
                        fontWeight: identical(groups[i], current)
                            ? FontWeight.w800
                            : FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.memory_rounded,
                size: 13.5,
                color: isPeerModel(widget.selectedModel)
                    ? colorScheme.tertiary
                    : colorScheme.primary,
              ),
              const SizedBox(width: 5),
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: isMobile ? 118 : 200),
                child: Text(
                  groupLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.labelSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: isPeerModel(widget.selectedModel)
                        ? colorScheme.tertiary
                        : colorScheme.onSurface,
                  ),
                ),
              ),
              Icon(
                Icons.arrow_drop_down_rounded,
                size: 15,
                color: colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
        if (current != null && current.hasEffortChoices) ...[
          const SizedBox(width: 4),
          PopupMenuButton<String>(
            tooltip:
                'Mức suy luận (mặc định: ${ModelGroup.effortLabel(kDefaultModelEffort)})',
            onSelected: widget.onSelectModel,
            itemBuilder: (ctx) => [
              for (final option in current.options)
                PopupMenuItem<String>(
                  value: option.id,
                  child: Text(
                    ModelGroup.effortLabel(option.effort ?? ''),
                    style: TextStyle(
                      fontWeight: option.id == widget.selectedModel
                          ? FontWeight.w800
                          : FontWeight.w500,
                    ),
                  ),
                ),
            ],
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: colorScheme.primary.withAlpha(24),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    ModelGroup.effortLabel(effort ?? kDefaultModelEffort),
                    style: textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: colorScheme.primary,
                    ),
                  ),
                  Icon(
                    Icons.arrow_drop_down_rounded,
                    size: 15,
                    color: colorScheme.primary,
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// Header của mỗi khối trong popup chọn model. Khối máy phụ ghi tên máy: `Claude Cli · <máy>`
  List<PopupMenuEntry<String>> _providerHeaderEntries(
    String modelId,
    ColorScheme colorScheme, {
    required bool showDivider,
  }) {
    final isClaude = _isClaudeCliModel(modelId);
    final isPeer = isPeerModel(modelId);
    final host = widget.peerHost.trim();
    final accent = isPeer ? colorScheme.tertiary : colorScheme.primary;
    final title = isPeer
        ? (isClaude
            ? 'Claude Cli · ${host.isEmpty ? 'máy phụ' : host}'
            : 'Agy · ${host.isEmpty ? 'máy phụ' : host}')
        : (isClaude
            ? 'Claude Code CLI · limit tài khoản Claude'
            : 'Antigravity (agy) · quota Gemini/Claude');
    return [
      if (showDivider) const PopupMenuDivider(),
      PopupMenuItem<String>(
        enabled: false,
        height: 34,
        child: Row(
          children: [
            Icon(
              isPeer
                  ? Icons.lan_rounded
                  : (isClaude ? Icons.terminal_rounded : Icons.hub_rounded),
              size: 14,
              color: accent,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    ];
  }

  /// Lọc model theo conversation: đúng provider (`source`) và đúng nơi chạy. Conversation máy chính
  /// không hiện model máy phụ, conversation máy phụ chỉ hiện model máy phụ.
  List<String> _getFilteredModelsForSession() {
    final session = widget.session;
    if (session == null || widget.isNewConversationMode) {
      return widget.availableModels;
    }
    final wantPrefix =
        session.source == 'claude-cli' ? 'claude-cli:' : 'agy:';
    return widget.availableModels
        .where((m) =>
            isPeerModel(m) == widget.isPeerSession &&
            remoteModelId(m).startsWith(wantPrefix))
        .toList();
  }

  /// Provider của thanh quota. Thanh ở màn chat dùng provider của cuộc chat (`quotaScope`);
  /// màn chung thì theo model đang chọn.
  String get _quotaProvider {
    if (widget.quotaScope.isNotEmpty) return widget.quotaScope;
    final base = _isClaudeCliModel(widget.selectedModel)
        ? kQuotaProviderClaude
        : kQuotaProviderAgy;
    // Model máy phụ: quota của máy phụ (`peer:<provider>`)
    return isPeerModel(widget.selectedModel) ? '$kPeerQuotaScopePrefix$base' : base;
  }

  /// Nhóm quota của provider đang hiển thị, chọn theo model đang chọn (agy có nhiều nhóm).
  /// Thiếu dữ liệu thì [primaryGroup] là null và [error] ghi lý do.
  ({ModelQuotaGroup? primaryGroup, ModelQuotaGroup? geminiGroup, String error})
  _resolveQuotaForSelectedModel() {
    final report = widget.quotaReports[_quotaProvider];
    final error = report == null
        ? 'Chưa lấy được dữ liệu quota'
        : (report.error.isEmpty ? 'Không có dữ liệu quota' : report.error);
    final groups = (report?.groups ?? const <ModelQuotaGroup>[])
        .where((g) => g.buckets.isNotEmpty)
        .toList();
    if (quotaProviderOf(_quotaProvider) == kQuotaProviderClaude) {
      return (primaryGroup: groups.firstOrNull, geminiGroup: null, error: error);
    }

    ModelQuotaGroup? gemini;
    ModelQuotaGroup? claudeGpt;
    ModelQuotaGroup? argon;
    for (final g in groups) {
      final lower = g.displayName.toLowerCase();
      if (lower.contains('argon')) {
        argon = g;
      } else if (lower.contains('claude') || lower.contains('gpt')) {
        claudeGpt = g;
      } else if (lower.contains('gemini')) {
        gemini = g;
      }
    }

    final m = widget.selectedModel.toLowerCase();
    if (m.contains('claude') || m.contains('gpt')) {
      return (primaryGroup: claudeGpt ?? gemini, geminiGroup: gemini, error: error);
    }
    if (m.contains('argon')) {
      return (primaryGroup: argon ?? gemini, geminiGroup: gemini, error: error);
    }
    return (
      primaryGroup: gemini ?? argon ?? claudeGpt,
      geminiGroup: gemini,
      error: error,
    );
  }

  Color _quotaStatusColor(double remainingPct) =>
      quotaStatusColor(context, remainingPct);

  /// Chip context: số token đang dùng / giới hạn của model, kèm thanh tiến trình.
  /// Ẩn khi chưa có dữ liệu (session mới hoặc model không rõ giới hạn).
  Widget _buildContextChip(
    ColorScheme colorScheme,
    TextTheme textTheme, {
    bool compact = false,
  }) {
    final session = widget.session;
    final tokens = session?.contextTokens ?? 0;
    final limit =
        widget.modelContextLimits[widget.selectedModel] ??
        widget.modelContextLimits[session?.contextModel ?? ''] ??
        0;
    if (tokens <= 0 || limit <= 0) return const SizedBox.shrink();

    final ratio = (tokens / limit).clamp(0.0, 1.0).toDouble();
    final pct = ratio * 100;
    final color = pct >= 90
        ? colorScheme.error
        : pct >= 70
        ? context.status.warning
        : colorScheme.onSurfaceVariant;

    final tooltip =
        'Context đang dùng: $tokens / $limit token (${pct.toStringAsFixed(0)}%)';

    // Mobile: chỉ hiện phần trăm để nhường chỗ cho thanh quota
    if (compact) {
      return Padding(
        padding: const EdgeInsets.only(right: 6),
        child: Tooltip(
          message: tooltip,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: colorScheme.outlineVariant.withAlpha(160),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.data_usage, size: 12, color: color),
                const SizedBox(width: 3),
                Text(
                  '${pct.round()}%',
                  style: textTheme.labelSmall?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w700,
                    fontSize: 10.5,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Tooltip(
        message: tooltip,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: colorScheme.outlineVariant.withAlpha(160),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.data_usage, size: 14, color: color),
              const SizedBox(width: 4),
              Text(
                '${_ChatCanvasViewState._formatTokensShort(tokens)} / ${_ChatCanvasViewState._formatTokensShort(limit)}',
                style: textTheme.labelSmall?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 6),
              SizedBox(
                width: 28,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: ratio,
                    minHeight: 4,
                    color: color,
                    backgroundColor: colorScheme.surfaceContainerHighest,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// [2] THANH THÔNG TIN GỌN TRÊN ĐỈNH ĐẢO CHAT: Model, Effort, Context % và Quota ngắn gọn
  /// Nút mở cấu hình tự gửi lại khi chạm giới hạn của conversation đang mở.
  /// Có lịch đang chờ thì đổi icon sang đồng hồ cát màu cảnh báo.
  Widget _buildRetryConfigButton(BuildContext context) {
    final conversationId = widget.session?.id;
    final fetch = widget.onFetchRetryConfig;
    final save = widget.onSaveRetryConfig;
    final enabled =
        conversationId != null &&
        fetch != null &&
        save != null &&
        !widget.isPeerSession;
    final hasPending =
        widget.pendingRetry != null &&
        widget.pendingRetry!.conversationId == conversationId;
    final color = hasPending
        ? context.status.warning
        : context.scheme.onSurfaceVariant;

    return Tooltip(
      message: enabled
          ? 'Tự gửi lại khi chạm giới hạn'
          : 'Mở một conversation để cấu hình tự gửi lại',
      child: IconButton(
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
        padding: EdgeInsets.zero,
        iconSize: 16,
        onPressed: enabled
            ? () => _openRetryConfig(
                context,
                conversationId,
                fetch,
                save,
              )
            : null,
        icon: hasPending
            ? SpinningIcon(
                icon: Icons.hourglass_top_rounded,
                size: 16,
                color: color,
              )
            : Icon(Icons.autorenew_rounded, color: color),
      ),
    );
  }

  Future<void> _openRetryConfig(
    BuildContext context,
    String conversationId,
    Future<ConversationRetryConfig?> Function(String conversationId) fetch,
    Future<({bool ok, String message})> Function(ConversationRetryConfig config)
    save,
  ) async {
    final loaded = await fetch(conversationId);
    if (!context.mounted) return;
    final pending = widget.pendingRetry?.conversationId == conversationId
        ? widget.pendingRetry
        : null;
    await showRetryConfigSheet(
      context: context,
      initial:
          loaded ?? ConversationRetryConfig(conversationId: conversationId),
      onSave: save,
      pending: pending,
      onCancelPending: widget.onCancelRetry,
    );
  }

  Widget _buildModelUsageMiddleBar(BuildContext context, bool isMobile) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final resolved = _resolveQuotaForSelectedModel();
    final quotaLoading = widget.quotaReports[_quotaProvider]?.loading ?? false;
    final primaryGroup = resolved.primaryGroup;
    final geminiGroup = resolved.geminiGroup;

    final weeklyBucket = primaryGroup?.weeklyBucket;
    final fiveHourBucket =
        primaryGroup?.fiveHourBucket ?? geminiGroup?.fiveHourBucket;

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: isMobile ? 4 : 6, vertical: 2),
      child: Row(
        children: [
          _buildModelSelector(colorScheme, textTheme, isMobile),
          const SizedBox(width: 6),
          _buildContextChip(colorScheme, textTheme, compact: isMobile),
          const SizedBox(width: 2),
          _buildRetryConfigButton(context),
          const Spacer(),
          if (widget.onOpenAgentMap != null && !isMobile) ...[
            InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: widget.onOpenAgentMap,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.hub_outlined,
                      size: 13,
                      color: colorScheme.primary,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      'Agent map',
                      style: textTheme.labelSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 6),
          ],
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => _showQuotaSheet(context),
            child: primaryGroup == null
                ? Tooltip(
                    message: resolved.error,
                    child: Text(
                      quotaLoading ? 'Quota…' : 'Quota —',
                      style: textTheme.labelSmall?.copyWith(
                        fontSize: 10.5,
                        color: colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  )
                : _buildCompactQuotaStrip(
                    colorScheme,
                    textTheme,
                    weeklyBucket: weeklyBucket,
                    fiveHourBucket: fiveHourBucket,
                    isMobile: isMobile,
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildCompactQuotaStrip(
    ColorScheme colorScheme,
    TextTheme textTheme, {
    required ModelQuotaBucket? weeklyBucket,
    required ModelQuotaBucket? fiveHourBucket,
    required bool isMobile,
  }) {
    Widget badge(String label, ModelQuotaBucket? bucket) {
      final pct = bucket?.remainingPercent;
      final color = pct == null
          ? colorScheme.onSurfaceVariant
          : _quotaStatusColor(pct);
      final reset =
          bucket == null ? null : formatQuotaResetCompact(bucket.resetTime);
      final tooltip = bucket == null
          ? label
          : '$label: ${pct?.round() ?? 0}% (reset ${formatQuotaReset(bucket.resetTime)})';
      return Tooltip(
        message: tooltip,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 4),
            Text(
              isMobile
                  ? (pct == null ? '—' : '${pct.round()}%')
                  : '$label ${pct == null ? '—' : '${pct.round()}%'}${reset != null ? ' ($reset)' : ''}',
              style: textTheme.labelSmall?.copyWith(
                fontFamily: 'monospace',
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          badge('Tuần', weeklyBucket),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 5),
            child: Text(
              '•',
              style: TextStyle(
                fontSize: 10,
                color: colorScheme.onSurfaceVariant.withAlpha(140),
              ),
            ),
          ),
          badge('5h', fiveHourBucket),
        ],
      ),
    );
  }

  /// Bảng chi tiết quota. Chat Claude chỉ có Claude, chat agy chỉ có agy;
  /// màn chung có cả hai. Provider chưa có dữ liệu vẫn hiện mục với lý do.
  void _showQuotaSheet(BuildContext context) {
    final providers = widget.quotaScope.isEmpty
        ? const [kQuotaProviderAgy, kQuotaProviderClaude]
        : [widget.quotaScope];
    showQuotaDetailSheet(context, [
      for (final p in providers)
        widget.quotaReports[p] ?? QuotaReport.missing(p),
    ]);
  }
}
