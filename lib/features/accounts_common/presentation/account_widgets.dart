import 'package:material_ui/material_ui.dart';

import 'package:muop_agent/core/theme/app_theme.dart';

/// Thẻ trạng thái tài khoản dùng chung cho agy và Claude Code CLI (cùng một widget, cùng bố cục).
/// [description] là dòng mô tả dưới email; [badge] là nhãn gói (ví dụ "PRO"), rỗng thì không hiện.
class AccountStatusCard extends StatelessWidget {
  const AccountStatusCard({
    super.key,
    required this.loggedIn,
    required this.description,
    this.email = '',
    this.badge = '',
  });

  final bool loggedIn;
  final String description;
  final String email;
  final String badge;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final status = context.status;
    final textTheme = Theme.of(context).textTheme;
    final color = loggedIn ? status.success : status.warning;

    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(
                loggedIn
                    ? Icons.verified_user_rounded
                    : Icons.lock_open_rounded,
                color: color,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        loggedIn ? 'Đã đăng nhập' : 'Chưa đăng nhập',
                        style: textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: color,
                        ),
                      ),
                      if (loggedIn && badge.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: scheme.primaryContainer,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            badge.toUpperCase(),
                            style: textTheme.labelSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: scheme.onPrimaryContainer,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (loggedIn && email.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      email,
                      style: textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurface,
                      ),
                    ),
                  ],
                  const SizedBox(height: 4),
                  Text(
                    description,
                    style: textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Nút đăng xuất dùng chung (nút viền, màu lỗi); đang bận thì hiện vòng quay và khóa nút
class AccountLogoutButton extends StatelessWidget {
  const AccountLogoutButton({
    super.key,
    required this.busy,
    required this.onLogout,
  });

  final bool busy;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return Align(
      alignment: Alignment.centerLeft,
      child: OutlinedButton.icon(
        style: OutlinedButton.styleFrom(foregroundColor: scheme.error),
        onPressed: busy ? null : onLogout,
        icon: busy
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.logout_rounded),
        label: const Text('Đăng xuất'),
      ),
    );
  }
}
