import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'package:muop_agent/core/theme/app_theme.dart';
import 'package:muop_agent/features/interactions/domain/interaction_entities.dart';

/// Mở bảng cấu hình tự gửi lại của một conversation.
/// [onSave] lưu cấu hình lên server; [pending] là lịch đang chờ (nếu có) để hiện nút hủy.
Future<void> showRetryConfigSheet({
  required BuildContext context,
  required ConversationRetryConfig initial,
  required Future<({bool ok, String message})> Function(
    ConversationRetryConfig config,
  )
  onSave,
  PendingRetry? pending,
  Future<void> Function()? onCancelPending,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheetContext) => RetryConfigSheet(
      initial: initial,
      onSave: onSave,
      pending: pending,
      onCancelPending: onCancelPending,
    ),
  );
}

/// Form cấu hình tự gửi lại: bật/tắt, chờ theo quota, khoảng chờ dự phòng, số lần, nội dung gửi lại.
class RetryConfigSheet extends StatefulWidget {
  const RetryConfigSheet({
    super.key,
    required this.initial,
    required this.onSave,
    this.pending,
    this.onCancelPending,
  });

  final ConversationRetryConfig initial;
  final Future<({bool ok, String message})> Function(
    ConversationRetryConfig config,
  )
  onSave;
  final PendingRetry? pending;
  final Future<void> Function()? onCancelPending;

  @override
  State<RetryConfigSheet> createState() => _RetryConfigSheetState();
}

class _RetryConfigSheetState extends State<RetryConfigSheet> {
  late bool _enabled;
  late bool _useQuotaReset;
  late final TextEditingController _intervalController;
  late final TextEditingController _attemptsController;
  late final TextEditingController _promptController;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final cfg = widget.initial;
    _enabled = cfg.enabled;
    _useQuotaReset = cfg.useQuotaReset;
    _intervalController = TextEditingController(text: '${cfg.intervalMinutes}');
    _attemptsController = TextEditingController(text: '${cfg.maxAttempts}');
    _promptController = TextEditingController(text: cfg.prompt);
  }

  @override
  void dispose() {
    _intervalController.dispose();
    _attemptsController.dispose();
    _promptController.dispose();
    super.dispose();
  }

  /// Kiểm tra và dựng cấu hình từ form. Trả về null nếu có lỗi (đã gán [_error]).
  ConversationRetryConfig? _buildConfig() {
    const limits = ConversationRetryConfig.maxAttemptsLimit;
    final interval = int.tryParse(_intervalController.text.trim());
    final attempts = int.tryParse(_attemptsController.text.trim());
    final prompt = _promptController.text.trim();
    if (interval == null ||
        interval < ConversationRetryConfig.intervalMinutesMin ||
        interval > ConversationRetryConfig.intervalMinutesMax) {
      _error =
          'Khoảng chờ phải từ ${ConversationRetryConfig.intervalMinutesMin} đến ${ConversationRetryConfig.intervalMinutesMax} phút';
      return null;
    }
    if (attempts == null || attempts < 0 || attempts > limits) {
      _error = 'Số lần gửi lại từ 0 đến $limits';
      return null;
    }
    if (prompt.length > ConversationRetryConfig.promptMaxChars) {
      _error =
          'Nội dung gửi lại tối đa ${ConversationRetryConfig.promptMaxChars} ký tự';
      return null;
    }
    return widget.initial.copyWith(
      enabled: _enabled,
      useQuotaReset: _useQuotaReset,
      intervalMinutes: interval,
      maxAttempts: attempts,
      prompt: prompt,
    );
  }

  Future<void> _save() async {
    final config = _buildConfig();
    if (config == null) {
      setState(() {});
      return;
    }
    setState(() {
      _error = null;
      _saving = true;
    });
    final result = await widget.onSave(config);
    if (!mounted) return;
    if (result.ok) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _saving = false;
      _error = result.message;
    });
  }

  Future<void> _cancelPending() async {
    final cancel = widget.onCancelPending;
    if (cancel == null) return;
    setState(() => _saving = true);
    await cancel();
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final textTheme = Theme.of(context).textTheme;
    final pending = widget.pending;
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    return Padding(
      padding: EdgeInsets.fromLTRB(16, 8, 16, 16 + bottomInset),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Tự gửi lại khi chạm giới hạn',
              style: textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Khi Claude hoặc agy báo hết quota, hệ thống gửi lại tin nhắn theo cấu hình này.',
              style: textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            if (pending != null) ...[
              const SizedBox(height: 10),
              _PendingSummary(pending: pending),
            ],
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Bật tự gửi lại'),
              value: _enabled,
              onChanged: _saving ? null : (v) => setState(() => _enabled = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Chờ đến khi quota reset'),
              subtitle: Text(
                'Gửi lại đúng lúc quota được cấp lại. Khi chưa có thời điểm reset, dùng khoảng chờ dự phòng.',
                style: textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              value: _useQuotaReset,
              onChanged: _saving
                  ? null
                  : (v) => setState(() => _useQuotaReset = v),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _intervalController,
                    enabled: !_saving,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: InputDecoration(
                      labelText: _useQuotaReset
                          ? 'Khoảng chờ dự phòng (phút)'
                          : 'Khoảng chờ (phút)',
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _attemptsController,
                    enabled: !_saving,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(
                      labelText: 'Số lần gửi lại tối đa',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _promptController,
              enabled: !_saving,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: 'Nội dung gửi lại',
                hintText: 'Để trống = gửi lại đúng tin nhắn đã gửi',
                border: OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: textTheme.bodySmall?.copyWith(color: scheme.error),
              ),
            ],
            const SizedBox(height: 14),
            Row(
              children: [
                if (pending != null && widget.onCancelPending != null)
                  TextButton(
                    onPressed: _saving ? null : _cancelPending,
                    child: Text(
                      'Hủy lượt đang chờ',
                      style: TextStyle(color: scheme.error),
                    ),
                  ),
                const Spacer(),
                TextButton(
                  onPressed: _saving ? null : () => Navigator.of(context).pop(),
                  child: const Text('Đóng'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _saving ? null : _save,
                  child: _saving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Lưu'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Tóm tắt lịch đang chờ hiện trong bảng cấu hình
class _PendingSummary extends StatelessWidget {
  const _PendingSummary({required this.pending});

  final PendingRetry pending;

  @override
  Widget build(BuildContext context) {
    final warning = context.status.warning;
    final textTheme = Theme.of(context).textTheme;
    final detail = pending.waitDetail.isEmpty
        ? 'Đang chờ gửi lại'
        : pending.waitDetail;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: warning.withAlpha(28),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: warning.withAlpha(140)),
      ),
      child: Text(
        'Lần ${pending.attempt}/${pending.maxAttempts} · $detail',
        style: textTheme.labelMedium?.copyWith(color: context.scheme.onSurface),
      ),
    );
  }
}
