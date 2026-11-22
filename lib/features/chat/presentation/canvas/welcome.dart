part of '../chat_canvas_view.dart';

extension _CanvasExtWelcome on _ChatCanvasViewState {
  Widget _buildEmptyAntigravityWelcome(BuildContext context, bool isMobile) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final projectName =
        widget.selectedProject?.name ??
        widget.session?.projectName ??
        'Chưa chọn project';

    final quickStarters = [
      (
        icon: Icons.call_split_rounded,
        label: '/erp-parallel-sync',
        desc: 'Đồng bộ tính năng song song giữa muop-erp-server & muop-erp-app',
        prompt: '/erp-parallel-sync Kiểm tra và đồng bộ tính năng giữa muop-erp-server và muop-erp-app',
      ),
      (
        icon: Icons.terminal_rounded,
        label: 'Kiểm tra Build & Analyze',
        desc: 'Chạy kiểm tra biên dịch và phân tích mã nguồn trong project',
        prompt: 'Chạy kiểm tra biên dịch và phân tích tĩnh trong project hiện tại, báo cáo ngắn gọn.',
      ),
      (
        icon: Icons.folder_open_rounded,
        label: 'Khảo sát cấu trúc Project',
        desc: 'Tóm tắt kiến trúc và các module chính trong $projectName',
        prompt:
            'Tóm tắt cấu trúc thư mục và các module chính trong project $projectName.',
      ),
    ];

    return Center(
      child: SingleChildScrollView(
        padding: EdgeInsets.all(isMobile ? 16 : 32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest.withAlpha(180),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: colorScheme.outlineVariant.withAlpha(120),
                  ),
                ),
                padding: const EdgeInsets.all(6),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.asset(
                    'assets/images/logo.png',
                    width: 44,
                    height: 44,
                    fit: BoxFit.contain,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Antigravity — $projectName',
                textAlign: TextAlign.center,
                style: textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  fontSize: isMobile ? 18 : 21,
                  color: colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Trò chuyện với Agent, theo dõi Task Running, % Quota Tuần/Giờ và duyệt tệp SFTP.',
                textAlign: TextAlign.center,
                style: textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 20),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                alignment: WrapAlignment.center,
                children: [
                  for (final item in quickStarters)
                    InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () {
                        _promptController.text = item.prompt;
                        _promptController
                            .selection = TextSelection.fromPosition(
                          TextPosition(offset: _promptController.text.length),
                        );
                        _inputFocusNode.requestFocus();
                      },
                      child: Container(
                        width: isMobile ? double.infinity : 200,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: colorScheme.surfaceContainer,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: colorScheme.outlineVariant),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  item.icon,
                                  size: 16,
                                  color: colorScheme.primary,
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    item.label,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: textTheme.labelMedium?.copyWith(
                                      fontWeight: FontWeight.w700,
                                      color: colorScheme.onSurface,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              item.desc,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: textTheme.labelSmall?.copyWith(
                                color: colorScheme.onSurfaceVariant,
                                height: 1.35,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
