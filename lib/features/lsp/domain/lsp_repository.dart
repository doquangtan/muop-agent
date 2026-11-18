import 'package:muop_agent/features/lsp/domain/lsp_entities.dart';

/// Interface (domain) của feature lsp. Presentation chỉ phụ thuộc interface này.
abstract class LspRepository {
  Future<CodeResult> fetchCodeFold(String address, String path);

  Future<CodeResult> fetchCodeSymbols(String address, String path);

  Future<CodeResult> fetchCodeDefinition(
    String address, {
    required String path,
    required int line,
    required int character,
  });

  Future<CodeTokens> fetchCodeTokens(String address, String path);

  Future<CodeHoverResult> fetchCodeHover(
    String address, {
    required String path,
    required int line,
    required int character,
  });

  Future<CodeResult> fetchCodeReferences(
    String address, {
    required String path,
    required int line,
    required int character,
  });

  Future<LspSettingsResult> fetchLspSettings(String address);

  Future<LspSettingsResult> saveLspSetting(
    String address, {
    required String language,
    required String path,
  });
}
