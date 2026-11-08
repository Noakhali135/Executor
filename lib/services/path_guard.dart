import 'package:path/path.dart' as p;

import 'saf_workspace.dart';

/// Thrown whenever a requested path would escape the workspace root.
class UnsafePathException implements Exception {
  final String reason;
  final String attemptedPath;

  UnsafePathException(this.reason, {this.attemptedPath = ''});

  @override
  String toString() => attemptedPath.isEmpty
      ? 'UnsafePathException: $reason'
      : 'UnsafePathException: $reason ($attemptedPath)';
}

/// Central containment checks.
///
/// Every filesystem write/delete and every static-file response goes through
/// here so that a crafted script or HTTP request cannot reach outside the
/// directory the user explicitly selected.
class PathGuard {
  static const int maxNameLength = 255;

  /// Normalises a root directory to an absolute form without a trailing slash.
  static String normalizeRoot(String rootDir) {
    var root = p.normalize(p.absolute(rootDir));
    if (root.length > 1 && (root.endsWith('/') || root.endsWith(r'\'))) {
      root = root.substring(0, root.length - 1);
    }
    return root;
  }

  /// Returns true when [candidate] is strictly inside [root].
  ///
  /// The root itself is *not* considered inside, which prevents an action from
  /// replacing or deleting the workspace directory.
  static bool isInside(String root, String candidate) {
    // SAF trees are virtual paths; compare them with posix semantics so the
    // containment guarantee holds for granted folders as well.
    if (SafWorkspace.isSafPath(root)) {
      final r = _posixNormalize(root);
      final c = _posixNormalize(candidate);
      if (r == c) return false;
      return c.startsWith('$r/');
    }
    final r = normalizeRoot(root);
    final c = p.normalize(p.absolute(candidate));
    if (p.equals(r, c)) return false;
    return p.isWithin(r, c);
  }

  static String _posixNormalize(String path) {
    final parts = <String>[];
    for (final segment in path.replaceAll(r'\', '/').split('/')) {
      if (segment.isEmpty || segment == '.') continue;
      if (segment == '..') {
        if (parts.isNotEmpty) parts.removeLast();
        continue;
      }
      parts.add(segment);
    }
    return '/${parts.join('/')}';
  }

  /// Validates a single file/folder name coming from `[NAME]:`.
  ///
  /// Returns `null` when the name is safe, otherwise a human readable reason.
  static String? validateName(String name) {
    final value = name.trim();
    if (value.isEmpty) return 'Name is empty';
    if (value == '.' || value == '..') return 'Name "$value" is not allowed';
    if (value.contains('/')) return 'Name may not contain "/": $value';
    if (value.contains(r'\')) return 'Name may not contain "\\": $value';
    if (value.contains('\u0000')) return 'Name may not contain NUL bytes';
    if (p.isAbsolute(value)) return 'Name may not be an absolute path: $value';
    if (value.length > maxNameLength) {
      return 'Name exceeds $maxNameLength characters';
    }
    return null;
  }

  /// Resolves `relativePath + name` against [rootDir] and guarantees the
  /// result stays inside the workspace.
  ///
  /// Throws [UnsafePathException] for traversal attempts, absolute paths and
  /// invalid names.
  static String resolveInRoot(
    String rootDir, {
    required String relativePath,
    required String name,
  }) {
    final root = SafWorkspace.isSafPath(rootDir) ? rootDir : normalizeRoot(rootDir);

    final nameError = validateName(name);
    if (nameError != null) {
      throw UnsafePathException(nameError, attemptedPath: name);
    }

    if (SafWorkspace.isSafPath(rootDir)) {
      // Virtual SAF path: build it with posix join and verify containment.
      final cleaned = _cleanRelative(relativePath);
      final candidate = _posixNormalize(
        cleaned.isEmpty ? '$root/${name.trim()}' : '$root/$cleaned/${name.trim()}',
      );
      if (!isInside(root, candidate)) {
        throw UnsafePathException(
          'Path escapes the workspace root',
          attemptedPath: p.join(relativePath, name),
        );
      }
      return candidate;
    }

    final cleanedRelative = _cleanRelative(relativePath);
    final candidate = p.normalize(p.join(root, cleanedRelative, name.trim()));

    if (!isInside(root, candidate)) {
      throw UnsafePathException(
        'Path escapes the workspace root',
        attemptedPath: p.join(relativePath, name),
      );
    }
    return candidate;
  }

  /// Converts a user supplied `[PATH]:` value into a safe relative path.
  ///
  /// Leading/trailing separators are removed and any `.`/`..` segment is
  /// rejected rather than silently collapsed.
  static String _cleanRelative(String raw) {
    final replaced = raw.replaceAll(r'\', '/').trim();
    final parts = replaced
        .split('/')
        .where((segment) => segment.isNotEmpty && segment != '.')
        .toList();

    for (final part in parts) {
      if (part == '..') {
        throw UnsafePathException(
          'Path may not contain ".." segments',
          attemptedPath: raw,
        );
      }
      if (part.contains('\u0000')) {
        throw UnsafePathException(
          'Path may not contain NUL bytes',
          attemptedPath: raw,
        );
      }
    }
    return parts.isEmpty ? '' : p.joinAll(parts);
  }

  /// True when [path] contains a `..` segment (used for HTTP request paths).
  static bool containsTraversal(String path) {
    return path
        .replaceAll(r'\', '/')
        .split('/')
        .any((segment) => segment == '..');
  }
}
