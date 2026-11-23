import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:muop_agent/core/storage/local_config_store.dart';
import 'package:muop_agent/core/theme/chat_theme.dart';

/// Trạng thái giao diện chat (6 bộ theme/hình nền, tùy chỉnh widget User/AI và Dark/Light) dùng chung toàn app.
final chatThemeProvider = NotifierProvider<ChatThemeNotifier, ChatThemeConfig>(
  ChatThemeNotifier.new,
);

class ChatThemeNotifier extends Notifier<ChatThemeConfig> {
  static const String _fileName = 'muop_agent_theme_config.json';

  @override
  ChatThemeConfig build() => ChatThemeConfig.defaults;

  /// Nạp cấu hình giao diện đã lưu bền vững trước khi dựng app.
  static Future<ChatThemeConfig> loadSavedConfig() async {
    final decoded = await LocalConfigStore.readJson(_fileName);
    if (decoded.isEmpty) return ChatThemeConfig.defaults;
    return ChatThemeConfig.fromJson(decoded);
  }

  void hydrate(ChatThemeConfig config) {
    if (config != state) state = config;
  }

  /// Chọn nhanh một trong 6 bộ theme hoàn chỉnh (cập nhật đồng bộ nền, widget User, widget AI và màu nhấn).
  void selectPreset(String presetId) {
    final next = state.copyWith(
      presetId: presetId,
      clearWallpaper: true,
      clearUserBubble: true,
      clearAiBubble: true,
    );
    _update(next);
  }

  void setWallpaper(String? wallpaperId) {
    final next = wallpaperId == null
        ? state.copyWith(clearWallpaper: true)
        : state.copyWith(customWallpaperId: wallpaperId);
    _update(next);
  }

  void setUserBubble(String? userBubbleId) {
    final next = userBubbleId == null
        ? state.copyWith(clearUserBubble: true)
        : state.copyWith(customUserBubbleId: userBubbleId);
    _update(next);
  }

  void setAiBubble(String? aiBubbleId) {
    final next = aiBubbleId == null
        ? state.copyWith(clearAiBubble: true)
        : state.copyWith(customAiBubbleId: aiBubbleId);
    _update(next);
  }

  void toggleBrightness() => _update(state.copyWith(isDark: !state.isDark));

  void setDarkMode(bool isDark) => _update(state.copyWith(isDark: isDark));

  void _update(ChatThemeConfig next) {
    if (next == state) return;
    state = next;
    _persist(next);
  }

  Future<void> _persist(ChatThemeConfig config) async {
    await LocalConfigStore.writeJson(_fileName, config.toJson());
  }
}
