import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// A folder the user granted through the Storage Access Framework.
class SafTree {
  final String treeId;

  /// The opaque virtual path the rest of the app uses, e.g.
  /// `/devrunner-saf/cHJpbWFyeTpEb3dubG9hZC9hcHA`.
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

  /// Scan/hash progress events from the native side.
  ///
  /// `{type: scan, scanned, dirs}` while a tree is walked and
  /// `{type: hash, done, total}` while blob ids are computed.
  static Stream<Map<String, Object?>> get progress => _progress.receiveBroadcastStream()
      .map((event) => Map<String, Object?>.from(event as Map));

  static const EventChannel _progress = EventChannel('devrunner/saf_progress');

  /// Asks the native side to stop the current long operation.
  static Future<void> cancel() async {
    try {
      await _channel.invokeMethod('cancelSafOp');
    } catch (_) {}
  }

  /// Git blob SHA-1 for [paths], computed natively without moving the bytes.
  ///
  /// Returns `{path: sha}`; a null sha means the file could not be read.
  static Future<Map<String, String?>> hashFiles(List<String> paths) async {
    if (paths.isEmpty) return const {};
    final out = <String, String?>{};
    // Chunked so one huge list never becomes one huge channel message.
    const chunkSize = 1000;
    for (var i = 0; i < paths.length; i += chunkSize) {
      // clamp() returns num; sublist() requires int.
      final end = (i + chunkSize) < paths.length ? (i + chunkSize) : paths.length;
      final chunk = paths.sublist(i, end);
      try {
        // Large payloads are fine here (a mobile app, not a server), and this
        // is the difference between one channel round trip and one per file:
        // 144 files cost ~38s when hashed in small batches.
        final rows = await _channel.invokeListMethod<Map<Object?, Object?>>(
          'hashSafFiles',
          {'paths': chunk},
        );
        for (final row in rows ?? const <Map<Object?, Object?>>[]) {
          final path = row['path'] as String?;
          if (path == null) continue;
          final sha = row['sha'] as String?;
          // Native code returns "" for "could not hash"; normalise to null so
          // the caller uploads the file instead of comparing against "".
          out[path] = (sha == null || sha.isEmpty) ? null : sha;
        }
      } catch (_) {
        // Leave these unresolved; the caller treats a missing sha as changed.
      }
    }
    return out;
  }

  /// Lists every file below [path] (recursively; SAF trees are expanded natively).
  static Future<List<Map<String, Object?>>> listFiles(
    String path, {
    int maxFiles = 5000,
  }) async {
    final result = await listTree(path, maxFiles: maxFiles);
    return result.files;
  }

  /// Lists a tree and keeps the diagnosis, not just the files.
  ///
  /// The previous version only ever returned the file list, so "the walk could
  /// not open the folder" and "the folder really is empty" looked identical -
  /// which is how a perfectly good project got reported as having no readable
  /// files. [unreadable] and [errors] now say which one it was.
  static Future<SafTreeListing> listTree(
    String path, {
    int maxFiles = 5000,
  }) async {
    try {
      final raw = await _channel.invokeMapMethod<Object?, Object?>(
        'listSafFiles',
        {'path': path, 'maxFiles': maxFiles},
      );
      if (raw == null) {
        return const SafTreeListing(
          files: [],
          errors: ['The folder listing returned nothing. Pick the folder again.'],
          unreadable: 1,
        );
      }

      // Older native builds returned a bare list; accept both shapes so a
      // stale APK cannot break the scan.
      final rows = raw['files'];
      final list = rows is List ? rows : const [];
      final files = <Map<String, Object?>>[];
      for (final row in list) {
        if (row is! Map) continue;
        final filePath = row['path'] as String?;
        if (filePath == null) continue;
        files.add({
          'path': filePath,
          'size': (row['size'] as num?)?.toInt() ?? -1,
        });
      }

      final errors = <String>[];
      final rawErrors = raw['errors'];
      if (rawErrors is List) {
        for (final error in rawErrors) {
          if (error is String && error.isNotEmpty) errors.add(error);
        }
      }

      return SafTreeListing(
        files: files,
        directories: (raw['dirs'] as num?)?.toInt() ?? 0,
        unreadable: (raw['unreadable'] as num?)?.toInt() ?? 0,
        errors: errors,
        root: path,
      );
    } catch (e) {
      return SafTreeListing(
        files: const [],
        unreadable: 1,
        errors: ['Could not list the folder: $e'],
      );
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
  /// Reads a value that may arrive as `bool` or as a legacy `0`/`1`.
  static bool _asBool(Object? value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    return false;
  }

  static Future<Map<String, Object?>?> describe(String path) async {
    try {
      final map = await _channel.invokeMethod<Map<Object?, Object?>>(
        'safDescribe',
        {'path': path},
      );
      if (map == null) return null;
      return <String, Object?>{
        'name': map['name'] as String? ?? p.basename(path),
        // Native sends a boolean. Accepting only a number here meant this was
        // always false, so a real folder looked like a file.
        'isDirectory': _asBool(map['isDirectory']),
        'size': (map['size'] as num?)?.toInt() ?? -1,
      };
    } catch (_) {
      return null;
    }
  }

  /// Convenience for the executor: write a text file through SAF.
  ///
  /// UTF-8, not `codeUnits`. Code units are UTF-16: writing them as bytes drops
  /// the high byte of every character, so any non-Latin text was destroyed on
  /// save (Bengali became "¹Í¯¾²Ë", an emoji became a control character).
  static Future<bool> writeString(String path, String content) =>
      writeFile(path, Uint8List.fromList(utf8.encode(content)));

  /// Convenience for the explorer/editor: read a text file through SAF.
  static Future<String?> readString(String path) async {
    final bytes = await readFile(path);
    if (bytes == null) return null;
    return WorkspaceFs.decodeText(bytes);
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
                'isDirectory': _asBool(row['isDirectory']),
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

/// Result of walking a granted SAF tree.
class SafTreeListing {
  final List<Map<String, Object?>> files;
  final int directories;

  /// Folders that could not be opened at all.
  final int unreadable;

  /// Human-readable reasons, already stripped of the virtual path prefix.
  final List<String> errors;

  /// The exact path that was asked for, so callers can tell "this folder is
  /// empty" apart from "this folder's project is entirely in subfolders".
  final String root;

  const SafTreeListing({
    required this.files,
    this.directories = 0,
    this.unreadable = 0,
    this.errors = const [],
    this.root = '',
  });
}
