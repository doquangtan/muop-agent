part of '../chat_canvas_view.dart';

/// Nền gradient + hoa văn doodle kiểu Telegram đọc trực tiếp từ [ChatAppearanceColors],
/// tái sử dụng [ChatWallpaperSurface] cô lập bằng [RepaintBoundary].
class _TelegramChatWallpaper extends StatelessWidget {
  const _TelegramChatWallpaper();

  @override
  Widget build(BuildContext context) {
    return ChatWallpaperSurface(
      key: const Key('chat-telegram-wallpaper'),
      highContrast: MediaQuery.highContrastOf(context),
    );
  }
}
