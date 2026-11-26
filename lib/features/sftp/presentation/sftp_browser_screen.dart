import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'package:muop_agent/core/di/app_dependencies.dart';
import 'package:muop_agent/core/state/server_address_provider.dart';
import 'package:muop_agent/core/theme/app_theme.dart';
import 'package:muop_agent/core/widgets/glass_scaffold.dart';
import 'package:muop_agent/features/sftp/data/sftp_transfers.dart';
import 'package:muop_agent/features/sftp/domain/sftp_entities.dart';
import 'package:muop_agent/features/sftp/domain/sftp_repository.dart';
import 'package:muop_agent/features/sftp/presentation/download_progress.dart';
import 'package:muop_agent/features/ssh/presentation/ssh_password_dialog.dart';

/// Lưu file tải về (file tạm đã tải xong) qua hộp thoại của hệ điều hành. Trả về false nếu người dùng hủy.
typedef SaveFileFn = Future<bool> Function(DownloadedFile file);

Future<bool> _defaultSaveFile(DownloadedFile file) async {
  final bytes = await File(file.tempPath).readAsBytes();
  final uri = await FilePicker.saveFile(fileName: file.name, bytes: bytes);
  return uri != null;
}

/// Cách sắp xếp danh sách (thư mục luôn đứng trước)
enum _SortKey { name, size }

/// Thao tác thêm mục (gom vào một menu trên màn hình hẹp)
enum _AddAction { folder, file, upload }

/// Duyệt file trên máy SFTP (máy SSH đã lưu hoặc "Máy này"): chọn nhiều mục để tải xuống hoặc xóa,
/// xem trước và sửa file văn bản, tải file lên, đổi tên, tạo thư mục/file. Màn đóng thì phiên đóng theo.
class SftpBrowserScreen extends ConsumerWidget {
  const SftpBrowserScreen({
    super.key,
    required this.hostId,
    required this.hostName,
    required this.hostAddress,
  });

  final int hostId;
  final String hostName;
  final String hostAddress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final serverAddress = ref.watch(serverAddressProvider);
    return SftpBrowserScreenView(
      key: ValueKey(serverAddress),
      serverAddress: serverAddress,
      hostId: hostId,
      hostName: hostName,
      hostAddress: hostAddress,
      repository: AppDependencies.sftp,
    );
  }
}

/// Giới hạn tải lên trong một lần (khớp server)
const int _kMaxUploadBytes = 50 * 1024 * 1024;

class SftpBrowserScreenView extends StatefulWidget {
  const SftpBrowserScreenView({
    super.key,
    required this.serverAddress,
    required this.hostId,
    required this.hostName,
    required this.hostAddress,
    required this.repository,
    this.saveFile,
    this.transfers,
  });

  final String serverAddress;
  final int hostId;
  final String hostName;
  final String hostAddress;
  final SftpRepository repository;

  /// Mặc định dùng hộp thoại lưu của hệ điều hành; test có thể thay
  final SaveFileFn? saveFile;

  /// Luồng tải xuống (mặc định tải từ [repository]); test có thể thay
  final SftpTransfers? transfers;

  @override
  State<SftpBrowserScreenView> createState() => _SftpBrowserScreenState();
}

class _SftpBrowserScreenState extends State<SftpBrowserScreenView> {
  String? _sessionId;
  String _path = '/';
  List<SftpEntry> _entries = const [];
  /// Đường dẫn các mục đang được chọn (trong thư mục hiện tại)
  final Set<String> _selected = <String>{};
  bool _busy = true;
  String? _error;

  /// Ô tìm kiếm trong thư mục, bộ lọc file ẩn và cách sắp xếp
  final TextEditingController _searchController = TextEditingController();
  String _query = '';
  bool _showHidden = false;
  _SortKey _sort = _SortKey.name;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    final sid = _sessionId;
    if (sid != null) {
      widget.repository.close(widget.serverAddress, sid);
    }
    _searchController.dispose();
    super.dispose();
  }

  String get _addr => widget.serverAddress;

  SaveFileFn get _save => widget.saveFile ?? _defaultSaveFile;

  SftpTransfers get _transfers =>
      widget.transfers ?? SftpTransfers(widget.repository);

  /// Mục hiển thị: đã lọc file ẩn và từ khóa, rồi sắp xếp (thư mục trước)
  List<SftpEntry> get _visible {
    final q = _query.trim().toLowerCase();
    final items = _entries.where((e) {
      if (!_showHidden && e.name.startsWith('.')) return false;
      if (q.isNotEmpty && !e.name.toLowerCase().contains(q)) return false;
      return true;
    }).toList();
    items.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      if (_sort == _SortKey.size) {
        final c = b.size.compareTo(a.size);
        if (c != 0) return c;
      }
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return items;
  }

  /// Mở phiên: dùng mật khẩu đã lưu; thiếu hoặc sai thì hỏi người dùng (có tùy chọn lưu).
  /// Trả false nếu người dùng hủy hoặc máy không mở được.
  Future<bool> _ensureSession() async {
    var password = '';
    var save = false;
    for (var attempt = 0; attempt < 6; attempt++) {
      final reply = await widget.repository.open(
        _addr,
        widget.hostId,
        password: password,
        savePassword: save,
      );
      if (!mounted) return false;
      final session = reply.session;
      if (reply.ok && session != null) {
        _sessionId = session.sessionId;
        _path = session.home;
        return true;
      }
      if (!reply.needsPassword) {
        setState(() => _error = reply.error);
        return false;
      }
      final input = await showSshPasswordDialog(
        context,
        hostName: widget.hostName,
        address: widget.hostAddress,
        hint: reply.passwordWrong ? 'Mật khẩu không đúng, vui lòng nhập lại.' : null,
      );
      if (!mounted || input == null) return false;
      password = input.password;
      save = input.save;
    }
    return false;
  }

  /// Chạy một thao tác trên phiên. Nếu phiên đã mất hoặc máy cần mật khẩu thì mở lại phiên rồi chạy lại.
  Future<SftpReply?> _call(Future<SftpReply> Function(String sid) op) async {
    if (_sessionId == null && !await _ensureSession()) return null;
    var reply = await op(_sessionId!);
    if (reply.sessionGone) {
      _sessionId = null;
      if (!await _ensureSession()) return null;
      reply = await op(_sessionId!);
    }
    if (reply.needsPassword) {
      _sessionId = null;
      if (!await _ensureSession()) return null;
      reply = await op(_sessionId!);
    }
    return reply;
  }

  void _showMessage(String message) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _start() async {
    setState(() => _busy = true);
    final ok = await _ensureSession();
    if (!mounted) return;
    if (!ok) {
      setState(() => _busy = false);
      return;
    }
    await _load(_path);
  }

  Future<void> _load(String path) async {
    setState(() => _busy = true);
    final reply =
        await _call((sid) => widget.repository.list(_addr, sid, path));
    if (!mounted) return;
    if (reply == null || !reply.ok) {
      setState(() {
        _busy = false;
        _error = reply?.error ?? _error;
      });
      if (reply != null) _showMessage(reply.error);
      return;
    }
    setState(() {
      _path = path;
      _entries = reply.entries;
      _busy = false;
      _error = null;
      // Lựa chọn chỉ có nghĩa trong thư mục đang xem
      _selected.clear();
    });
  }

  void _refresh() => _load(_path);

  Future<void> _runOp(
    Future<SftpReply> Function(String sid) op, {
    String? success,
  }) async {
    setState(() => _busy = true);
    final reply = await _call(op);
    if (!mounted) return;
    setState(() => _busy = false);
    if (reply == null) return;
    if (!reply.ok) {
      _showMessage(reply.error);
      return;
    }
    if (success != null) _showMessage(success);
    _refresh();
  }

  // ---- chọn nhiều ----

  void _toggleSelected(SftpEntry entry) {
    setState(() {
      if (!_selected.remove(entry.path)) _selected.add(entry.path);
    });
  }

  void _toggleSelectAll() {
    final visible = _visible;
    setState(() {
      if (visible.isNotEmpty && visible.every((e) => _selected.contains(e.path))) {
        _selected.clear();
      } else {
        _selected
          ..clear()
          ..addAll(visible.map((e) => e.path));
      }
    });
  }

  void _clearSelection() => setState(_selected.clear);

  // ---- tải xuống ----

  /// Chuẩn bị các mục trên máy đích, tải về file tạm (hiện % tiến trình), rồi lưu bằng hộp thoại
  Future<void> _downloadPaths(List<String> paths) async {
    if (paths.isEmpty) return;
    setState(() => _busy = true);
    final prepared = await _call(
        (sid) => widget.repository.prepareDownload(_addr, sid, paths));
    if (!mounted) return;
    if (prepared == null || !prepared.ok || prepared.downloadId.isEmpty) {
      setState(() => _busy = false);
      _showMessage(
        prepared != null && prepared.error.isNotEmpty
            ? prepared.error
            : 'Không chuẩn bị được file tải xuống',
      );
      return;
    }
    setState(() => _busy = false);
    final DownloadedFile file;
    try {
      file = await runWithDownloadProgress(
        context,
        name: prepared.downloadName,
        run: (onProgress) => _transfers.fetchToTemp(
          address: _addr,
          downloadId: prepared.downloadId,
          name: prepared.downloadName,
          expectedSize: prepared.size,
          onProgress: onProgress,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      _showMessage('Không tải được: $e');
      return;
    }
    final saved = await _save(file);
    await _transfers.discard(file);
    if (!mounted) return;
    if (saved) {
      _showMessage('Đã tải ${file.name} (${_fmtSize(file.size)})');
    }
  }

  Future<void> _downloadSelected() => _downloadPaths(
      _entries.where((e) => _selected.contains(e.path)).map((e) => e.path).toList());

  // ---- xóa nhiều ----

  Future<void> _deleteSelected() async {
    final chosen = _entries.where((e) => _selected.contains(e.path)).toList();
    if (chosen.isEmpty) return;
    final folders = chosen.where((e) => e.isDir).length;
    final message = folders == 0
        ? 'Xóa ${chosen.length} file đã chọn? Không hoàn tác được.'
        : 'Xóa ${chosen.length} mục đã chọn (gồm $folders thư mục và toàn bộ nội dung bên trong)? Không hoàn tác được.';
    final ok = await _confirm('Xóa ${chosen.length} mục?', message);
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    var failed = 0;
    var lastError = '';
    for (final entry in chosen) {
      if (!mounted) return;
      final reply = await _call((sid) =>
          widget.repository.delete(_addr, sid, entry.path, isDir: entry.isDir));
      if (reply == null || !reply.ok) {
        failed++;
        lastError = reply?.error ?? lastError;
      }
    }
    if (!mounted) return;
    setState(() => _busy = false);
    _showMessage(failed == 0
        ? 'Đã xóa ${chosen.length} mục'
        : 'Xóa được ${chosen.length - failed}/${chosen.length} mục: $lastError');
    _refresh();
  }

  // ---- hộp thoại dùng chung ----

  /// Nhập tên mục (tạo mới hoặc đổi tên). Trả null nếu hủy hoặc tên không hợp lệ.
  Future<String?> _askName(String title, {String initial = '', String action = 'Lưu'}) async {
    final controller = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Tên'),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Hủy'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: Text(action),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result == null || result.isEmpty) return null;
    if (result.contains('/') || result == '.' || result == '..') {
      if (mounted) _showMessage('Tên không hợp lệ (không chứa "/")');
      return null;
    }
    return result;
  }

  Future<bool> _confirm(String title, String message, {String action = 'Xóa'}) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Hủy'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(action),
          ),
        ],
      ),
    );
    return ok == true;
  }

  // ---- thao tác ----

  void _up() {
    if (_path == '/') return;
    _load(sftpParentOf(_path));
  }

  Future<void> _newFolder() async {
    final name = await _askName('Thư mục mới', action: 'Tạo');
    if (name == null || !mounted) return;
    final target = sftpJoin(_path, name);
    await _runOp((sid) => widget.repository.mkdir(_addr, sid, target),
        success: 'Đã tạo thư mục $name');
  }

  Future<void> _newFile() async {
    final name = await _askName('File mới', action: 'Tạo');
    if (name == null || !mounted) return;
    final target = sftpJoin(_path, name);
    final empty = Uint8List(0);
    await _runOp((sid) => widget.repository.upload(_addr, sid, target, empty),
        success: 'Đã tạo file $name');
  }

  Future<void> _upload() async {
    final List<PlatformFile> files;
    try {
      files = await FilePicker.pickFiles();
    } catch (e) {
      if (mounted) _showMessage('Không mở được hộp thoại chọn file: $e');
      return;
    }
    if (!mounted || files.isEmpty) return;
    setState(() => _busy = true);
    var done = 0;
    for (final file in files) {
      if (!mounted) return;
      final bytes = await file.readAsBytes();
      if (bytes.length > _kMaxUploadBytes) {
        _showMessage('${file.name}: vượt quá 50 MB');
        continue;
      }
      final target = sftpJoin(_path, file.name);
      var reply = await _call((sid) =>
          widget.repository.upload(_addr, sid, target, bytes, overwrite: false));
      if (!mounted) return;
      if (reply != null && reply.exists) {
        final overwrite = await _confirm(
          'Ghi đè file?',
          '${file.name} đã có trong thư mục này. Ghi đè bằng file mới?',
          action: 'Ghi đè',
        );
        if (!mounted) return;
        if (overwrite) {
          reply = await _call((sid) =>
              widget.repository.upload(_addr, sid, target, bytes, overwrite: true));
        } else {
          continue;
        }
      }
      if (!mounted) return;
      if (reply == null || !reply.ok) {
        _showMessage('${file.name}: ${reply?.error ?? 'không tải lên được'}');
      } else {
        done++;
      }
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (done > 0) _showMessage('Đã tải lên $done file');
    _refresh();
  }

  Future<void> _rename(SftpEntry entry) async {
    final name = await _askName('Đổi tên', initial: entry.name, action: 'Đổi tên');
    if (name == null || name == entry.name || !mounted) return;
    final to = sftpJoin(sftpParentOf(entry.path), name);
    await _runOp((sid) => widget.repository.rename(_addr, sid, entry.path, to));
  }

  Future<void> _delete(SftpEntry entry) async {
    final message = entry.isDir
        ? 'Xóa thư mục "${entry.name}" và toàn bộ nội dung bên trong? Không hoàn tác được.'
        : 'Xóa file "${entry.name}"? Không hoàn tác được.';
    final ok = await _confirm('Xóa ${entry.isDir ? 'thư mục' : 'file'}?', message);
    if (!ok || !mounted) return;
    await _runOp(
      (sid) => widget.repository.delete(_addr, sid, entry.path, isDir: entry.isDir),
      success: 'Đã xóa ${entry.name}',
    );
  }

  /// Đọc nội dung file văn bản (giới hạn 1MB) rồi mở trình xem/sửa
  Future<String?> _readText(SftpEntry entry) async {
    setState(() => _busy = true);
    final reply = await _call(
        (sid) => widget.repository.read(_addr, sid, entry.path));
    if (!mounted) return null;
    setState(() => _busy = false);
    if (reply == null) return null;
    if (!reply.ok) {
      _showMessage(reply.error);
      return null;
    }
    if (reply.binary) {
      _showMessage('${entry.name} là file nhị phân, không mở được dạng văn bản');
      return null;
    }
    return reply.content;
  }

  /// Xem trước file văn bản (chỉ đọc)
  Future<void> _preview(SftpEntry entry) async {
    final content = await _readText(entry);
    if (content == null || !mounted) return;
    await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        fullscreenDialog: true,
        builder: (_) => _SftpEditorPage(
          name: entry.name,
          initial: content,
          readOnly: true,
        ),
      ),
    );
  }

  /// Mở file văn bản để sửa rồi ghi lại trên máy đích
  Future<void> _edit(SftpEntry entry) async {
    final content = await _readText(entry);
    if (content == null || !mounted) return;
    final edited = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        fullscreenDialog: true,
        builder: (_) => _SftpEditorPage(name: entry.name, initial: content),
      ),
    );
    if (edited == null || edited == content || !mounted) return;
    setState(() => _busy = true);
    final bytes = Uint8List.fromList(utf8.encode(edited));
    final saved = await _call((sid) =>
        widget.repository.upload(_addr, sid, entry.path, bytes, overwrite: true));
    if (!mounted) return;
    setState(() => _busy = false);
    if (saved == null || !saved.ok) {
      _showMessage(saved?.error ?? 'Không lưu được file');
      return;
    }
    _showMessage('Đã lưu ${entry.name}');
    _refresh();
  }

  static String _fmtSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  void _onAddAction(_AddAction action) {
    switch (action) {
      case _AddAction.folder:
        _newFolder();
      case _AddAction.file:
        _newFile();
      case _AddAction.upload:
        _upload();
    }
  }

  void _onEntryTap(SftpEntry entry) {
    if (entry.isDir) {
      _load(entry.path);
    } else {
      _preview(entry);
    }
  }

  // ---- giao diện ----

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final textTheme = Theme.of(context).textTheme;
    final visible = _visible;
    // Điện thoại: ít nút trên thanh tiêu đề, dòng mục gọn hơn
    final compact = MediaQuery.sizeOf(context).width < 760;

    return GlassScreenScaffold(
      titleWidget: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            widget.hostName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: textTheme.titleSmall,
          ),
          Text(
            widget.hostAddress,
            style: textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
      actions: [
        IconButton(
          tooltip: visible.isNotEmpty && visible.every((e) => _selected.contains(e.path))
              ? 'Bỏ chọn tất cả'
              : 'Chọn tất cả',
          icon: const Icon(Icons.select_all_rounded),
          onPressed: _busy || visible.isEmpty ? null : _toggleSelectAll,
        ),
        if (compact)
          PopupMenuButton<_AddAction>(
            tooltip: 'Thêm',
            enabled: !_busy,
            icon: const Icon(Icons.add_rounded),
            onSelected: _onAddAction,
            itemBuilder: (_) => const [
              PopupMenuItem(value: _AddAction.folder, child: Text('Thư mục mới')),
              PopupMenuItem(value: _AddAction.file, child: Text('File mới')),
              PopupMenuItem(value: _AddAction.upload, child: Text('Tải file lên')),
            ],
          )
        else ...[
          IconButton(
            tooltip: 'Thư mục mới',
            icon: const Icon(Icons.create_new_folder_outlined),
            onPressed: _busy ? null : _newFolder,
          ),
          IconButton(
            tooltip: 'File mới',
            icon: const Icon(Icons.note_add_outlined),
            onPressed: _busy ? null : _newFile,
          ),
          IconButton(
            tooltip: 'Tải file lên',
            icon: const Icon(Icons.upload_file_rounded),
            onPressed: _busy ? null : _upload,
          ),
        ],
      ],
      body: Column(
        children: [
          if (_busy) const LinearProgressIndicator(minHeight: 2),
          _pathBar(scheme, textTheme),
          _searchBar(scheme, textTheme, compact),
          if (_selected.isNotEmpty) _selectionBar(scheme, textTheme),
          Expanded(child: _body(scheme, textTheme, visible, compact)),
        ],
      ),
    );
  }

  /// Nút lên, thanh đường dẫn (bấm từng đoạn để đi tới) và nút làm mới
  Widget _pathBar(ColorScheme scheme, TextTheme textTheme) {
    final parts = _path.split('/').where((p) => p.isNotEmpty).toList();
    final crumbs = <Widget>[
      _crumb('/', '/', scheme, textTheme, bold: parts.isEmpty),
    ];
    var acc = '';
    for (var i = 0; i < parts.length; i++) {
      acc = '$acc/${parts[i]}';
      crumbs.add(Icon(Icons.chevron_right_rounded, size: 16, color: scheme.onSurfaceVariant));
      crumbs.add(_crumb(parts[i], acc, scheme, textTheme, bold: i == parts.length - 1));
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Row(
        children: [
          IconButton.filledTonal(
            tooltip: 'Lên thư mục cha',
            icon: const Icon(Icons.arrow_upward_rounded),
            onPressed: _busy || _path == '/' ? null : _up,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Container(
              height: 40,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(12),
              ),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                reverse: true,
                child: Row(children: crumbs),
              ),
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            tooltip: 'Làm mới',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _busy ? null : _refresh,
          ),
        ],
      ),
    );
  }

  Widget _crumb(String label, String target, ColorScheme scheme, TextTheme textTheme,
      {required bool bold}) {
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: _busy || target == _path ? null : () => _load(target),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Text(
          label,
          style: textTheme.labelLarge?.copyWith(
            fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
            color: bold ? scheme.onSurface : scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  /// Ô tìm trong thư mục (kèm số thư mục/tệp), nút hiện file ẩn và nút sắp xếp.
  /// Màn hẹp: ô tìm một hàng, số liệu cùng hai nút nằm ở hàng dưới.
  Widget _searchBar(ColorScheme scheme, TextTheme textTheme, bool compact) {
    final folders = _entries.where((e) => e.isDir).length;
    final files = _entries.length - folders;
    final field = TextField(
      controller: _searchController,
      onChanged: (v) => setState(() => _query = v),
      decoration: InputDecoration(
        isDense: true,
        prefixIcon: const Icon(Icons.search_rounded, size: 20),
        hintText: compact
            ? 'Tìm trong thư mục…'
            : 'Tìm trong thư mục ($folders thư mục, $files tệp)…',
        suffixIcon: _query.isEmpty
            ? null
            : IconButton(
                tooltip: 'Xóa',
                icon: const Icon(Icons.close_rounded, size: 18),
                onPressed: () {
                  _searchController.clear();
                  setState(() => _query = '');
                },
              ),
      ),
    );
    final hidden = FilterChip(
      tooltip: 'Hiện file ẩn (tên bắt đầu bằng dấu chấm)',
      label: const Text('Ẩn'),
      selected: _showHidden,
      onSelected: (v) => setState(() => _showHidden = v),
    );
    final sort = PopupMenuButton<_SortKey>(
      tooltip: 'Sắp xếp',
      initialValue: _sort,
      onSelected: (v) => setState(() => _sort = v),
      itemBuilder: (_) => const [
        PopupMenuItem(value: _SortKey.name, child: Text('Tên')),
        PopupMenuItem(value: _SortKey.size, child: Text('Kích thước')),
      ],
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          border: Border.all(color: scheme.outlineVariant),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.sort_rounded, size: 16, color: scheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Text(
              _sort == _SortKey.name ? 'Tên' : 'Kích thước',
              style: textTheme.labelLarge,
            ),
          ],
        ),
      ),
    );
    if (compact) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
        child: Column(
          children: [
            field,
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '$folders thư mục · $files tệp',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.labelSmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
                hidden,
                const SizedBox(width: 8),
                sort,
              ],
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
      child: Row(
        children: [
          Expanded(child: field),
          const SizedBox(width: 8),
          hidden,
          const SizedBox(width: 8),
          sort,
        ],
      ),
    );
  }

  Widget _selectionBar(ColorScheme scheme, TextTheme textTheme) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      padding: const EdgeInsets.fromLTRB(12, 2, 4, 2),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Đã chọn ${_selected.length}',
              style: textTheme.labelLarge?.copyWith(color: scheme.onSecondaryContainer),
            ),
          ),
          IconButton(
            tooltip: 'Tải xuống mục đã chọn',
            icon: const Icon(Icons.download_rounded),
            onPressed: _busy ? null : _downloadSelected,
          ),
          IconButton(
            tooltip: 'Xóa mục đã chọn',
            icon: Icon(Icons.delete_outline_rounded, color: scheme.error),
            onPressed: _busy ? null : _deleteSelected,
          ),
          IconButton(
            tooltip: 'Bỏ chọn',
            icon: const Icon(Icons.close_rounded),
            onPressed: _busy ? null : _clearSelection,
          ),
        ],
      ),
    );
  }

  Widget _body(
    ColorScheme scheme,
    TextTheme textTheme,
    List<SftpEntry> visible,
    bool compact,
  ) {
    if (_error != null && _entries.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!, style: textTheme.bodyMedium?.copyWith(color: scheme.error)),
              const SizedBox(height: 12),
              FilledButton(onPressed: _busy ? null : _start, child: const Text('Thử lại')),
            ],
          ),
        ),
      );
    }
    if (!_busy && _entries.isEmpty) {
      return Center(
        child: Text(
          'Thư mục trống',
          style: textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
        ),
      );
    }
    if (!_busy && visible.isEmpty) {
      return Center(
        child: Text(
          'Không có mục khớp',
          style: textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
      itemCount: visible.length,
      itemBuilder: (context, i) =>
          _row(visible[i], scheme, textTheme, compact: compact),
    );
  }

  Widget _row(
    SftpEntry entry,
    ColorScheme scheme,
    TextTheme textTheme, {
    required bool compact,
  }) {
    return compact
        ? _compactRow(entry, scheme, textTheme)
        : _wideRow(entry, scheme, textTheme);
  }

  /// Dòng trên màn hẹp: hàng 1 là checkbox, icon, tên và menu; hàng 2 là kích thước/thời gian
  /// và nút tải về, thẳng hàng với tên. Chạm vào dòng: mở thư mục hoặc xem file.
  Widget _compactRow(SftpEntry entry, ColorScheme scheme, TextTheme textTheme) {
    final selected = _selected.contains(entry.path);
    final visual = _fileVisual(entry, scheme);
    final meta = [
      if (!entry.isDir) _fmtSize(entry.size),
      if (entry.modified.isNotEmpty) entry.modified,
    ].join('  ·  ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: selected
            ? scheme.secondaryContainer.withValues(alpha: 0.45)
            : scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: _busy ? null : () => _onEntryTap(entry),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(2, 4, 4, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Checkbox(
                      value: selected,
                      onChanged: _busy ? null : (_) => _toggleSelected(entry),
                    ),
                    Icon(visual.$1, color: visual.$2, size: 22),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        entry.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: scheme.onSurface,
                        ),
                      ),
                    ),
                    _entryMenu(entry, scheme),
                  ],
                ),
                Padding(
                  // Checkbox (48) + icon (22) + khoảng cách (10): thẳng hàng với tên
                  padding: const EdgeInsets.only(left: 80, right: 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          meta,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.labelSmall?.copyWith(
                            fontFamily: 'monospace',
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      IconButton.filledTonal(
                        tooltip: 'Tải về',
                        icon: const Icon(Icons.download_rounded, size: 18),
                        onPressed: _busy ? null : () => _downloadPaths([entry.path]),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Menu thao tác của một mục: sửa (chỉ file), đổi tên, xóa
  Widget _entryMenu(SftpEntry entry, ColorScheme scheme) {
    return PopupMenuButton<String>(
      tooltip: 'Thao tác',
      enabled: !_busy,
      onSelected: (value) {
        switch (value) {
          case 'edit':
            _edit(entry);
          case 'rename':
            _rename(entry);
          case 'delete':
            _delete(entry);
        }
      },
      itemBuilder: (_) => [
        if (!entry.isDir) const PopupMenuItem(value: 'edit', child: Text('Sửa')),
        const PopupMenuItem(value: 'rename', child: Text('Đổi tên')),
        PopupMenuItem(
          value: 'delete',
          child: Text('Xóa', style: TextStyle(color: scheme.error)),
        ),
      ],
    );
  }

  /// Dòng trên màn hình rộng (desktop): một hàng với đủ quyền, kích thước, thời gian, xem trước và tải về
  Widget _wideRow(SftpEntry entry, ColorScheme scheme, TextTheme textTheme) {
    final selected = _selected.contains(entry.path);
    final visual = _fileVisual(entry, scheme);
    final mono = textTheme.labelSmall?.copyWith(fontFamily: 'monospace');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: selected
            ? scheme.secondaryContainer.withValues(alpha: 0.45)
            : scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: _busy ? null : () => _onEntryTap(entry),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 6, 4, 6),
            child: Row(
              children: [
                Checkbox(
                  value: selected,
                  onChanged: _busy ? null : (_) => _toggleSelected(entry),
                ),
                Icon(visual.$1, color: visual.$2, size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: scheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Wrap(
                        spacing: 10,
                        runSpacing: 2,
                        children: [
                          Text(entry.mode, style: mono?.copyWith(color: scheme.onSurfaceVariant)),
                          if (!entry.isDir)
                            Text(
                              _fmtSize(entry.size),
                              style: mono?.copyWith(
                                color: scheme.primary,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          if (entry.modified.isNotEmpty)
                            Text(
                              entry.modified,
                              style: textTheme.labelSmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (!entry.isDir)
                  IconButton(
                    tooltip: 'Xem trước',
                    icon: const Icon(Icons.visibility_outlined),
                    onPressed: _busy ? null : () => _preview(entry),
                  ),
                FilledButton.tonalIcon(
                  onPressed: _busy ? null : () => _downloadPaths([entry.path]),
                  icon: const Icon(Icons.download_rounded, size: 18),
                  label: const Text('Tải về'),
                ),
                _entryMenu(entry, scheme),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Icon và màu theo loại mục (chỉ dùng màu ngữ nghĩa của theme)
  (IconData, Color) _fileVisual(SftpEntry entry, ColorScheme scheme) {
    if (entry.isDir) return (Icons.folder_rounded, scheme.primary);
    if (entry.isLink) return (Icons.link_rounded, scheme.secondary);
    final dot = entry.name.lastIndexOf('.');
    final ext = dot > 0 ? entry.name.substring(dot + 1).toLowerCase() : '';
    switch (ext) {
      case 'json':
      case 'yaml':
      case 'yml':
      case 'toml':
      case 'xml':
      case 'ini':
      case 'env':
      case 'lock':
        return (Icons.data_object_rounded, scheme.tertiary);
      case 'dart':
      case 'rs':
      case 'go':
      case 'py':
      case 'js':
      case 'ts':
      case 'sh':
      case 'c':
      case 'cpp':
      case 'h':
      case 'java':
      case 'kt':
      case 'swift':
      case 'html':
      case 'css':
        return (Icons.code_rounded, scheme.primary);
      case 'zip':
      case 'tar':
      case 'gz':
      case 'xz':
      case 'bz2':
      case 'apk':
      case 'ipa':
      case 'jar':
      case 'deb':
      case 'rpm':
      case 'dmg':
      case '7z':
        return (Icons.archive_rounded, scheme.secondary);
      case 'png':
      case 'jpg':
      case 'jpeg':
      case 'gif':
      case 'webp':
      case 'svg':
      case 'bmp':
        return (Icons.image_outlined, scheme.tertiary);
      case 'md':
      case 'txt':
      case 'log':
      case 'rst':
        return (Icons.description_outlined, scheme.onSurface);
      default:
        return (Icons.insert_drive_file_outlined, scheme.onSurfaceVariant);
    }
  }
}

/// Trình xem/sửa file văn bản toàn màn hình. Trả về nội dung mới khi bấm Lưu, null khi thoát.
/// [readOnly]: chỉ xem trước, không có nút Lưu.
class _SftpEditorPage extends StatefulWidget {
  const _SftpEditorPage({
    required this.name,
    required this.initial,
    this.readOnly = false,
  });

  final String name;
  final String initial;
  final bool readOnly;

  @override
  State<_SftpEditorPage> createState() => _SftpEditorPageState();
}

class _SftpEditorPageState extends State<_SftpEditorPage> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.readOnly ? 'Xem: ${widget.name}' : widget.name),
        actions: [
          if (!widget.readOnly)
            TextButton(
              onPressed: () => Navigator.of(context).pop(_controller.text),
              child: const Text('Lưu'),
            ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: TextField(
          controller: _controller,
          readOnly: widget.readOnly,
          expands: true,
          maxLines: null,
          minLines: null,
          textAlignVertical: TextAlignVertical.top,
          style: TextStyle(fontFamily: 'monospace', color: scheme.onSurface),
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
      ),
    );
  }
}
