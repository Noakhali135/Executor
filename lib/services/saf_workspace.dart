import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// A folder the user granted through the Storage Access Framework.
class SafTree {
  final String treeId;

  /// The path the rest of the app uses, e.g. `/devrunner-saf/primary:Download/app`.
  final String virtualPath;

  /// Human readable location, e.g. `Download/rou_is-Full-Project`.
  final String displayPath;

  const SafTree({
    required this.treeId,
    required this.virtualPath,
    required this.displayPath,
  });

  static SafTree? fromMap(Map<Object?, Object?>? map) {
    if (map == null) return null;
    final treeId = map['treeId'] as String?;
    final virtualPath = map['virtualPath'] as String?;
    if (treeId == null || virtualPath == null) return null;
    return SafTree(
      treeId: treeId,
      virtualPath: virtualPath,
      displayPath: (map['displayPath'] as String?) ?? treeId,
    );
  }
}

/// Storage Access Framework bridge.
///
/// A SAF grant is durable (it survives reboots and app updates), requires no
/// storage permission, and is exempt from Android 11+ scoped storage — which is
/// exactly what a project folder in `Download/` needs.
///
/// Granted trees are exposed to the app as virtual paths under
/// `/devrunner-saf/<treeId>/...`, so the explorer, executor, exporter and GitHub
/// push all keep working on ordinary path strings.
class SafWorkspace {
  SafWorkspace._();

  static const String virtualRoot = '/devrunner-saf';
  static const MethodChannel _channel = MethodChannel('devrunner/native');

  static bool isSafPath(String path) => path.startsWith('$virtualRoot/');

  /// Splits a virtual path into its opaque tree segment and relative remainder.
  ///
  /// The segment is an encoded document id, **not** a human readable name and
  /// not comparable to [SafTree.treeId]; compare [SafTree.virtualPath] instead.
  static ({String segment, String relative}) split(String path) {
    final rest = path.substring(virtualRoot.length + 1);
    final slash = rest.indexOf('/');
    if (slash < 0) return (segment: rest, relative: '');
    return (segment: rest.substring(0, slash), relative: rest.substring(slash + 1));
  }

  /// True when [path] belongs to [tree].
  static bool belongsTo(String path, SafTree tree) =>
      isSafPath(path) && split(path).segment == split(tree.virtualPath).segment;

  /// Opens the system folder picker. Returns null when the user cancels.
  static Future<SafTree?> pickDirectory() async {
    try {
      final map = await _channel.invokeMethod<Map<Object?, Object?>>('pickDirectory');
      return SafTree.fromMap(map);
    } on PlatformException {
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Trees granted previously (persisted across restarts).
  static Future<List<SafTree>> grantedTrees() async {
    try {
      final list = await _channel.invokeListMethod<Map<Object?, Object?>>('listGrantedTrees');
      return (list ?? const [])
          // listGrantedTrees includes virtualPath; SafTree.fromMap needs it.
          .map(SafTree.fromMap)
          .whereType<SafTree>()
          .toList();
    } catch (_) {
      return const [];
    }
  }

  static Future<void> forgetTree(String treeId) async {
    try {
      await _channel.invokeMethod('forgetTree', {'treeId': treeId});
    } catch (_) {}
  }

  /// Lists every file below [path] (recursively; SAF trees are expanded natively).
  static Future<List<Map<String, Object?>>> listFiles(
    String path, {
    int maxFiles = 5000,
  }) async {
    try {
      final rows = await _channel.invokeListMethod<Map<Object?, Object?>>(
        'listSafFiles',
        {'path': path, 'maxFiles': maxFiles},
      );
      return (rows ?? const [])
          .map((row) => <String, Object?>{
                'path': row['path'] as String?,
                'size': (row['size'] as num?)?.toInt() ?? 0,
              })
          .where((row) => row['path'] != null)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  static Future<Uint8List?> readFile(String path) async {
    try {
      return await _channel.invokeMethod<Uint8List>('readSafFile', {'path': path});
    } catch (_) {
      return null;
    }
  }

  static Future<bool> writeFile(String path, List<int> bytes) async {
    try {
      final ok = await _channel.invokeMethod<bool>(
        'writeSafFile',
        {'path': path, 'bytes': Uint8List.fromList(bytes)},
      );
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Name/isDirectory/size for one virtual path, or null when unreadable.
  static Future<Map<String, Object?>?> describe(String path) async {
    try {
      final map = await _channel.invokeMethod<Map<Object?, Object?>>(
        'safDescribe',
        {'path': path},
      );
      if (map == null) return null;
      return <String, Object?>{
        'name': map['name'] as String? ?? p.basename(path),
        'isDirectory': (map['isDirectory'] as num?)?.toInt() == 1,
        'size': (map['size'] as num?)?.toInt() ?? 0,
      };
    } catch (_) {
      return null;
    }
  }

  /// Convenience for the executor: write a text file through SAF.
  static Future<bool> writeString(String path, String content) =>
      writeFile(path, Uint8List.fromList(content.codeUnits));

  /// Convenience for the explorer/editor: read a text file through SAF.
  static Future<String?> readString(String path) async {
    final bytes = await readFile(path);
    if (bytes == null) return null;
    return String.fromCharCodes(bytes);
  }

  /// Direct children of a folder, for the explorer tree.
  static Future<List<Map<String, Object?>>> listChildren(String path) async {
    try {
      final rows = await _channel.invokeListMethod<Map<Object?, Object?>>(
        'listSafChildren',
        {'path': path},
      );
      return (rows ?? const [])
          .map((row) => <String, Object?>{
                'path': row['path'] as String?,
                'name': row['name'] as String?,
                'isDirectory': (row['isDirectory'] as num?)?.toInt() == 1,
                'size': (row['size'] as num?)?.toInt() ?? 0,
              })
          .where((row) => row['path'] != null)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  static Future<bool> createDirectory(String path) async {
    try {
      return await _channel.invokeMethod<bool>('createSafDirectory', {'path': path}) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> delete(String path) async {
    try {
      return await _channel.invokeMethod<bool>('deleteSafPath', {'path': path}) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// True when [path] is a SAF path whose tree is still granted.
  static Future<bool> isAccessible(String path) async {
    if (!isSafPath(path)) return false;
    if (path == virtualRoot) return true;
    return await describe(path) != null;
  }

  /// A stable, human readable label for any workspace path.
  static String displayLabel(String path, List<SafTree> trees) {
    if (!isSafPath(path)) return path;
    final parts = split(path);
    for (final tree in trees) {
      if (belongsTo(path, tree)) {
        return parts.relative.isEmpty
            ? tree.displayPath
            : '${tree.displayPath}/${parts.relative}';
      }
    }
    return path;
  }
}

/// Human readable label for any workspace path.
///
/// SAF workspaces live at a virtual path; this turns them into something a
/// person can read, e.g. `Download/rou_is-Full-Project`.
Future<String> workspaceLabel(String path, {List<SafTree>? trees}) async {
  if (path.isEmpty) return 'No folder selected';
  if (!SafWorkspace.isSafPath(path)) return path;

  final parts = SafWorkspace.split(path);
  final granted = trees ?? await SafWorkspace.grantedTrees();

  for (final tree in granted) {
    if (!SafWorkspace.belongsTo(path, tree)) continue;
    return parts.relative.isEmpty
        ? tree.displayPath
        : '${tree.displayPath}/${parts.relative}';
  }
  // No matching grant (revoked, or the platform could not decode it).
  return 'Granted folder (unavailable)';
}
