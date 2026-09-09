import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/command_action.dart';
import '../services/command_parser_service.dart';
import '../services/file_execution_service.dart';
import '../services/storage_service.dart';

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
    final picked = await StorageService.pickDirectory();
    if (picked != null) {
      widget.onDirectoryChanged(picked);
      _addLog('Changed working directory to: $picked', LogLevel.info);
    } else {
      _showManualDirectoryDialog();
    }
  }

  void _showManualDirectoryDialog() {
    final controller = TextEditingController(text: widget.workingDir);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF111827),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Color(0xFF1E293B)),
        ),
        title: const Row(
          children: [
            Icon(Icons.folder_open, color: Color(0xFF818CF8)),
            SizedBox(width: 8),
            Text(
              'Set Working Directory',
              style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Enter the device absolute path for your project workspace:',
              style: TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              style: const TextStyle(color: Colors.white, fontSize: 13, fontFamily: 'monospace'),
              decoration: InputDecoration(
                filled: true,
                fillColor: const Color(0xFF090D16),
                hintText: '/storage/emulated/0/projects/app',
                hintStyle: const TextStyle(color: Color(0xFF475569)),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: Color(0xFF1E293B)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: Color(0xFF6366F1)),
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: Color(0xFF94A3B8))),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF6366F1),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () async {
              final newPath = controller.text.trim();
              if (newPath.isNotEmpty) {
                await StorageService.saveDirectory(newPath);
                widget.onDirectoryChanged(newPath);
                _addLog('Working directory updated to: $newPath', LogLevel.info);
              }
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Save Path', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Future<void> _handlePaste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data != null && data.text != null && data.text!.isNotEmpty) {
      widget.codeController.text = data.text!;
      _updateTextMetrics();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Pasted from clipboard'),
          duration: Duration(milliseconds: 1000),
          backgroundColor: Color(0xFF1E293B),
        ),
      );
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
      _addLog('No valid [ACTION] commands found in the input.', LogLevel.warning);
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
                  onTap: _showManualDirectoryDialog,
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
                      'batch_commands.txt',
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
                hintText: '// Type or paste your code/commands here...\n// Supports 