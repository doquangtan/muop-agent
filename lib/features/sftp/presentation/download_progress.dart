import 'package:material_ui/material_ui.dart';

/// Tiến trình tải: [total] < 0 khi chưa biết kích thước (đang chuẩn bị ở server)
class DownloadProgress {
  const DownloadProgress(this.received, this.total);

  final int received;
  final int total;

  /// 0..1, hoặc null khi chưa biết tổng (hiện thanh chạy vô định)
  double? get fraction =>
      total > 0 ? (received / total).clamp(0.0, 1.0).toDouble() : null;
}

/// Hiện tiến trình tải trong SnackBar (giữ tới khi [run] xong), rồi trả về kết quả của [run].
/// Dùng chung cho khung chat và màn SFTP để mọi lần tải đều hiện % giống nhau.
Future<T> runWithDownloadProgress<T>(
  BuildContext context, {
  required String name,
  required Future<T> Function(void Function(int received, int total) onProgress)
      run,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final progress = ValueNotifier<DownloadProgress>(const DownloadProgress(0, -1));
  messenger?.showSnackBar(
    SnackBar(
      duration: const Duration(hours: 1),
      content: ValueListenableBuilder<DownloadProgress>(
        valueListenable: progress,
        builder: (context, value, _) =>
            DownloadProgressView(name: name, progress: value),
      ),
    ),
  );
  try {
    return await run(
      (received, total) => progress.value = DownloadProgress(received, total),
    );
  } finally {
    messenger?.hideCurrentSnackBar();
  }
}

/// Nội dung SnackBar tiến trình: tên file, thanh tiến trình và phần trăm kèm dung lượng
class DownloadProgressView extends StatelessWidget {
  const DownloadProgressView({
    super.key,
    required this.name,
    required this.progress,
  });

  final String name;
  final DownloadProgress progress;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final fraction = progress.fraction;
    final percent = fraction == null ? null : (fraction * 100).round();
    final sizeText = progress.total > 0
        ? '${formatDownloadSize(progress.received)} / ${formatDownloadSize(progress.total)}'
        : 'Đang chuẩn bị…';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Đang tải $name',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: textTheme.bodyMedium,
        ),
        const SizedBox(height: 8),
        LinearProgressIndicator(value: fraction),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: Text(
                sizeText,
                style: textTheme.labelSmall,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text(
              percent == null ? '' : '$percent%',
              style: textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ],
    );
  }
}

/// Dung lượng gọn cho hiển thị (B / KB / MB / GB)
String formatDownloadSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}
