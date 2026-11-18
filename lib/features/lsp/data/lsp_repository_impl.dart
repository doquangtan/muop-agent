import 'package:muop_agent/core/network/rest_client.dart';
import 'package:muop_agent/features/lsp/domain/lsp_entities.dart';
import 'package:muop_agent/features/lsp/domain/lsp_repository.dart';

class LspRepositoryImpl implements LspRepository {
  LspRepositoryImpl();

  static const _lspTimeout = Duration(seconds: 90);

  /// Vùng gấp code của tệp (LSP). Lần đầu có thể chậm vì LSP đang khởi động và lập chỉ mục.
  @override
  Future<CodeResult> fetchCodeFold(String address, String path) async {
    try {
      final (_, body) = await restRequest(
        address,
        'GET',
        '/api/code/fold?path=${Uri.encodeQueryComponent(path)}',
        timeout: _lspTimeout,
      );
      return CodeResult.fromJson(body);
    } catch (e) {
      return CodeResult.failure('Không gọi được server: $e');
    }
  }

  /// Danh sách ký hiệu (hàm, class...) của tệp
  @override
  Future<CodeResult> fetchCodeSymbols(String address, String path) async {
    try {
      final (_, body) = await restRequest(
        address,
        'GET',
        '/api/code/symbols?path=${Uri.encodeQueryComponent(path)}',
        timeout: _lspTimeout,
      );
      return CodeResult.fromJson(body);
    } catch (e) {
      return CodeResult.failure('Không gọi được server: $e');
    }
  }

  /// Định nghĩa của ký hiệu tại vị trí (dòng, cột đếm từ 0)
  @override
  Future<CodeResult> fetchCodeDefinition(
    String address, {
    required String path,
    required int line,
    required int character,
  }) async {
    try {
      final (_, body) = await restRequest(
        address,
        'POST',
        '/api/code/definition',
        body: {'path': path, 'line': line, 'character': character},
        timeout: _lspTimeout,
      );
      return CodeResult.fromJson(body);
    } catch (e) {
      return CodeResult.failure('Không gọi được server: $e');
    }
  }

  /// Token ngữ nghĩa để tô màu cú pháp (LSP)
  @override
  Future<CodeTokens> fetchCodeTokens(String address, String path) async {
    try {
      final (_, body) = await restRequest(
        address,
        'GET',
        '/api/code/tokens?path=${Uri.encodeQueryComponent(path)}',
        timeout: _lspTimeout,
      );
      return CodeTokens.fromJson(body);
    } catch (e) {
      return CodeTokens.failure('Không gọi được server: $e');
    }
  }

  /// Hover (kiểu, tài liệu) của ký hiệu tại vị trí (dòng, cột đếm từ 0)
  @override
  Future<CodeHoverResult> fetchCodeHover(
    String address, {
    required String path,
    required int line,
    required int character,
  }) async {
    try {
      final (_, body) = await restRequest(
        address,
        'POST',
        '/api/code/hover',
        body: {'path': path, 'line': line, 'character': character},
        timeout: _lspTimeout,
      );
      return CodeHoverResult.fromJson(body);
    } catch (e) {
      return CodeHoverResult.failure('Không gọi được server: $e');
    }
  }

  /// Mọi chỗ tham chiếu tới ký hiệu tại vị trí (kể cả khai báo)
  @override
  Future<CodeResult> fetchCodeReferences(
    String address, {
    required String path,
    required int line,
    required int character,
  }) async {
    try {
      final (_, body) = await restRequest(
        address,
        'POST',
        '/api/code/references',
        body: {'path': path, 'line': line, 'character': character},
        timeout: _lspTimeout,
      );
      return CodeResult.fromJson(body);
    } catch (e) {
      return CodeResult.failure('Không gọi được server: $e');
    }
  }

  /// Trạng thái LSP của Go / Dart / Rust
  @override
  Future<LspSettingsResult> fetchLspSettings(String address) async {
    try {
      final (_, body) = await restRequest(address, 'GET', '/api/lsp/settings');
      return LspSettingsResult.fromJson(body);
    } catch (e) {
      return LspSettingsResult.failure('Không gọi được server: $e');
    }
  }

  /// Đặt đường dẫn LSP cho một ngôn ngữ (path rỗng = xóa, dùng lại tự dò). Lưu trong SQLite trên server.
  @override
  Future<LspSettingsResult> saveLspSetting(
    String address, {
    required String language,
    required String path,
  }) async {
    try {
      final (_, body) = await restRequest(
        address,
        'POST',
        '/api/lsp/settings',
        body: {'language': language, 'path': path},
        timeout: const Duration(seconds: 30),
      );
      return LspSettingsResult.fromJson(body);
    } catch (e) {
      return LspSettingsResult.failure('Không gọi được server: $e');
    }
  }
}
