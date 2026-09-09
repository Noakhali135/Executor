import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/command_action.dart';
import '../services/command_parser_service.dart';
import '../services/file_execution_service.dart';
import '../services/storage_service.dart';
import '../widgets/directory_picker_dialog.dart';

class RunnerScreen extends StatefulWidget {
  final String workingDir;
  final Function(String) onDirectoryChanged;
  final TextEditingController codeController;
  final VoidCallback onExecutionCompleted;

  const RunnerScreen({
    super.key,
    required this.workingDir,
    required this.onDirectoryChanged,
    required this.codeController,
    required this.onExecutionCompleted,
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

  @override
  void initState() {
    super.initState();
    _updateTextMetrics();
    widget.codeController.addListener(_updateTextMetrics);
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
    }
  }

  Future<void> _handlePaste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data != null && data.text != null && data.text!.isNotEmpty) {
      widget.codeController.text = data.text!;
      _updateTextMetrics();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Pasted from clipboard'),
            duration: Duration(milliseconds: 1000),
            backgroundColor: Color(0xFF1E293B),
          ),
        );
      }
    }
  }

  void _handleClear() {
    widget.codeController.clear();
    _updateTextMetrics();
  }

  void _addLog(String msg, LogLevel level) {
    setState(() {
      _terminalLogs.add(TerminalLog(message: msg, level: level));
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_terminalScrollController.hasClients) {
        _terminalScrollController.animateTo(
          _terminalScrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _executeScript() async {
    final text = widget.codeController.text;
    if (text.trim().isEmpty) {
      _addLog('Warning: Code/Command input is empty.', LogLevel.warning);
      return;
    }

    if (widget.workingDir.trim().isEmpty) {
      _addLog('Error: No working directory selected. Tap Browse to select one.', LogLevel.error);
      return;
    }

    setState(() {
      _isExecuting = true;
    });

    _addLog('Parsing input commands...', LogLevel.info);
    final parseResult = CommandParserService.parse(text);

    for (final err in parseResult.errors) {
      _addLog('[SYNTAX ERROR] $err', LogLevel.error);
    }

    if (!parseResult.hasActions) {
      _addLog('No valid commands found to execute.', LogLevel.warning);
      setState(() {
        _isExecuting = false;
      });
      return;
    }

    await FileExecutionService.executeBatch(
      rootDir: widget.workingDir,
      actions: parseResult.actions,
      onLog: (log) {
        if (mounted) {
          setState(() {
            _terminalLogs.add(log);
          });
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_terminalScrollController.hasClients) {
              _terminalScrollController.animateTo(
                _terminalScrollController.position.maxScrollExtent,
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
              );
            }
          });
        }
      },
    );

    widget.onExecutionCompleted();

    if (mounted) {
      setState(() {
        _isExecuting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildWorkingDirectoryCard(),
          const SizedBox(height: 14),
          _buildEditorCard(),
          const SizedBox(height: 14),
          _buildExecuteButton(),
          const SizedBox(height: 14),
          _buildTerminalCard(),
          const SizedBox(height: 24),
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
        color: const Color(0xFF101626),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF1E293B)),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Row(
                children: [
                  Icon(Icons.folder, size: 16, color: Color(0xFF38BDF8)),
                  SizedBox(width: 8),
                  Text(
                    'WORKING DIRECTORY',
                    style: TextStyle(
                      color: Color(0xFF94A3B8),
                      fontSize: 11,
                      letterSpacing: 1.0,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              Text(
                'Local storage',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.4),
                  fontSize: 11,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: _handleBrowse,
                  child: Container(
                    height: 44,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF090D16),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: const Color(0xFF1E293B)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.storage_rounded, size: 17, color: Color(0xFF64748B)),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            pathDisplay,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: widget.workingDir.isEmpty
                                  ? const Color(0xFF64748B)
                                  : const Color(0xFFE2E8F0),
                              fontFamily: 'monospace',
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                height: 44,
                child: ElevatedButton.icon(
                  onPressed: _handleBrowse,
                  icon: const Icon(Icons.folder_open, size: 17, color: Colors.white),
                  label: const Text(
                    'Browse',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF6366F1),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
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
        color: const Color(0xFF101626),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF1E293B)),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(
                        color: Color(0xFF38BDF8),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      'main.py',
                      style: TextStyle(
                        color: Color(0xFFE2E8F0),
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
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
                    const SizedBox(width: 8),
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
            height: 210,
            color: const Color(0xFF070B14),
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: widget.codeController,
              maxLines: null,
              expands: true,
              style: const TextStyle(
                color: Color(0xFFCBD5E1),
                fontFamily: 'monospace',
                fontSize: 13,
                height: 1.45,
              ),
              decoration: const InputDecoration(
                isDense: true,
                contentPadding: EdgeInsets.zero,
                border: InputBorder.none,
                hintText: '// Type or paste your code/commands here...',
                hintStyle: TextStyle(
                  color: Color(0xFF475569),
                  fontFamily: 'monospace',
                  fontSize: 13,
                ),
              ),
            ),
          ),
          const Divider(height: 1, color: Color(0xFF1E293B)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Lines: $_lineCount | Chars: $_charCount',
                  style: const TextStyle(
                    color: Color(0xFF64748B),
                    fontFamily: 'monospace',
                    fontSize: 12,
                  ),
                ),
                const Text(
                  'Python 3.11',
                  style: TextStyle(
                    color: Color(0xFF818CF8),
                    fontFamily: 'monospace',
                    fontSize: 12,
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
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: iconColor ?? const Color(0xFF94A3B8)),
            const SizedBox(width: 5),
            Text(
              label,
              style: const TextStyle(
                color: Color(0xFFE2E8F0),
                fontSize: 12,
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
      height: 52,
      child: ElevatedButton(
        onPressed: _isExecuting ? null : _executeScript,
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF10B981),
          disabledBackgroundColor: const Color(0xFF065F46),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          elevation: 4,
          shadowColor: const Color(0xFF10B981).withOpacity(0.4),
        ),
        child: _isExecuting
            ? const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  ),
                  SizedBox(width: 12),
                  Text(
                    'EXECUTING SCRIPT...',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.0,
                    ),
                  ),
                ],
              )
            : const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.play_arrow_rounded, color: Colors.white, size: 22),
                  SizedBox(width: 6),
                  Text(
                    'EXECUTE SCRIPT',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.0,
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
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF1E293B)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Row(
                  children: [
                    Icon(Icons.terminal_rounded, size: 16, color: Color(0xFF38BDF8)),
                    SizedBox(width: 8),
                    Text(
                      'EXECUTION OUTPUT',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        letterSpacing: 0.8,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                InkWell(
                  onTap: () {
                    setState(() {
                      _terminalLogs.clear();
                    });
                  },
                  borderRadius: BorderRadius.circular(6),
                  child: const Padding(
                    padding: EdgeInsets.all(4.0),
                    child: Icon(Icons.block_rounded, size: 16, color: Color(0xFF64748B)),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: Color(0xFF1E293B)),
          Container(
            height: 170,
            color: const Color(0xFF050811),
            padding: const EdgeInsets.all(12),
            child: _terminalLogs.isEmpty
                ? const Align(
                    alignment: Alignment.topLeft,
                    child: Text(
                      '// Terminal ready. Click \'EXECUTE SCRIPT\' to view logs.',
                      style: TextStyle(
                        color: Color(0xFF475569),
                        fontFamily: 'monospace',
                        fontStyle: FontStyle.italic,
                        fontSize: 12.5,
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
                        padding: const EdgeInsets.symmetric(vertical: 2.0),
                        child: Text(
                          '[${log.formattedTime}] ${log.message}',
                          style: TextStyle(
                            color: textColor,
                            fontFamily: 'monospace',
                            fontSize: 12,
                            height: 1.35,
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