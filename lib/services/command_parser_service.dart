import '../models/command_action.dart';

class ParseResult {
  final List<CommandAction> actions;
  final List<String> errors;

  const ParseResult({
    required this.actions,
    required this.errors,
  });

  bool get hasErrors => errors.isNotEmpty;
  bool get hasActions => actions.isNotEmpty;
}

class CommandParserService {
  static final String _tagAction = '[' + 'ACTION]:';
  static final String _tagPath = '[' + 'PATH]:';
  static final String _tagName = '[' + 'NAME]:';
  static final String _tagContent = '[' + 'CONTENT]:';

  static String _stripFences(String input) {
    final bt = String.fromCharCode(96);
    final fencePattern = RegExp(bt + r'{3,4}(?:text)?\s*([\s\S]*?)' + bt + r'{3,4}');
    final matches = fencePattern.allMatches(input);
    if (matches.isNotEmpty) {
      return matches.map((m) => m.group(1) ?? '').join('\n\n');
    }
    return input;
  }

  static ParseResult parse(String rawInput) {
    final actions = <CommandAction>[];
    final errors = <String>[];

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

    void flushAction() {
      if (currentType != null) {
        if (currentPath == null || currentPath!.trim().isEmpty) {
          errors.add('Missing path parameter for action ${currentType!.name}');
        } else if (currentName == null || currentName!.trim().isEmpty) {
          errors.add('Missing name parameter for action ${currentType!.name}');
        } else {
          String normalizedPath = currentPath!.trim();
          if (!normalizedPath.startsWith('/')) {
            normalizedPath = '/$normalizedPath';
          }
          if (!normalizedPath.endsWith('/')) {
            normalizedPath = '$normalizedPath/';
          }

          actions.add(CommandAction(
            type: currentType!,
            relativePath: normalizedPath,
            name: currentName!.trim(),
            content: currentType == ActionType.createFile
                ? contentBuffer.toString().trimRight()
                : '',
          ));
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
          default:
            errors.add('Unknown action type: $val on line ${i + 1}');
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
        readingContent = true;
        continue;
      }

      if (readingContent) {
        contentBuffer.writeln(line);
      }
    }

    flushAction();

    return ParseResult(actions: actions, errors: errors);
  }
}