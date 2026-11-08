import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../services/storage_service.dart';

class DirectoryPickerDialog extends StatefulWidget {
  final String initialPath;

  const DirectoryPickerDialog({
    super.key,
    required this.initialPath,
  });

  @override
  State<DirectoryPickerDialog> createState() => _DirectoryPickerDialogState();
}

class _DirectoryPickerDialogState extends State<DirectoryPickerDialog> {
  late String _currentPath;
  final TextEditingController _pathInputController = TextEditingController();
  final TextEditingController _newFolderController = TextEditingController();
  List<Directory> _subDirectories = [];
  bool _isLoading = false;
  bool _hasBroadAccess = true;

  final List<String> _shortcuts = [
    '/storage/emulated/0',
    '/sdcard',
    '/storage/emulated/0/projects',
    '/storage/emulated/0/Download',
    '/storage/emulated/0/Documents',
  ];

  Future<void> _bootstrap() async {
    final hasAccess = await StorageService.hasBroadStorageAccess();

    String startPath = widget.initialPath.trim();
    if (startPath.isEmpty || !Directory(startPath).existsSync()) {
      startPath = await StorageService.defaultWorkspaceDir();
    }

    if (!mounted) return;
    setState(() => _hasBroadAccess = hasAccess);
    _loadDirectories(startPath);
  }

  Future<void> _promptForBroadAccess() async {
    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF111827),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: Color(0xFF1E293B)),
        ),
        title: const Text(
          'Allow access to all files?',
          style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
        ),
        content: const Text(
          'DevRunner can already create, edit and push projects inside its own '
          'workspace without any permission.\n\n'
          'To work on folders elsewhere on the device (Downloads, an existing '
          'project, an SD card), Android requires "All files access". You will be '
          'taken to a system settings screen to approve it.',
          style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12.5, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Not now', style: TextStyle(color: Color(0xFF94A3B8))),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Open settings', style: TextStyle(color: Color(0xFF818CF8))),
          ),
        ],
      ),
    );

    if (proceed != true) return;

    final granted = await StorageService.requestAllFilesAccess();
    if (!granted) {
      await StorageService.openAppSettingsPage();
    }
    final hasAccess = await StorageService.hasBroadStorageAccess();
    if (!mounted) return;
    setState(() => _hasBroadAccess = hasAccess);
    if (!hasAccess) {
      await _loadDirectories(await StorageService.defaultWorkspaceDir());
    }
  }

  Future<void> _jumpToDefaultWorkspace() async {
    final dir = await StorageService.defaultWorkspaceDir();
    await _loadDirectories(dir);
  }

  late final AppLifecycleListener _lifecycleListener;

  @override
  void initState() {
    super.initState();
    _currentPath = Directory.current.path;
    _pathInputController.text = _currentPath;

    // "All files access" is granted in a system settings screen; when the user
    // comes back, re-check rather than assuming the grant did not happen.
    _lifecycleListener = AppLifecycleListener(
      onResume: () async {
        if (!mounted) return;
        final access = await StorageService.refreshAllFilesAccess();
        if (mounted && access != _hasBroadAccess) {
          setState(() => _hasBroadAccess = access);
          if (access) await _loadDirectories(_currentPath);
        }
      },
    );

    // Deliberately no permission request here: opening the picker must not
    // trigger a system dialog. Access is requested only from the explicit
    // "grant access" action below.
    _bootstrap();
  }

  @override
  void dispose() {
    _lifecycleListener.dispose();
    _pathInputController.dispose();
    _newFolderController.dispose();
    super.dispose();
  }

  Future<void> _loadDirectories(String path) async {
    setState(() {
      _isLoading = true;
      _currentPath = path;
      _pathInputController.text = path;
    });

    final dir = Directory(path);
    if (!await dir.exists()) {
      setState(() {
        _subDirectories = [];
        _isLoading = false;
      });
      return;
    }

    try {
      final entries = await dir.list(followLinks: false).toList();
      final dirs = entries.whereType<Directory>().where((d) {
        final name = p.basename(d.path);
        return !name.startsWith('.');
      }).toList();

      dirs.sort((a, b) => p.basename(a.path).toLowerCase().compareTo(p.basename(b.path).toLowerCase()));

      if (mounted) {
        setState(() {
          _subDirectories = dirs;
          _isLoading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _subDirectories = [];
          _isLoading = false;
        });
      }
    }
  }

  void _goUp() {
    final parent = p.dirname(_currentPath);
    if (parent.isNotEmpty && parent != _currentPath) {
      _loadDirectories(parent);
    }
  }

  void _promptCreateFolder() {
    _newFolderController.clear();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF111827),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: Color(0xFF1E293B)),
        ),
        title: const Text('New Folder', style: TextStyle(color: Colors.white, fontSize: 16)),
        content: TextField(
          controller: _newFolderController,
          autofocus: true,
          style: const TextStyle(color: Colors.white, fontFamily: 'monospace', fontSize: 13),
          decoration: InputDecoration(
            hintText: 'folder_name',
            hintStyle: const TextStyle(color: Color(0xFF475569)),
            filled: true,
            fillColor: const Color(0xFF090D16),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Color(0xFF1E293B)),
            ),
          ),
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
              final name = _newFolderController.text.trim();
              if (name.isNotEmpty) {
                final newDir = Directory(p.join(_currentPath, name));
                if (!await newDir.exists()) {
                  await newDir.create(recursive: true);
                }
                await _loadDirectories(_currentPath);
              }
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Create', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF0E1424),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Color(0xFF1E293B)),
      ),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.78,
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: Color(0xFF1E293B))),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.folder_shared_rounded, color: Color(0xFF818CF8), size: 20),
                      SizedBox(width: 8),
                      Text(
                        'Select Working Directory',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, color: Color(0xFF94A3B8), size: 20),
                    onPressed: () => Navigator.pop(context),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
            ),
            if (!_hasBroadAccess)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF111728),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0xFF312E81)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.lock_outline_rounded, size: 15, color: Color(0xFF818CF8)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: InkWell(
                          onTap: _promptForBroadAccess,
                          child: const Text(
                            'Only the app workspace is writable. Tap to allow access to all files.',
                            style: TextStyle(color: Color(0xFFC7D2FE), fontSize: 11.5, height: 1.3),
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: _jumpToDefaultWorkspace,
                        style: TextButton.styleFrom(
                          foregroundColor: const Color(0xFF818CF8),
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                        ),
                        child: const Text('Workspace', style: TextStyle(fontSize: 11.5)),
                      ),
                    ],
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
              child: Container(
                height: 40,
                decoration: BoxDecoration(
                  color: const Color(0xFF090D16),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFF1E293B)),
                ),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_upward_rounded, size: 18, color: Color(0xFF818CF8)),
                      tooltip: 'Up one level',
                      onPressed: _goUp,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 36),
                    ),
                    Expanded(
                      child: TextField(
                        controller: _pathInputController,
                        style: const TextStyle(
                          color: Color(0xFFE2E8F0),
                          fontFamily: 'monospace',
                          fontSize: 12,
                        ),
                        decoration: const InputDecoration(
                          border: InputBorder.none,
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(vertical: 10),
                        ),
                        onSubmitted: (val) {
                          if (val.trim().isNotEmpty) {
                            _loadDirectories(val.trim());
                          }
                        },
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.arrow_forward_rounded, size: 18, color: Color(0xFF38BDF8)),
                      tooltip: 'Navigate',
                      onPressed: () => _loadDirectories(_pathInputController.text.trim()),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 36),
                    ),
                  ],
                ),
              ),
            ),
            SizedBox(
              height: 36,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                itemCount: _shortcuts.length,
                itemBuilder: (ctx, i) {
                  final shortcut = _shortcuts[i];
                  final name = p.basename(shortcut).isEmpty ? 'Root' : p.basename(shortcut);
                  final isSelected = _currentPath == shortcut;

                  return Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      label: Text(
                        name,
                        style: TextStyle(
                          fontSize: 11,
                          color: isSelected ? Colors.white : const Color(0xFF94A3B8),
                          fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                        ),
                      ),
                      selected: isSelected,
                      selectedColor: const Color(0xFF6366F1),
                      backgroundColor: const Color(0xFF111827),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                        side: BorderSide(
                          color: isSelected ? const Color(0xFF6366F1) : const Color(0xFF1E293B),
                        ),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      onSelected: (_) => _loadDirectories(shortcut),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 6),
            const Divider(height: 1, color: Color(0xFF1E293B)),
            Expanded(
              child: _isLoading
                  ? const Center(
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Color(0xFF818CF8),
                      ),
                    )
                  : _subDirectories.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(Icons.folder_off_outlined, size: 36, color: Color(0xFF475569)),
                              const SizedBox(height: 8),
                              const Text(
                                'No subdirectories found',
                                style: TextStyle(color: Color(0xFF64748B), fontSize: 13),
                              ),
                              const SizedBox(height: 10),
                              TextButton.icon(
                                onPressed: _promptCreateFolder,
                                icon: const Icon(Icons.add, size: 16),
                                label: const Text('Create Folder Here'),
                                style: TextButton.styleFrom(
                                  foregroundColor: const Color(0xFF818CF8),
                                ),
                              ),
                            ],
                          ),
                        )
                      : ListView.builder(
                          itemCount: _subDirectories.length,
                          physics: const BouncingScrollPhysics(),
                          itemBuilder: (ctx, i) {
                            final dir = _subDirectories[i];
                            final name = p.basename(dir.path);
                            return InkWell(
                              onTap: () => _loadDirectories(dir.path),
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                                decoration: const BoxDecoration(
                                  border: Border(bottom: BorderSide(color: Color(0xFF131B2E))),
                                ),
                                child: Row(
                                  children: [
                                    const Icon(Icons.folder_rounded, size: 20, color: Color(0xFFF59E0B)),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Text(
                                        name,
                                        style: const TextStyle(
                                          color: Color(0xFFE2E8F0),
                                          fontFamily: 'monospace',
                                          fontSize: 13,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    const Icon(Icons.chevron_right_rounded, size: 18, color: Color(0xFF475569)),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: const BoxDecoration(
                color: Color(0xFF090D16),
                border: Border(top: BorderSide(color: Color(0xFF1E293B))),
              ),
              child: Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: _promptCreateFolder,
                    icon: const Icon(Icons.create_new_folder_outlined, size: 16),
                    label: const Text('New Folder'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFFCBD5E1),
                      side: const BorderSide(color: Color(0xFF1E293B)),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () async {
                        final writable = await StorageService.canWriteTo(_currentPath);
                        if (!context.mounted) return;
                        if (!writable) {
                          final useWorkspace = await showDialog<bool>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              backgroundColor: const Color(0xFF111827),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                                side: const BorderSide(color: Color(0xFF7F1D1D)),
                              ),
                              title: const Text(
                                'This folder is not writable',
                                style: TextStyle(color: Colors.white, fontSize: 15),
                              ),
                              content: Text(
                                'DevRunner cannot write to\n$_currentPath\n\n'
                                'Android blocks app access here without "All files access". '
                                'Use the app workspace instead?',
                                style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12.5, height: 1.4),
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(ctx, false),
                                  child: const Text('Back', style: TextStyle(color: Color(0xFF94A3B8))),
                                ),
                                TextButton(
                                  onPressed: () => Navigator.pop(ctx, true),
                                  child: const Text('Use workspace', style: TextStyle(color: Color(0xFF818CF8))),
                                ),
                              ],
                            ),
                          );
                          if (useWorkspace == true) {
                            final dir = await StorageService.defaultWorkspaceDir();
                            if (context.mounted) Navigator.pop(context, dir);
                          }
                          return;
                        }
                        if (context.mounted) Navigator.pop(context, _currentPath);
                      },
                      icon: const Icon(Icons.check_rounded, size: 18, color: Colors.white),
                      label: const Text(
                        'Select Folder',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF6366F1),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        elevation: 0,
                      ),
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