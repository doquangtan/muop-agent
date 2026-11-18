import 'package:muop_agent/features/server_files/domain/server_file_entities.dart';

/// Interface (domain) của feature server_files. Presentation chỉ phụ thuộc interface này.
abstract class ServerFilesRepository {
  Future<ServerDirListResponse> fetchServerDirectory({
    required String address,
    required String path,
    bool showHidden = false,
  });

  Future<ServerFileReadResponse> readServerFile({
    required String address,
    required String path,
  });

  Future<ServerFileLinesResponse> fetchServerFileLines({
    required String address,
    required String path,
    required int offset,
    int limit = 200,
  });

  Future<ServerGitStatus> fetchGitStatus({
    required String address,
    required String projectPath,
  });

  String getFileDownloadUrl({
    required String address,
    required String remotePath,
  });

  Future<FileDownloadResult> downloadFileFromServer({
    required String address,
    required String remotePath,
    void Function(int receivedBytes, int totalBytes)? onProgress,
  });

  Future<({bool ok, String error})> openDownloadedFile(String savedPath);
}
