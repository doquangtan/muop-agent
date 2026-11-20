part of '../chat_canvas_view.dart';

/// Giới hạn ảnh đính kèm, khớp với server (`server/src/chat/attachments.rs`)
const int _kMaxComposerImages = 6;
const int _kMaxComposerImageBytes = 20 * 1024 * 1024;

extension _CanvasExtComposer on _ChatCanvasViewState {
  void _handleSend() {
    final text = _promptController.text.trim();
    final images = _pendingImages;
    if ((text.isEmpty && images.isEmpty) || widget.isSending) return;
    _promptController.clear();
    _applyState(() {
      _composerRevealed = false;
      _pendingImages = const [];
    });
    widget.onSendMessage(text, images);
    Future.delayed(const Duration(milliseconds: 100), () {
      _scrollToBottom(animated: true);
    });
  }

  void _showComposerNotice(String message) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  /// Chọn ảnh từ máy (desktop: hộp thoại file; Android: trình chọn file/ảnh của hệ thống)
  Future<void> _pickComposerImages() async {
    final remaining = _kMaxComposerImages - _pendingImages.length;
    if (remaining <= 0) {
      _showComposerNotice('Tối đa $_kMaxComposerImages ảnh cho mỗi tin nhắn');
      return;
    }
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['png', 'jpg', 'jpeg', 'webp'],
    );
    if (!mounted || files.isEmpty) return;

    final picked = <ChatImageAttachment>[];
    String? problem;
    for (final file in files) {
      if (picked.length >= remaining) {
        problem = 'Chỉ thêm tối đa $_kMaxComposerImages ảnh cho mỗi tin nhắn';
        break;
      }
      final mime = _imageMimeFor(file.extension);
      if (mime == null) {
        problem = '${file.name}: chỉ hỗ trợ PNG, JPEG, WebP';
        continue;
      }
      final size = await file.length();
      if (size != null && size > _kMaxComposerImageBytes) {
        problem = '${file.name}: vượt quá 20 MB';
        continue;
      }
      final bytes = await file.readAsBytes();
      if (bytes.length > _kMaxComposerImageBytes) {
        problem = '${file.name}: vượt quá 20 MB';
        continue;
      }
      picked.add(
        ChatImageAttachment(name: file.name, mimeType: mime, bytes: bytes),
      );
    }
    if (!mounted) return;
    if (picked.isNotEmpty) {
      _applyState(() => _pendingImages = [..._pendingImages, ...picked]);
    }
    if (problem != null) _showComposerNotice(problem);
  }

  static String? _imageMimeFor(String? extension) {
    switch (extension?.toLowerCase()) {
      case 'png':
        return 'image/png';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'webp':
        return 'image/webp';
      default:
        return null;
    }
  }

  /// Dải ảnh đang chờ gửi, mỗi ảnh có nút bỏ
  Widget _buildPendingImagesStrip(ColorScheme colorScheme, bool isMobile) {
    final size = isMobile ? 56.0 : 64.0;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        isMobile ? 12 : 16,
        isMobile ? 8 : 10,
        isMobile ? 12 : 16,
        0,
      ),
      child: SizedBox(
        height: size + 6,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: _pendingImages.length,
          separatorBuilder: (context, index) => const SizedBox(width: 8),
          itemBuilder: (context, index) {
            final image = _pendingImages[index];
            return Stack(
              clipBehavior: Clip.none,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.memory(
                    image.bytes,
                    width: size,
                    height: size,
                    fit: BoxFit.cover,
                    cacheWidth: 160,
                    gaplessPlayback: true,
                    errorBuilder: (context, error, stack) => Container(
                      width: size,
                      height: size,
                      color: colorScheme.surfaceContainerHighest,
                      child: Icon(
                        Icons.broken_image_outlined,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: -6,
                  right: -6,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _applyState(() {
                      _pendingImages = [..._pendingImages]..removeAt(index);
                    }),
                    child: Container(
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        color: colorScheme.surface,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: colorScheme.outlineVariant,
                          width: 0.8,
                        ),
                      ),
                      child: Icon(
                        Icons.close_rounded,
                        size: 13,
                        color: colorScheme.onSurface,
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  KeyEventResult _handleComposerKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key != LogicalKeyboardKey.enter &&
        key != LogicalKeyboardKey.numpadEnter) {
      return KeyEventResult.ignored;
    }
    if (HardwareKeyboard.instance.isShiftPressed) return KeyEventResult.ignored;
    if (_promptController.value.composing.isValid) {
      return KeyEventResult.ignored;
    }
    _handleSend();
    return KeyEventResult.handled;
  }

  /// Hàng công cụ nằm ngay trên khung chat: Agent map, duyệt SFTP và Git Tree.
  /// Tách khỏi khung chat để vẫn dùng được khi khung chat đang ẩn (lúc agent đang chạy).
  Widget _buildComposerToolRow(BuildContext context, bool isMobile) {
    final colorScheme = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          if (widget.onOpenAgentMap != null) ...[
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: widget.onOpenAgentMap,
              child: _ComposerPill(
                icon: Icons.hub_outlined,
                label: isMobile ? 'Agent' : 'Agent map',
                colorScheme: colorScheme,
              ),
            ),
            const SizedBox(width: 5),
          ],
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: widget.onOpenFileBrowser,
            child: _ComposerPill(
              icon: Icons.dns_outlined,
              label: isMobile ? 'SFTP' : 'Duyệt SFTP Server',
              colorScheme: colorScheme,
            ),
          ),
          if (widget.onOpenGitHistory != null) ...[
            const SizedBox(width: 5),
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: widget.onOpenGitHistory,
              child: _ComposerPill(
                icon: Icons.account_tree_outlined,
                label: isMobile ? 'Git Tree' : 'Git Tree & History',
                colorScheme: colorScheme,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// [3] KHUNG NHẬP CHAT HỢP NHẤT (COMPOSER BOX) — Nằm dưới cùng
  Widget _buildAntigravityComposer(
    BuildContext context,
    bool isMobile,
    bool isTurnRunning,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final activeProjectName =
        widget.selectedProject?.name ??
        widget.session?.projectName ??
        'muop-erp-server';

    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colorScheme.outlineVariant, width: 1.1),
        boxShadow: [
          BoxShadow(
            color: context.scheme.shadow.withAlpha(14),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_pendingImages.isNotEmpty)
            _buildPendingImagesStrip(colorScheme, isMobile),
          Padding(
            padding: EdgeInsets.fromLTRB(
              isMobile ? 12 : 16,
              isMobile ? 6 : 8,
              isMobile ? 12 : 16,
              2,
            ),
            child: RepaintBoundary(
              child: Focus(
                onKeyEvent: isMobile ? null : _handleComposerKeyEvent,
                child: TextField(
                  controller: _promptController,
                  focusNode: _inputFocusNode,
                  minLines: 4,
                  maxLines: 10,
                  keyboardType: TextInputType.multiline,
                  autocorrect: false,
                  enableSuggestions: true,
                  textInputAction: TextInputAction.newline,
                  style: textTheme.bodyMedium?.copyWith(
                    height: 1.38,
                    fontSize: isMobile ? 13.5 : 14,
                    color: colorScheme.onSurface,
                  ),
                  decoration: InputDecoration(
                    hintText: isMobile
                        ? 'Nhập tin nhắn cho Agent ($activeProjectName)...'
                        : 'Ask anything in $activeProjectName, or type / for workflows...',
                    hintStyle: textTheme.bodyMedium?.copyWith(
                      fontSize: isMobile ? 13 : 13.5,
                      color: colorScheme.onSurfaceVariant.withAlpha(155),
                    ),
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 5),
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 2, 8, 6),
            child: Row(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: () => _showSlashCommandsPicker(context),
                          child: _ComposerPill(
                            icon: Icons.terminal_rounded,
                            label: '/',
                            colorScheme: colorScheme,
                          ),
                        ),
                        const SizedBox(width: 5),

                        PopupMenuButton<dynamic>(
                          tooltip: 'Chọn Project Workspace',
                          onSelected: (val) {
                            if (val is ProjectWorkspace) {
                              widget.onSelectProject(val);
                            } else if (val == '__create_project__') {
                              widget.onOpenCreateProject?.call();
                            }
                          },
                          itemBuilder: (ctx) => [
                            if (widget.onOpenCreateProject != null)
                              PopupMenuItem<String>(
                                value: '__create_project__',
                                child: Row(
                                  children: [
                                    Icon(
                                      Icons.create_new_folder_outlined,
                                      size: 16,
                                      color: colorScheme.primary,
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      '+ Tạo Project mới',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w700,
                                        color: colorScheme.primary,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            for (final p in widget.projects)
                              PopupMenuItem<ProjectWorkspace>(
                                value: p,
                                child: Row(
                                  children: [
                                    Icon(
                                      Icons.folder_outlined,
                                      size: 16,
                                      color: p.name == activeProjectName
                                          ? colorScheme.primary
                                          : colorScheme.onSurfaceVariant,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        p.name,
                                        style: TextStyle(
                                          fontWeight:
                                              p.name == activeProjectName
                                              ? FontWeight.w700
                                              : FontWeight.w500,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                          child: _ComposerPill(
                            icon: Icons.folder_outlined,
                            label: activeProjectName,
                            hasDropdown: true,
                            colorScheme: colorScheme,
                          ),
                        ),
                        const SizedBox(width: 5),

                        PopupMenuButton<String>(
                          tooltip: 'Chọn Agent',
                          onSelected: widget.onSelectAgent,
                          itemBuilder: (ctx) {
                            final effectiveAgents =
                                (widget.session != null &&
                                    widget.session!.availableAgents.isNotEmpty)
                                ? widget.session!.availableAgents
                                : (widget.selectedProject != null &&
                                      widget
                                          .selectedProject!
                                          .availableAgents
                                          .isNotEmpty)
                                ? widget.selectedProject!.availableAgents
                                : widget.availableAgents;
                            return [
                              for (final a in effectiveAgents)
                                PopupMenuItem<String>(
                                  value: a,
                                  child: Text(
                                    a,
                                    style: TextStyle(
                                      fontWeight: a == widget.selectedAgent
                                          ? FontWeight.w700
                                          : FontWeight.w500,
                                    ),
                                  ),
                                ),
                            ];
                          },
                          child: _ComposerPill(
                            icon: Icons.smart_toy_outlined,
                            label: widget.selectedAgent,
                            hasDropdown: true,
                            colorScheme: colorScheme,
                          ),
                        ),
                        const SizedBox(width: 5),

                        InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: widget.isSending ? null : _pickComposerImages,
                          child: _ComposerPill(
                            icon: Icons.image_outlined,
                            label: _pendingImages.isEmpty
                                ? (isMobile ? 'Ảnh' : 'Đính kèm ảnh')
                                : 'Ảnh (${_pendingImages.length})',
                            colorScheme: colorScheme,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                if (isTurnRunning)
                  IconButton.filledTonal(
                    tooltip: 'Dừng lượt chạy (Stop)',
                    onPressed: widget.onStopTurn,
                    style: IconButton.styleFrom(
                      backgroundColor: context.scheme.error.withAlpha(40),
                      foregroundColor: context.scheme.error,
                      minimumSize: const Size(32, 32),
                      padding: EdgeInsets.zero,
                    ),
                    icon: const Icon(Icons.stop_rounded, size: 17),
                  )
                else
                  IconButton.filled(
                    tooltip: 'Gửi tin nhắn (Enter)',
                    onPressed: _handleSend,
                    style: IconButton.styleFrom(
                      minimumSize: const Size(32, 32),
                      padding: EdgeInsets.zero,
                    ),
                    icon: const Icon(Icons.arrow_upward_rounded, size: 17),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showSlashCommandsPicker(BuildContext context) async {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final isClaude = _isClaudeCliModel(widget.selectedModel);
    final List<CustomAgentSpec> projectSkills;
    final List<CustomAgentSpec> claudeAgents;
    final List<CustomAgentSpec> claudeCommands;
    if (isClaude) {
      final projectPath =
          widget.session?.projectPath ?? widget.selectedProject?.path ?? '';
      final items =
          await widget.onFetchClaudeExtensions?.call(projectPath) ??
          const <CustomAgentSpec>[];
      if (!context.mounted) return;
      projectSkills = items.where((s) => s.kind == 'skill').toList();
      claudeAgents = items.where((s) => s.kind == 'agent').toList();
      claudeCommands = items.where((s) => s.kind == 'command').toList();
    } else {
      final sessionCustom = widget.session?.customAgents ?? const [];
      final allCustom = sessionCustom.isNotEmpty
          ? sessionCustom
          : widget.selectedProject?.customAgents ?? const [];
      projectSkills = allCustom.where((s) => s.kind == 'skill').toList();
      claudeAgents = const [];
      claudeCommands = const [];
    }
    final skillSourceLabel = isClaude
        ? 'Kỹ năng Claude Code (.claude/skills)'
        : 'Kỹ năng Dự án & Ecosystem (.agents)';

    final coreCommands = const [
      (
        cmd: '/plan',
        label: 'Lập kế hoạch chi tiết',
        desc: 'Thiết kế Shared Contract, phân chia tác vụ & chờ duyệt',
        icon: Icons.architecture_rounded,
      ),
      (
        cmd: '/boost',
        label: 'Phân tích chuyên sâu',
        desc: 'Kích hoạt suy luận đa góc nhìn và giải quyết vấn đề phức tạp',
        icon: Icons.bolt_rounded,
      ),
      (
        cmd: '/goal',
        label: 'Tự chủ hoàn thành mục tiêu',
        desc: 'Thực thi không dừng cho đến khi hoàn tất 100% mục tiêu',
        icon: Icons.flag_rounded,
      ),
      (
        cmd: '/compact',
        label: 'Thu gọn ngữ cảnh',
        desc: 'Nén và giải phóng context window cho cuộc hội thoại dài',
        icon: Icons.compress_rounded,
      ),
      (
        cmd: '/learn',
        label: 'Ghi nhớ kinh nghiệm',
        desc: 'Lưu trữ kinh nghiệm và quy tắc xử lý cho các lần sau',
        icon: Icons.menu_book_rounded,
      ),
    ];

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: colorScheme.surfaceContainer,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        String searchQuery = '';
        return StatefulBuilder(
          builder: (modalCtx, setModalState) {
            final query = searchQuery.trim().toLowerCase();

            final filteredCore = coreCommands.where((c) {
              if (query.isEmpty) return true;
              return c.cmd.toLowerCase().contains(query) ||
                  c.label.toLowerCase().contains(query) ||
                  c.desc.toLowerCase().contains(query);
            }).toList();

            bool matchesQuery(CustomAgentSpec s) {
              if (query.isEmpty) return true;
              return s.name.toLowerCase().contains(query) ||
                  s.description.toLowerCase().contains(query);
            }

            final filteredSkills = projectSkills.where(matchesQuery).toList();
            final filteredAgents = claudeAgents.where(matchesQuery).toList();
            final filteredCommands = claudeCommands
                .where(matchesQuery)
                .toList();

            return DraggableScrollableSheet(
              initialChildSize: 0.65,
              minChildSize: 0.40,
              maxChildSize: 0.90,
              expand: false,
              builder: (context, scrollController) {
                return Column(
                  children: [
                    Center(
                      child: Container(
                        margin: const EdgeInsets.only(top: 10, bottom: 6),
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(
                          color: colorScheme.outlineVariant,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                      child: Row(
                        children: [
                          Icon(
                            Icons.terminal_rounded,
                            size: 20,
                            color: context.scheme.tertiary,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Slash Workflows & Kỹ Năng (/skill)',
                              style: textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.close_rounded),
                            onPressed: () => Navigator.of(ctx).pop(),
                            tooltip: 'Đóng',
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                      child: TextField(
                        onChanged: (val) {
                          setModalState(() {
                            searchQuery = val;
                          });
                        },
                        style: textTheme.bodyMedium,
                        decoration: InputDecoration(
                          hintText: 'Tìm kiếm lệnh hoặc kỹ năng...',
                          prefixIcon: const Icon(
                            Icons.search_rounded,
                            size: 18,
                          ),
                          isDense: true,
                          filled: true,
                          fillColor: colorScheme.surfaceContainerHighest
                              .withAlpha(120),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(
                              color: colorScheme.outlineVariant.withAlpha(60),
                            ),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(
                              color: colorScheme.outlineVariant.withAlpha(60),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: ListView(
                        controller: scrollController,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        children: [
                          if (filteredSkills.isNotEmpty)
                            ..._buildSlashGroup(
                              ctx,
                              title: skillSourceLabel,
                              icon: Icons.auto_awesome_rounded,
                              color: context.scheme.tertiary,
                              itemIcon: Icons.auto_awesome_rounded,
                              items: filteredSkills,
                              tokenOf: (s) => '/${s.name}',
                            ),
                          if (filteredAgents.isNotEmpty)
                            ..._buildSlashGroup(
                              ctx,
                              title: 'Sub-agents Claude Code (.claude/agents)',
                              icon: Icons.smart_toy_rounded,
                              color: context.status.success,
                              itemIcon: Icons.smart_toy_outlined,
                              items: filteredAgents,
                              tokenOf: (s) => '@agent-${s.name}',
                            ),
                          if (filteredCommands.isNotEmpty)
                            ..._buildSlashGroup(
                              ctx,
                              title: 'Lệnh Claude Code (.claude/commands)',
                              icon: Icons.terminal_rounded,
                              color: colorScheme.secondary,
                              itemIcon: Icons.code_rounded,
                              items: filteredCommands,
                              tokenOf: (s) => '/${s.name}',
                            ),
                          if (filteredCore.isNotEmpty) ...[
                            Padding(
                              padding: const EdgeInsets.only(top: 6, bottom: 6),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.tune_rounded,
                                    size: 14,
                                    color: colorScheme.primary,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    'Workflows Điều Phối (Core)',
                                    style: textTheme.labelSmall?.copyWith(
                                      fontWeight: FontWeight.w800,
                                      color: colorScheme.primary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            for (final c in filteredCore)
                              InkWell(
                                borderRadius: BorderRadius.circular(10),
                                onTap: () {
                                  Navigator.of(ctx).pop();
                                  _insertSlashCommand('${c.cmd} ');
                                },
                                child: Container(
                                  margin: const EdgeInsets.only(bottom: 6),
                                  padding: const EdgeInsets.all(10),
                                  decoration: BoxDecoration(
                                    color: colorScheme.surfaceContainerHigh,
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(
                                      color: colorScheme.outlineVariant
                                          .withAlpha(60),
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.all(6),
                                        decoration: BoxDecoration(
                                          color: colorScheme.primary.withAlpha(
                                            25,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                        ),
                                        child: Icon(
                                          c.icon,
                                          size: 16,
                                          color: colorScheme.primary,
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Row(
                                              children: [
                                                Text(
                                                  c.cmd,
                                                  style: textTheme.labelLarge
                                                      ?.copyWith(
                                                        fontWeight:
                                                            FontWeight.w700,
                                                        color:
                                                            colorScheme.primary,
                                                      ),
                                                ),
                                                const SizedBox(width: 6),
                                                Text(
                                                  '— ${c.label}',
                                                  style: textTheme.labelMedium
                                                      ?.copyWith(
                                                        fontWeight:
                                                            FontWeight.w600,
                                                      ),
                                                ),
                                              ],
                                            ),
                                            const SizedBox(height: 2),
                                            Text(
                                              c.desc,
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                              style: textTheme.bodySmall
                                                  ?.copyWith(
                                                    color: colorScheme
                                                        .onSurfaceVariant,
                                                    fontSize: 11,
                                                  ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      Icon(
                                        Icons.add_rounded,
                                        size: 16,
                                        color: colorScheme.onSurfaceVariant
                                            .withAlpha(140),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                          ],
                          if (filteredSkills.isEmpty &&
                              filteredAgents.isEmpty &&
                              filteredCommands.isEmpty &&
                              filteredCore.isEmpty)
                            Padding(
                              padding: const EdgeInsets.all(32),
                              child: Center(
                                child: Text(
                                  'Không tìm thấy lệnh hoặc kỹ năng phù hợp với "$searchQuery"',
                                  style: textTheme.bodySmall?.copyWith(
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }

  List<Widget> _buildSlashGroup(
    BuildContext sheetCtx, {
    required String title,
    required IconData icon,
    required Color color,
    required IconData itemIcon,
    required List<CustomAgentSpec> items,
    required String Function(CustomAgentSpec spec) tokenOf,
  }) {
    final colorScheme = Theme.of(sheetCtx).colorScheme;
    final textTheme = Theme.of(sheetCtx).textTheme;
    return [
      Padding(
        padding: const EdgeInsets.only(top: 6, bottom: 6),
        child: Row(
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 6),
            Text(
              title,
              style: textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.w800,
                color: color,
              ),
            ),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: color.withAlpha(30),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                '${items.length}',
                style: TextStyle(
                  fontSize: 9.5,
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
            ),
          ],
        ),
      ),
      for (final s in items)
        InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () {
            Navigator.of(sheetCtx).pop();
            _insertSlashCommand('${tokenOf(s)} ');
          },
          child: Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: colorScheme.outlineVariant.withAlpha(60),
              ),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: color.withAlpha(25),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(itemIcon, size: 16, color: color),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        tokenOf(s),
                        style: textTheme.labelLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: color,
                        ),
                      ),
                      if (s.description.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          s.description,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                Icon(
                  Icons.add_rounded,
                  size: 16,
                  color: colorScheme.onSurfaceVariant.withAlpha(140),
                ),
              ],
            ),
          ),
        ),
      const SizedBox(height: 8),
    ];
  }

  void _insertSlashCommand(String cmd) {
    final text = _promptController.text;
    if (text.startsWith('/')) {
      final firstSpace = text.indexOf(' ');
      if (firstSpace != -1) {
        _promptController.text = '$cmd${text.substring(firstSpace + 1)}';
      } else {
        _promptController.text = cmd;
      }
    } else {
      _promptController.text = '$cmd$text';
    }
    _promptController.selection = TextSelection.fromPosition(
      TextPosition(offset: _promptController.text.length),
    );
    _inputFocusNode.requestFocus();
  }
}
