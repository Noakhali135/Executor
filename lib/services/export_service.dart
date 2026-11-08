import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'file_types.dart';

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
    final filesToProcess = <String, File>{};

    for (final rawPath in selectedPaths) {
      final normalized = p.normalize(rawPath);
      final f = File(normalized);
      final d = Directory(normalized);

      if (await f.exists()) {
        filesToProcess[normalized] = f;
      } else if (await d.exists()) {
        try {
          final subEntities = await d.list(recursive: true, followLinks: false).toList();
          for (final entity in subEntities) {
            if (entity is File) {
              filesToProcess[p.normalize(entity.path)] = entity;
            }
          }
        } catch (_) {}
      }
    }

    final sortedPaths = filesToProcess.keys.toList()..sort();
    final buffer = StringBuffer();

    for (int i = 0; i < sortedPaths.length; i++) {
      final fullPath = sortedPaths[i];
      final file = filesToProcess[fullPath]!;

      final relPath = p.relative(fullPath, from: rootDir);
      String parentRel = p.dirname(relPath);
      if (parentRel == '.' || parentRel.isEmpty) {
        parentRel = '/';
      } else {
        if (!parentRel.startsWith('/')) parentRel = '/$parentRel';
        if (!parentRel.endsWith('/')) parentRel = '$parentRel/';
      }

      final fileName = p.basename(fullPath);
      final isBinary = await FileTypes.isBinary(file);

      if (i > 0) buffer.writeln();

      // Binary payloads cannot survive a text round trip. Previously they were
      // exported as the literal text "Size 43kb", which the runner then wrote
      // over the real image. Emitting SKIP_BINARY keeps the file intact.
      if (isBinary) {
        final length = await file.length();
        buffer.writeln(_tagActionSkip);
        buffer.writeln('$_tagPath$parentRel');
        buffer.writeln('$_tagName$fileName');
        buffer.writeln('$_tagContent');
        buffer.writeln('Size ${FileTypes.formatSize(length)} (binary asset — not modified)');
        buffer.writeln(_tagEndFile);
        continue;
      }

      String content;
      try {
        final bytes = await file.readAsBytes();
        content = utf8.decode(bytes, allowMalformed: true);
      } catch (_) {
        // Declared text but unreadable: mark it as binary rather than
        // truncating the user's file on the next execute.
        final length = await file.length();
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
      // A single trailing newline is the body terminator; the parser removes
      // exactly this one so trailing blank lines inside the file survive.
      buffer.writeln(content);
      buffer.writeln(_tagEndFile);
    }

    return buffer.toString();
  }
}
