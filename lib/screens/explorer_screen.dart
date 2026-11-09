import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import '../models/tree_node.dart';
import '../services/export_service.dart';
import '../services/saf_workspace.dart';
import '../services/workspace_fs.dart';
import '../services/workspace_probe.dart';
import '../widgets/file_editor_dialog.dart';

class ExplorerScreen extends StatefulWidget {
  final String workingDir;
  final Function(String relativePath, String content) onFileSelected;
  final Function(String exportContent, String label)? onBatchExportLoaded;
  final VoidCallback onRefreshRequested;

  const ExplorerScreen({
    super.key,
    required this.workingDir,
    required this.onFileSelected,
    this.onBatchExportLoaded,
    required this.onRefreshRequested,
  });

  @override
  State<ExplorerScreen> createState() => ExplorerScreenState();
}

class ExplorerScreenState extends State<ExplorerScreen> {
  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _createNameController = TextEditingController();
  List<TreeNode> _rootNodes = [];
  bool _isLoading = false;
  String _filterQuery = '';

  bool _showHidden = false;

  /// Set when a folder could not be read, so the UI can explain why a project
  /// looks empty instead of silently rendering nothing.
  String? _scanError;

  bool _isSelectionMode = false;
  final Set<String> _selectedPaths = <String>{};

  @override
  void initState() {
    super.initState();
    _loadDirectoryTree();
    _searchController.addListener(() {
      setState(() {
        _filterQuery = _searchController.text.trim().toLowerCase();
      });
    });
  }

  @override
  void didUpdateWidget(covariant ExplorerScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.workingDir != widget.workingDir) {
      _selectedPaths.clear();
      _isSelectionMode = false;
      _loadDirectoryTree();
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _createNameController.dispose();
    super.dispose();
  }

  Future<void> refresh() async {
    await _loadDirectoryTree();
  }

  Future<void> _loadDirectoryTree() async {
    if (widget.workingDir.isEmpty) {
      setState(() {
        _rootNodes = [];
      });
      return;
    }

    if (!await WorkspaceFs.exists(widget.workingDir)) {
      setState(() {
        _rootNodes = [];
      });
      return;
    }

    setState(() {
      _isLoading = true;
    });

    final requestedDir = widget.workingDir;
    try {
      final nodes = await _scanChildren(requestedDir, 0);
      // Discard results for a directory the user has already navigated away
      // from, otherwise a slow scan can overwrite a newer tree.
      if (mounted && widget.workingDir == requestedDir) {
        setState(() {
          _rootNodes = nodes;
          _isLoading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<List<TreeNode>> _scanChildren(String dirPath, int depth) async {
    final nodes = <TreeNode>[];

    try {
      // WorkspaceFs handles both normal paths and granted SAF trees, so the
      // explorer works on a folder selected through the system picker.
      final entries = await WorkspaceFs.listDirectory(dirPath);
      for (final entry in entries) {
        if (!_showHidden && entry.name.startsWith('.')) continue;
        nodes.add(TreeNode(
          fullPath: entry.path,
          name: entry.name,
          isDirectory: entry.isDirectory,
          depth: depth,
        ));
      }
      if (mounted && _scanError != null) {
        setState(() => _scanError = null);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _scanError = 'Cannot read ${p.basename(dirPath)}: ${_describeError(e)}';
        });
      }
    }

    nodes.sort((a, b) {
      if (a.isDirectory && !b.isDirectory) return -1;
      if (!a.isDirectory && b.isDirectory) return 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });

    return nodes;
  }

  String _describeError(Object error) {
    final text = error.toString();
    if (text.contains('errno = 13') || text.contains('Permission denied')) {
      return 'permission denied by Android (scoped storage)';
    }
    if (text.contains('errno = 2')) return 'no longer exists';
    return error is FileSystemException ? error.message : text;
  }

  /// Walks up to find the first folder that actually exposes files.
  ///
  /// A project inside /storage/emulated/0/Download is invisible to dart:io on
  /// Android 11+; only a granted SAF tree can read it. This tells the user that
  /// directly instead of letting them wonder where the files went.
  Future<void> _diagnoseEmptyView() async {
    final problems = await WorkspaceProbe.diagnose(widget.workingDir);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF111827),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: Color(0xFF1E293B)),
        ),
        title: const Row(
          children: [
            Icon(Icons.info_outline_rounded, color: Color(0xFF818CF8), size: 18),
            SizedBox(width: 8),
            Text(
              'Why is this empty?',
              style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Text(
            problems.isEmpty
                ? 'This folder really is empty.'
                : problems.map((e) => '• $e').join('\n\n'),
            style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 12.5, height: 1.4),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close', style: TextStyle(color: Color(0xFF94A3B8))),
          ),
        ],
      ),
    );
  }

  Future<void> _toggleFolder(TreeNode node) async {
    if (!node.isDirectory) return;

    if (node.isExpanded) {
      setState(() {
        node.isExpanded = false;
      });
    } else {
      if (node.children == null) {
        final children = await _scanChildren(node.fullPath, node.depth + 1);
        node.children = children;
      }
      setState(() {
        node.isExpanded = true;
      });
    }
  }

  void _expandAll() {
    void expandRecursive(List<TreeNode> nodes) {
      for (final n in nodes) {
        if (n.isDirectory) {
          n.isExpanded = true;
          if (n.children != null) {
            expandRecursive(n.children!);
          }
        }
      }
    }

    setState(() {
      expandRecursive(_rootNodes);
    });
  }

  void _collapseAll() {
    void collapseRecursive(List<TreeNode> nodes) {
      for (final n in nodes) {
        if (n.isDirectory) {
          n.isExpanded = false;
          if (n.children != null) {
            collapseRecursive(n.children!);
          }
        }
      }
    }

    setState(() {
      collapseRecursive(_rootNodes);
    });
  }

  Future<void> _toggleNodeSelection(TreeNode node) async {
    final isSelected = _selectedPaths.contains(node.fullPath);
    setState(() {
      _isSelectionMode = true;
    });

    if (isSelected) {
      _deselectRecursively(node.fullPath);
    } else {
      await _selectRecursively(node.fullPath, node.isDirectory);
    }

    if (_selectedPaths.isEmpty) {
      setState(() {
        _isSelectionMode = false;
      });
    }
  }

  Future<void> _selectRecursively(String targetPath, bool isDir) async {
    await _collectRecursive(targetPath, isDir, _selectedPaths);
    if (mounted) setState(() {});
  }

  void _deselectRecursively(String targetPath) {
    final normTarget = p.normalize(targetPath);
    _selectedPaths.remove(normTarget);

    final prefix = normTarget.endsWith(p.separator) ? normTarget : '$normTarget${p.separator}';
    _selectedPaths.removeWhere((item) => item.startsWith(prefix));

    if (mounted) setState(() {});
  }

  /// Selects every node with a single tree walk and a single rebuild.
  ///
  /// The previous implementation awaited a full recursive directory listing
  /// per root entry and called setState for each one, which froze the UI on
  /// large workspaces.
  Future<void> _selectAll() async {
    setState(() {
      _isSelectionMode = true;
    });

    final collected = <String>{};
    for (final node in _rootNodes) {
      await _collectRecursive(node.fullPath, node.isDirectory, collected);
    }

    if (!mounted) return;
    setState(() {
      _selectedPaths
        ..clear()
        ..addAll(collected);
    });
  }

  Future<void> _collectRecursive(String targetPath, bool isDir, Set<String> into) async {
    final normalized = WorkspaceFs.isSaf(targetPath)
        ? targetPath
        : p.normalize(targetPath);
    into.add(normalized);
    if (!isDir) return;
    try {
      final entries = await WorkspaceFs.listDirectory(normalized, recursive: true);
      for (final entry in entries) {
        if (_showHidden || !entry.name.startsWith('.')) {
          into.add(WorkspaceFs.isSaf(entry.path) ? entry.path : p.normalize(entry.path));
        }
      }
    } catch (_) {}
  }

  void _clearSelection() {
    setState(() {
      _selectedPaths.clear();
      _isSelectionMode = false;
    });
  }

  Future<void> _exportSelected() async {
    if (_selectedPaths.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No files or folders selected to export'),
          backgroundColor: Color(0xFF1E293B),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(
        child: CircularProgressIndicator(color: Color(0xFF818CF8)),
      ),
    );

    final exportText = await ExportService.generateBatchExport(
      rootDir: widget.workingDir,
      selectedPaths: _selectedPaths,
    );

    if (mounted) Navigator.pop(context);

    if (!mounted) return;
    _showExportResultDialog(exportText);
  }

  void _showExportResultDialog(String exportText) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0F1523),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: Color(0xFF1E293B)),
        ),
        title: const Row(
          children: [
            Icon(Icons.ios_share_rounded, color: Color(0xFF34D399), size: 18),
            SizedBox(width: 8),
            Text(
              'Batch Export Preview',
              style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          height: 250,
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFF070B14),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFF1E293B)),
            ),
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              child: SelectableText(
                exportText.isEmpty ? '// No files found to export' : exportText,
                style: const TextStyle(
                  color: Color(0xFFCBD5E1),
                  fontFamily: 'monospace',
                  fontSize: 12,
                  height: 1.35,
                ),
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close', style: TextStyle(color: Color(0xFF94A3B8))),
          ),
          if (widget.onBatchExportLoaded != null)
            TextButton.icon(
              onPressed: () {
                Navigator.pop(ctx);
                widget.onBatchExportLoaded!(exportText, '${_selectedPaths.length} exported file(s)');
                _clearSelection();
              },
              icon: const Icon(Icons.send_rounded, size: 14),
              label: const Text('Load into Runner'),
              style: TextButton.styleFrom(foregroundColor: const Color(0xFF818CF8)),
            ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF10B981),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: exportText));
              if (ctx.mounted) Navigator.pop(ctx);
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Batch export copied to clipboard!'),
                    backgroundColor: Color(0xFF10B981),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              }
              _clearSelection();
            },
            icon: const Icon(Icons.copy_rounded, size: 15, color: Colors.white),
            label: const Text('Copy Text', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  List<TreeNode> _flattenVisibleNodes(List<TreeNode> nodes) {
    final result = <TreeNode>[];

    for (final node in nodes) {
      if (_filterQuery.isNotEmpty) {
        if (_nodeOrDescendantMatches(node, _filterQuery)) {
          result.add(node);
          if (node.isDirectory && node.children != null) {
            result.addAll(_flattenVisibleNodes(node.children!));
          }
        }
      } else {
        result.add(node);
        if (node.isDirectory && node.isExpanded && node.children != null) {
          result.addAll(_flattenVisibleNodes(node.children!));
        }
      }
    }

    return result;
  }

  bool _nodeOrDescendantMatches(TreeNode node, String query) {
    if (node.name.toLowerCase().contains(query)) return true;
    if (node.isDirectory && node.children != null) {
      for (final child in node.children!) {
        if (_nodeOrDescendantMatches(child, query)) return true;
      }
    }
    return false;
  }

  Future<void> _handleFileTap(TreeNode node) async {
    if (_isSelectionMode) {
      await _toggleNodeSelection(node);
      return;
    }

    if (node.isDirectory) {
      await _toggleFolder(node);
      return;
    }

    await showDialog(
      context: context,
      builder: (ctx) => FileEditorDialog(
        filePath: node.fullPath,
        workingDir: widget.workingDir,
        onSaved: () {
          _loadDirectoryTree();
        },
        onSendToRunner: (content) {
          final relPath = p.relative(node.fullPath, from: widget.workingDir);
          widget.onFileSelected(relPath, content);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Loaded "${node.name}" into Runner Editor'),
              backgroundColor: const Color(0xFF6366F1),
              behavior: SnackBarBehavior.floating,
            ),
          );
        },
      ),
    );
  }

  void _showCreateDialog() {
    _createNameController.clear();
    bool isFolder = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF111827),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: const BorderSide(color: Color(0xFF1E293B)),
          ),
          title: const Text(
            'Create New Item',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  ChoiceChip(
                    label: const Text('File'),
                    selected: !isFolder,
                    selectedColor: const Color(0xFF6366F1),
                    // onSelected reports the chip's *new* selected state, so
                    // "File" being selected means isFolder must be false.
                    onSelected: (val) => setDialogState(() => isFolder = !val),
                  ),
                  const SizedBox(width: 8),
                  ChoiceChip(
                    label: const Text('Folder'),
                    selected: isFolder,
                    selectedColor: const Color(0xFF6366F1),
                    onSelected: (val) => setDialogState(() => isFolder = val),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _createNameController,
                autofocus: true,
                style: const TextStyle(color: Colors.white, fontFamily: 'monospace', fontSize: 12.5),
                decoration: InputDecoration(
                  hintText: isFolder ? 'folder_name' : 'index.html',
                  hintStyle: const TextStyle(color: Color(0xFF475569)),
                  filled: true,
                  fillColor: const Color(0xFF090D16),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: Color(0xFF1E293B)),
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
                final name = _createNameController.text.trim();
                if (name.isNotEmpty) {
                  final target = WorkspaceFs.isSaf(widget.workingDir)
                      ? '${widget.workingDir}/$name'
                      : p.join(widget.workingDir, name);
                  if (isFolder) {
                    await WorkspaceFs.createDirectory(target);
                  } else {
                    await WorkspaceFs.writeString(target, '');
                  }
                  await _loadDirectoryTree();
                }
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('Create', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFileIcon(TreeNode node) {
    if (node.isDirectory) {
      return Icon(
        node.isExpanded ? Icons.folder_open_rounded : Icons.folder_rounded,
        size: 16,
        color: const Color(0xFFF59E0B),
      );
    }

    final ext = node.extension;
    switch (ext) {
      case 'html':
      case 'htm':
        return const Icon(Icons.html_rounded, size: 16, color: Color(0xFFF97316));
      case 'py':
        return const Icon(Icons.code_rounded, size: 16, color: Color(0xFF38BDF8));
      case 'dart':
        return const Icon(Icons.flutter_dash, size: 16, color: Color(0xFF0284C7));
      case 'json':
        return const Icon(Icons.data_object_rounded, size: 16, color: Color(0xFF22D3EE));
      case 'csv':
        return const Icon(Icons.table_chart_rounded, size: 16, color: Color(0xFF34D399));
      case 'md':
        return const Icon(Icons.description_rounded, size: 16, color: Color(0xFF60A5FA));
      case 'sh':
        return const Icon(Icons.terminal_rounded, size: 16, color: Color(0xFFA78BFA));
      case 'png':
      case 'jpg':
      case 'jpeg':
      case 'gif':
      case 'webp':
        return const Icon(Icons.image_rounded, size: 16, color: Color(0xFF10B981));
      default:
        return const Icon(Icons.insert_drive_file_outlined, size: 16, color: Color(0xFF94A3B8));
    }
  }

  @override
  Widget build(BuildContext context) {
    final visibleNodes = _flattenVisibleNodes(_rootNodes);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFF0F1523),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF1E293B)),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Column(
              children: [
                if (_isSelectionMode)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          InkWell(
                            onTap: _clearSelection,
                            child: const Padding(
                              padding: EdgeInsets.all(4.0),
                              child: Icon(Icons.close_rounded, size: 18, color: Color(0xFF94A3B8)),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '${_selectedPaths.length} selected',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12.5,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      Row(
                        children: [
                          TextButton(
                            onPressed: _selectAll,
                            style: TextButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              padding: const EdgeInsets.symmetric(horizontal: 8),
                            ),
                            child: const Text('All', style: TextStyle(color: Color(0xFF818CF8), fontSize: 12)),
                          ),
                          const SizedBox(width: 4),
                          ElevatedButton.icon(
                            onPressed: _exportSelected,
                            icon: const Icon(Icons.ios_share_rounded, size: 13, color: Colors.white),
                            label: const Text('Export', style: TextStyle(color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.bold)),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF6366F1),
                              visualDensity: VisualDensity.compact,
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                            ),
                          ),
                        ],
                      ),
                    ],
                  )
                else
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.account_tree_outlined, size: 16, color: Color(0xFF818CF8)),
                          SizedBox(width: 6),
                          Text(
                            'FILE EXPLORER',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              letterSpacing: 0.8,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      Row(
                        children: [
                          _buildSmallIconButton(
                            icon: _showHidden
                                ? Icons.visibility_rounded
                                : Icons.visibility_off_outlined,
                            tooltip: _showHidden ? 'Hide dotfiles' : 'Show dotfiles',
                            onTap: () async {
                              setState(() => _showHidden = !_showHidden);
                              await _loadDirectoryTree();
                            },
                          ),
                          const SizedBox(width: 5),
                          _buildSmallIconButton(
                            icon: Icons.unfold_more,
                            tooltip: 'Expand All',
                            onTap: _expandAll,
                          ),
                          const SizedBox(width: 5),
                          _buildSmallIconButton(
                            icon: Icons.unfold_less,
                            tooltip: 'Collapse All',
                            onTap: _collapseAll,
                          ),
                          const SizedBox(width: 5),
                          _buildSmallIconButton(
                            icon: Icons.add,
                            tooltip: 'Add File/Folder',
                            onTap: _showCreateDialog,
                            isPrimary: true,
                          ),
                        ],
                      ),
                    ],
                  ),
                const SizedBox(height: 8),
                Container(
                  height: 36,
                  decoration: BoxDecoration(
                    color: const Color(0xFF080C16),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFF1E293B)),
                  ),
                  child: TextField(
                    controller: _searchController,
                    style: const TextStyle(color: Colors.white, fontSize: 12.5),
                    decoration: const InputDecoration(
                      isDense: true,
                      prefixIcon: Icon(Icons.search, size: 16, color: Color(0xFF64748B)),
                      hintText: 'Filter files or folders...',
                      hintStyle: TextStyle(color: Color(0xFF64748B), fontSize: 12),
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.symmetric(vertical: 8),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFF0C111E),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFF1E293B)),
              ),
              child: Column(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: const BoxDecoration(
                      border: Border(bottom: BorderSide(color: Color(0xFF1E293B))),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.storage_rounded, size: 14, color: Color(0xFF64748B)),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            widget.workingDir.isEmpty ? '/...' : widget.workingDir,
                            style: const TextStyle(
                              color: Color(0xFF94A3B8),
                              fontFamily: 'monospace',
                              fontSize: 11.5,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        InkWell(
                          onTap: _loadDirectoryTree,
                          child: const Icon(Icons.refresh, size: 15, color: Color(0xFF64748B)),
                        ),
                      ],
                    ),
                  ),
                  if (_scanError != null)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      color: const Color(0xFF3F1D1D),
                      child: Row(
                        children: [
                          const Icon(Icons.lock_outline_rounded, size: 14, color: Color(0xFFFCA5A5)),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _scanError!,
                              style: const TextStyle(color: Color(0xFFFCA5A5), fontSize: 11.5),
                            ),
                          ),
                          InkWell(
                            onTap: _diagnoseEmptyView,
                            child: const Text(
                              'Details',
                              style: TextStyle(
                                color: Color(0xFFF87171),
                                fontSize: 11.5,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  Expanded(
                    child: _isLoading
                        ? const Center(
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Color(0xFF818CF8),
                            ),
                          )
                        : visibleNodes.isEmpty
                            ? Center(
                                child: Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        widget.workingDir.isEmpty
                                            ? 'Select a working directory in Runner'
                                            : 'Directory is empty',
                                        textAlign: TextAlign.center,
                                        style: const TextStyle(
                                          color: Color(0xFF64748B),
                                          fontSize: 12,
                                        ),
                                      ),
                                      if (widget.workingDir.isNotEmpty) ...[
                                        const SizedBox(height: 10),
                                        TextButton.icon(
                                          onPressed: _diagnoseEmptyView,
                                          icon: const Icon(Icons.help_outline_rounded, size: 15),
                                          label: const Text(
                                            'Why is this empty?',
                                            style: TextStyle(fontSize: 12),
                                          ),
                                          style: TextButton.styleFrom(
                                            foregroundColor: const Color(0xFF818CF8),
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              )
                            : ListView.builder(
                                physics: const BouncingScrollPhysics(),
                                itemCount: visibleNodes.length,
                                itemBuilder: (ctx, index) {
                                  final node = visibleNodes[index];
                                  return _buildTreeItemRow(node);
                                },
                              ),
                  ),
                ],
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFF111728),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFF312E81)),
            ),
            child: Row(
              children: [
                const Icon(Icons.touch_app_rounded, size: 15, color: Color(0xFF818CF8)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _isSelectionMode
                        ? 'Select files/folders and tap "Export" to generate batch script.'
                        : 'Tap any file to view, edit, or render HTML! Long-press to select.',
                    style: const TextStyle(
                      color: Color(0xFFC7D2FE),
                      fontSize: 11.5,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTreeItemRow(TreeNode node) {
    const double indentSize = 16.0;
    final isSelected = _selectedPaths.contains(node.fullPath);

    return InkWell(
      onTap: () => _handleFileTap(node),
      onLongPress: () => _toggleNodeSelection(node),
      child: Container(
        color: isSelected ? const Color(0xFF6366F1).withValues(alpha: 0.16) : Colors.transparent,
        padding: EdgeInsets.only(
          left: 10.0 + (node.depth * indentSize),
          right: 10.0,
          top: 5.0,
          bottom: 5.0,
        ),
        child: Row(
          children: [
            if (_isSelectionMode) ...[
              GestureDetector(
                onTap: () => _toggleNodeSelection(node),
                child: Padding(
                  padding: const EdgeInsets.only(right: 6.0),
                  child: Icon(
                    isSelected ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded,
                    size: 16,
                    color: isSelected ? const Color(0xFF818CF8) : const Color(0xFF475569),
                  ),
                ),
              ),
            ],
            if (node.depth > 0 && !_isSelectionMode)
              Container(
                width: 1,
                height: 14,
                color: const Color(0xFF1E293B),
                margin: const EdgeInsets.only(right: 6),
              ),
            if (node.isDirectory)
              GestureDetector(
                onTap: () => _toggleFolder(node),
                child: Padding(
                  padding: const EdgeInsets.only(right: 4.0),
                  child: Icon(
                    node.isExpanded
                        ? Icons.keyboard_arrow_down_rounded
                        : Icons.keyboard_arrow_right_rounded,
                    size: 15,
                    color: const Color(0xFF64748B),
                  ),
                ),
              )
            else
              const SizedBox(width: 12),
            _buildFileIcon(node),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                node.name,
                style: TextStyle(
                  color: isSelected
                      ? Colors.white
                      : (node.isDirectory ? const Color(0xFFE2E8F0) : const Color(0xFFCBD5E1)),
                  fontFamily: 'monospace',
                  fontSize: 12.5,
                  fontWeight: node.isDirectory ? FontWeight.w600 : FontWeight.normal,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSmallIconButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    bool isPrimary = false,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: isPrimary ? const Color(0xFF6366F1) : const Color(0xFF1E293B),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Icon(
            icon,
            size: 15,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}