part of '../chat_canvas_view.dart';

extension _CanvasExtModelBar on _ChatCanvasViewState {
  /// Model thuộc Claude Code CLI (id dạng `claude-cli:<alias>`), còn lại là Antigravity (`agy:<model>`)
  bool _isClaudeCliModel(String modelId) => modelId.startsWith('claude-cli:');

  String _formatModelLabel(String modelId) {
    // Bỏ hậu tố mức (ví dụ `-high`) để tra nhãn theo model gốc
    final base = parseModelId(
      modelId,
      levels: resolveEffortLevels(widget.effortLevels),
    ).groupId;
    switch (base) {
      case 'default':
      case 'claude-cli:claude-sonnet-5-5':
        return 'Claude Sonnet 5.5';
      case 'claude-cli:claude-opus-5-5':
        return 'Claude Opus 5.5';
      case 'claude-cli:claude-haiku-5-5':
        return 'Claude Haiku 5.5';
      default:
        // Model Antigravity lấy từ `agy models` (nhãn do server gửi); thiếu nhãn thì bỏ tiền tố provider
        final fromServer = widget.modelLabels[modelId];
        if (fromServer != null && fromServer.isNotEmpty) return fromServer;
        return modelId.startsWith('agy:') ? modelId.substring(4) : modelId;
    }
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
    final groups = groupModels(
      _getFilteredModelsForSession(),
      _labelMapFor(_getFilteredModelsForSession()),
      effortLevels: resolveEffortLevels(widget.effortLevels),
    );
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
                  _isClaudeCliModel(groups[i].id) !=
                      _isClaudeCliModel(groups[i - 1].id))
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
                      color: identical(groups[i], current)
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
                color: colorScheme.primary,
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
                    color: colorScheme.onSurface,
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

  /// Header của mỗi nhóm provider trong popup chọn model
  List<PopupMenuEntry<String>> _providerHeaderEntries(
    String modelId,
    ColorScheme colorScheme, {
    required bool showDivider,
  }) {
    final isClaude = _isClaudeCliModel(modelId);
    return [
      if (showDivider) const PopupMenuDivider(),
      PopupMenuItem<String>(
        enabled: false,
        height: 34,
        child: Row(
          children: [
            Icon(
              isClaude ? Icons.terminal_rounded : Icons.hub_rounded,
              size: 14,
              color: colorScheme.primary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                isClaude
                    ? 'Claude Code CLI · limit tài khoản Claude'
                    : 'Antigravity (agy) · quota Gemini/Claude',
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

  /// Lọc danh sách model dựa trên session source
  List<String> _getFilteredModelsForSession() {
    final session = widget.session;
    if (session == null || widget.isNewConversationMode) {
      return widget.availableModels;
    }

    if (session.source == 'claude-cli') {
      return widget.availableModels
          .where((m) => m.startsWith('claude-cli:'))
          .toList();
    } else {
      return widget.availableModels.where((m) => m.startsWith('agy:')).toList();
    }
  }

  /// Tìm nhóm Quota Antigravity khớp với Model đang chọn
  ({ModelQuotaGroup? primaryGroup, ModelQuotaGroup? geminiGroup})
  _resolveQuotaForSelectedModel() {
    ModelQuotaGroup? gemini;
    ModelQuotaGroup? claudeGpt;
    ModelQuotaGroup? argon;

    ModelQuotaGroup? claudeCode;
    for (final g in widget.modelQuotas) {
      final lower = g.displayName.toLowerCase();
      if (lower.contains('claude code')) {
        // Limit tài khoản của Claude Code CLI: chỉ dùng cho model claude-cli
        claudeCode = g;
      } else if (lower.contains('argon')) {
        argon = g;
      } else if (lower.contains('claude') || lower.contains('gpt')) {
        claudeGpt = g;
      } else if (lower.contains('gemini')) {
        gemini = g;
      }
    }

    if (_isClaudeCliModel(widget.selectedModel)) {
      return (primaryGroup: claudeCode, geminiGroup: null);
    }

    final m = widget.selectedModel.toLowerCase();
    if (m.contains('claude') || m.contains('gpt')) {
      return (primaryGroup: claudeGpt ?? gemini, geminiGroup: gemini);
    }
    if (m.contains('argon')) {
      return (primaryGroup: argon ?? gemini, geminiGroup: gemini);
    }
    return (primaryGroup: gemini ?? argon ?? claudeGpt, geminiGroup: gemini);
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

  /// [2] THANH % USAGE CỦA MODEL AI — Nằm ở giữa phần Task Running và Khung Chat
  /// Hiển thị chính xác Limit Tuần (Weekly Limit Remaining) & Limit Giờ / 5h (Five Hour Limit Remaining)
  /// lấy trực tiếp từ Antigravity LanguageServer (`RetrieveUserQuotaSummary`).
  Widget _buildModelUsageMiddleBar(BuildContext context, bool isMobile) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final resolved = _resolveQuotaForSelectedModel();
    final primaryGroup = resolved.primaryGroup;
    final geminiGroup = resolved.geminiGroup;

    final weeklyBucket = primaryGroup?.weeklyBucket;
    final fiveHourBucket =
        primaryGroup?.fiveHourBucket ?? geminiGroup?.fiveHourBucket;

    final double weeklyPct = weeklyBucket?.remainingPercent ?? 70.0;
    final double hourlyPct = fiveHourBucket?.remainingPercent ?? 95.0;

    final Color weeklyColor = _quotaStatusColor(weeklyPct);
    final Color hourlyColor = _quotaStatusColor(hourlyPct);

    // Thời gian reset của từng cột: ngắn dưới thanh %, đầy đủ trong tooltip
    final String? weeklyReset = weeklyBucket == null
        ? null
        : formatQuotaResetCompact(weeklyBucket.resetTime);
    final String? weeklyResetFull = weeklyBucket == null
        ? null
        : formatQuotaReset(weeklyBucket.resetTime);
    final String? hourlyReset = fiveHourBucket == null
        ? null
        : formatQuotaResetCompact(fiveHourBucket.resetTime);
    final String? hourlyResetFull = fiveHourBucket == null
        ? null
        : formatQuotaReset(fiveHourBucket.resetTime);

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: isMobile ? 10 : 12,
        vertical: isMobile ? 5 : 6,
      ),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow.withAlpha(220),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colorScheme.outlineVariant.withAlpha(160)),
      ),
      child: Row(
        children: [
          // Chọn nhanh Model AI: nhóm theo tên, mức suy luận ở ngay bên cạnh
          _buildModelSelector(colorScheme, textTheme, isMobile),

          const SizedBox(width: 6),

          _buildContextChip(colorScheme, textTheme, compact: isMobile),

          // Hiển thị 2 cột Limit Tuần & Limit Giờ (5h) chuẩn Antigravity (bấm vào để mở bảng chi tiết tất cả Model)
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: () => _showAntigravityQuotaSheet(context),
              child: Row(
                children: [
                  // 1. Limit Tuần (Weekly Limit Remaining)
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Flexible(
                              child: Text(
                                isMobile ? 'Tuần' : 'Limit Tuần',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: textTheme.labelSmall?.copyWith(
                                  fontSize: 10,
                                  color: colorScheme.onSurfaceVariant,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            Text(
                              '${weeklyPct.round()}%',
                              style: textTheme.labelSmall?.copyWith(
                                fontFamily: 'monospace',
                                fontSize: 10.5,
                                fontWeight: FontWeight.w800,
                                color: weeklyColor,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2.5),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            minHeight: 4.5,
                            value: (weeklyPct / 100.0).clamp(0.0, 1.0),
                            backgroundColor:
                                colorScheme.surfaceContainerHighest,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              weeklyColor,
                            ),
                          ),
                        ),
                        if (weeklyReset != null)
                          Tooltip(
                            message: weeklyResetFull ?? '',
                            child: Text(
                              '↻ $weeklyReset',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: textTheme.labelSmall?.copyWith(
                                fontSize: 9,
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),

                  const SizedBox(width: 10),

                  // 2. Limit Giờ / 5h (Five Hour Limit Remaining)
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Flexible(
                              child: Text(
                                isMobile ? '5h' : 'Limit Giờ (5h)',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: textTheme.labelSmall?.copyWith(
                                  fontSize: 10,
                                  color: colorScheme.onSurfaceVariant,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            Text(
                              '${hourlyPct.round()}%',
                              style: textTheme.labelSmall?.copyWith(
                                fontFamily: 'monospace',
                                fontSize: 10.5,
                                fontWeight: FontWeight.w800,
                                color: hourlyColor,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2.5),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            minHeight: 4.5,
                            value: (hourlyPct / 100.0).clamp(0.0, 1.0),
                            backgroundColor:
                                colorScheme.surfaceContainerHighest,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              hourlyColor,
                            ),
                          ),
                        ),
                        if (hourlyReset != null)
                          Tooltip(
                            message: hourlyResetFull ?? '',
                            child: Text(
                              '↻ $hourlyReset',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: textTheme.labelSmall?.copyWith(
                                fontSize: 9,
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),

                  if (!isMobile) ...[
                    const SizedBox(width: 4),
                    Icon(
                      Icons.info_outline_rounded,
                      size: 13.5,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Bảng chi tiết toàn bộ các nhóm Quota AI (Antigravity + Claude Code CLI)
  void _showAntigravityQuotaSheet(BuildContext context) {
    showQuotaDetailSheet(context, widget.modelQuotas);
  }
}
