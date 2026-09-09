import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../models/tree_node.dart';

class ExplorerScreen extends StatefulWidget {
  final String workingDir;
  final Function(String relativePath, String content) onFileSelected;
  final VoidCallback onRefreshRequested;

  const ExplorerScreen({
    super.key,
    required this.workingDir,
    required this.onFileSelected,
    required this.onRefreshRequested,
  });

  @override
  State<ExplorerScreen> createState() => ExplorerScreenState();
}

class ExplorerScreenState extends State<ExplorerScreen> {
  final TextEditingController _searchController = TextEditingController();
  List<TreeNode> _rootNodes = [];
  bool _isLoading = false;
  String _filterQuery = '';

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
      _loadDirectoryTree();
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
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

    final rootDir = Directory(widget.workingDir);
    if (!await rootDir.exists()) {
      setState(() {
        _rootNodes = [];
      });
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      final nodes = await _scanChildren(widget.workingDir, 0);
      if (mounted) {
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
    final dir = Directory(dirPath);
    if (!await dir.exists()) return [];

    try {
      final entries = await dir.list(followLinks: false).toList();
      final nodes = <TreeNode>[];

      for (final entity in entries) {
        final name = p.basename(entity.path);
        if (name.startsWith('.')) continue;

        final isDir = entity is Directory;
        nodes.add(TreeNode(
          fullPath: entity.path,
          name: name,
          isDirectory: isDir,
          depth: depth,
        ));
      }

      nodes.sort((a, b) {
        if (a.isDirectory && !b.isDirectory) return -1;
        if (!a.isDirectory && b.isDirectory) return 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });

      return nodes;
    } catch (_) {
      return [];
    }
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
    if (node.isDirectory) {
      await _toggleFolder(node);
      return;
    }

    try {
      final file = File(node.fullPath);
      final content = await file.readAsString();
      final relPath = p.relative(node.fullPath, from: widget.workingDir);
      widget.onFileSelected(relPath, content);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Loaded "${node.name}" into Editor'),
            duration: const Duration(milliseconds: 1400),
            backgroundColor: const Color(0xFF1E293B),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to read file: $e'),
            backgroundColor: const Color(0xFFDC2626),
          ),
        );
      }
    }
  }

  void _showCreateDialog() {
    final nameController = TextEditingController();
    bool isFolder = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF111827),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: Color(0xFF1E293B)),
          ),
          title: const Text(
            'Create New Item',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
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
              const SizedBox(height: 12),
              TextField(
                controller: nameController,
                autofocus: true,
                style: const TextStyle(color: Colors.white, fontFamily: 'monospace', fontSize: 13),
                decoration: InputDecoration(
                  hintText: isFolder ? 'folder_name' : 'script.py',
                  hintStyle: const TextStyle(color: Color(0xFF475569)),
                  filled: true,
                  fillColor: const Color(0xFF090D16),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
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
                final name = nameController.text.trim();
                if (name.isNotEmpty) {
                  final target = p.join(widget.workingDir, name);
                  if (isFolder) {
                    await Directory(target).create(recursive: true);
                  } else {
                    await File(target).writeAsString('');
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
        size: 18,
        color: const Color(0xFFF59E0B),
      );
    }

    final ext = node.extension;
    switch (ext) {
      case 'py':
        return const Icon(Icons.code_rounded, size: 18, color: Color(0xFF38BDF8));
      case 'json':
        return const Icon(Icons.data_object_rounded, size: 18, color: Color(0xFF22D3EE));
      case 'csv':
        return const Icon(Icons.table_chart_rounded, size: 18, color: Color(0xFF34D399));
      case 'md':
        return const Icon(Icons.description_rounded, size: 18, color: Color(0xFF60A5FA));
      case 'sh':
        return const Icon(Icons.terminal_rounded, size: 18, color: Color(0xFFA78BFA));
      default:
        return const Icon(Icons.insert_drive_file_outlined, size: 18, color: Color(0xFF94A3B8));
    }
  }

  @override
  Widget build(BuildContext context) {
    final visibleNodes = _flattenVisibleNodes(_rootNodes);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFF101626),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFF1E293B)),
            ),
            padding: const EdgeInsets.all(14),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.account_tree_outlined, size: 18, color: Color(0xFF818CF8)),
                        SizedBox(width: 8),
                        Text(
                          'FILE EXPLORER',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            letterSpacing: 1.0,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    Row(
                      children: [
                        _buildSmallIconButton(
                          icon: Icons.unfold_more,
                          tooltip: 'Expand All',
                          onTap: _expandAll,
                        ),
                        const SizedBox(width: 6),
                        _buildSmallIconButton(
                          icon: Icons.unfold_less,
                          tooltip: 'Collapse All',
                          onTap: _collapseAll,
                        ),
                        const SizedBox(width: 6),
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
                const SizedBox(height: 12),
                Container(
                  height: 40,
                  decoration: BoxDecoration(
                    color: const Color(0xFF090D16),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0xFF1E293B)),
                  ),
                  child: TextField(
                    controller: _searchController,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                    decoration: const InputDecoration(
                      isDense: true,
                      prefixIcon: Icon(Icons.search, size: 18, color: Color(0xFF64748B)),
                      hintText: 'Filter files or folders...',
                      hintStyle: TextStyle(color: Color(0xFF64748B), fontSize: 13),
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.symmetric(vertical: 10),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFF0C111E),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFF1E293B)),
              ),
              child: Column(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: const BoxDecoration(
                      border: Border(bottom: BorderSide(color: Color(0xFF1E293B))),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.storage_rounded, size: 16, color: Color(0xFF64748B)),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            widget.workingDir.isEmpty ? '/...' : widget.workingDir,
                            style: const TextStyle(
                              color: Color(0xFF94A3B8),
                              fontFamily: 'monospace',
                              fontSize: 12,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        InkWell(
                          onTap: _loadDirectoryTree,
                          child: const Icon(Icons.refresh, size: 16, color: Color(0xFF64748B)),
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
                                child: Text(
                                  widget.workingDir.isEmpty
                                      ? 'Select a working directory in Runner'
                                      : 'Directory is empty',
                                  style: const TextStyle(color: Color(0xFF64748B), fontSize: 13),
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
          padding: const EdgeInsets.all(16),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFF111728),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF312E81)),
            ),
            child: const Row(
              children: [
                Icon(Icons.info_outline_rounded, size: 16, color: Color(0xFF818CF8)),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Tap any file in the tree to load its content directly into the code editor!',
                    style: TextStyle(
                      color: Color(0xFFC7D2FE),
                      fontSize: 12,
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
    const double indentSize = 18.0;

    return InkWell(
      onTap: () => _handleFileTap(node),
      child: Container(
        padding: EdgeInsets.only(
          left: 12.0 + (node.depth * indentSize),
          right: 12.0,
          top: 7.0,
          bottom: 7.0,
        ),
        child: Row(
          children: [
            if (node.depth > 0)
              Container(
                width: 1,
                height: 16,
                color: const Color(0xFF1E293B),
                margin: const EdgeInsets.only(right: 8),
              ),
            if (node.isDirectory)
              Padding(
                padding: const EdgeInsets.only(right: 6.0),
                child: Icon(
                  node.isExpanded
                      ? Icons.keyboard_arrow_down_rounded
                      : Icons.keyboard_arrow_right_rounded,
                  size: 16,
                  color: const Color(0xFF64748B),
                ),
              )
            else
              const SizedBox(width: 14),
            _buildFileIcon(node),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                node.name,
                style: TextStyle(
                  color: node.isDirectory ? const Color(0xFFE2E8F0) : const Color(0xFFCBD5E1),
                  fontFamily: 'monospace',
                  fontSize: 13,
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
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: isPrimary ? const Color(0xFF6366F1) : const Color(0xFF1E293B),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            icon,
            size: 16,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}