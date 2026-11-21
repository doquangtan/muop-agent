import 'package:material_ui/material_ui.dart';

import 'package:muop_agent/core/theme/app_theme.dart';
import 'package:muop_agent/features/quota/domain/quota_entities.dart';
import 'package:muop_agent/features/sessions/domain/session_entities.dart';

/// Màu theo phần còn lại của quota: đỏ khi ≤15%, vàng khi ≤45%, còn lại xanh
Color quotaStatusColor(BuildContext context, double remainingPct) {
  if (remainingPct <= 15) return context.scheme.error;
  if (remainingPct <= 45) return context.status.warning;
  return context.status.success;
}

String _two(int n) => n.toString().padLeft(2, '0');

/// Chuỗi thời gian reset kèm thời gian còn lại, ví dụ `Reset 08:30 hôm nay · còn 2g 15p`.
/// [raw] là thời điểm RFC3339 (UTC hoặc có offset). Trả về null nếu không đọc được.
String? formatQuotaReset(String raw, {DateTime? now}) {
  if (raw.trim().isEmpty) return null;
  final parsed = DateTime.tryParse(raw.trim());
  if (parsed == null) return null;
  final resetAt = parsed.toLocal();
  final current = (now ?? DateTime.now()).toLocal();
  final left = resetAt.difference(current);
  if (left.isNegative) return 'Đã reset';

  final sameDay =
      resetAt.year == current.year &&
      resetAt.month == current.month &&
      resetAt.day == current.day;
  final clock = '${_two(resetAt.hour)}:${_two(resetAt.minute)}';
  final when = sameDay
      ? 'hôm nay'
      : '${_two(resetAt.day)}/${_two(resetAt.month)}';

  final String remain;
  if (left.inDays >= 1) {
    remain = '${left.inDays}n ${left.inHours % 24}g';
  } else if (left.inHours >= 1) {
    remain = '${left.inHours}g ${left.inMinutes % 60}p';
  } else {
    remain = '${left.inMinutes}p';
  }
  return 'Reset $clock $when · còn $remain';
}

/// Phiên bản ngắn cho thanh % trên chat: `08:30` (cùng ngày) hoặc `20/11 13:00`.
/// Trả về null khi không có thời điểm reset hoặc đã qua thời điểm đó.
String? formatQuotaResetCompact(String raw, {DateTime? now}) {
  if (raw.trim().isEmpty) return null;
  final parsed = DateTime.tryParse(raw.trim());
  if (parsed == null) return null;
  final resetAt = parsed.toLocal();
  final current = (now ?? DateTime.now()).toLocal();
  if (!resetAt.isAfter(current)) return null;
  final clock = '${_two(resetAt.hour)}:${_two(resetAt.minute)}';
  final sameDay =
      resetAt.year == current.year &&
      resetAt.month == current.month &&
      resetAt.day == current.day;
  return sameDay ? clock : '${_two(resetAt.day)}/${_two(resetAt.month)} $clock';
}

/// Mở bảng chi tiết quota dạng bottom sheet. Mỗi báo cáo là một provider (agy / Claude).
Future<void> showQuotaDetailSheet(
  BuildContext context,
  List<QuotaReport> reports,
) {
  final colorScheme = Theme.of(context).colorScheme;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: colorScheme.surfaceContainer,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => QuotaDetailSheet(
      reports: reports,
      onClose: () => Navigator.of(ctx).pop(),
    ),
  );
}

/// Nội dung bảng quota. Header cố định, danh sách nhóm cuộn được và không vượt
/// 80% chiều cao màn hình, nên vẫn xem đủ trên điện thoại màn hình nhỏ.
class QuotaDetailSheet extends StatelessWidget {
  const QuotaDetailSheet({super.key, required this.reports, this.onClose});

  final List<QuotaReport> reports;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final maxHeight = MediaQuery.sizeOf(context).height * 0.8;

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.speed_rounded, size: 18, color: colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Quota & Limits',
                    style: textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                if (onClose != null)
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close_rounded),
                    onPressed: onClose,
                  ),
              ],
            ),
            const Divider(height: 10),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.only(right: 8, bottom: 4),
                children: [
                  for (final report in reports)
                    _QuotaReportSection(report: report),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Một provider trong bảng: tiêu đề, rồi các nhóm quota, hoặc thông báo không có dữ liệu kèm lý do
class _QuotaReportSection extends StatelessWidget {
  const _QuotaReportSection({required this.report});

  final QuotaReport report;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 4),
          child: Text(
            report.providerLabel,
            style: textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w800,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        if (!report.hasData)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              report.error.isEmpty
                  ? 'Không có dữ liệu quota'
                  : 'Không có dữ liệu quota: ${report.error}',
              style: textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          )
        else
          for (final group in report.groups) _QuotaGroupCard(group: group),
      ],
    );
  }
}

class _QuotaGroupCard extends StatelessWidget {
  const _QuotaGroupCard({required this.group});

  final ModelQuotaGroup group;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            group.displayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w800,
              color: colorScheme.primary,
            ),
          ),
          if (group.description.isNotEmpty)
            Text(
              group.description,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: textTheme.labelSmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          const SizedBox(height: 6),
          for (final bucket in group.buckets)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: _QuotaBucketRow(bucket: bucket),
            ),
        ],
      ),
    );
  }
}

class _QuotaBucketRow extends StatelessWidget {
  const _QuotaBucketRow({required this.bucket});

  final ModelQuotaBucket bucket;

  String get _label => bucket.window == '5h'
      ? 'Limit giờ (5h)'
      : 'Limit tuần (${bucket.displayName})';

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final color = quotaStatusColor(context, bucket.remainingPercent);
    final resetText = formatQuotaReset(bucket.resetTime);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                _label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.labelSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${bucket.remainingPercent.round()}%',
              style: textTheme.labelSmall?.copyWith(
                fontFamily: 'monospace',
                fontWeight: FontWeight.w800,
                color: color,
              ),
            ),
          ],
        ),
        const SizedBox(height: 3),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            minHeight: 4,
            value: bucket.remainingFraction.clamp(0.0, 1.0),
            backgroundColor: colorScheme.surfaceContainerHighest,
            valueColor: AlwaysStoppedAnimation<Color>(color),
          ),
        ),
        if (bucket.description.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(
            bucket.description,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: textTheme.labelSmall?.copyWith(
              fontSize: 10,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        if (resetText != null) ...[
          const SizedBox(height: 2),
          Text(
            resetText,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: textTheme.labelSmall?.copyWith(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}
