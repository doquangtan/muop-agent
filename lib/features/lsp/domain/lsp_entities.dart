
/// Vùng gấp code (0-based) lấy từ LSP
class CodeFoldRange {
  const CodeFoldRange({
    required this.startLine,
    required this.endLine,
    required this.kind,
  });

  final int startLine;
  final int endLine;
  final String kind;

  factory CodeFoldRange.fromJson(Map<String, dynamic> json) => CodeFoldRange(
        startLine: (json['startLine'] as num?)?.toInt() ?? 0,
        endLine: (json['endLine'] as num?)?.toInt() ?? 0,
        kind: '${json['kind'] ?? ''}',
      );
}

/// Ký hiệu trong tệp (hàm, class, method...), 0-based
class CodeSymbol {
  const CodeSymbol({
    required this.name,
    required this.kindLabel,
    required this.line,
    required this.endLine,
    required this.depth,
  });

  final String name;
  final String kindLabel;
  final int line;
  final int endLine;
  final int depth;

  factory CodeSymbol.fromJson(Map<String, dynamic> json) => CodeSymbol(
        name: '${json['name'] ?? ''}',
        kindLabel: '${json['kindLabel'] ?? ''}',
        line: (json['line'] as num?)?.toInt() ?? 0,
        endLine: (json['endLine'] as num?)?.toInt() ?? 0,
        depth: (json['depth'] as num?)?.toInt() ?? 0,
      );
}

/// Vị trí định nghĩa (0-based dòng, cột UTF-16)
class CodeLocation {
  const CodeLocation({
    required this.path,
    required this.line,
    required this.character,
  });

  final String path;
  final int line;
  final int character;

  factory CodeLocation.fromJson(Map<String, dynamic> json) => CodeLocation(
        path: '${json['path'] ?? ''}',
        line: (json['line'] as num?)?.toInt() ?? 0,
        character: (json['character'] as num?)?.toInt() ?? 0,
      );
}

/// Kết quả gọi API code (gấp / ký hiệu / định nghĩa)
class CodeResult {
  const CodeResult({
    required this.ok,
    required this.error,
    required this.language,
    required this.folds,
    required this.symbols,
    required this.locations,
  });

  final bool ok;
  final String error;
  final String language;
  final List<CodeFoldRange> folds;
  final List<CodeSymbol> symbols;
  final List<CodeLocation> locations;

  factory CodeResult.failure(String error) => CodeResult(
        ok: false,
        error: error,
        language: '',
        folds: const [],
        symbols: const [],
        locations: const [],
      );

  factory CodeResult.fromJson(Map<String, dynamic> json) {
    List<T> list<T>(String key, T Function(Map<String, dynamic>) f) =>
        ((json[key] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => f(Map<String, dynamic>.from(e)))
            .toList();
    return CodeResult(
      ok: json['ok'] == true,
      error: '${json['error'] ?? ''}',
      language: '${json['language'] ?? ''}',
      folds: list('ranges', CodeFoldRange.fromJson),
      symbols: list('symbols', CodeSymbol.fromJson),
      locations: list('locations', CodeLocation.fromJson),
    );
  }
}

/// Trạng thái LSP của một ngôn ngữ (Go / Dart / Rust)
class LspLanguageStatus {
  const LspLanguageStatus({
    required this.language,
    required this.label,
    required this.configuredPath,
    required this.detectedPath,
    required this.effectivePath,
    required this.source,
    required this.available,
    required this.note,
  });

  final String language;
  final String label;
  /// Đường dẫn người dùng đã lưu (rỗng nếu không có)
  final String configuredPath;
  /// Đường dẫn tự dò được
  final String detectedPath;
  final String effectivePath;
  /// `config` | `auto` | `none`
  final String source;
  final bool available;
  final String note;

  factory LspLanguageStatus.fromJson(Map<String, dynamic> json) => LspLanguageStatus(
        language: '${json['language'] ?? ''}',
        label: '${json['label'] ?? ''}',
        configuredPath: '${json['configuredPath'] ?? ''}',
        detectedPath: '${json['detectedPath'] ?? ''}',
        effectivePath: '${json['effectivePath'] ?? ''}',
        source: '${json['source'] ?? 'none'}',
        available: json['available'] == true,
        note: '${json['note'] ?? ''}',
      );
}

/// Kết quả đọc/ghi cài đặt LSP
class LspSettingsResult {
  const LspSettingsResult({
    required this.ok,
    required this.error,
    required this.languages,
  });

  final bool ok;
  final String error;
  final List<LspLanguageStatus> languages;

  factory LspSettingsResult.failure(String error) =>
      LspSettingsResult(ok: false, error: error, languages: const []);

  factory LspSettingsResult.fromJson(Map<String, dynamic> json) => LspSettingsResult(
        ok: json['ok'] == true,
        error: '${json['error'] ?? ''}',
        languages: ((json['languages'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => LspLanguageStatus.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
      );
}

/// Token ngữ nghĩa của tệp để tô màu. `data` gồm bộ 4 số: [dòng, cột, độ dài, chỉ số trong `kinds`]
class CodeTokens {
  const CodeTokens({
    required this.ok,
    required this.error,
    required this.kinds,
    required this.data,
  });

  final bool ok;
  final String error;
  final List<String> kinds;
  final List<int> data;

  factory CodeTokens.fromJson(Map<String, dynamic> json) => CodeTokens(
        ok: json['ok'] == true,
        error: '${json['error'] ?? ''}',
        kinds: ((json['kinds'] as List?) ?? const []).map((e) => '$e').toList(),
        data: ((json['data'] as List?) ?? const [])
            .map((e) => (e as num).toInt())
            .toList(),
      );

  factory CodeTokens.failure(String error) =>
      CodeTokens(ok: false, error: error, kinds: const [], data: const []);
}

/// Nội dung hover (kiểu, tài liệu) của một ký hiệu
class CodeHoverResult {
  const CodeHoverResult({
    required this.ok,
    required this.error,
    required this.contents,
  });

  final bool ok;
  final String error;
  final String contents;

  factory CodeHoverResult.fromJson(Map<String, dynamic> json) => CodeHoverResult(
        ok: json['ok'] == true,
        error: '${json['error'] ?? ''}',
        contents: '${json['contents'] ?? ''}',
      );

  factory CodeHoverResult.failure(String error) =>
      CodeHoverResult(ok: false, error: error, contents: '');
}
