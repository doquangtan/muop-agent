import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'package:muop_agent/core/di/app_dependencies.dart';
import 'package:muop_agent/core/theme/app_theme.dart';
import 'package:muop_agent/core/widgets/glass_scaffold.dart';
import 'package:muop_agent/features/agy_auth/domain/agy_auth_repository.dart';
import 'package:muop_agent/features/chat/presentation/run_command_dialog.dart';
import 'package:muop_agent/features/claude_auth/domain/claude_auth_repository.dart';
import 'package:muop_agent/features/setup/domain/setup_entities.dart';
import 'package:muop_agent/features/setup/domain/setup_repository.dart';
import 'package:muop_agent/features/setup/presentation/setup_accounts_section.dart';
import 'package:muop_agent/features/setup/presentation/tool_path_field.dart';
import 'package:muop_agent/features/setup/presentation/workspace_root_field.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:muop_agent/core/state/server_address_provider.dart';

/// Các CLI người dùng có thể chọn (khớp với `CLI_IDS` ở server)
const _cliIds = ['agy', 'claude'];

const _cliLabels = {
  'agy': 'Antigravity CLI (agy)',
  'claude': 'Claude Code CLI',
};

const _cliDescriptions = {
  'agy': 'CLI của Antigravity (Google): model Gemini và các agent agy.',
  'claude': 'Claude Code CLI (Anthropic): model Claude.',
};

enum _SetupStep { check, choose, login }

/// Wizard khởi tạo muop-agent-server, mở khi server báo chưa khởi tạo.
/// Mọi lệnh gửi cho server qua socket; server tự cài tool trên máy của mình.
/// Trả về `true` khi người dùng vào màn hình chính.
/// Màn gắn với server đang kết nối: đổi địa chỉ (provider toàn cục) thì dựng lại và tải lại dữ liệu
class SetupWizardScreen extends ConsumerWidget {
  const SetupWizardScreen({
    super.key,
    this.repository,
    this.agyRepository,
    this.claudeRepository,
  });

  final SetupRepository? repository;
  final AgyAuthRepository? agyRepository;
  final ClaudeAuthRepository? claudeRepository;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final serverAddress = ref.watch(serverAddressProvider);
    return SetupWizardScreenView(
      key: ValueKey(serverAddress),
      serverAddress: serverAddress,
      repository: repository,
      agyRepository: agyRepository,
      claudeRepository: claudeRepository,
    );
  }
}

class SetupWizardScreenView extends StatefulWidget {
  const SetupWizardScreenView({
    super.key,
    required this.serverAddress,
    this.repository,
    this.agyRepository,
    this.claudeRepository,
  });

  final String serverAddress;
  final SetupRepository? repository;
  final AgyAuthRepository? agyRepository;

  /// Repository đăng nhập Claude cho bước Đăng nhập (mặc định của app; test có thể truyền bản giả)
  final ClaudeAuthRepository? claudeRepository;

  @override
  State<SetupWizardScreenView> createState() => _SetupWizardScreenState();
}

class _SetupWizardScreenState extends State<SetupWizardScreenView> {
  late final SetupRepository _repo =
      widget.repository ?? AppDependencies.setup;
  late final AgyAuthRepository _agyRepo =
      widget.agyRepository ?? AppDependencies.agyAuth;
  StreamSubscription<SetupStatus>? _updatesSub;

  _SetupStep _step = _SetupStep.check;
  SetupStatus _status = SetupStatus.empty;
  final Set<String> _selected = {};
  bool _busy = false;
  String _message = '';

  @override
  void initState() {
    super.initState();
    _updatesSub = _repo.updates.listen((s) {
      if (!mounted || !s.ok) return;
      setState(() => _status = s);
    });
    _checkTools();
  }

  @override
  void dispose() {
    _updatesSub?.cancel();
    super.dispose();
  }

  Future<void> _checkTools() async {
    setState(() {
      _busy = true;
      _message = '';
    });
    final s = await _repo.fetchStatus();
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (s.ok) {
        _status = s;
        if (_selected.isEmpty) _selected.addAll(s.selectedClis);
        // Lần mở đầu: đang cài dở (app đã thoát giữa chừng) thì ở bước Chọn CLI để thấy tiến trình;
        // setup đã đủ, chỉ còn đăng nhập agy thì vào thẳng bước đăng nhập
        if (!_firstCheckDone) {
          if (s.installing) {
            _step = _SetupStep.choose;
          } else if (_onlyLoginLeft(s)) {
            _step = _SetupStep.login;
          }
        }
        _firstCheckDone = true;
      } else {
        _message = s.error;
      }
    });
  }

  bool _firstCheckDone = false;

  /// Setup đã đủ (khởi tạo, có một CLI đã cài); chỉ còn việc đăng nhập
  bool _onlyLoginLeft(SetupStatus s) =>
      s.completed &&
      !s.installing &&
      s.workspaceRoot.isNotEmpty &&
      s.selectedClis.any(s.isInstalled) &&
      !s.tools.any((t) => t.group == 'base' && !t.installed);

  List<SetupTool> get _missingRequired => _status.tools
      .where((t) => t.group == 'base' && !t.installed)
      .toList();

  /// Cài một CLI và chờ job kết thúc. Trả về null nếu thành công, hoặc thông báo lỗi.
  Future<String?> _installOne(String id) async {
    // Đăng ký nghe trước khi gửi lệnh để không bỏ lỡ trạng thái kết thúc
    final finished = _repo.updates
        .firstWhere((s) => s.job != null && s.job!.tool == id && !s.job!.running)
        .timeout(const Duration(minutes: 25));

    final started = await _repo.install(id);
    final alreadyRunning =
        started.job != null && started.job!.tool == id && started.job!.running;
    if (!started.ok && !alreadyRunning) return started.error;

    try {
      final done = await finished;
      final job = done.job!;
      if (job.state == 'done') return null;
      return job.error.isNotEmpty ? job.error : 'Cài ${_cliLabels[id]} thất bại';
    } catch (e) {
      return 'Không theo dõi được tiến trình cài ${_cliLabels[id]}: $e';
    }
  }

  /// Cài các CLI đã chọn còn thiếu. [advance] = true thì sang bước đăng nhập khi xong.
  Future<void> _runInstalls({required bool advance}) async {
    if (_selected.isEmpty) {
      setState(() => _message = 'Hãy chọn ít nhất một CLI');
      return;
    }
    setState(() {
      _busy = true;
      _message = '';
    });
    for (final id in _cliIds.where(_selected.contains)) {
      if (_status.isInstalled(id)) continue;
      final err = await _installOne(id);
      if (!mounted) return;
      if (err != null) {
        setState(() {
          _busy = false;
          _message = err;
        });
        return;
      }
    }
    await _checkTools();
    if (!mounted) return;
    setState(() => _busy = false);
    if (advance) await _continueToLogin();
  }

  /// Lưu CLI đã chọn và sang bước đăng nhập
  Future<void> _continueToLogin() async {
    setState(() {
      _busy = true;
      _message = '';
    });
    final saved = await _repo.selectClis(
      _cliIds.where(_selected.contains).toList(),
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (saved.ok) {
        _status = saved;
        _step = _SetupStep.login;
      } else {
        _message = saved.error;
      }
    });
  }

  /// Đánh dấu khởi tạo xong. Dùng cho cả "Vào màn hình chính" và "Đăng nhập sau".
  Future<void> _finish() async {
    setState(() {
      _busy = true;
      _message = '';
    });
    final s = await _repo.complete();
    if (!mounted) return;
    if (!s.ok) {
      setState(() {
        _busy = false;
        _message = s.error;
      });
      return;
    }
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return GlassScreenScaffold(
      automaticallyImplyLeading: false,
      title: 'Khởi tạo Mướp Agent',
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              _StepIndicator(current: _step),
              const SizedBox(height: 20),
              switch (_step) {
                _SetupStep.check => _buildCheck(textTheme),
                _SetupStep.choose => _buildChoose(textTheme),
                _SetupStep.login => _buildLogin(textTheme),
              },
              if (_message.isNotEmpty) ...[
                const SizedBox(height: 16),
                _ErrorText(message: _message),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Gói bắt buộc còn thiếu (apt trên Linux, Homebrew trên macOS); khi còn thì không hiện nút Tiếp tục
  List<SetupAptPackage> get _blockingApt => _status.isMacOS
      ? _status.brewPackages.where((p) => p.required && !p.installed).toList()
      : _status.aptPackages.where((p) => p.required && !p.installed).toList();

  /// Mở terminal của "Máy này" và chạy lệnh cài gói apt do server tạo (`aptInstallCommand`).
  /// Người dùng nhập mật khẩu sudo trực tiếp trong terminal; app không nhận hay lưu mật khẩu.
  Future<void> _installAptWithSudo() async {
    final command = _status.aptInstallCommand;
    if (command.isEmpty) return;
    await showRunCommandDialog(
      context,
      serverAddress: widget.serverAddress,
      command: command,
    );
    if (!mounted) return;
    await _checkTools();
  }

  /// Mở terminal của "Máy này" và chạy `brew install --cask ...` do server tạo (`brewInstallCommand`).
  /// Cask cài bằng trình cài của hệ thống nên macOS hỏi mật khẩu admin trong terminal; app không nhận mật khẩu.
  Future<void> _installBrewCasks() async {
    final command = _status.brewInstallCommand;
    if (command.isEmpty) return;
    await showRunCommandDialog(
      context,
      serverAddress: widget.serverAddress,
      command: command,
    );
    if (!mounted) return;
    await _checkTools();
  }

  Widget _buildCheck(TextTheme textTheme) {
    final hasTools = _status.tools.isNotEmpty;
    final missing = _missingRequired;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Kiểm tra công cụ', style: textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(
          'Server kiểm tra các công cụ cần thiết trên máy đang chạy nó. '
          'CLI sẽ được cài ở bước sau.',
          style: textTheme.bodyMedium,
        ),
        if (_status.isMacOS) ...[
          const SizedBox(height: 8),
          Text(
            'Máy chủ đang chạy macOS: git, ssh, curl và python3 đi kèm Xcode Command Line Tools. '
            'FUSE-T (mount project của máy khác) là bắt buộc, cài bằng Homebrew ở mục Gói Homebrew bên dưới.',
            style: textTheme.bodySmall,
          ),
        ],
        const SizedBox(height: 16),
        if (_busy && !hasTools)
          const Center(child: CircularProgressIndicator())
        else
          // CLI (agy/claude) kiểm tra ở bước Chọn CLI, không ở đây
          for (final tool in _status.tools.where((t) => t.group != 'cli'))
            _ToolRow(
              tool: tool,
              repository: _repo,
              enabled: !_busy,
              onSaved: (s) => setState(() => _status = s),
            ),
        if (missing.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            'Thiếu công cụ bắt buộc. Cài bằng lệnh gợi ý rồi bấm "Kiểm tra lại": '
            '${missing.map((t) => t.hint).where((h) => h.isNotEmpty).join('; ')}',
            style: textTheme.bodySmall?.copyWith(color: context.status.warning),
          ),
        ],
        if (_blockingApt.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            'Cần cài đủ gói bắt buộc (${_blockingApt.map((p) => p.package).join(', ')}) '
            'để tiếp tục.',
            style: textTheme.bodySmall?.copyWith(color: context.status.warning),
          ),
        ],
        if (_status.isMacOS && _status.brewPackages.isNotEmpty) ...[
          const SizedBox(height: 20),
          Text('Gói Homebrew (macOS)', style: textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'Cài bằng Homebrew trong terminal của máy này (macOS hỏi mật khẩu admin). '
            'Danh sách do server quản lý.',
            style: textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          for (final pkg in _status.brewPackages) _AptPackageRow(pkg: pkg),
          if (_status.brewInstallCommand.isNotEmpty) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _busy ? null : _installBrewCasks,
              icon: const Icon(Icons.terminal_rounded),
              label: const Text('Cài các gói Homebrew còn thiếu'),
            ),
            const SizedBox(height: 4),
            Text(
              _status.brewInstallCommand,
              style: textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                color: context.scheme.onSurfaceVariant,
              ),
            ),
          ] else if (_status.brewPackages.any((p) => !p.installed)) ...[
            const SizedBox(height: 8),
            Text(
              'Chưa có Homebrew: cài tại brew.sh rồi bấm "Kiểm tra lại".',
              style: textTheme.bodySmall?.copyWith(color: context.status.warning),
            ),
          ],
        ],
        const SizedBox(height: 20),
        Text('Thư mục project', style: textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'Thư mục chứa các project sẽ quét và sửa. Chọn xong rồi bấm Tiếp tục; '
          'việc quét bắt đầu khi khởi tạo xong.',
          style: textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        WorkspaceRootField(
          repository: _repo,
          current: _status.workspaceRoot,
          enabled: !_busy,
          onSaved: (s) => setState(() => _status = s),
        ),
        if (!_status.isMacOS && _status.aptPackages.isNotEmpty) ...[
          const SizedBox(height: 20),
          Text('Gói hệ thống (apt)', style: textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'Cài bằng sudo trong terminal của máy này. Danh sách do server quản lý.',
            style: textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          for (final pkg in _status.aptPackages) _AptPackageRow(pkg: pkg),
          if (_status.aptInstallCommand.isNotEmpty) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _busy ? null : _installAptWithSudo,
              icon: const Icon(Icons.terminal_rounded),
              label: const Text('Cài các gói còn thiếu bằng sudo'),
            ),
            const SizedBox(height: 4),
            Text(
              _status.aptInstallCommand,
              style: textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                color: context.scheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
        const SizedBox(height: 20),
        Row(
          children: [
            if (!hasTools)
              FilledButton.icon(
                onPressed: _busy ? null : _checkTools,
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('Khởi tạo'),
              )
            else ...[
              OutlinedButton.icon(
                onPressed: _busy ? null : _checkTools,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Kiểm tra lại'),
              ),
              const Spacer(),
              // Ẩn Tiếp tục khi còn công cụ, gói bắt buộc chưa cài, hoặc chưa chọn thư mục project
              if (missing.isEmpty &&
                  _blockingApt.isEmpty &&
                  _status.workspaceRoot.isNotEmpty)
                FilledButton(
                  onPressed: _busy
                      ? null
                      : () => setState(() => _step = _SetupStep.choose),
                  child: const Text('Tiếp tục'),
                ),
            ],
          ],
        ),
      ],
    );
  }

  Widget _buildChoose(TextTheme textTheme) {
    final job = _status.job;
    final showJob = job != null && job.running;
    // Đang cài (kể cả job của lần mở trước): không cho bấm cài/đi tiếp chồng lên
    final busy = _busy || showJob;
    // Phải có ít nhất một CLI đã cài mới được đi tiếp; chưa có thì nút là "Cài đã chọn"
    // Chỉ cần một CLI đã cài là đi tiếp được; CLI còn lại có thể cài thêm sau
    final anyInstalled = _cliIds.any(_status.isInstalled);
    final needsInstall = _cliIds.any(
      (id) => _selected.contains(id) && !_status.isInstalled(id),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Chọn CLI', style: textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(
          'Chọn một hoặc cả hai. CLI chưa có sẽ được cài tự động trên máy server.',
          style: textTheme.bodyMedium,
        ),
        const SizedBox(height: 16),
        for (final id in _cliIds)
          _CliCard(
            label: _cliLabels[id] ?? id,
            description: _cliDescriptions[id] ?? '',
            installed: _status.isInstalled(id),
            selected: _selected.contains(id),
            enabled: !busy,
            onChanged: (value) => setState(() {
              value ? _selected.add(id) : _selected.remove(id);
            }),
          ),
        if (busy) ...[
          const SizedBox(height: 12),
          const LinearProgressIndicator(),
          if (showJob) ...[
            const SizedBox(height: 8),
            Text(
              'Đang cài ${_cliLabels[job.tool] ?? job.tool}…',
              style: textTheme.labelLarge,
            ),
            const SizedBox(height: 8),
            _LogBox(lines: job.log),
          ],
        ],
        const SizedBox(height: 20),
        // Wrap thay Row để hai nút phải không tràn khi chữ dài (màn hẹp)
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          spacing: 8,
          runSpacing: 8,
          children: [
            TextButton(
              onPressed: busy
                  ? null
                  : () => setState(() => _step = _SetupStep.check),
              child: const Text('Quay lại'),
            ),
            if (!anyInstalled)
              FilledButton(
                onPressed: busy || _selected.isEmpty
                    ? null
                    : () => _runInstalls(advance: false),
                child: const Text('Cài đã chọn'),
              )
            else ...[
              if (needsInstall)
                OutlinedButton(
                  onPressed: busy ? null : () => _runInstalls(advance: false),
                  child: const Text('Cài thêm phần đã chọn'),
                ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: busy ? null : _continueToLogin,
                child: const Text('Tiếp tục'),
              ),
            ],
          ],
        ),
      ],
    );
  }

  Widget _buildLogin(TextTheme textTheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Đăng nhập', style: textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(
          'Đăng nhập các CLI đã chọn. Có thể bỏ qua và đăng nhập sau '
          'trong màn hình Tài khoản.',
          style: textTheme.bodyMedium,
        ),
        const SizedBox(height: 16),
        // Chỉ hiện đăng nhập/đăng xuất cho CLI đã cài trên máy
        SetupAccountsSection(
          serverAddress: widget.serverAddress,
          repository: _agyRepo,
          claudeRepository: widget.claudeRepository,
          showAgy: _status.isInstalled('agy'),
          showClaude: _status.isInstalled('claude'),
        ),
        const SizedBox(height: 12),
        const SizedBox(height: 8),
        Row(
          children: [
            OutlinedButton(
              onPressed: _busy ? null : _finish,
              child: const Text('Đăng nhập sau'),
            ),
            const Spacer(),
            FilledButton(
              onPressed: _busy ? null : _finish,
              child: const Text('Vào màn hình chính'),
            ),
          ],
        ),
      ],
    );
  }
}

class _StepIndicator extends StatelessWidget {
  const _StepIndicator({required this.current});

  final _SetupStep current;

  @override
  Widget build(BuildContext context) {
    const labels = ['1. Khởi tạo', '2. Chọn CLI', '3. Đăng nhập'];
    return Row(
      children: [
        for (var i = 0; i < labels.length; i++) ...[
          Expanded(
            child: Text(
              labels[i],
              textAlign: TextAlign.center,
              style: TextStyle(
                fontWeight: i == current.index ? FontWeight.w700 : FontWeight.w400,
                color: i <= current.index
                    ? context.scheme.primary
                    : context.scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// Một dòng trong danh sách gói apt (trạng thái + lý do cần)
class _AptPackageRow extends StatelessWidget {
  const _AptPackageRow({required this.pkg});

  final SetupAptPackage pkg;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            pkg.installed
                ? Icons.check_circle_rounded
                : Icons.radio_button_unchecked_rounded,
            color: pkg.installed ? context.status.success : scheme.outline,
            size: 20,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${pkg.label} (${pkg.package})', style: textTheme.bodyLarge),
                Text(
                  pkg.note,
                  style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ToolRow extends StatelessWidget {
  const _ToolRow({
    required this.tool,
    required this.repository,
    required this.enabled,
    required this.onSaved,
  });

  final SetupTool tool;
  final SetupRepository repository;
  final bool enabled;
  final ValueChanged<SetupStatus> onSaved;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final textTheme = Theme.of(context).textTheme;
    // Mục tùy chọn: thiếu thì chỉ tính năng liên quan không dùng được, không chặn khởi tạo
    final optional = tool.group == 'optional';
    final subtitle = tool.installed
        ? tool.path
        : optional
            ? (tool.hint.isNotEmpty
                ? 'Không bắt buộc. Gợi ý: ${tool.hint}'
                : 'Không bắt buộc')
            : (tool.hint.isNotEmpty ? 'Gợi ý: ${tool.hint}' : 'Chưa cài');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            tool.installed
                ? Icons.check_circle_rounded
                : Icons.radio_button_unchecked_rounded,
            color: tool.installed ? context.status.success : scheme.outline,
            size: 20,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tool.label, style: textTheme.bodyLarge),
                Text(
                  subtitle,
                  style: textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                if (!tool.installed) ...[
                  const SizedBox(height: 8),
                  ToolPathField(
                    repository: repository,
                    toolId: tool.id,
                    current: tool.overridden,
                    enabled: enabled,
                    onSaved: onSaved,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CliCard extends StatelessWidget {
  const _CliCard({
    required this.label,
    required this.description,
    required this.installed,
    required this.selected,
    required this.enabled,
    required this.onChanged,
  });

  final String label;
  final String description;
  final bool installed;
  final bool selected;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final textTheme = Theme.of(context).textTheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: enabled ? () => onChanged(!selected) : null,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Checkbox(
                value: selected,
                onChanged: enabled ? (v) => onChanged(v ?? false) : null,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: textTheme.titleMedium),
                    const SizedBox(height: 2),
                    Text(
                      description,
                      style: textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                installed ? 'Đã cài' : 'Sẽ cài tự động',
                style: textTheme.labelMedium?.copyWith(
                  color: installed ? context.status.success : scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LogBox extends StatelessWidget {
  const _LogBox({required this.lines});

  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    final tail = lines.length > 12 ? lines.sublist(lines.length - 12) : lines;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: context.scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        tail.isEmpty ? '…' : tail.join('\n'),
        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
      ),
    );
  }
}

class _ErrorText extends StatelessWidget {
  const _ErrorText({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Text(
      message,
      style: TextStyle(color: context.scheme.error),
    );
  }
}

/// Đăng nhập agy: lấy link Google OAuth, dán mã. Dùng cùng socket `agy:auth:*` với màn Tài khoản.
