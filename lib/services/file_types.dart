import 'dart:io';
import 'package:path/path.dart' as p;

/// Single source of truth for "can this file be treated as text?".
///
/// Previously three different lists existed (export, editor, execution) and
/// they disagreed, which meant a batch export could silently replace a binary
/// file with a text placeholder. Everything now consults this class.
class FileTypes {
  FileTypes._();

  /// Raster formats that `Image.file` can decode. SVG is deliberately absent:
  /// it is XML text and is edited/exported as text.
  static const Set<String> imageExtensions = {
    'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'ico',
  };

  static const Set<String> binaryExtensions = {
    // archives / packages
    'zip', 'apk', 'aab', 'tar', 'gz', 'tgz', 'rar', '7z', 'jar', 'aar', 'whl',
    // executables / native
    'exe', 'dll', 'so', 'dylib', 'bin', 'dat', 'class', 'dex', 'o', 'a',
    // documents / media
    'pdf', 'mp3', 'mp4', 'm4a', 'wav', 'ogg', 'flac', 'aac', 'mov', 'avi',
    'mkv', 'heic', 'ttf', 'otf', 'woff', 'woff2', 'eot',
    // databases / disk images / other opaque blobs
    'iso', 'db', 'sqlite', 'sqlite3', 'realm', 'keystore', 'jks', 'p12',
  };

  static String extensionOf(String path) =>
      p.extension(path).replaceFirst('.', '').toLowerCase();

  static bool isImage(String path) => imageExtensions.contains(extensionOf(path));

  /// Extension-based check. Fast, but not authoritative — see [isBinary].
  static bool hasBinaryExtension(String path) =>
      binaryExtensions.contains(extensionOf(path));

  /// Authoritative check: extension list first, then a NUL-byte sniff.
  ///
  /// Only the first 1 KiB is read so a multi-gigabyte file costs nothing.
  static Future<bool> isBinary(File file) async {
    if (hasBinaryExtension(file.path)) return true;
    try {
      final length = await file.length();
      if (length == 0) return false;
      final stream = file.openRead(0, length < 1024 ? length : 1024);
      final bytes = await stream.first;
      return bytes.contains(0);
    } catch (_) {
      // Unreadable is treated as binary so we never corrupt it with text.
      return true;
    }
  }

  static String formatSize(int bytes) {
    // The SAF tree walk reports -1: asking the provider for each file's length
    // costs one query per file, so the size is only fetched when needed.
    if (bytes < 0) return '—';
    if (bytes < 1024) return '${bytes}b';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).round()}kb';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}mb';
  }
}
