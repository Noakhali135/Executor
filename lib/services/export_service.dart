import 'dart:io';
import 'package:path/path.dart' as p;
import 'file_types.dart';
import 'workspace_fs.dart';

class ExportService {
  static const String _openWrite = '<<<FILE_WRITE path="';
  static const String _end = '<<<END>>>';

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

      // The new format uses one project-relative path per block, so the
      // parent/name split is no longer needed.
      final relative = relPath.replaceAll(r'\', '/');
      if (relative.isEmpty || relative == '.') continue;

      if (buffer.isNotEmpty) buffer.writeln();

      // Binary detection needs the extension list at minimum; SAF files are
      // classified by name because reading every byte twice is wasteful.
      final isBinary = isSafPath
          ? FileTypes.hasBinaryExtension(fullPath)
          : await FileTypes.isBinary(File(fullPath));

      if (isBinary) {
        // Binary payloads cannot be expressed in this format, and emitting a
        // text placeholder would overwrite the real file with a few ASCII
        // bytes. Emit nothing and say so in the header instead.
        continue;
      }

      final content = await WorkspaceFs.readString(fullPath);
      if (content == null) continue;

      // The body is written verbatim. The newline after it exists only to put
      // <<<END>>> on its own line, and the parser excludes that one line
      // terminator, so file bodies round-trip exactly - including content that
      // ends with one or more newlines, and CRLF endings.
      buffer.write('$_openWrite$relative\">>>\n');
      buffer.write(content);
      buffer.write('\n$_end\n');
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
