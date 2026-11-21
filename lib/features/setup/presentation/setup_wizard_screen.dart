import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'package:muop_agent/core/di/app_dependencies.dart';
import 'package:muop_agent/core/theme/app_theme.dart';
import 'package:muop_agent/features/agy_auth/domain/agy_auth_repository.dart';
import 'package:muop_agent/features/claude_auth/domain/claude_auth_repository.dart';
import 'package:muop_agent/features/setup/domain/setup_entities.dart';
import 'package:muop_agent/features/setup/domain/setup_repository.dart';
import 'package:muop_agent/features/setup/presentation/setup_accounts_section.dart';
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
        // Lần mở đầu mà setup đã đủ, chỉ còn đăng nhập agy: vào thẳng bước đăng nhập
        if (!_firstCheckDone && _onlyLoginLeft(s)) _step = _SetupStep.login;
        _firstCheckDone = true;
      } else {
        _message = s.error;
      }
    });
  }

  bool _firstCheckDone = false;

  /// Setup đã đủ (khởi tạo, CLI đã cài); chỉ còn việc đăng nhập
  bool _onlyLoginLeft(SetupStatus s) =>
      s.completed &&
      s.selectedClis.isNotEmpty &&
      s.selectedClis.every(s.isInstalled) &&
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

  Future<void> _installAndContinue() async {
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
    return Scaffold(
      appBar: AppBar(title: const Text('Khởi tạo Mướp Agent')),
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

  /// Chạy một lệnh SSH của server rồi cập nhật trạng thái (kể cả khi lệnh báo lỗi: server vẫn trả trạng thái SSH)
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
        const SizedBox(height: 16),
        if (_busy && !hasTools)
          const Center(child: CircularProgressIndicator())
        else
          for (final tool in _status.tools) _ToolRow(tool: tool),
        if (missing.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            'Thiếu công cụ bắt buộc. Cài bằng lệnh gợi ý rồi bấm "Kiểm tra lại": '
            '${missing.map((t) => t.hint).where((h) => h.isNotEmpty).join('; ')}',
            style: textTheme.bodySmall?.copyWith(color: context.status.warning),
          ),
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
    // Đã chọn CLI nào cài rồi thì không cần cài gì nữa: nút chỉ là "Tiếp tục"
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
            enabled: !_busy,
            onChanged: (value) => setState(() {
              value ? _selected.add(id) : _selected.remove(id);
            }),
          ),
        if (_busy || showJob) ...[
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
        Row(
          children: [
            TextButton(
              onPressed: _busy
                  ? null
                  : () => setState(() => _step = _SetupStep.check),
              child: const Text('Quay lại'),
            ),
            const Spacer(),
            FilledButton(
              onPressed: _busy ? null : _installAndContinue,
              child: Text(needsInstall ? 'Cài & tiếp tục' : 'Tiếp tục'),
            ),
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
        SetupAccountsSection(
          serverAddress: widget.serverAddress,
          repository: _agyRepo,
          claudeRepository: widget.claudeRepository,
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

class _ToolRow extends StatelessWidget {
  const _ToolRow({required this.tool});

  final SetupTool tool;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final textTheme = Theme.of(context).textTheme;
    final subtitle = tool.installed
        ? tool.path
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
