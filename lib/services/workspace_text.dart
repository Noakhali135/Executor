import 'dart:convert';
import 'dart:typed_data';

/// UTF-8 conversion for anything that stores file text.
///
/// This lives in its own library for one reason: `workspace_fs.dart` imports
/// `saf_workspace.dart`, so `saf_workspace.dart` cannot import `workspace_fs`
/// back. A helper that both need has to sit below both of them.
///
/// The distinction that matters: `String.codeUnits` and `String.fromCharCodes`
/// are **UTF-16**, not bytes. Treating them as bytes truncates every character
/// above U+00FF, which turns Bengali into mojibake and eats emoji entirely.
class WorkspaceText {
  WorkspaceText._();

  /// Decodes UTF-8, tolerating a BOM and never throwing on bad input.
  ///
  /// [allowMalformed] is deliberate: a file with one corrupt byte should open
  /// with a replacement character, not crash the editor.
  static String decode(List<int> bytes) {
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      return utf8.decode(bytes.sublist(3), allowMalformed: true);
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  /// Encodes text as UTF-8 bytes, ready to write to disk or a SAF document.
  static Uint8List encode(String text) =>
      Uint8List.fromList(utf8.encode(text));
}
