import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import 'package:muop_agent/core/theme/app_theme.dart';
import 'package:muop_agent/core/widgets/spinning_icon.dart';
import 'package:muop_agent/features/interactions/domain/interaction_entities.dart';

/// Định dạng thời gian còn lại: `mm:ss` hoặc `h:mm:ss`
String formatRetryRemaining(Duration remaining) {
  if (remaining.isNegative) return '00:00';
  final total = remaining.inSeconds;
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
}

/// Dòng mô tả căn cứ chờ: `Chờ reset quota · Phiên 5 giờ · reset 14:30`. Rỗng nếu server không gửi.
String retryWaitLine(PendingRetry retry) {
  if (retry.waitDetail.isEmpty) return '';
  final reset = retry.resetAt;
  if (reset == null) return retry.waitDetail;
  final local = reset.toLocal();
  if (!local.isAfter(DateTime.now())) return retry.waitDetail;
  String two(int v) => v.toString().padLeft(2, '0');
  return '${retry.waitDetail} · reset ${two(local.hour)}:${two(local.minute)}';
}

/// Đếm ngược tới `retryAt`, tự cập nhật mỗi giây. Khi hết giờ hiện "Đang gửi lại…".
class RetryCountdownText extends StatefulWidget {
  const RetryCountdownText({
    super.key,
    required this.retryAt,
    this.style,
  });

  final DateTime retryAt;
  final TextStyle? style;

  @override
  State<RetryCountdownText> createState() => _RetryCountdownTextState();
}

class _RetryCountdownTextState extends State<RetryCountdownText> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final remaining = widget.retryAt.difference(DateTime.now());
    final text = remaining.inSeconds <= 0
        ? 'Đang gửi lại…'
        : formatRetryRemaining(remaining);
    return Text(text, style: widget.style);
  }
}

/// Banner trong conversation: báo lịch tự gửi lại và có nút hủy
class RetryBanner extends StatelessWidget {
  const RetryBanner({
    super.key,
    required this.retry,
    required this.onCancel,
    this.isMobile = false,
  });

  final PendingRetry retry;
  final Future<void> Function() onCancel;
  final bool isMobile;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final textTheme = Theme.of(context).textTheme;
    final warning = context.status.warning;

    return Container(
      margin: EdgeInsets.only(bottom: isMobile ? 6 : 8),
      padding: EdgeInsets.symmetric(
        horizontal: isMobile ? 10 : 14,
        vertical: isMobile ? 8 : 10,
      ),
      decoration: BoxDecoration(
        color: warning.withAlpha(28),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: warning.withAlpha(140)),
      ),
      child: Row(
        children: [
          SpinningIcon(
            icon: Icons.hourglass_top_rounded,
            size: 18,
            color: warning,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Đã chạm giới hạn · tự gửi lại sau',
                  style: textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Row(
                  children: [
                    RetryCountdownText(
                      retryAt: retry.retryAt,
                      style: textTheme.titleSmall?.copyWith(
                        color: warning,
                        fontWeight: FontWeight.w700,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'lần ${retry.attempt}/${retry.maxAttempts}',
                      style: textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                if (retryWaitLine(retry).isNotEmpty)
                  Text(
                    retryWaitLine(retry),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          TextButton(
            onPressed: () => onCancel(),
            child: const Text('Hủy'),
          ),
        ],
      ),
    );
  }
}

/// Popup hiện ngay khi có lịch tự gửi lại. Tự đóng khi lịch biến mất (đã gửi lại hoặc đã hủy).
class RetryPopup extends StatelessWidget {
  const RetryPopup({
    super.key,
    required this.conversationId,
    required this.retries,
    required this.onCancel,
  });

  final String conversationId;
  final ValueListenable<List<PendingRetry>> retries;
  final Future<void> Function() onCancel;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<PendingRetry>>(
      valueListenable: retries,
      builder: (context, list, _) {
        final matches =
            list.where((r) => r.conversationId == conversationId).toList();
        final retry = matches.isEmpty ? null : matches.first;
        if (retry == null) {
          // Lịch đã được gửi lại hoặc hủy: đóng popup
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (context.mounted && Navigator.of(context).canPop()) {
              Navigator.of(context).pop();
            }
          });
          return const SizedBox.shrink();
        }
        final scheme = context.scheme;
        final textTheme = Theme.of(context).textTheme;
        final warning = context.status.warning;

        return AlertDialog(
          icon: SpinningIcon(
            icon: Icons.hourglass_top_rounded,
            color: warning,
            size: 32,
          ),
          title: const Text('Đã chạm giới hạn'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Agent sẽ tự gửi lại tin nhắn khi hết thời gian chờ.',
                style: textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
              Center(
                child: RetryCountdownText(
                  retryAt: retry.retryAt,
                  style: textTheme.displaySmall?.copyWith(
                    color: warning,
                    fontWeight: FontWeight.w700,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Center(
                child: Text(
                  'Lần thử ${retry.attempt}/${retry.maxAttempts}',
                  style: textTheme.labelMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              if (retryWaitLine(retry).isNotEmpty) ...[
                const SizedBox(height: 6),
                Center(
                  child: Text(
                    retryWaitLine(retry),
                    style: textTheme.labelMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
              if (retry.reason.isNotEmpty) ...[
                const SizedBox(height: 14),
                Text(
                  retry.reason,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () async {
                await onCancel();
              },
              child: const Text('Hủy tự gửi lại'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Đóng'),
            ),
          ],
        );
      },
    );
  }
}
