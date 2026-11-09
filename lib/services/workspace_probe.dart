import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'saf_workspace.dart';

/// Directories that are never worth pushing and are usually enormous.
const Set<String> kIgnoredDirectoryNames = {
  '.git', '.dart_tool', 'build', 'node_modules', '.gradle', '.idea',
  '.vscode', '__pycache__', '.venv', 'venv', 'Pods', '.next', '.cache',
};

/// One file in a workspace, readable from `dart:io` or a granted SAF tree.
///
/// Scoped storage can expose *folder names* through `dart:io` while denying
/// access to the files inside them. For those, the platform channel is used to
/// read the bytes, so a real project can still be pushed.
class WorkspaceFile {
  final String path;
  final int size;

  const WorkspaceFile(this.path, {this.size = -1});

  String get name => p.basename(path);

  Future<int> length() async {
    if (size >= 0) return size;
    if (SafWorkspace.isSafPath(path)) {
      return (await readAsBytes()).length;
    }
    return File(path).length();
  }

  Future<Uint8List> readAsBytes() async {
    if (SafWorkspace.isSafPath(path)) {
      return await SafWorkspace.readFile(path) ?? Uint8List(0);
    }
    return File(path).readAsBytes();
  }

  Stream<List<int>> openRead() async* {
    if (SafWorkspace.isSafPath(path)) {
      yield await readAsBytes();
      return;
    }
    yield* File(path).openRead();
  }
}

/// Outcome of walking a workspace directory.
class WorkspaceScan {
  final List<WorkspaceFile> files;
  final int directoryCount;
  final int unreadableEntries;
  final int skippedIgnored;
  final List<String> errors;

  /// True when the files came from a granted SAF tree.
  final bool viaSaf;

  const WorkspaceScan({
    required this.files,
    required this.directoryCount,
    required this.unreadableEntries,
    required this.skippedIgnored,
    required this.errors,
    this.viaSaf = false,
  });

  static const WorkspaceScan empty = WorkspaceScan(
    files: [],
    directoryCount: 0,
    unreadableEntries: 0,
    skippedIgnored: 0,
    errors: [],
  );

  /// Folders are visible but their files are not readable.
  bool get looksLikePermissionProblem =>
      files.isEmpty && (directoryCount > 0 || unreadableEntries > 0);
}

/// Resolves paths, walks workspaces, and works around Android scoped storage.
class WorkspaceProbe {
  WorkspaceProbe._();

  static String canonical(String path) {
    try {
      return Directory(path).resolveSymbolicLinksSync();
    } catch (_) {
      return p.normalize(p.absolute(path));
    }
  }

  static bool isIgnored(String path) =>
      p.split(path).any((segment) => kIgnoredDirectoryNames.contains(segment));

  /// True when `path` lives in a directory Android already lets us read.
  static bool isAppOwnedPath(String path) {
    final normalized = canonical(path);
    return normalized.contains('/Android/data/') ||
        normalized.contains('/Android/media/') ||
        normalized.contains('/Android/obb/');
  }

  /// Walks [root] with plain `dart:io`, surviving individual failures.
  static Future<WorkspaceScan> scan(
    String root, {
    int maxFiles = 5000,
    Set<String>? specificPaths,
  }) async {
    // SAF trees are readable regardless of scoped storage, so use them first.
    if (SafWorkspace.isSafPath(root)) {
      return scanSaf(root, maxFiles: maxFiles);
    }

    final files = <WorkspaceFile>[];
    final errors = <String>[];
    var directoryCount = 0;
    var unreadable = 0;
    var skippedIgnored = 0;

    Future<void> walk(Directory dir, int depth) async {
      if (files.length >= maxFiles || depth > 32) return;
      try {
        await for (final entity in dir.list(followLinks: false)) {
          if (files.length >= maxFiles) return;
          if (entity is Link) continue;

          if (entity is Directory) {
            if (isIgnored(entity.path)) {
              skippedIgnored++;
              continue;
            }
            directoryCount++;
            await walk(entity, depth + 1);
          } else if (entity is File) {
            if (isIgnored(entity.path)) {
              skippedIgnored++;
              continue;
            }
            files.add(WorkspaceFile(entity.path));
          }
        }
      } catch (e) {
        unreadable++;
        if (errors.length < 3) {
          errors.add('${p.basename(dir.path)}: ${describeError(e)}');
        }
      }
    }

    if (specificPaths != null && specificPaths.isNotEmpty) {
      for (final raw in specificPaths) {
        if (await File(raw).exists()) {
          if (!isIgnored(raw)) files.add(WorkspaceFile(raw));
        } else if (await Directory(raw).exists()) {
          directoryCount++;
          await walk(Directory(raw), 0);
        }
      }
      return WorkspaceScan(
        files: files,
        directoryCount: directoryCount,
        unreadableEntries: unreadable,
        skippedIgnored: skippedIgnored,
        errors: errors,
      );
    }

    final rootDir = Directory(root);
    if (!await rootDir.exists()) {
      return const WorkspaceScan(
        files: [],
        directoryCount: 0,
        unreadableEntries: 0,
        skippedIgnored: 0,
        errors: ['Root directory does not exist'],
      );
    }

    directoryCount++;
    await walk(rootDir, 0);

    return WorkspaceScan(
      files: files,
      directoryCount: directoryCount,
      unreadableEntries: unreadable,
      skippedIgnored: skippedIgnored,
      errors: errors,
    );
  }

  /// Walks a granted SAF tree.
  ///
  /// No permission check is involved: a persisted `OPEN_DOCUMENT_TREE` grant
  /// is full read/write access to that folder for as long as the user keeps it.
  static Future<WorkspaceScan> scanSaf(String root, {int maxFiles = 5000}) async {
    // If the folder cannot even be described, the grant was revoked or the
    // folder was deleted. Fail fast instead of walking a dead tree.
    if (root != SafWorkspace.virtualRoot) {
      final rootInfo = await SafWorkspace.describe(root);
      if (rootInfo == null) {
        return const WorkspaceScan(
          files: [],
          directoryCount: 0,
          unreadableEntries: 1,
          skippedIgnored: 0,
          errors: ['The granted folder is no longer accessible. Pick it again.'],
          viaSaf: true,
        );
      }
    }

    final rows = await SafWorkspace.listFiles(root, maxFiles: maxFiles);
    final files = <WorkspaceFile>[];
    var skippedIgnored = 0;

    for (final row in rows) {
      final path = row['path'] as String?;
      if (path == null) continue;
      if (isIgnored(path)) {
        skippedIgnored++;
        continue;
      }
      files.add(WorkspaceFile(path, size: (row['size'] as int?) ?? -1));
    }

    return WorkspaceScan(
      files: files,
      directoryCount: 1,
      unreadableEntries: 0,
      skippedIgnored: skippedIgnored,
      errors: const [],
      viaSaf: true,
    );
  }

  /// The scan a push should use.
  ///
  /// SAF trees are read directly; plain paths use `dart:io`.
  static Future<WorkspaceScan> scanForPush(String root, {int maxFiles = 5000}) async {
    if (SafWorkspace.isSafPath(root)) return scanSaf(root, maxFiles: maxFiles);
    return scan(root, maxFiles: maxFiles);
  }

  static String describeError(Object error) {
    final text = error.toString();
    if (error is FileSystemException) {
      if (text.contains('errno = 13')) return 'permission denied';
      if (text.contains('errno = 2')) return 'no longer exists';
      return error.message;
    }
    return text;
  }

  /// Explains what is wrong with [path] and what to do about it.
  ///
  /// Returns an empty list when the workspace is usable. The advice is now
  /// SAF-specific: there is no permission to grant, so the only remedy is to
  /// re-grant the folder (or use the app workspace).
  static Future<List<String>> diagnose(String path) async {
    final problems = <String>[];

    if (SafWorkspace.isSafPath(path)) {
      final scan = await scanSaf(path, maxFiles: 200);
      if (scan.files.isEmpty) {
        problems.add('The granted folder contains no readable files.');
      }
      return problems;
    }

    if (!await Directory(path).exists()) {
      problems.add('Directory does not exist: $path');
      return problems;
    }

    final direct = await scan(path, maxFiles: 200);
    if (direct.files.isNotEmpty) {
      problems.add(
        'This location is outside a granted folder. If files are missing, pick it '
        'again with "Pick a folder" so Android grants access.',
      );
      return problems;
    }

    if (!direct.looksLikePermissionProblem) {
      problems.add('No files found under $path.');
      return problems;
    }

    problems.add(
      'Android is showing ${direct.directoryCount} folder(s) here but hiding the '
      'files inside them. This location was not granted to DevRunner.',
    );
    problems.add(
      'Open the workspace picker and choose "Pick a folder", then select this '
      'folder. The grant is permanent and needs no storage permission.',
    );
    return problems;
  }
}
