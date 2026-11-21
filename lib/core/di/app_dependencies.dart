import 'package:muop_agent/core/network/socket_gateway.dart';
import 'package:muop_agent/features/agy_auth/data/agy_auth_repository_impl.dart';
import 'package:muop_agent/features/agy_auth/domain/agy_auth_repository.dart';
import 'package:muop_agent/features/claude_auth/data/claude_auth_repository_impl.dart';
import 'package:muop_agent/features/claude_auth/domain/claude_auth_repository.dart';
import 'package:muop_agent/features/chat/data/chat_repository_impl.dart';
import 'package:muop_agent/features/chat/domain/chat_repository.dart';
import 'package:muop_agent/features/connection/data/connection_repository_impl.dart';
import 'package:muop_agent/features/connection/domain/connection_repository.dart';
import 'package:muop_agent/features/docker/data/docker_repository_impl.dart';
import 'package:muop_agent/features/docker/domain/docker_repository.dart';
import 'package:muop_agent/features/interactions/data/interactions_repository_impl.dart';
import 'package:muop_agent/features/interactions/domain/interactions_repository.dart';
import 'package:muop_agent/features/lsp/data/lsp_repository_impl.dart';
import 'package:muop_agent/features/lsp/domain/lsp_repository.dart';
import 'package:muop_agent/features/projects/data/projects_repository_impl.dart';
import 'package:muop_agent/features/quota/data/quota_repository_impl.dart';
import 'package:muop_agent/features/quota/domain/quota_repository.dart';
import 'package:muop_agent/features/projects/domain/projects_repository.dart';
import 'package:muop_agent/features/screen/data/screen_repository_impl.dart';
import 'package:muop_agent/features/screen/domain/screen_repository.dart';
import 'package:muop_agent/features/server_files/data/server_files_repository_impl.dart';
import 'package:muop_agent/features/server_files/domain/server_files_repository.dart';
import 'package:muop_agent/features/sessions/data/session_repository_impl.dart';
import 'package:muop_agent/features/sessions/domain/session_repository.dart';
import 'package:muop_agent/features/setup/data/setup_repository_impl.dart';
import 'package:muop_agent/features/setup/domain/setup_repository.dart';
import 'package:muop_agent/features/ssh/data/ssh_repository_impl.dart';
import 'package:muop_agent/features/ssh/domain/ssh_repository.dart';

/// Composition root: tạo một lần các kết nối và repository dùng chung cho toàn app.
/// Presentation chỉ lấy các interface ở đây, không biết lớp data cụ thể.
class AppDependencies {
  AppDependencies._();

  static final SocketGateway socket = SocketGateway();

  static final ConnectionRepository connection =
      ConnectionRepositoryImpl(socket);
  static final SessionRepository sessions = SessionRepositoryImpl(socket);
  static final ChatRepository chat = ChatRepositoryImpl(socket);
  static final InteractionsRepository interactions =
      InteractionsRepositoryImpl(socket);
  static final ProjectsRepository projects = ProjectsRepositoryImpl(socket);
  static final ServerFilesRepository serverFiles =
      ServerFilesRepositoryImpl();
  static final SshRepository ssh = SshRepositoryImpl(socket);
  static final DockerRepository docker = DockerRepositoryImpl(socket);
  static final LspRepository lsp = LspRepositoryImpl();
  static final QuotaRepository quota = QuotaRepositoryImpl();
  static final ScreenRepository screen = ScreenRepositoryImpl(socket);
  static final AgyAuthRepository agyAuth = AgyAuthRepositoryImpl(socket);
  static final ClaudeAuthRepository claudeAuth = ClaudeAuthRepositoryImpl(socket);
  static final SetupRepository setup = SetupRepositoryImpl(socket);
}
