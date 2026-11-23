import 'package:material_ui/material_ui.dart';

/// 6 kiểu hoa văn nền chat kiểu Telegram, tự động thích ứng Sáng / Tối.
enum ChatWallpaperPattern {
  telegramClassic,
  geometricCrystal,
  mathLab,
  sakuraBlossom,
  auroraDream,
  retroArcade,
}

/// Cấu hình giao diện chat do người dùng chọn (gồm preset tổng thể và tùy chỉnh từng phần).
@immutable
class ChatThemeConfig {
  const ChatThemeConfig({
    this.presetId = 'ocean_slate',
    this.customWallpaperId,
    this.customUserBubbleId,
    this.customAiBubbleId,
    this.isDark = true,
  });

  static const ChatThemeConfig defaults = ChatThemeConfig();

  final String presetId;
  final String? customWallpaperId;
  final String? customUserBubbleId;
  final String? customAiBubbleId;
  final bool isDark;

  String get effectiveWallpaperId => customWallpaperId ?? preset.wallpaper.id;
  String get effectiveUserBubbleId => customUserBubbleId ?? preset.userBubble.id;
  String get effectiveAiBubbleId => customAiBubbleId ?? preset.aiBubble.id;

  ChatThemePreset get preset =>
      kChatThemePresets.firstWhere(
        (p) => p.id == presetId,
        orElse: () => kChatThemePresets.first,
      );

  ChatThemeConfig copyWith({
    String? presetId,
    String? customWallpaperId,
    bool clearWallpaper = false,
    String? customUserBubbleId,
    bool clearUserBubble = false,
    String? customAiBubbleId,
    bool clearAiBubble = false,
    bool? isDark,
  }) {
    return ChatThemeConfig(
      presetId: presetId ?? this.presetId,
      customWallpaperId: clearWallpaper
          ? null
          : (customWallpaperId ?? this.customWallpaperId),
      customUserBubbleId: clearUserBubble
          ? null
          : (customUserBubbleId ?? this.customUserBubbleId),
      customAiBubbleId: clearAiBubble
          ? null
          : (customAiBubbleId ?? this.customAiBubbleId),
      isDark: isDark ?? this.isDark,
    );
  }

  Map<String, dynamic> toJson() => {
    'presetId': presetId,
    'customWallpaperId': customWallpaperId,
    'customUserBubbleId': customUserBubbleId,
    'customAiBubbleId': customAiBubbleId,
    'isDark': isDark,
  };

  factory ChatThemeConfig.fromJson(Map<String, dynamic> json) {
    String? optStr(String key) {
      final raw = json[key];
      if (raw is String && raw.trim().isNotEmpty) return raw.trim();
      return null;
    }

    return ChatThemeConfig(
      presetId: optStr('presetId') ?? defaults.presetId,
      customWallpaperId: optStr('customWallpaperId'),
      customUserBubbleId: optStr('customUserBubbleId'),
      customAiBubbleId: optStr('customAiBubbleId'),
      isDark: json['isDark'] is bool ? json['isDark'] as bool : true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ChatThemeConfig &&
      other.presetId == presetId &&
      other.customWallpaperId == customWallpaperId &&
      other.customUserBubbleId == customUserBubbleId &&
      other.customAiBubbleId == customAiBubbleId &&
      other.isDark == isDark;

  @override
  int get hashCode => Object.hash(
    presetId,
    customWallpaperId,
    customUserBubbleId,
    customAiBubbleId,
    isDark,
  );
}

@immutable
class WallpaperStylePreset {
  const WallpaperStylePreset({
    required this.id,
    required this.name,
    required this.pattern,
    required this.darkGradient,
    required this.darkStroke,
    required this.lightGradient,
    required this.lightStroke,
  });

  final String id;
  final String name;
  final ChatWallpaperPattern pattern;
  final List<Color> darkGradient;
  final Color darkStroke;
  final List<Color> lightGradient;
  final Color lightStroke;
}

@immutable
class UserBubbleStylePreset {
  const UserBubbleStylePreset({
    required this.id,
    required this.name,
    required this.darkGradient,
    required this.darkBorder,
    required this.darkText,
    required this.darkLink,
    required this.lightGradient,
    required this.lightBorder,
    required this.lightText,
    required this.lightLink,
  });

  final String id;
  final String name;
  final List<Color> darkGradient;
  final Color darkBorder;
  final Color darkText;
  final Color darkLink;
  final List<Color> lightGradient;
  final Color lightBorder;
  final Color lightText;
  final Color lightLink;
}

@immutable
class AiBubbleStylePreset {
  const AiBubbleStylePreset({
    required this.id,
    required this.name,
    required this.darkBackground,
    required this.darkBorder,
    required this.darkText,
    required this.darkMutedText,
    required this.lightBackground,
    required this.lightBorder,
    required this.lightText,
    required this.lightMutedText,
  });

  final String id;
  final String name;
  final Color darkBackground;
  final Color darkBorder;
  final Color darkText;
  final Color darkMutedText;
  final Color lightBackground;
  final Color lightBorder;
  final Color lightText;
  final Color lightMutedText;
}

@immutable
class ChatThemePreset {
  const ChatThemePreset({
    required this.id,
    required this.name,
    required this.icon,
    required this.badgeColor,
    required this.accentDark,
    required this.accentLight,
    required this.wallpaper,
    required this.userBubble,
    required this.aiBubble,
  });

  final String id;
  final String name;
  final IconData icon;
  final Color badgeColor;
  final Color accentDark;
  final Color accentLight;
  final WallpaperStylePreset wallpaper;
  final UserBubbleStylePreset userBubble;
  final AiBubbleStylePreset aiBubble;
}

/// Bảng màu đã giải quyết cho [ThemeData.extensions] để mọi widget user, AI và nền đọc thống nhất.
@immutable
class ChatAppearanceColors extends ThemeExtension<ChatAppearanceColors> {
  const ChatAppearanceColors({
    required this.pattern,
    required this.wallpaperGradient,
    required this.wallpaperStroke,
    required this.userBubbleGradient,
    required this.userBubbleBorder,
    required this.userBubbleText,
    required this.userBubbleLink,
    required this.aiBubbleBackground,
    required this.aiBubbleBorder,
    required this.aiBubbleText,
    required this.aiBubbleMutedText,
  });

  final ChatWallpaperPattern pattern;
  final List<Color> wallpaperGradient;
  final Color wallpaperStroke;
  final List<Color> userBubbleGradient;
  final Color userBubbleBorder;
  final Color userBubbleText;
  final Color userBubbleLink;
  final Color aiBubbleBackground;
  final Color aiBubbleBorder;
  final Color aiBubbleText;
  final Color aiBubbleMutedText;

  static ChatAppearanceColors resolve(
    ChatThemeConfig config,
    Brightness brightness,
  ) {
    final isDark = brightness == Brightness.dark;
    final preset = config.preset;

    final wallpaper = kWallpaperPresets.firstWhere(
      (w) => w.id == config.effectiveWallpaperId,
      orElse: () => preset.wallpaper,
    );
    final userStyle = kUserBubblePresets.firstWhere(
      (u) => u.id == config.effectiveUserBubbleId,
      orElse: () => preset.userBubble,
    );
    final aiStyle = kAiBubblePresets.firstWhere(
      (a) => a.id == config.effectiveAiBubbleId,
      orElse: () => preset.aiBubble,
    );

    return ChatAppearanceColors(
      pattern: wallpaper.pattern,
      wallpaperGradient: isDark ? wallpaper.darkGradient : wallpaper.lightGradient,
      wallpaperStroke: isDark ? wallpaper.darkStroke : wallpaper.lightStroke,
      userBubbleGradient: isDark
          ? userStyle.darkGradient
          : userStyle.lightGradient,
      userBubbleBorder: isDark ? userStyle.darkBorder : userStyle.lightBorder,
      userBubbleText: isDark ? userStyle.darkText : userStyle.lightText,
      userBubbleLink: isDark ? userStyle.darkLink : userStyle.lightLink,
      aiBubbleBackground: isDark
          ? aiStyle.darkBackground
          : aiStyle.lightBackground,
      aiBubbleBorder: isDark ? aiStyle.darkBorder : aiStyle.lightBorder,
      aiBubbleText: isDark ? aiStyle.darkText : aiStyle.lightText,
      aiBubbleMutedText: isDark
          ? aiStyle.darkMutedText
          : aiStyle.lightMutedText,
    );
  }

  @override
  ChatAppearanceColors copyWith({
    ChatWallpaperPattern? pattern,
    List<Color>? wallpaperGradient,
    Color? wallpaperStroke,
    List<Color>? userBubbleGradient,
    Color? userBubbleBorder,
    Color? userBubbleText,
    Color? userBubbleLink,
    Color? aiBubbleBackground,
    Color? aiBubbleBorder,
    Color? aiBubbleText,
    Color? aiBubbleMutedText,
  }) {
    return ChatAppearanceColors(
      pattern: pattern ?? this.pattern,
      wallpaperGradient: wallpaperGradient ?? this.wallpaperGradient,
      wallpaperStroke: wallpaperStroke ?? this.wallpaperStroke,
      userBubbleGradient: userBubbleGradient ?? this.userBubbleGradient,
      userBubbleBorder: userBubbleBorder ?? this.userBubbleBorder,
      userBubbleText: userBubbleText ?? this.userBubbleText,
      userBubbleLink: userBubbleLink ?? this.userBubbleLink,
      aiBubbleBackground: aiBubbleBackground ?? this.aiBubbleBackground,
      aiBubbleBorder: aiBubbleBorder ?? this.aiBubbleBorder,
      aiBubbleText: aiBubbleText ?? this.aiBubbleText,
      aiBubbleMutedText: aiBubbleMutedText ?? this.aiBubbleMutedText,
    );
  }

  @override
  ChatAppearanceColors lerp(
    ThemeExtension<ChatAppearanceColors>? other,
    double t,
  ) {
    if (other is! ChatAppearanceColors) return this;
    List<Color> lerpColors(List<Color> a, List<Color> b) {
      final len = a.length < b.length ? a.length : b.length;
      return [for (var i = 0; i < len; i++) Color.lerp(a[i], b[i], t)!];
    }

    return ChatAppearanceColors(
      pattern: t < 0.5 ? pattern : other.pattern,
      wallpaperGradient: lerpColors(wallpaperGradient, other.wallpaperGradient),
      wallpaperStroke: Color.lerp(wallpaperStroke, other.wallpaperStroke, t)!,
      userBubbleGradient: lerpColors(
        userBubbleGradient,
        other.userBubbleGradient,
      ),
      userBubbleBorder: Color.lerp(
        userBubbleBorder,
        other.userBubbleBorder,
        t,
      )!,
      userBubbleText: Color.lerp(userBubbleText, other.userBubbleText, t)!,
      userBubbleLink: Color.lerp(userBubbleLink, other.userBubbleLink, t)!,
      aiBubbleBackground: Color.lerp(
        aiBubbleBackground,
        other.aiBubbleBackground,
        t,
      )!,
      aiBubbleBorder: Color.lerp(aiBubbleBorder, other.aiBubbleBorder, t)!,
      aiBubbleText: Color.lerp(aiBubbleText, other.aiBubbleText, t)!,
      aiBubbleMutedText: Color.lerp(
        aiBubbleMutedText,
        other.aiBubbleMutedText,
        t,
      )!,
    );
  }
}

/// 6 bộ theme hoàn chỉnh theo phong cách Telegram Browse Themes (cả Dark lẫn Light).
const List<ChatThemePreset> kChatThemePresets = [
  ChatThemePreset(
    id: 'ocean_slate',
    name: 'Slate Chuẩn',
    icon: Icons.home_rounded,
    badgeColor: Color(0xFF4C8DFF),
    accentDark: Color(0xFF4C8DFF),
    accentLight: Color(0xFF1F6FEB),
    wallpaper: WallpaperStylePreset(
      id: 'ocean_slate',
      name: 'Telegram',
      pattern: ChatWallpaperPattern.telegramClassic,
      darkGradient: [
        Color(0xFF121A24),
        Color(0xFF1A2533),
        Color(0xFF15202C),
        Color(0xFF101720),
      ],
      darkStroke: Color(0x139DB8D4),
      lightGradient: [
        Color(0xFFD5E2EE),
        Color(0xFFE5EEF7),
        Color(0xFFDCE7F2),
        Color(0xFFCFDCE9),
      ],
      lightStroke: Color(0x132B4662),
    ),
    userBubble: UserBubbleStylePreset(
      id: 'ocean_blue',
      name: 'Xanh Dương',
      darkGradient: [Color(0xFF214E80), Color(0xFF2A67A6)],
      darkBorder: Color(0x4D7BB2FF),
      darkText: Color(0xFFF3F7FF),
      darkLink: Color(0xFFA8D0FF),
      lightGradient: [Color(0xFF2574D9), Color(0xFF398DF0)],
      lightBorder: Color(0x401D5FB5),
      lightText: Color(0xFFFFFFFF),
      lightLink: Color(0xFFE0EDFF),
    ),
    aiBubble: AiBubbleStylePreset(
      id: 'slate_ai',
      name: 'Slate',
      darkBackground: Color(0xFF18202A),
      darkBorder: Color(0x1FFFFFFF),
      darkText: Color(0xFFF0F2F5),
      darkMutedText: Color(0xFFA1A8B6),
      lightBackground: Color(0xFFF4F7FB),
      lightBorder: Color(0x14000000),
      lightText: Color(0xFF141A24),
      lightMutedText: Color(0xFF566273),
    ),
  ),
  ChatThemePreset(
    id: 'lagoon_diamond',
    name: 'Ngọc Lam',
    icon: Icons.diamond_rounded,
    badgeColor: Color(0xFF3FD2E6),
    accentDark: Color(0xFF45D0E6),
    accentLight: Color(0xFF0E8296),
    wallpaper: WallpaperStylePreset(
      id: 'lagoon_diamond',
      name: 'Hình Học',
      pattern: ChatWallpaperPattern.geometricCrystal,
      darkGradient: [
        Color(0xFF0C1A1D),
        Color(0xFF12272B),
        Color(0xFF0F2024),
        Color(0xFF0A1417),
      ],
      darkStroke: Color(0x155ED2E3),
      lightGradient: [
        Color(0xFFD2ECEF),
        Color(0xFFE4F5F7),
        Color(0xFFD9EFF2),
        Color(0xFFC5E3E7),
      ],
      lightStroke: Color(0x14135B66),
    ),
    userBubble: UserBubbleStylePreset(
      id: 'aqua_teal',
      name: 'Ngọc Lam',
      darkGradient: [Color(0xFF1B6473), Color(0xFF258496)],
      darkBorder: Color(0x525CE1F5),
      darkText: Color(0xFFF1FDFF),
      darkLink: Color(0xFF9DF2FF),
      lightGradient: [Color(0xFF148296), Color(0xFF20A0B5)],
      lightBorder: Color(0x40106B7D),
      lightText: Color(0xFFFFFFFF),
      lightLink: Color(0xFFD7FBFF),
    ),
    aiBubble: AiBubbleStylePreset(
      id: 'lagoon_ai',
      name: 'Ngọc Tối',
      darkBackground: Color(0xFF122024),
      darkBorder: Color(0x2469DCEB),
      darkText: Color(0xFFECF7F9),
      darkMutedText: Color(0xFF95B3B8),
      lightBackground: Color(0xFFF2FAFB),
      lightBorder: Color(0x1A135B66),
      lightText: Color(0xFF112124),
      lightMutedText: Color(0xFF4D6C72),
    ),
  ),
  ChatThemePreset(
    id: 'math_emerald',
    name: 'Bảng Toán',
    icon: Icons.functions_rounded,
    badgeColor: Color(0xFF5AD497),
    accentDark: Color(0xFF5AD497),
    accentLight: Color(0xFF1C7D53),
    wallpaper: WallpaperStylePreset(
      id: 'math_emerald',
      name: 'Toán Học',
      pattern: ChatWallpaperPattern.mathLab,
      darkGradient: [
        Color(0xFF0D1914),
        Color(0xFF14261E),
        Color(0xFF101F18),
        Color(0xFF0A140F),
      ],
      darkStroke: Color(0x157ED8A7),
      lightGradient: [
        Color(0xFFD8E9DF),
        Color(0xFFE8F3EC),
        Color(0xFFDFEDE4),
        Color(0xFFCBE0D3),
      ],
      lightStroke: Color(0x141D593A),
    ),
    userBubble: UserBubbleStylePreset(
      id: 'forest_emerald',
      name: 'Rừng Xanh',
      darkGradient: [Color(0xFF225B47), Color(0xFF2E775D)],
      darkBorder: Color(0x4D72DBA9),
      darkText: Color(0xFFF1FFF8),
      darkLink: Color(0xFF9EF5CC),
      lightGradient: [Color(0xFF1F7A57), Color(0xFF2C966E)],
      lightBorder: Color(0x40186245),
      lightText: Color(0xFFFFFFFF),
      lightLink: Color(0xFFDBFFED),
    ),
    aiBubble: AiBubbleStylePreset(
      id: 'emerald_ai',
      name: 'Rừng Sâu',
      darkBackground: Color(0xFF131F19),
      darkBorder: Color(0x2474D4A2),
      darkText: Color(0xFFEDF7F1),
      darkMutedText: Color(0xFF97B3A3),
      lightBackground: Color(0xFFF4FAF6),
      lightBorder: Color(0x1A1D593A),
      lightText: Color(0xFF122119),
      lightMutedText: Color(0xFF4D6B59),
    ),
  ),
  ChatThemePreset(
    id: 'crystal_rose',
    name: 'Anh Đào',
    icon: Icons.local_florist_rounded,
    badgeColor: Color(0xFFF07EB0),
    accentDark: Color(0xFFF07EB0),
    accentLight: Color(0xFFB03D70),
    wallpaper: WallpaperStylePreset(
      id: 'crystal_rose',
      name: 'Hoa & Tinh Thể',
      pattern: ChatWallpaperPattern.sakuraBlossom,
      darkGradient: [
        Color(0xFF19101C),
        Color(0xFF26172A),
        Color(0xFF1E1322),
        Color(0xFF130C15),
      ],
      darkStroke: Color(0x15E694B8),
      lightGradient: [
        Color(0xFFF2DCE6),
        Color(0xFFF9ECF2),
        Color(0xFFF4E2EA),
        Color(0xFFE8CCD9),
      ],
      lightStroke: Color(0x147A2F52),
    ),
    userBubble: UserBubbleStylePreset(
      id: 'sakura_rose',
      name: 'Hồng Đào',
      darkGradient: [Color(0xFF7B3858), Color(0xFF9E4B70)],
      darkBorder: Color(0x52F299BE),
      darkText: Color(0xFFFFF4F9),
      darkLink: Color(0xFFFFC2DC),
      lightGradient: [Color(0xFFA84370), Color(0xFFC45686)],
      lightBorder: Color(0x408C345C),
      lightText: Color(0xFFFFFFFF),
      lightLink: Color(0xFFFFE2EF),
    ),
    aiBubble: AiBubbleStylePreset(
      id: 'rose_ai',
      name: 'Mận Tối',
      darkBackground: Color(0xFF201623),
      darkBorder: Color(0x24E68FB4),
      darkText: Color(0xFFF9EFF4),
      darkMutedText: Color(0xFFBC9FB0),
      lightBackground: Color(0xFFFCF6F9),
      lightBorder: Color(0x1A7A2F52),
      lightText: Color(0xFF26141D),
      lightMutedText: Color(0xFF754F61),
    ),
  ),
  ChatThemePreset(
    id: 'violet_dusk',
    name: 'Tím Đêm',
    icon: Icons.favorite_rounded,
    badgeColor: Color(0xFFA68BFF),
    accentDark: Color(0xFFA68BFF),
    accentLight: Color(0xFF6244C4),
    wallpaper: WallpaperStylePreset(
      id: 'violet_dusk',
      name: 'Cực Quang',
      pattern: ChatWallpaperPattern.auroraDream,
      darkGradient: [
        Color(0xFF121023),
        Color(0xFF1C1836),
        Color(0xFF16132B),
        Color(0xFF0E0C1C),
      ],
      darkStroke: Color(0x15A98FFF),
      lightGradient: [
        Color(0xFFE1DCF5),
        Color(0xFFEFEBFB),
        Color(0xFFE5E0F7),
        Color(0xFFD3CCF0),
      ],
      lightStroke: Color(0x144A3594),
    ),
    userBubble: UserBubbleStylePreset(
      id: 'royal_violet',
      name: 'Tím Indigo',
      darkGradient: [Color(0xFF513CA3), Color(0xFF724CC2)],
      darkBorder: Color(0x52B399FF),
      darkText: Color(0xFFF7F4FF),
      darkLink: Color(0xFFD2C4FF),
      lightGradient: [Color(0xFF6346C4), Color(0xFF815CE0)],
      lightBorder: Color(0x404E36A6),
      lightText: Color(0xFFFFFFFF),
      lightLink: Color(0xFFEAE3FF),
    ),
    aiBubble: AiBubbleStylePreset(
      id: 'violet_ai',
      name: 'Chàm Đêm',
      darkBackground: Color(0xFF18162A),
      darkBorder: Color(0x24A88FFF),
      darkText: Color(0xFFF2F0FA),
      darkMutedText: Color(0xFFA5A0C4),
      lightBackground: Color(0xFFF8F6FE),
      lightBorder: Color(0x1A4A3594),
      lightText: Color(0xFF181529),
      lightMutedText: Color(0xFF5D5682),
    ),
  ),
  ChatThemePreset(
    id: 'retro_sunset',
    name: 'Arcade',
    icon: Icons.sports_esports_rounded,
    badgeColor: Color(0xFFFF8F5E),
    accentDark: Color(0xFFFF8F5E),
    accentLight: Color(0xFFC9523B),
    wallpaper: WallpaperStylePreset(
      id: 'retro_sunset',
      name: 'Retro Arcade',
      pattern: ChatWallpaperPattern.retroArcade,
      darkGradient: [
        Color(0xFF131622),
        Color(0xFF1E2030),
        Color(0xFF181A28),
        Color(0xFF0F121B),
      ],
      darkStroke: Color(0x156BB8FF),
      lightGradient: [
        Color(0xFFF5E2D7),
        Color(0xFFFBF0E9),
        Color(0xFFF6E6DC),
        Color(0xFFEBD3C5),
      ],
      lightStroke: Color(0x147C442E),
    ),
    userBubble: UserBubbleStylePreset(
      id: 'sunset_ember',
      name: 'Hoàng Hôn',
      darkGradient: [Color(0xFF9E4260), Color(0xFFC46638)],
      darkBorder: Color(0x52FFA477),
      darkText: Color(0xFFFFF7F2),
      darkLink: Color(0xFFFFD3BD),
      lightGradient: [Color(0xFFC74E52), Color(0xFFDF763A)],
      lightBorder: Color(0x40A63A3E),
      lightText: Color(0xFFFFFFFF),
      lightLink: Color(0xFFFFE9DD),
    ),
    aiBubble: AiBubbleStylePreset(
      id: 'arcade_ai',
      name: 'Carbon Ấm',
      darkBackground: Color(0xFF1B1D29),
      darkBorder: Color(0x24FF9E6D),
      darkText: Color(0xFFF7F3F0),
      darkMutedText: Color(0xFFB8ABA4),
      lightBackground: Color(0xFFFFF8F4),
      lightBorder: Color(0x1A7C442E),
      lightText: Color(0xFF241914),
      lightMutedText: Color(0xFF785C4F),
    ),
  ),
];

/// Danh sách 6 kiểu hình nền trích từ 6 preset để chọn độc lập.
final List<WallpaperStylePreset> kWallpaperPresets = [
  for (final p in kChatThemePresets) p.wallpaper,
];

/// Danh sách màu widget User (6 màu của preset + tùy chọn trung tính).
final List<UserBubbleStylePreset> kUserBubblePresets = [
  for (final p in kChatThemePresets) p.userBubble,
  const UserBubbleStylePreset(
    id: 'graphite_neutral',
    name: 'Than Chì',
    darkGradient: [Color(0xFF252A36), Color(0xFF2D3342)],
    darkBorder: Color(0x26FFFFFF),
    darkText: Color(0xFFF0F2F5),
    darkLink: Color(0xFF88B4FF),
    lightGradient: [Color(0xFFE6EBF3), Color(0xFFDCE4EF)],
    lightBorder: Color(0x1A000000),
    lightText: Color(0xFF151B24),
    lightLink: Color(0xFF1F6FEB),
  ),
];

/// Danh sách màu widget AI phản hồi (6 tông của preset + tùy chọn trung tính).
final List<AiBubbleStylePreset> kAiBubblePresets = [
  for (final p in kChatThemePresets) p.aiBubble,
  const AiBubbleStylePreset(
    id: 'pure_neutral',
    name: 'Trung Tính',
    darkBackground: Color(0xFF1A1C23),
    darkBorder: Color(0x1AFFFFFF),
    darkText: Color(0xFFF0F2F5),
    darkMutedText: Color(0xFFA1A8B6),
    lightBackground: Color(0xFFF7F8FA),
    lightBorder: Color(0x14000000),
    lightText: Color(0xFF14171D),
    lightMutedText: Color(0xFF5E6673),
  ),
];
