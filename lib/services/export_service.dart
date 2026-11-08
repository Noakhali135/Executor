import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'file_types.dart';
import 'workspace_fs.dart';

class ExportService {
  static final String _tagActionCreate = '[' + 'ACTION]: CREATE_FILE';
  static final String _tagActionSkip = '[' + 'ACTION]: SKIP_BINARY';
  static final String _tagPath = '[' + 'PATH]: ';
  static final String _tagName = '[' + 'NAME]: ';
  static final String _tagContent = '[' + 'CONTENT]:';
  static final String _tagEndFile = '[' + 'ENDFILE]';

  static String formatSize(int bytes) => FileTypes.formatSize(bytes);

  static Future<bool> isBinaryFile(File file) => FileTypes.isBinary(file);

  static Future<String> generateBatchExport({
    required String rootDir,
    required Set<String> selectedPaths,
  }) async {
    // Gather (path -> size) for every file that will be exported.
    final filesToProcess = <String, int>{};

    for (final rawPath in selectedPaths) {
      final isSaf = WorkspaceFs.isSaf(rawPath);
      final normalized = isSaf ? rawPath : p.normalize(rawPath);

      final isDir = await WorkspaceFs.isDirectory(normalized);
      if (!isDir) {
        if (await WorkspaceFs.exists(normalized)) {
          filesToProcess[normalized] = await WorkspaceFs.length(normalized);
        }
        continue;
      }

      final entries = await WorkspaceFs.listDirectory(normalized, recursive: true);
      for (final entry in entries) {
        if (entry.isDirectory) continue;
        filesToProcess[entry.path] = entry.size;
      }
    }

    final sortedPaths = filesToProcess.keys.toList()..sort();
    final buffer = StringBuffer();

    for (int i = 0; i < sortedPaths.length; i++) {
      final fullPath = sortedPaths[i];

      final isSafPath = WorkspaceFs.isSaf(fullPath);
      final relPath = isSafPath
          ? _relativeSaf(fullPath, rootDir)
          : p.relative(fullPath, from: rootDir);

      String parentRel = p.dirname(relPath);
      if (parentRel == '.' || parentRel.isEmpty || parentRel == '/') {
        parentRel = '/';
      } else {
        if (!parentRel.startsWith('/')) parentRel = '/$parentRel';
        if (!parentRel.endsWith('/')) parentRel = '$parentRel/';
      }

      final fileName = isSafPath
          ? fullPath.split('/').last
          : p.basename(fullPath);

      if (i > 0) buffer.writeln();

      // Binary detection needs the extension list at minimum; SAF files are
      // classified by name because reading every byte twice is wasteful.
      final isBinary = isSafPath
          ? FileTypes.hasBinaryExtension(fullPath)
          : await FileTypes.isBinary(File(fullPath));

      if (isBinary) {
        final length = filesToProcess[fullPath] ?? 0;
        buffer.writeln(_tagActionSkip);
        buffer.writeln('$_tagPath$parentRel');
        buffer.writeln('$_tagName$fileName');
        buffer.writeln(_tagContent);
        buffer.writeln('Size ${FileTypes.formatSize(length)} (binary asset — not modified)');
        buffer.writeln(_tagEndFile);
        continue;
      }

      final content = await WorkspaceFs.readString(fullPath);
      if (content == null) {
        final length = filesToProcess[fullPath] ?? 0;
        buffer.writeln(_tagActionSkip);
        buffer.writeln('$_tagPath$parentRel');
        buffer.writeln('$_tagName$fileName');
        buffer.writeln(_tagContent);
        buffer.writeln('Size ${FileTypes.formatSize(length)} (unreadable — not modified)');
        buffer.writeln(_tagEndFile);
        continue;
      }

      buffer.writeln(_tagActionCreate);
      buffer.writeln('$_tagPath$parentRel');
      buffer.writeln('$_tagName$fileName');
      buffer.writeln(_tagContent);
      buffer.writeln(content);
      buffer.writeln(_tagEndFile);
    }

    return buffer.toString();
  }

  /// Relative path for a SAF file: strips the tree root prefix.
  static String _relativeSaf(String fullPath, String rootDir) {
    if (fullPath.startsWith('$rootDir/')) {
      return fullPath.substring(rootDir.length + 1);
    }
    // Fall back to the path below the tree id.
    final parts = fullPath.split('/');
    if (parts.length > 3) return parts.sublist(3).join('/');
    return fullPath;
  }
}
