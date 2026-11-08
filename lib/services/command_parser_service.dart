import '../models/command_action.dart';
import 'path_guard.dart';

class ParseResult {
  final List<CommandAction> actions;
  final List<String> errors;
  final List<String> warnings;

  const ParseResult({
    required this.actions,
    required this.errors,
    this.warnings = const [],
  });

  bool get hasErrors => errors.isNotEmpty;
  bool get hasActions => actions.isNotEmpty;
}

/// Parses the DevRunner batch format:
///
/// ```
/// [ACTION]: CREATE_FILE
/// [PATH]: /lib/
/// [NAME]: main.dart
/// [CONTENT]:
/// <verbatim file body>
/// [ENDFILE]
/// ```
///
/// Supported action types: CREATE_FILE, DELETE_FILE, CREATE_FOLDER,
/// DELETE_FOLDER, SKIP_BINARY.
class CommandParserService {
  static final String _tagAction = '[' + 'ACTION]:';
  static final String _tagPath = '[' + 'PATH]:';
  static final String _tagName = '[' + 'NAME]:';
  static final String _tagContent = '[' + 'CONTENT]:';
  static final String _tagEndFile = '[' + 'ENDFILE]';
  static final String _tagRest = '[' + 'REST]:';

  /// Removes markdown code fences from the outside of the input.
  ///
  /// Only fences that wrap the *whole* payload are removed. The previous
  /// implementation joined every fenced block and dropped everything outside
  /// them, which silently discarded real content when a file body happened to
  /// contain its own fence.
  static String _stripFences(String input) {
    final bt = String.fromCharCode(96);
    final fencePattern = RegExp(
      '^\\s*' + bt + '{3,4}(?:text|dart|js|html|json|sh)?\\s*\\n([\\s\\S]*?)\\n?\\s*' + bt + '{3,4}\\s*\$',
    );
    final match = fencePattern.firstMatch(input);
    return match != null ? (match.group(1) ?? '') : input;
  }

  /// Drops exactly the newline that the encoder appended to the last line.
  ///
  /// `content.trimRight()` used to be used here, which destroyed meaningful
  /// trailing newlines and trailing spaces. Removing a single terminator makes
  /// export -> parse a lossless round trip (including CRLF line endings).
  static String _dropEncoderNewline(String content) {
    if (content.endsWith('\n')) return content.substring(0, content.length - 1);
    return content;
  }

  static ParseResult parse(String rawInput) {
    final actions = <CommandAction>[];
    final errors = <String>[];
    final warnings = <String>[];

    if (rawInput.trim().isEmpty) {
      return const ParseResult(actions: [], errors: ['Input text is empty']);
    }

    final cleaned = _stripFences(rawInput);
    final lines = cleaned.split('\n');

    ActionType? currentType;
    String? currentPath;
    String? currentName;
    final contentBuffer = StringBuffer();
    bool readingContent = false;
    bool ignoringRest = false;

    void flushAction() {
      if (currentType != null) {
        final type = currentType!;
        final name = (currentName ?? '').trim();
        final path = (currentPath ?? '').trim();

        if (path.isEmpty) {
          errors.add('Missing [PATH] parameter for action ${type.name}');
        } else if (name.isEmpty) {
          errors.add('Missing [NAME] parameter for action ${type.name}');
        } else {
          final nameError = PathGuard.validateName(name);
          if (nameError != null) {
            errors.add('Invalid [NAME] "${name}" for ${type.name}: $nameError');
          } else {
            String normalizedPath = path.replaceAll(r'\', '/');
            if (!normalizedPath.startsWith('/')) normalizedPath = '/$normalizedPath';
            if (!normalizedPath.endsWith('/')) normalizedPath = '$normalizedPath/';

            actions.add(CommandAction(
              type: type,
              relativePath: normalizedPath,
              name: name,
              content: type == ActionType.createFile
                  ? _dropEncoderNewline(contentBuffer.toString())
                  : '',
            ));
          }
        }
      }
      currentType = null;
      currentPath = null;
      currentName = null;
      contentBuffer.clear();
      readingContent = false;
    }

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];
      final trimmed = line.trim();

      // Everything after a [REST]: marker belongs to prose (typically an AI's
      // commentary appended after the last file). Without this boundary the
      // trailing text was appended to the final file's contents.
      if (trimmed == _tagRest) {
        flushAction();
        ignoringRest = true;
        continue;
      }
      if (ignoringRest) continue;

      if (trimmed == _tagEndFile) {
        flushAction();
        continue;
      }

      if (trimmed.startsWith(_tagAction)) {
        flushAction();
        final val = trimmed.substring(_tagAction.length).trim().toUpperCase();
        switch (val) {
          case 'CREATE_FILE':
            currentType = ActionType.createFile;
            break;
          case 'DELETE_FILE':
            currentType = ActionType.deleteFile;
            break;
          case 'CREATE_FOLDER':
            currentType = ActionType.createFolder;
            break;
          case 'DELETE_FOLDER':
            currentType = ActionType.deleteFolder;
            break;
          case 'SKIP_BINARY':
            currentType = ActionType.skipBinary;
            break;
          default:
            errors.add('Unknown action type: "$val" on line ${i + 1}');
        }
        continue;
      }

      if (!readingContent && trimmed.startsWith(_tagPath)) {
        currentPath = trimmed.substring(_tagPath.length).trim();
        continue;
      }

      if (!readingContent && trimmed.startsWith(_tagName)) {
        currentName = trimmed.substring(_tagName.length).trim();
        continue;
      }

      if (!readingContent && trimmed.startsWith(_tagContent)) {
        // Guard against a file whose first line is itself the tag: treat the
        // remainder of the tag line as the beginning of the body.
        final inline = trimmed.substring(_tagContent.length).trim();
        readingContent = true;
        if (inline.isNotEmpty) contentBuffer.writeln(inline);
        continue;
      }

      if (readingContent) {
        contentBuffer.writeln(line);
      }
    }

    flushAction();

    if (currentPath != null && PathGuard.containsTraversal(currentPath!)) {
      warnings.add('[PATH] "$currentPath" contains ".." segments and will be rejected');
    }

    return ParseResult(
      actions: actions,
      errors: errors,
      warnings: warnings,
    );
  }
}
