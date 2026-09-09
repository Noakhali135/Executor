import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:webview_flutter/webview_flutter.dart';
import '../services/php_service.dart';
import 'html_preview_widget.dart';

class FileEditorDialog extends StatefulWidget {
  final String filePath;
  final String workingDir;
  final VoidCallback? onSaved;
  final Function(String content)? onSendToRunner;

  const FileEditorDialog({
    super.key,
    required this.filePath,
    required this.workingDir,
    this.onSaved,
    this.onSendToRunner,
  });

  @override
  State<FileEditorDialog> createState() => _FileEditorDialogState();
}

class _FileEditorDialogState extends State<FileEditorDialog> {
  final TextEditingController _codeController = TextEditingController();
  final List<String> _undoStack = [];
  final List<String> _redoStack = [];
  bool _isPerformingUndoRedo = false;

  String _savedContent = '';
  bool _isLoading = true;
  bool _isSaving = false;
  bool _isDirty = false;
  bool _isBinary = false;
  bool _isImage = false;
  int _activeTab = 0;
  int _lineCount = 1;
  int _charCount = 0;
  int _fileSizeBytes = 0;

  WebViewController? _phpWebViewController;
  int? _phpServerPort;
  bool _isPhpServerRunning = false;
  String _phpStatusText = 'Smart Engine Active';
  bool _hasNativePhp = false;
  bool _isNativeServerMode = false;

  static const Set<String> _imageExtensions = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'ico'};
  static const Set<String> _binaryExtensions = {
    'zip', 'apk', 'aab', 'tar', 'gz', 'rar', '7z', 'jar', 'exe',
    'so', 'dll', 'dylib', 'bin', 'dat', 'pdf', 'mp3', 'mp4', 'wav',
    'class', 'dex', 'iso', 'db', 'sqlite', 'aar',
  };

  bool get _isHtml {
    final ext = p.extension(widget.filePath).toLowerCase();
    return ext == '.html' || ext == '.htm';
  }

  bool get _isPhp {
    final ext = p.extension(widget.filePath).toLowerCase();
    return ext == '.php';
  }

  @override
  void initState() {
    super.initState();
    _loadFileContent();
    _codeController.addListener(_onTextChanged);
    if (_isPhp) {
      _initPhpEnvironment();
    }
  }

  @override
  void dispose() {
    _codeController.removeListener(_onTextChanged);
    _codeController.dispose();
    PhpService.stopPhpServer();
    super.dispose();
  }

  Future<void> _initPhpEnvironment() async {
    final phpInfo = await PhpService.detectPhp();
    if (mounted) {
      setState(() {
        _hasNativePhp = phpInfo.isAvailable;
        _phpStatusText = phpInfo.isAvailable ? phpInfo.versionString : 'Smart GUI Engine';
      });
    }

    _phpWebViewController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF070B14));
  }

  Future<void> _launchPhpPreview() async {
    if (_phpWebViewController == null) return;

    if (_isNativeServerMode && _hasNativePhp) {
      setState(() => _isPhpServerRunning = true);
      final port = await PhpService.startPhpServer(docRoot: widget.workingDir);
      if (port != null && mounted) {
        setState(() {
          _phpServerPort = port;
          _isPhpServerRunning = false;
        });
        final relPath = p.relative(widget.filePath, from: widget.workingDir).replaceAll(r'\', '/');
        final targetUrl = 'http://127.0.0.1:$port/$relPath';
        await _phpWebViewController!.loadRequest(Uri.parse(targetUrl));
        return;
      }
    }

    final renderedHtml = PhpService.renderPhpFileToHtml(
      phpCode: _codeController.text,
      fileName: p.basename(widget.filePath),
    );

    await _phpWebViewController!.loadHtmlString(
      renderedHtml,
      baseUrl: 'https://acmeacademy.edu.bd/',
    );
  }

  Future<void> _runPhpCli() async {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF0F1523),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        side: BorderSide(color: Color(0xFF1E293B)),
      ),
      builder: (ctx) {
        return FutureBuilder<PhpExecutionResult>(
          future: PhpService.runCliScript(
            scriptPath: widget.filePath,
            workingDir: widget.workingDir,
          ),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const SizedBox(
                height: 200,
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      CircularProgressIndicator(color: Color(0xFF818CF8), strokeWidth: 2),
                      SizedBox(height: 12),
                      Text('Executing PHP CLI...', style: TextStyle(color: Color(0xFF94A3B8), fontSize: 13)),
                    ],
                  ),
                ),
              );
            }

            final res = snapshot.data;
            final isSuccess = res?.isSuccess ?? false;
            final outputText = (res?.stdout.isNotEmpty ?? false)
                ? res!.stdout
                : (res?.stderr.isNotEmpty ?? false)
                    ? res!.stderr
                    : '[Script finished with no output]';

            return Container(
              height: 320,
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Icon(
                            isSuccess ? Icons.check_circle_rounded : Icons.error_rounded,
                            size: 16,
                            color: isSuccess ? const Color(0xFF10B981) : const Color(0xFFF87171),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'PHP CLI (Exit: ${res?.exitCode})',
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                          ),
                        ],
                      ),
                      Text(
                        '${res?.duration.inMilliseconds}ms',
                        style: const TextStyle(color: Color(0xFF64748B), fontFamily: 'monospace', fontSize: 11),
                      ),
                    ],
                  ),
                  const Divider(color: Color(0xFF1E293B), height: 16),
                  Expanded(
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFF070B14),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFF1E293B)),
                      ),
                      child: SingleChildScrollView(
                        physics: const BouncingScrollPhysics(),
                        child: SelectableText(
                          outputText,
                          style: TextStyle(
                            color: isSuccess ? const Color(0xFFCBD5E1) : const Color(0xFFFCA5A5),
                            fontFamily: 'monospace',
                            fontSize: 12,
                            height: 1.35,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _onTextChanged() {
    final text = _codeController.text;
    final lines = text.isEmpty ? 1 : text.split('\n').length;
    final hasContentChanged = (text != _savedContent);

    if (!_isPerformingUndoRedo) {
      if (_undoStack.isEmpty || _undoStack.last != text) {
        _undoStack.add(text);
        if (_undoStack.length > 60) _undoStack.removeAt(0);
        _redoStack.clear();
      }
    }

    if (hasContentChanged != _isDirty || lines != _lineCount || text.length != _charCount) {
      if (mounted) {
        setState(() {
          _isDirty = hasContentChanged;
          _lineCount = lines;
          _charCount = text.length;
        });
      }
    }
  }

  void _undo() {
    if (_undoStack.length > 1) {
      _isPerformingUndoRedo = true;
      final current = _undoStack.removeLast();
      _redoStack.add(current);
      final prev = _undoStack.last;
      _codeController.text = prev;
      _codeController.selection = TextSelection.collapsed(offset: prev.length);
      _isPerformingUndoRedo = false;

      final hasChanged = (prev != _savedContent);
      setState(() {
        _isDirty = hasChanged;
        _lineCount = prev.isEmpty ? 1 : prev.split('\n').length;
        _charCount = prev.length;
      });
    }
  }

  void _redo() {
    if (_redoStack.isNotEmpty) {
      _isPerformingUndoRedo = true;
      final next = _redoStack.removeLast();
      _undoStack.add(next);
      _codeController.text = next;
      _codeController.selection = TextSelection.collapsed(offset: next.length);
      _isPerformingUndoRedo = false;

      final hasChanged = (next != _savedContent);
      setState(() {
        _isDirty = hasChanged;
        _lineCount = next.isEmpty ? 1 : next.split('\n').length;
        _charCount = next.length;
      });
    }
  }

  Future<void> _loadFileContent() async {
    final file = File(widget.filePath);
    if (!await file.exists()) {
      if (mounted) Navigator.pop(context);
      return;
    }

    final ext = p.extension(widget.filePath).replaceFirst('.', '').toLowerCase();
    final length = await file.length();
    _fileSizeBytes = length;

    if (_imageExtensions.contains(ext)) {
      if (mounted) {
        setState(() {
          _isImage = true;
          _isLoading = false;
        });
      }
      return;
    }

    if (_binaryExtensions.contains(ext)) {
      if (mounted) {
        setState(() {
          _isBinary = true;
          _isLoading = false;
        });
      }
      return;
    }

    try {
      final text = await file.readAsString();
      if (mounted) {
        setState(() {
          _savedContent = text;
          _isPerformingUndoRedo = true;
          _codeController.text = text;
          _undoStack.clear();
          _undoStack.add(text);
          _redoStack.clear();
          _isPerformingUndoRedo = false;
          _isDirty = false;
          _isLoading = false;
          _lineCount = text.isEmpty ? 1 : text.split('\n').length;
          _charCount = text.length;
        });
      }
    } catch (_) {
      try {
        final bytes = await file.readAsBytes();
        final text = String.fromCharCodes(bytes);
        if (mounted) {
          setState(() {
            _savedContent = text;
            _isPerformingUndoRedo = true;
            _codeController.text = text;
            _undoStack.clear();
            _undoStack.add(text);
            _redoStack.clear();
            _isPerformingUndoRedo = false;
            _isDirty = false;
            _isLoading = false;
            _lineCount = text.isEmpty ? 1 : text.split('\n').length;
            _charCount = text.length;
          });
        }
      } catch (_) {
        if (mounted) {
          setState(() {
            _isBinary = true;
            _isLoading = false;
          });
        }
      }
    }
  }

  Future<void> _saveFile() async {
    if (_isBinary || _isImage) return;
    setState(() => _isSaving = true);

    try {
      final file = File(widget.filePath);
      await file.writeAsString(_codeController.text);
      final len = await file.length();
      if (mounted) {
        setState(() {
          _savedContent = _codeController.text;
          _isSaving = false;
          _isDirty = false;
          _fileSizeBytes = len;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('File saved successfully!'),
            backgroundColor: Color(0xFF10B981),
            duration: Duration(milliseconds: 1000),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      widget.onSaved?.call();
      if (_isPhp && _activeTab == 1) {
        _launchPhpPreview();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isSaving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save file: $e'), backgroundColor: const Color(0xFFDC2626)),
        );
      }
    }
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  Widget _buildFileIcon() {
    final ext = p.extension(widget.filePath).toLowerCase();
    if (ext == '.php') return const Icon(Icons.code_rounded, color: Color(0xFFA855F7), size: 20);
    if (ext == '.html' || ext == '.htm') return const Icon(Icons.html_rounded, color: Color(0xFFF97316), size: 20);
    if (ext == '.py') return const Icon(Icons.code_rounded, color: Color(0xFF38BDF8), size: 20);
    if (ext == '.dart') return const Icon(Icons.flutter_dash, color: Color(0xFF0284C7), size: 20);
    if (ext == '.json') return const Icon(Icons.data_object_rounded, color: Color(0xFF22D3EE), size: 20);
    if (ext == '.sh') return const Icon(Icons.terminal_rounded, color: Color(0xFFA78BFA), size: 20);
    if (ext == '.md') return const Icon(Icons.description_rounded, color: Color(0xFF60A5FA), size: 20);
    if (_isImage) return const Icon(Icons.image_rounded, color: Color(0xFF34D399), size: 20);
    return const Icon(Icons.insert_drive_file_outlined, color: Color(0xFF94A3B8), size: 20);
  }

  Widget _buildPhpPreview() {
    final fileName = p.basename(widget.filePath);
    final displayStatus = _isNativeServerMode
        ? 'http://127.0.0.1:$_phpServerPort/$fileName'
        : 'Smart GUI Render Engine';

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: const BoxDecoration(
            color: Color(0xFF0F1523),
            border: Border(bottom: BorderSide(color: Color(0xFF1E293B))),
          ),
          child: Row(
            children: [
              const Icon(Icons.auto_awesome_rounded, size: 15, color: Color(0xFFA855F7)),
              const SizedBox(width: 8),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFF070B14),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: const Color(0xFF1E293B)),
                  ),
                  child: Text(
                    displayStatus,
                    style: const TextStyle(
                      color: Color(0xFF94A3B8),
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              if (_hasNativePhp)
                InkWell(
                  onTap: () {
                    setState(() => _isNativeServerMode = !_isNativeServerMode);
                    _launchPhpPreview();
                  },
                  borderRadius: BorderRadius.circular(6),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                    decoration: BoxDecoration(
                      color: _isNativeServerMode ? const Color(0xFF10B981).withOpacity(0.2) : const Color(0xFF1E293B),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: _isNativeServerMode ? const Color(0xFF10B981) : const Color(0xFF334155)),
                    ),
                    child: Text(
                      _isNativeServerMode ? 'Server' : 'Template',
                      style: TextStyle(
                        color: _isNativeServerMode ? const Color(0xFF34D399) : const Color(0xFF94A3B8),
                        fontSize: 10.5,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              const SizedBox(width: 4),
              InkWell(
                onTap: _launchPhpPreview,
                borderRadius: BorderRadius.circular(6),
                child: const Padding(
                  padding: EdgeInsets.all(5),
                  child: Icon(Icons.refresh_rounded, size: 16, color: Color(0xFFCBD5E1)),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: _phpWebViewController != null
              ? WebViewWidget(controller: _phpWebViewController!)
              : const Center(child: CircularProgressIndicator(color: Color(0xFFA855F7), strokeWidth: 2)),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final fileName = p.basename(widget.filePath);
    final relPath = p.relative(widget.filePath, from: widget.workingDir);
    final canUndo = _undoStack.length > 1;
    final canRedo = _redoStack.isNotEmpty;

    return Dialog(
      backgroundColor: const Color(0xFF0F1523),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Color(0xFF1E293B)),
      ),
      insetPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 18),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.88,
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: Color(0xFF1E293B))),
              ),
              child: Row(
                children: [
                  _buildFileIcon(),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                fileName,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                  fontFamily: 'monospace',
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (_isDirty) ...[
                              const SizedBox(width: 6),
                              Container(
                                width: 6,
                                height: 6,
                                decoration: const BoxDecoration(
                                  color: Color(0xFFF59E0B),
                                  shape: BoxShape.circle,
                                ),
                              ),
                            ],
                          ],
                        ),
                        Text(
                          _isPhp
                              ? '$relPath • $_phpStatusText'
                              : '$relPath  (${_formatSize(_fileSizeBytes)})',
                          style: const TextStyle(color: Color(0xFF64748B), fontSize: 10.5),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  if (_isHtml || _isPhp)
                    Container(
                      margin: const EdgeInsets.only(right: 8),
                      height: 30,
                      decoration: BoxDecoration(
                        color: const Color(0xFF080C16),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFF1E293B)),
                      ),
                      child: Row(
                        children: [
                          InkWell(
                            onTap: () => setState(() => _activeTab = 0),
                            borderRadius: const BorderRadius.horizontal(left: Radius.circular(8)),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              color: _activeTab == 0 ? const Color(0xFF6366F1) : Colors.transparent,
                              child: const Row(
                                children: [
                                  Icon(Icons.code_rounded, size: 13, color: Colors.white),
                                  SizedBox(width: 4),
                                  Text('Code', style: TextStyle(color: Colors.white, fontSize: 11)),
                                ],
                              ),
                            ),
                          ),
                          InkWell(
                            onTap: () {
                              setState(() => _activeTab = 1);
                              if (_isPhp) {
                                _launchPhpPreview();
                              }
                            },
                            borderRadius: const BorderRadius.horizontal(right: Radius.circular(8)),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              color: _activeTab == 1 ? const Color(0xFF10B981) : Colors.transparent,
                              child: Row(
                                children: [
                                  Icon(_isPhp ? Icons.auto_awesome_rounded : Icons.visibility_rounded, size: 13, color: Colors.white),
                                  const SizedBox(width: 4),
                                  Text(_isPhp ? 'Render GUI' : 'Render', style: const TextStyle(color: Colors.white, fontSize: 11)),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (!_isBinary && !_isImage) ...[
                    if (_isPhp)
                      IconButton(
                        icon: const Icon(Icons.terminal_rounded, color: Color(0xFFA855F7), size: 19),
                        tooltip: 'Run PHP CLI',
                        onPressed: _runPhpCli,
                      ),
                    if (widget.onSendToRunner != null)
                      IconButton(
                        icon: const Icon(Icons.send_to_mobile_rounded, color: Color(0xFF818CF8), size: 18),
                        tooltip: 'Send to Runner Editor',
                        onPressed: () {
                          widget.onSendToRunner!(_codeController.text);
                          Navigator.pop(context);
                        },
                      ),
                    SizedBox(
                      height: 32,
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF10B981),
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        onPressed: _isSaving ? null : _saveFile,
                        icon: _isSaving
                            ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                            : const Icon(Icons.save_rounded, color: Colors.white, size: 15),
                        label: const Text('Save', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ],
                  const SizedBox(width: 4),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded, color: Color(0xFF94A3B8), size: 20),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
            ),
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator(color: Color(0xFF818CF8), strokeWidth: 2))
                  : _isImage
                      ? Center(
                          child: InteractiveViewer(
                            child: Image.file(File(widget.filePath)),
                          ),
                        )
                      : _isBinary
                          ? Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Icon(Icons.extension_rounded, size: 48, color: Color(0xFF64748B)),
                                  const SizedBox(height: 12),
                                  Text(
                                    fileName,
                                    style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    'Binary file (${_formatSize(_fileSizeBytes)})\nCannot edit directly as plain text.',
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
                                  ),
                                ],
                              ),
                            )
                          : _isPhp && _activeTab == 1
                              ? _buildPhpPreview()
                              : _isHtml && _activeTab == 1
                                  ? HtmlPreviewWidget(
                                      htmlContent: _codeController.text,
                                      baseDir: p.dirname(widget.filePath),
                                      fileName: fileName,
                                    )
                                  : Container(
                                      color: const Color(0xFF070B14),
                                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                      child: TextField(
                                        controller: _codeController,
                                        maxLines: null,
                                        expands: true,
                                        style: const TextStyle(
                                          color: Color(0xFFCBD5E1),
                                          fontFamily: 'monospace',
                                          fontSize: 12.5,
                                          height: 1.42,
                                        ),
                                        decoration: const InputDecoration(
                                          border: InputBorder.none,
                                          contentPadding: EdgeInsets.zero,
                                        ),
                                      ),
                                    ),
            ),
            if (!_isBinary && !_isImage)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: const BoxDecoration(
                  color: Color(0xFF080C16),
                  border: Border(top: BorderSide(color: Color(0xFF1E293B))),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Text(
                          'Lines: $_lineCount | Chars: $_charCount',
                          style: const TextStyle(color: Color(0xFF64748B), fontFamily: 'monospace', fontSize: 11),
                        ),
                        const SizedBox(width: 12),
                        InkWell(
                          onTap: canUndo ? _undo : null,
                          borderRadius: BorderRadius.circular(4),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                            child: Icon(
                              Icons.undo_rounded,
                              size: 16,
                              color: canUndo ? const Color(0xFF818CF8) : const Color(0xFF334155),
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        InkWell(
                          onTap: canRedo ? _redo : null,
                          borderRadius: BorderRadius.circular(4),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                            child: Icon(
                              Icons.redo_rounded,
                              size: 16,
                              color: canRedo ? const Color(0xFF818CF8) : const Color(0xFF334155),
                            ),
                          ),
                        ),
                      ],
                    ),
                    Text(
                      _isDirty ? '● Unsaved' : 'Saved',
                      style: TextStyle(
                        color: _isDirty ? const Color(0xFFF59E0B) : const Color(0xFF10B981),
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}