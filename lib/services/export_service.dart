import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;

class ExportService {
  static final String _tagAction = '[' + 'ACTION]: CREATE_FILE';
  static final String _tagPath = '[' + 'PATH]: ';
  static final String _tagName = '[' + 'NAME]: ';
  static final String _tagContent = '[' + 'CONTENT]:';

  static const Set<String> _binaryExtensions = {
    'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'ico', 'svgz',
    'zip', 'apk', 'aab', 'tar', 'gz', 'rar', '7z', 'jar', 'exe',
    'dll', 'so', 'dylib', 'bin', 'dat', 'pdf', 'mp3', 'mp4', 'wav',
    'm4a', 'ogg', 'flac', 'ttf', 'otf', 'woff', 'woff2', 'class',
    'dex', 'iso', 'db', 'sqlite', 'aar',
  };

  static String formatSize(int bytes) {
    if (bytes < 1024) {
      return '${bytes}b';
    } else if (bytes < 1024 * 1024) {
      final kb = (bytes / 1024).round();
      return '${kb}kb';
    } else {
      final mb = (bytes / (1024 * 1024)).toStringAsFixed(1);
      return '${mb}mb';
    }
  }

  static Future<bool> isBinaryFile(File file) async {
    final ext = p.extension(file.path).replaceFirst('.', '').toLowerCase();
    if (_binaryExtensions.contains(ext)) {
      return true;
    }
    try {
      final stream = file.openRead(0, 1024);
      final bytes = await stream.first;
      if (bytes.contains(0)) {
        return true;
      }
    } catch (_) {}
    return false;
  }

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
      final isBinary = await isBinaryFile(file);

      String content;
      if (isBinary) {
        final length = await file.length();
        content = 'Size ${formatSize(length)}';
      } else {
        try {
          final bytes = await file.readAsBytes();
          content = utf8.decode(bytes, allowMalformed: true);
        } catch (_) {
          final length = await file.length();
          content = 'Size ${formatSize(length)}';
        }
      }

      if (i > 0) {
        buffer.writeln();
      }

      buffer.writeln(_tagAction);
      buffer.writeln('$_tagPath$parentRel');
      buffer.writeln('$_tagName$fileName');
      buffer.writeln(_tagContent);
      buffer.writeln(content);
    }

    return buffer.toString();
  }
}