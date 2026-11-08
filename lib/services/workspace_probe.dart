import 'dart:io';
import 'package:path/path.dart' as p;

/// Directories that are never worth pushing and are usually enormous.
const Set<String> kIgnoredDirectoryNames = {
  '.git', '.dart_tool', 'build', 'node_modules', '.gradle', '.idea',
  '.vscode', '__pycache__', '.venv', 'venv', 'Pods', '.next', '.cache',
};

/// Outcome of walking a workspace directory.
class WorkspaceScan {
  final List<File> files;
  final int directoryCount;
  final int unreadableEntries;
  final int skippedIgnored;

  /// First few human readable errors, for the terminal log.
  final List<String> errors;

  const WorkspaceScan({
    required this.files,
    required this.directoryCount,
    required this.unreadableEntries,
    required this.skippedIgnored,
    required this.errors,
  });

  static const WorkspaceScan empty = WorkspaceScan(
    files: [],
    directoryCount: 0,
    unreadableEntries: 0,
    skippedIgnored: 0,
    errors: [],
  );

  /// The signature of a storage-permission problem rather than an empty
  /// workspace: folders are visible but their files are not.
  ///
  /// Scoped storage on Android 11+ will happily list directory entries for a
  /// location the app cannot read, so a project looks "there" in the explorer
  /// (only folders show up) while a push finds zero files.
  bool get looksLikePermissionProblem =>
      files.isEmpty && (directoryCount > 0 || unreadableEntries > 0);
}

/// Resolves a path without throwing, returning null when it is unreadable.
class WorkspaceProbe {
  WorkspaceProbe._();

  /// Canonicalises [path].
  ///
  /// `/storage/emulated/0` is a FUSE view; comparing a resolved path against a
  /// non-resolved one can falsely report "outside the root", so both sides of
  /// every comparison go through here first.
  static String canonical(String path) {
    try {
      final resolved = Directory(path).resolveSymbolicLinksSync();
      return resolved;
    } catch (_) {
      return p.normalize(p.absolute(path));
    }
  }

  /// Walks [root] collecting readable files.
  ///
  /// Unlike `Directory.list(recursive: true).toList()`, a failure on one entry
  /// does not abort the whole walk: each directory is visited in its own
  /// try/catch and failures are counted. That matters on Android, where a
  /// single inaccessible subdirectory used to make an entire project look
  /// empty.
  static Future<WorkspaceScan> scan(
    String root, {
    int maxFiles = 5000,
    Set<String>? specificPaths,
  }) async {
    final files = <File>[];
    final errors = <String>[];
    int directoryCount = 0;
    int unreadable = 0;
    int skippedIgnored = 0;

    bool isIgnored(String path) =>
        p.split(path).any((segment) => kIgnoredDirectoryNames.contains(segment));

    Future<void> walk(Directory dir, int depth) async {
      if (files.length >= maxFiles || depth > 32) return;
      try {
        await for (final entity in dir.list(followLinks: false)) {
          if (files.length >= maxFiles) return;

          // Symlinks are skipped: following them can escape the workspace or
          // loop forever.
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
            files.add(entity);
          }
        }
      } catch (e) {
        unreadable++;
        if (errors.length < 3) {
          errors.add('${p.basename(dir.path)}: ${_describe(e)}');
        }
        // Keep going: a sibling directory may still be readable.
      }
    }

    if (specificPaths != null && specificPaths.isNotEmpty) {
      for (final raw in specificPaths) {
        final file = File(raw);
        final dir = Directory(raw);
        if (await file.exists()) {
          if (!isIgnored(raw)) files.add(file);
        } else if (await dir.exists()) {
          directoryCount++;
          await walk(dir, 0);
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

    directoryCount++; // the root itself
    await walk(rootDir, 0);

    return WorkspaceScan(
      files: files,
      directoryCount: directoryCount,
      unreadableEntries: unreadable,
      skippedIgnored: skippedIgnored,
      errors: errors,
    );
  }

  static String _describe(Object error) {
    final text = error.toString();
    if (error is FileSystemException) {
      if (text.contains('errno = 13')) return 'permission denied';
      if (text.contains('errno = 2')) return 'no longer exists';
      return error.message;
    }
    return text;
  }

  /// Probes whether [path] is a usable workspace and explains what is wrong.
  ///
  /// Returns an empty list when everything looks fine.
  static Future<List<String>> diagnose(String path) async {
    final problems = <String>[];
    final dir = Directory(path);

    if (!await dir.exists()) {
      problems.add('Directory does not exist: $path');
      return problems;
    }

    final scan = await scan(path, maxFiles: 200);

    if (scan.looksLikePermissionProblem) {
      problems.add(
        'Android is letting DevRunner see ${scan.directoryCount} folder(s) here '
        'but not the files inside them, so a push would upload nothing.',
      );
      problems.add(
        'This is scoped storage: /storage/emulated/0/Download is only fully '
        'readable with "All files access". Grant it from the directory picker '
        '(tap the banner), or copy the project into the DevRunner workspace and '
        'work there.',
      );
    } else if (scan.files.isEmpty) {
      problems.add('No files found under $path.');
    }

    for (final error in scan.errors) {
      problems.add('Unreadable: $error');
    }

    return problems;
  }
}
