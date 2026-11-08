import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../services/saf_workspace.dart';
import '../services/storage_service.dart';

/// Workspace chooser.
///
/// Storage Access Framework only: the user grants a folder through Android's
/// own picker and the grant is persisted, so no storage permission is ever
/// requested and no folder becomes unreadable after the fact. The app's private
/// workspace is offered as a second, equally permission-free option.
class WorkspacePickerSheet extends StatefulWidget {
  /// Currently selected workspace, shown as the active choice.
  final String currentPath;

  const WorkspacePickerSheet({super.key, required this.currentPath});

  @override
  State<WorkspacePickerSheet> createState() => _WorkspacePickerSheetState();
}

class _WorkspacePickerSheetState extends State<WorkspacePickerSheet> {
  List<SafTree> _trees = const [];
  String _appWorkspace = '';
  bool _isPicking = false;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final trees = await SafWorkspace.grantedTrees();
    final workspace = await StorageService.defaultWorkspaceDir();
    if (!mounted) return;
    setState(() {
      _trees = trees;
      _appWorkspace = workspace;
      _isLoading = false;
    });
  }

  Future<void> _pick() async {
    setState(() => _isPicking = true);
    final tree = await SafWorkspace.pickDirectory();
    if (!mounted) return;
    setState(() => _isPicking = false);

    if (tree == null) return;
    Navigator.pop(context, tree.virtualPath);
  }

  Future<void> _forget(SafTree tree) async {
    await SafWorkspace.forgetTree(tree.treeId);
    await _load();
  }

  bool _isActive(String path) =>
      path.isNotEmpty && p.equals(path, widget.currentPath);

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.of(context).size.height * 0.72;

    return SafeArea(
      child: Container(
        height: height,
        decoration: const BoxDecoration(
          color: Color(0xFF0E1424),
          borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
        ),
        child: Column(
          children: [
            _header(),
            const Divider(height: 1, color: Color(0xFF1E293B)),
            Expanded(
              child: _isLoading
                  ? const Center(
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Color(0xFF818CF8),
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                      children: [
                        _primaryAction(),
                        const SizedBox(height: 16),
                        if (_trees.isNotEmpty) ...[
                          _label('GRANTED FOLDERS'),
                          const SizedBox(height: 8),
                          ..._trees.map(_treeTile),
                          const SizedBox(height: 16),
                        ],
                        _label('APP WORKSPACE'),
                        const SizedBox(height: 8),
                        _appWorkspaceTile(),
                        const SizedBox(height: 16),
                        _explanation(),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 10, 12),
      child: Row(
        children: [
          const Icon(Icons.folder_open_rounded, color: Color(0xFF818CF8), size: 20),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              'Choose workspace',
              style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded, color: Color(0xFF94A3B8), size: 20),
            onPressed: () => Navigator.pop(context),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
        ],
      ),
    );
  }

  Widget _primaryAction() {
    return InkWell(
      onTap: _isPicking ? null : _pick,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          color: const Color(0xFF132033),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFF38BDF8)),
        ),
        child: Row(
          children: [
            _isPicking
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF38BDF8)),
                  )
                : const Icon(Icons.add_circle_outline_rounded,
                    color: Color(0xFF38BDF8), size: 20),
            const SizedBox(width: 12),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Pick a folder',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 13.5,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  SizedBox(height: 2),
                  Text(
                    'Opens Android\'s folder picker. Access is kept permanently — '
                    'no storage permission involved.',
                    style: TextStyle(color: Color(0xFF94A3B8), fontSize: 11.5, height: 1.3),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, color: Color(0xFF38BDF8), size: 20),
          ],
        ),
      ),
    );
  }

  Widget _label(String text) {
    return Text(
      text,
      style: const TextStyle(
        color: Color(0xFF64748B),
        fontSize: 10.5,
        letterSpacing: 0.9,
        fontWeight: FontWeight.w700,
      ),
    );
  }

  Widget _treeTile(SafTree tree) {
    final active = _isActive(tree.virtualPath);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: InkWell(
        onTap: () => Navigator.pop(context, tree.virtualPath),
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: active ? const Color(0xFF1B2540) : const Color(0xFF0F1523),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: active ? const Color(0xFF6366F1) : const Color(0xFF1E293B),
            ),
          ),
          child: Row(
            children: [
              const Icon(Icons.folder_special_rounded, size: 17, color: Color(0xFFF59E0B)),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tree.displayPath.isEmpty ? tree.treeId : tree.displayPath,
                      style: const TextStyle(
                        color: Color(0xFFE2E8F0),
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (active)
                      const Text(
                        'Currently open',
                        style: TextStyle(color: Color(0xFF818CF8), fontSize: 10.5),
                      ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Remove access',
                onPressed: () => _forget(tree),
                icon: const Icon(Icons.link_off_rounded, size: 16, color: Color(0xFF64748B)),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _appWorkspaceTile() {
    final active = _isActive(_appWorkspace);
    return InkWell(
      onTap: _appWorkspace.isEmpty ? null : () => Navigator.pop(context, _appWorkspace),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: active ? const Color(0xFF1B2540) : const Color(0xFF0F1523),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: active ? const Color(0xFF6366F1) : const Color(0xFF1E293B),
          ),
        ),
        child: Row(
          children: [
            const Icon(Icons.phone_android_rounded, size: 17, color: Color(0xFF38BDF8)),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'DevRunner workspace',
                    style: TextStyle(color: Color(0xFFE2E8F0), fontSize: 12),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _appWorkspace.isEmpty
                        ? 'Unavailable'
                        : 'Android/data/com.executor.executor/files/DevRunner',
                    style: const TextStyle(
                      color: Color(0xFF64748B),
                      fontSize: 10.5,
                      fontFamily: 'monospace',
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            if (active)
              const Padding(
                padding: EdgeInsets.only(left: 6),
                child: Icon(Icons.check_circle_rounded, size: 16, color: Color(0xFF818CF8)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _explanation() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF111728),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF1E293B)),
      ),
      child: const Text(
        'DevRunner only ever touches folders you grant it. A granted folder stays '
        'available after a reboot and can be revoked at any time above or in '
        'Android Settings → Apps → DevRunner.',
        style: TextStyle(color: Color(0xFF94A3B8), fontSize: 11.5, height: 1.4),
      ),
    );
  }
}
