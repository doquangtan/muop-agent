
class ServerFileEntry {
  const ServerFileEntry({
    required this.name,
    required this.path,
    required this.isDir,
    required this.size,
    required this.modifiedAt,
    this.permissions = '',
  });

  final String name;
  final String path;
  final bool isDir;
  final int size;
  final DateTime modifiedAt;
  final String permissions;

  String get formattedSize {
    if (isDir) return 'DIR';
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) {
      return '${(size / 1024).toStringAsFixed(1)} KB';
    }
    return '${(size / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  factory ServerFileEntry.fromJson(Map<String, dynamic> json) {
    return ServerFileEntry(
      name: '${json['name'] ?? ''}',
      path: '${json['path'] ?? ''}',
      isDir: json['isDir'] == true,
      size: (json['size'] as num?)?.toInt() ?? 0,
      modifiedAt:
          DateTime.tryParse('${json['modifiedAt'] ?? ''}') ?? DateTime.now(),
      permissions: '${json['permissions'] ?? (json['isDir'] == true ? 'drwxr-xr-x' : '-rw-r--r--')}',
    );
  }
}

/// Một đoạn dòng của file văn bản (`/api/files/lines`), dùng để xem file lớn theo từng phần
class ServerFileLinesResponse {
  const ServerFileLinesResponse({
    required this.ok,
    required this.path,
    required this.name,
    required this.size,
    required this.isBinary,
    required this.totalLines,
    required this.offset,
    required this.lines,
    required this.hasMore,
    required this.gitDiff,
    this.error = '',
  });

  final bool ok;
  final String path;
  final String name;
  final int size;
  final bool isBinary;
  final int totalLines;
  final int offset;
  final List<String> lines;
  final bool hasMore;
  final String gitDiff;
  final String error;

  factory ServerFileLinesResponse.fromJson(Map<String, dynamic> json) {
    final rawLines = json['lines'];
    return ServerFileLinesResponse(
      ok: json['ok'] == true,
      path: '${json['path'] ?? ''}',
      name: '${json['name'] ?? ''}',
      size: (json['size'] as num?)?.toInt() ?? 0,
      isBinary: json['isBinary'] == true,
      totalLines: (json['totalLines'] as num?)?.toInt() ?? 0,
      offset: (json['offset'] as num?)?.toInt() ?? 0,
      lines: rawLines is List ? rawLines.map((e) => '$e').toList() : const [],
      hasMore: json['hasMore'] == true,
      gitDiff: '${json['gitDiff'] ?? ''}',
      error: '${json['error'] ?? ''}',
    );
  }

  factory ServerFileLinesResponse.failure(String path, String error) {
    return ServerFileLinesResponse(
      ok: false,
      path: path,
      name: path.split('/').last,
      size: 0,
      isBinary: false,
      totalLines: 0,
      offset: 0,
      lines: const [],
      hasMore: false,
      gitDiff: '',
      error: error,
    );
  }
}

class ServerFileReadResponse {
  const ServerFileReadResponse({
    required this.ok,
    required this.path,
    required this.name,
    required this.size,
    required this.isBinary,
    this.isImage = false,
    required this.content,
    required this.gitDiff,
    this.error = '',
  });

  final bool ok;
  final String path;
  final String name;
  final int size;
  final bool isBinary;
  final bool isImage;
  final String content;
  final String gitDiff;
  final String error;

  bool get isMarkdown {
    final lower = (name.isNotEmpty ? name : path).toLowerCase();
    return lower.endsWith('.md') ||
        lower.endsWith('.markdown') ||
        lower.endsWith('.mdown') ||
        lower.endsWith('.plan');
  }

  bool get isImageFile {
    if (isImage) return true;
    final lower = (name.isNotEmpty ? name : path).toLowerCase();
    return lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.bmp') ||
        lower.endsWith('.ico') ||
        lower.endsWith('.svg');
  }

  factory ServerFileReadResponse.fromJson(Map<String, dynamic> json) {
    return ServerFileReadResponse(
      ok: json['ok'] == true,
      path: '${json['path'] ?? ''}',
      name: '${json['name'] ?? ''}',
      size: (json['size'] as num?)?.toInt() ?? 0,
      isBinary: json['isBinary'] == true,
      isImage: json['isImage'] == true,
      content: '${json['content'] ?? ''}',
      gitDiff: '${json['gitDiff'] ?? ''}',
      error: '${json['error'] ?? ''}',
    );
  }
}

/// Trạng thái git của project so với HEAD (`/api/git/status`)
class ServerGitStatus {
  const ServerGitStatus({
    required this.ok,
    required this.isRepo,
    required this.kinds,
    this.error = '',
  });

  final bool ok;
  final bool isRepo;
  /// Đường dẫn tuyệt đối → "created" | "modified" | "deleted"
  final Map<String, String> kinds;
  final String error;
}

class ServerDirListResponse {
  const ServerDirListResponse({
    required this.ok,
    required this.currentPath,
    required this.parentPath,
    required this.entries,
    this.error = '',
  });

  final bool ok;
  final String currentPath;
  final String parentPath;
  final List<ServerFileEntry> entries;
  final String error;

  factory ServerDirListResponse.fromJson(Map<String, dynamic> json) {
    final list = <ServerFileEntry>[];
    if (json['entries'] is List) {
      for (final item in json['entries'] as List) {
        if (item is Map) {
          list.add(ServerFileEntry.fromJson(Map<String, dynamic>.from(item)));
        }
      }
    }
    return ServerDirListResponse(
      ok: json['ok'] == true,
      currentPath: '${json['currentPath'] ?? ''}',
      parentPath: '${json['parentPath'] ?? ''}',
      entries: list,
      error: '${json['error'] ?? ''}',
    );
  }
}

class FileDownloadResult {
  const FileDownloadResult({
    required this.ok,
    required this.savedPath,
    required this.sizeBytes,
    this.error = '',
  });

  final bool ok;
  final String savedPath;
  final int sizeBytes;
  final String error;
}
