import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'saf_workspace.dart';
import 'workspace_text.dart';

/// One filesystem operation surface for both plain paths and SAF trees.
///
/// Android 11+ refuses `dart:io` access to project folders in Download, but a
/// folder granted through the Storage Access Framework is fully readable. By
/// routing every call through here, the executor, exporter, editor, explorer
/// and GitHub push work on a SAF folder exactly like on a normal one.
class WorkspaceFs {
  WorkspaceFs._();

  static bool isSaf(String path) => SafWorkspace.isSafPath(path);

  /// A directory entry discovered by [listDirectory].
  static Future<List<WorkspaceEntry>> listDirectory(String dir, {bool recursive = false}) async {
    if (isSaf(dir)) {
      final rows = recursive
          ? await SafWorkspace.listFiles(dir)
          : await SafWorkspace.listChildren(dir);
      return rows
          .map((row) => WorkspaceEntry(
                path: row['path'] as String,
                name: (row['name'] as String?) ?? p.basename(row['path'] as String),
                isDirectory: (row['isDirectory'] as bool?) ?? false,
                size: (row['size'] as int?) ?? 0,
              ))
          .toList();
    }

    final out = <WorkspaceEntry>[];
    final directory = Directory(dir);
    if (!await directory.exists()) return out;

    try {
      await for (final entity in directory.list(
        recursive: recursive,
        followLinks: false,
      )) {
        if (entity is! File && entity is! Directory) continue;
        out.add(WorkspaceEntry(
          path: entity.path,
          name: p.basename(entity.path),
          isDirectory: entity is Directory,
          size: entity is File ? await entity.length() : 0,
        ));
      }
    } catch (_) {
      // A failure on one branch must not hide the rest.
    }
    return out;
  }

  static Future<bool> exists(String path) async {
    if (isSaf(path)) return path == SafWorkspace.virtualRoot || await SafWorkspace.describe(path) != null;
    return await File(path).exists() || await Directory(path).exists();
  }

  static Future<bool> isDirectory(String path) async {
    if (isSaf(path)) {
      if (path == SafWorkspace.virtualRoot) return true;
      final info = await SafWorkspace.describe(path);
      return info?['isDirectory'] == true;
    }
    return Directory(path).exists();
  }

  static Future<int> length(String path) async {
    if (isSaf(path)) {
      final info = await SafWorkspace.describe(path);
      return (info?['size'] as int?) ?? 0;
    }
    try {
      return await File(path).length();
    } catch (_) {
      return 0;
    }
  }

  static Future<Uint8List?> readBytes(String path) async {
    if (isSaf(path)) return SafWorkspace.readFile(path);
    try {
      return await File(path).readAsBytes();
    } catch (_) {
      return null;
    }
  }

  static Future<String?> readString(String path) async {
    final bytes = await readBytes(path);
    if (bytes == null) return null;
    // Must be UTF-8. String.fromCharCodes treats the bytes as UTF-16 code
    // units, which turns "হ্যালো" into mojibake and truncates every character
    // above U+00FF. A BOM is allowed: some editors write one.
    return decodeText(bytes);
  }

  static Future<bool> writeBytes(String path, List<int> bytes) async {
    if (isSaf(path)) return SafWorkspace.writeFile(path, bytes);
    try {
      final file = File(path);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes, flush: true);
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> writeString(String path, String content) =>
      // Must be UTF-8. content.codeUnits yields UTF-16 code units; storing
      // those as bytes truncates anything outside Latin-1.
      writeBytes(path, WorkspaceText.encode(content));

  /// Decodes UTF-8, tolerating a BOM and refusing to throw on bad input.
  static String decodeText(List<int> bytes) => WorkspaceText.decode(bytes);

  /// Copies one file, creating parents. Used by the pre-run backup.
  static Future<bool> copyFile(String from, String to) async {
    final bytes = await readBytes(from);
    if (bytes == null) return false;
    return writeBytes(to, bytes);
  }

  static Future<bool> createDirectory(String path) async {
    if (isSaf(path)) return SafWorkspace.createDirectory(path);
    try {
      await Directory(path).create(recursive: true);
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> delete(String path) async {
    if (isSaf(path)) return SafWorkspace.delete(path);
    try {
      final dir = Directory(path);
      if (await dir.exists()) {
        await dir.delete(recursive: true);
        return true;
      }
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
        return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Joins a SAF tree path with a relative action path and name.
  ///
  /// Traversal is rejected before the join, mirroring [PathGuard].
  static String joinSaf(String root, String relativePath, String name) {
    final cleanRelative = relativePath
        .replaceAll(r'\', '/')
        .split('/')
        .where((s) => s.isNotEmpty && s != '.')
        .toList();
    if (cleanRelative.any((s) => s == '..')) {
      throw ArgumentError('Path may not contain ".."');
    }
    return p.posix.joinAll([root, ...cleanRelative, name]);
  }
}

class WorkspaceEntry {
  final String path;
  final String name;
  final bool isDirectory;
  final int size;

  const WorkspaceEntry({
    required this.path,
    required this.name,
    required this.isDirectory,
    this.size = 0,
  });
}
