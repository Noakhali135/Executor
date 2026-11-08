import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/command_action.dart';
import '../services/command_parser_service.dart';
import '../services/file_execution_service.dart';
import '../services/storage_service.dart';
import '../services/workspace_probe.dart';
import '../widgets/directory_picker_dialog.dart';
import '../widgets/github_sync_dialog.dart';

/// Description of content pushed into the command buffer from the Explorer.
class PendingLoad {
  final String label;

  /// Incremented on every load so the Runner can detect a new one even when
  /// the label is identical.
  final int version;

  const PendingLoad({required this.label, required this.version});
}

class RunnerScreen extends StatefulWidget {
  final String workingDir;
  final Function(String) onDirectoryChanged;
  final TextEditingController codeController;
  final VoidCallback onExecutionCompleted;
  final PendingLoad? pendingLoad;
  final VoidCallback? onUndoLoad;

  const RunnerScreen({
    super.key,
    required this.workingDir,
    required this.onDirectoryChanged,
    required this.codeController,
    required this.onExecutionCompleted,
    this.pendingLoad,
    this.onUndoLoad,
  });

  @override
  State<RunnerScreen> createState() => _RunnerScreenState();
}

class _RunnerScreenState extends State<RunnerScreen> {
  final List<TerminalLog> _terminalLogs = [];
  final ScrollController _terminalScrollController = ScrollController();
  bool _isExecuting = false;
  int _lineCount = 1;
  int _charCount = 0;

  int _lastLoadVersion = 0;
  String? _pendingLoadLabel;

  /// True while the pre-flight confirmation sheet is open.
  bool _isReviewing = false;

  @override
  void initState() {
    super.initState();
    _updateTextMetrics();
    widget.codeController.addListener(_updateTextMetrics);
    _lastLoadVersion = widget.pendingLoad?.version ?? 0;
    if (widget.workingDir.isNotEmpty) {
      _diagnoseWorkingDir(widget.workingDir);
    }
  }

  @override
  void didUpdateWidget(covariant RunnerScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final incoming = widget.pendingLoad;
    if (incoming != null && incoming.version != _lastLoadVersion) {
      _lastLoadVersion = incoming.version;
      setState(() {
        // Surfacing this prevents the "loaded a file then ran an old script"
        // mistake: the buffer is replaced, not appended.
        _pendingLoadLabel = incoming.label;
      });
    }
  }

  @override
  void dispose() {
    widget.codeController.removeListener(_updateTextMetrics);
    _terminalScrollController.dispose();
    super.dispose();
  }

  void _updateTextMetrics() {
    final text = widget.codeController.text;
    final lines = text.isEmpty ? 1 : text.split('\n').length;
    if (mounted) {
      setState(() {
        _lineCount = lines;
        _charCount = text.length;
      });
    }
  }

  /// Checks the selected workspace as soon as it changes, so a scoped-storage
  /// problem is visible immediately instead of at push time.
  Future<void> _diagnoseWorkingDir(String dir) async {
    if (dir.trim().isEmpty) return;
    final problems = await WorkspaceProbe.diagnose(dir);
    if (!mounted || problems.isEmpty) return;

    _addLog('Workspace check: $dir', LogLevel.info);
    for (final problem in problems) {
      _addLog('[WORKSPACE] $problem', LogLevel.warning);
    }
  }

  Future<void> _handleBrowse() async {
    final selected = await showDialog<String>(
      context: context,
      builder: (ctx) => DirectoryPickerDialog(
        initialPath: widget.workingDir,
      ),
    );

    if (selected != null && selected.isNotEmpty) {
      await StorageService.saveDirectory(selected);
      widget.onDirectoryChanged(selected);
      _addLog('Changed working directory to: $selected', LogLevel.info);
      await _diagnoseWorkingDir(selected);
    }
  }

  void _handleOpenGitHubSync() {
    showDialog(
      context: context,
      builder: (ctx) => GitHubSyncDialog(
        workingDir: widget.workingDir,
        onLog: _addLog,
      ),
    );
  }

  Future<void> _handlePaste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data != null && data.text != null && data.text!.isNotEmpty) {
      setState(() => _pendingLoadLabel = null);
      widget.codeController.text = data.text!;
      _updateTextMetrics();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Pasted from clipboard'),
            duration: Duration(milliseconds: 900),
            backgroundColor: Color(0xFF1E293B),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  void _handleClear() {
    setState(() => _pendingLoadLabel = null);
    widget.codeController.clear();
    _updateTextMetrics();
  }

  Future<void> _handleCopyLogs() async {
    if (_terminalLogs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No terminal logs to copy'),
          duration: Duration(milliseconds: 800),
          backgroundColor: Color(0xFF1E293B),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    final rawLogs = _terminalLogs
        .map((l) => '[${l.formattedTime}] ${l.message}')
        .join('\n');
    await Clipboard.setData(ClipboardData(text: rawLogs));

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Output logs copied to clipboard'),
          duration: Duration(milliseconds: 1000),
          backgroundColor: Color(0xFF10B981),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void _addLog(String msg, LogLevel level) {
    if (!mounted) return;
    setState(() {
      _terminalLogs.add(TerminalLog(message: msg, level: level));
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_terminalScrollController.hasClients) {
        _terminalScrollController.animateTo(
          _terminalScrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _executeScript() async {
    final text = widget.codeController.text;
    if (text.trim().isEmpty) {
      _addLog('Warning: Command buffer is empty.', LogLevel.warning);
      return;
    }

    if (widget.workingDir.trim().isEmpty) {
      _addLog('Error: No working directory selected. Tap Browse to select one.', LogLevel.error);
      return;
    }

    _addLog('Parsing input commands...', LogLevel.info);
    final parseResult = CommandParserService.parse(text);

    for (final err in parseResult.errors) {
      _addLog('[SYNTAX ERROR] $err', LogLevel.error);
    }
    for (final warning in parseResult.warnings) {
      _addLog('[WARNING] $warning', LogLevel.warning);
    }

    if (!parseResult.hasActions) {
      _addLog('No valid actions found to execute.', LogLevel.warning);
      return;
    }

    // Resolve and validate every path before touching disk.
    final plan = FileExecutionService.plan(
      rootDir: widget.workingDir,
      actions: parseResult.actions,
    );
    for (final blocked in plan.errors) {
      _addLog('[BLOCKED] $blocked', LogLevel.error);
    }

    if (plan.runnable.isEmpty) {
      _addLog('Every action was blocked. Nothing to execute.', LogLevel.error);
      return;
    }

    if (plan.deleteCount > 0 || plan.rejected.isNotEmpty) {
      setState(() => _isReviewing = true);
      final approved = await _confirmExecution(plan);
      if (!mounted) return;
      setState(() => _isReviewing = false);
      if (!approved) {
        _addLog('Execution cancelled before any change was made.', LogLevel.warning);
        return;
      }
    }

    if (!mounted) return;
    setState(() {
      _isExecuting = true;
    });

    await FileExecutionService.executeBatch(
      rootDir: widget.workingDir,
      actions: parseResult.actions,
      onLog: (log) {
        if (!mounted) return;
        setState(() {
          _terminalLogs.add(log);
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          if (_terminalScrollController.hasClients) {
            _terminalScrollController.animateTo(
              _terminalScrollController.position.maxScrollExtent,
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
            );
          }
        });
      },
    );

    if (!mounted) return;
    widget.onExecutionCompleted();
    setState(() {
      _isExecuting = false;
    });
  }

  /// Pre-flight sheet shown whenever a batch deletes something or contains a
  /// blocked path. Nothing has been written at this point.
  Future<bool> _confirmExecution(PlanSummary plan) async {
    final destructive = plan.runnable.where((i) => i.action.isDestructive).toList();
    final preview = plan.runnable.take(40).toList();

    final result = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: const Color(0xFF0F1523),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.8,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                child: Row(
                  children: [
                    Icon(
                      destructive.isEmpty ? Icons.fact_check_outlined : Icons.warning_amber_rounded,
                      size: 18,
                      color: destructive.isEmpty
                          ? const Color(0xFF818CF8)
                          : const Color(0xFFFBBF24),
                    ),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'Review before executing',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    _summaryChip('${plan.createCount} create', const Color(0xFF10B981)),
                    if (plan.deleteCount > 0)
                      _summaryChip('${plan.deleteCount} delete', const Color(0xFFF87171)),
                    if (plan.skipCount > 0)
                      _summaryChip('${plan.skipCount} skip', const Color(0xFF94A3B8)),
                    if (plan.rejected.isNotEmpty)
                      _summaryChip('${plan.rejected.length} blocked', const Color(0xFFFBBF24)),
                  ],
                ),
              ),
              if (destructive.isNotEmpty)
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 10, 16, 0),
                  child: Text(
                    'Deletions are permanent — files are removed recursively and cannot be restored.',
                    style: TextStyle(color: Color(0xFFFCA5A5), fontSize: 11.5, height: 1.35),
                  ),
                ),
              const SizedBox(height: 8),
              const Divider(height: 1, color: Color(0xFF1E293B)),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  itemCount: preview.length,
                  itemBuilder: (c, i) {
                    final item = preview[i];
                    final a = item.action;
                    final isDelete = a.isDestructive;
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
                      child: Row(
                        children: [
                          Icon(
                            a.type == ActionType.createFile
                                ? Icons.insert_drive_file_outlined
                                : a.type == ActionType.createFolder
                                    ? Icons.create_new_folder_outlined
                                    : a.type == ActionType.skipBinary
                                        ? Icons.skip_next_rounded
                                        : Icons.delete_outline,
                            size: 15,
                            color: isDelete
                                ? const Color(0xFFF87171)
                                : a.type == ActionType.skipBinary
                                    ? const Color(0xFF64748B)
                                    : const Color(0xFF34D399),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '${a.displayName}  ${a.fullRelativePath}',
                              style: TextStyle(
                                color: isDelete ? const Color(0xFFFCA5A5) : const Color(0xFFCBD5E1),
                                fontFamily: 'monospace',
                                fontSize: 11.5,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              if (plan.runnable.length > preview.length)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Text(
                    '+ ${plan.runnable.length - preview.length} more action(s)',
                    style: const TextStyle(color: Color(0xFF64748B), fontSize: 11.5),
                  ),
                ),
              const Divider(height: 1, color: Color(0xFF1E293B)),
              Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFFCBD5E1),
                          side: const BorderSide(color: Color(0xFF1E293B)),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        child: const Text('Cancel'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 2,
                      child: ElevatedButton.icon(
                        onPressed: () => Navigator.pop(ctx, true),
                        icon: const Icon(Icons.play_arrow_rounded, size: 18, color: Colors.white),
                        label: const Text(
                          'Run',
                          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor:
                              destructive.isEmpty ? const Color(0xFF10B981) : const Color(0xFFDC2626),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );

    return result ?? false;
  }

  Widget _summaryChip(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.55)),
      ),
      child: Text(
        label,
        style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600),
      ),
    );
  }

  Widget _buildPendingLoadBanner() {
    if (_pendingLoadLabel == null) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF111728),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF312E81)),
      ),
      child: Row(
        children: [
          const Icon(Icons.info_outline_rounded, size: 15, color: Color(0xFF818CF8)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Buffer replaced with $_pendingLoadLabel. Running it will overwrite those files.',
              style: const TextStyle(color: Color(0xFFC7D2FE), fontSize: 11.5, height: 1.3),
            ),
          ),
          if (widget.onUndoLoad != null)
            TextButton(
              onPressed: () {
                widget.onUndoLoad!();
                setState(() => _pendingLoadLabel = null);
              },
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFF818CF8),
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 6),
              ),
              child: const Text('Undo', style: TextStyle(fontSize: 11.5)),
            ),
          InkWell(
            onTap: () => setState(() => _pendingLoadLabel = null),
            borderRadius: BorderRadius.circular(6),
            child: const Padding(
              padding: EdgeInsets.all(3),
              child: Icon(Icons.close_rounded, size: 15, color: Color(0xFF64748B)),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildWorkingDirectoryCard(),
          const SizedBox(height: 8),
          _buildPendingLoadBanner(),
          _buildEditorCard(),
          const SizedBox(height: 8),
          _buildExecuteButton(),
          const SizedBox(height: 8),
          _buildTerminalCard(),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  Widget _buildWorkingDirectoryCard() {
    final pathDisplay = widget.workingDir.isEmpty
        ? 'No directory selected. Tap Browse...'
        : widget.workingDir;

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0F1523),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF1E293B)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Row(
                children: [
                  Icon(Icons.folder, size: 14, color: Color(0xFF38BDF8)),
                  SizedBox(width: 6),
                  Text(
                    'WORKING DIRECTORY',
                    style: TextStyle(
                      color: Color(0xFF94A3B8),
                      fontSize: 10.5,
                      letterSpacing: 0.8,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              InkWell(
                onTap: _handleOpenGitHubSync,
                borderRadius: BorderRadius.circular(6),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFF6366F1).withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: const Color(0xFF6366F1)),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.cloud_upload_rounded, size: 12, color: Color(0xFF818CF8)),
                      SizedBox(width: 4),
                      Text(
                        'GitHub',
                        style: TextStyle(color: Color(0xFFCBD5E1), fontSize: 10.5, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: _handleBrowse,
                  child: Container(
                    height: 38,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF080C16),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFF1E293B)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.storage_rounded, size: 15, color: Color(0xFF64748B)),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            pathDisplay,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: widget.workingDir.isEmpty
                                  ? const Color(0xFF64748B)
                                  : const Color(0xFFE2E8F0),
                              fontFamily: 'monospace',
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                height: 38,
                child: ElevatedButton.icon(
                  onPressed: _handleBrowse,
                  icon: const Icon(Icons.folder_open, size: 15, color: Colors.white),
                  label: const Text(
                    'Browse',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF6366F1),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildEditorCard() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0F1523),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF1E293B)),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      decoration: const BoxDecoration(
                        color: Color(0xFF38BDF8),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 7),
                    const Text(
                      'Command Buffer',
                      style: TextStyle(
                        color: Color(0xFFE2E8F0),
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
                Row(
                  children: [
                    _buildPillButton(
                      icon: Icons.paste_rounded,
                      label: 'Paste',
                      onTap: _handlePaste,
                    ),
                    const SizedBox(width: 6),
                    _buildPillButton(
                      icon: Icons.delete_outline,
                      label: 'Clear',
                      iconColor: const Color(0xFFF87171),
                      onTap: _handleClear,
                    ),
                  ],
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: Color(0xFF1E293B)),
          Container(
            height: 180,
            color: const Color(0xFF070B14),
            padding: const EdgeInsets.all(10),
            child: TextField(
              controller: widget.codeController,
              maxLines: null,
              expands: true,
              style: const TextStyle(
                color: Color(0xFFCBD5E1),
                fontFamily: 'monospace',
                fontSize: 12.5,
                height: 1.4,
              ),
              decoration: const InputDecoration(
                isDense: true,
                contentPadding: EdgeInsets.zero,
                border: InputBorder.none,
                hintText: '// Type or paste your code/commands here...',
                hintStyle: TextStyle(
                  color: Color(0xFF475569),
                  fontFamily: 'monospace',
                  fontSize: 12.5,
                ),
              ),
            ),
          ),
          const Divider(height: 1, color: Color(0xFF1E293B)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Lines: $_lineCount | Chars: $_charCount',
                  style: const TextStyle(
                    color: Color(0xFF64748B),
                    fontFamily: 'monospace',
                    fontSize: 11,
                  ),
                ),
                const Text(
                  'Batch Engine',
                  style: TextStyle(
                    color: Color(0xFF818CF8),
                    fontFamily: 'monospace',
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPillButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    Color? iconColor,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: iconColor ?? const Color(0xFF94A3B8)),
            const SizedBox(width: 4),
            Text(
              label,
              style: const TextStyle(
                color: Color(0xFFE2E8F0),
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildExecuteButton() {
    return SizedBox(
      height: 44,
      child: ElevatedButton(
        onPressed: (_isExecuting || _isReviewing) ? null : _executeScript,
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF10B981),
          disabledBackgroundColor: const Color(0xFF065F46),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          elevation: 2,
        ),
        child: _isExecuting
            ? const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  ),
                  SizedBox(width: 10),
                  Text(
                    'EXECUTING SCRIPT...',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.8,
                    ),
                  ),
                ],
              )
            : const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.play_arrow_rounded, color: Colors.white, size: 20),
                  SizedBox(width: 5),
                  Text(
                    'EXECUTE SCRIPT',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.8,
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _buildTerminalCard() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0B101D),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF1E293B)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Row(
                  children: [
                    Icon(Icons.terminal_rounded, size: 14, color: Color(0xFF38BDF8)),
                    SizedBox(width: 6),
                    Text(
                      'EXECUTION OUTPUT',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        letterSpacing: 0.8,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                Row(
                  children: [
                    InkWell(
                      onTap: _handleCopyLogs,
                      borderRadius: BorderRadius.circular(6),
                      child: const Padding(
                        padding: EdgeInsets.all(3.0),
                        child: Icon(Icons.content_copy_rounded, size: 15, color: Color(0xFF94A3B8)),
                      ),
                    ),
                    const SizedBox(width: 8),
                    InkWell(
                      onTap: () {
                        setState(() {
                          _terminalLogs.clear();
                        });
                      },
                      borderRadius: BorderRadius.circular(6),
                      child: const Padding(
                        padding: EdgeInsets.all(3.0),
                        child: Icon(Icons.block_rounded, size: 15, color: Color(0xFF64748B)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: Color(0xFF1E293B)),
          Container(
            height: 150,
            color: const Color(0xFF050811),
            padding: const EdgeInsets.all(10),
            child: _terminalLogs.isEmpty
                ? const Align(
                    alignment: Alignment.topLeft,
                    child: Text(
                      '// Terminal ready. Click \'EXECUTE SCRIPT\' to view logs.',
                      style: TextStyle(
                        color: Color(0xFF475569),
                        fontFamily: 'monospace',
                        fontStyle: FontStyle.italic,
                        fontSize: 11.5,
                      ),
                    ),
                  )
                : ListView.builder(
                    controller: _terminalScrollController,
                    itemCount: _terminalLogs.length,
                    itemBuilder: (ctx, i) {
                      final log = _terminalLogs[i];
                      Color textColor;
                      switch (log.level) {
                        case LogLevel.success:
                          textColor = const Color(0xFF34D399);
                          break;
                        case LogLevel.error:
                          textColor = const Color(0xFFF87171);
                          break;
                        case LogLevel.warning:
                          textColor = const Color(0xFFFBBF24);
                          break;
                        case LogLevel.info:
                        default:
                          textColor = const Color(0xFF94A3B8);
                      }
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 1.5),
                        child: Text(
                          '[${log.formattedTime}] ${log.message}',
                          style: TextStyle(
                            color: textColor,
                            fontFamily: 'monospace',
                            fontSize: 11.5,
                            height: 1.3,
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}