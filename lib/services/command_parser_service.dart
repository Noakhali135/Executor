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
  static ParseResult parse(String rawInput) {
    final actions = <CommandAction>[];
    final errors = <String>[];

    if (rawInput.trim().isEmpty) {
      return const ParseResult(actions: [], errors: ['Input text is empty']);
    }

    String cleaned = rawInput;
    if (cleaned.contains('````text')) {
      final regex = RegExp(r'````text\s*([\s\S]*?)````');
      final matches = regex.allMatches(cleaned);
      if (matches.isNotEmpty) {
        cleaned = matches.map((m) => m.group(1) ?? '').join('\n\n');
      }
    } else if (cleaned.contains('````')) {
      final regex = RegExp(r'````\s*([\s\S]*?)````');
      final matches = regex.allMatches(cleaned);
      if (matches.isNotEmpty) {
        cleaned = matches.map((m) => m.group(1) ?? '').join('\n\n');
      }
    } else if (cleaned.contains('```')) {
      final regex = RegExp(r'```(?:text)?\s*([\s\S]*?)```');
      final matches = regex.allMatches(cleaned);
      if (matches.isNotEmpty) {
        cleaned = matches.map((m) => m.group(1) ?? '').join('\n\n');
      }
    }

    final lines = cleaned.split('\n');
    ActionType? currentType;
    String? currentPath;
    String? currentName;
    final contentBuffer = StringBuffer();
    bool readingContent = false;

    void flushAction() {
      if (currentType != null) {
        if (currentPath == null || currentPath!.trim().isEmpty) {
          errors.add('Missing [PATH] for action $currentType');
        } else if (currentName == null || currentName!.trim().isEmpty) {
          errors.add('Missing [NAME] for action $currentType');
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

      if (trimmed.startsWith('