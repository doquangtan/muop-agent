part of '../chat_canvas_view.dart';

extension _CanvasExtScroll on _ChatCanvasViewState {
  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;

    // Với ListView(reverse: true), pixels = 0.0 là đáy (đoạn chat mới nhất).
    final shouldShowBtn = pos.pixels > 240;
    if (shouldShowBtn != _showScrollToBottomNotifier.value) {
      _showScrollToBottomNotifier.value = shouldShowBtn;
    }

    _maybeLoadOlderTurns();
  }

  /// Nạp thêm lịch sử khi banner đầu danh sách còn nằm trong khung nhìn.
  /// Được gọi lại sau mỗi lần nạp để tiếp tục cho đến khi banner bị đẩy ra ngoài
  /// hoặc hết dữ liệu cũ.
  void _maybeLoadOlderTurns() {
    if (!_scrollController.hasClients ||
        _isLoadingMoreTurns ||
        _hasOlderHistoryError) {
      return;
    }
    final session = widget.session;
    // Chờ nạp xong trang bước ban đầu của phiên trước khi phân trang lịch sử cũ
    if (session == null ||
        widget.isNewConversationMode ||
        session.steps.isEmpty) {
      return;
    }
    final pos = _scrollController.position;
    if (pos.maxScrollExtent - pos.pixels < pos.viewportDimension) {
      _loadOlderTurnsPage();
    }
  }

  void _scheduleOlderTurnsCheck() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _maybeLoadOlderTurns();
    });
  }

  Future<void> _loadOlderTurnsPage() async {
    final session = widget.session;
    if (session == null ||
        widget.isNewConversationMode ||
        session.steps.isEmpty ||
        _isLoadingMoreTurns) {
      return;
    }

    final totalTurns = _countTurnGroups(session.steps);

    // 1. Nếu còn turn cũ trong bộ nhớ cục bộ, nạp thêm ngay lập tức không delay
    if (_loadedTurnCount < totalTurns) {
      _applyState(() {
        _loadedTurnCount = math.min(
          totalTurns,
          _loadedTurnCount + _ChatCanvasViewState._pageSize,
        );
      });
      _scheduleOlderTurnsCheck();
      return;
    }

    // 2. Nếu đã hiển thị hết turn cục bộ, gọi server nạp thêm một trang steps cũ hơn
    if (widget.onLoadOlderHistory != null && !_hasLoadedAllServerHistory) {
      _applyState(() {
        _isLoadingMoreTurns = true;
        _hasOlderHistoryError = false;
        _pendingServerTurnsExpand = true;
      });
      try {
        final hasMore = await widget.onLoadOlderHistory!();
        if (!mounted) return;
        final updatedTotalTurns = _countTurnGroups(
          widget.session?.steps ?? const [],
        );

        _applyState(() {
          if (updatedTotalTurns > totalTurns) {
            _pendingServerTurnsExpand = false;
            _loadedTurnCount = math.max(
              _loadedTurnCount,
              math.min(
                updatedTotalTurns,
                _loadedTurnCount + _ChatCanvasViewState._pageSize,
              ),
            );
          }
          if (hasMore == null) {
            // Lỗi mạng/timeout tạm thời: không khóa vĩnh viễn phân trang, cho phép nhấn thử lại
            _pendingServerTurnsExpand = false;
            _hasOlderHistoryError = true;
          } else {
            _hasOlderHistoryError = false;
            if (!hasMore) {
              _hasLoadedAllServerHistory = true;
            }
          }
          _isLoadingMoreTurns = false;
        });
        if (hasMore != null) {
          _scheduleOlderTurnsCheck();
        }
      } catch (_) {
        if (mounted) {
          _applyState(() {
            _pendingServerTurnsExpand = false;
            _hasOlderHistoryError = true;
            _isLoadingMoreTurns = false;
          });
        }
      }
    }
  }

  void _scrollToBottom({bool animated = true}) {
    if (!_scrollController.hasClients) return;
    if (animated) {
      _scrollController.animateTo(
        0.0,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
      );
    } else {
      _scrollController.jumpTo(0.0);
    }
  }

  Widget _buildLoadMoreOlderTurnsBanner(
    BuildContext context, {
    required int remainingCount,
    required int loadedCount,
    required int totalCount,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final nextBatch = math.min(_ChatCanvasViewState._pageSize, remainingCount);

    return Padding(
      padding: const EdgeInsets.only(bottom: 18, top: 6),
      child: Center(
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: _isLoadingMoreTurns
              ? null
              : () {
                  _hasOlderHistoryError = false;
                  _loadOlderTurnsPage();
                },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: _hasOlderHistoryError
                    ? colorScheme.error.withAlpha(140)
                    : colorScheme.outlineVariant,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_isLoadingMoreTurns) ...[
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: colorScheme.primary,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      'Đang tải thêm đoạn chat cũ...',
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.labelSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: colorScheme.primary,
                      ),
                    ),
                  ),
                ] else if (_hasOlderHistoryError) ...[
                  Icon(
                    Icons.refresh_rounded,
                    size: 15,
                    color: colorScheme.error,
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      'Không tải được lịch sử cũ • Nhấn để thử lại',
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.labelSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: colorScheme.error,
                      ),
                    ),
                  ),
                ] else ...[
                  Icon(
                    Icons.history_rounded,
                    size: 15,
                    color: colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      remainingCount > 0
                          ? 'Tải thêm $nextBatch đoạn hội thoại cũ ($loadedCount/$totalCount)'
                          : 'Nhấn hoặc cuộn để tải thêm lịch sử từ Server...',
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.labelSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: colorScheme.onSurface,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
