import '../models/command_action.dart';
import 'path_guard.dart';

/// Text that betrays a truncated AI response.
///
/// The whole point of this format is that the model must send the complete
/// file. A block containing "rest of code unchanged" would otherwise overwrite
/// a real file with a comment, which is silent data loss.
class PlaceholderHit {
  final int line;
  final String text;

  const PlaceholderHit(this.line, this.text);

  @override
  String toString() => 'line $line: "$text"';
}

class ParseResult {
  final List<CommandAction> actions;
  final List<String> errors;
  final List<String> warnings;

  /// Every rejected block, numbered the same way the accepted ones are.
  final List<RejectionEntry> rejections;

  /// Number of `<<<` blocks seen, including malformed ones.
  final int blockCount;

  /// Character count of the input, reported in the header line.
  final int charCount;

  const ParseResult({
    required this.actions,
    required this.errors,
    this.warnings = const [],
    this.rejections = const [],
    this.blockCount = 0,
    this.charCount = 0,
  });

  bool get hasErrors => errors.isNotEmpty;
  bool get hasActions => actions.isNotEmpty;
}

/// Parser for the block format:
///
/// ```
/// <<<FILE_WRITE path="src/main.py">>>
/// print("Hello World")
/// <<<END>>>
///
/// <<<FILE_DELETE path="src/old_file.py">>>
/// <<<FOLDER_CREATE path="src/utils">>>
/// <<<FOLDER_DELETE path="src/legacy">>>
/// ```
///
/// Rules enforced here:
///  * every FILE_WRITE must be closed by `<<<END>>>` (unclosed = error, never
///    a silent guess at where the body ends),
///  * the tag must name a known action,
///  * `path="..."` must be present and must not escape the project.
class CommandParserService {
  /// Matches a block opener: `<<<ACTION path="value">>>`.
  ///
  /// Double quotes are the documented form; single quotes are accepted too.
  /// The quote character is interpolated from a code point so the regex can be
  /// assembled entirely from raw strings - escaping quotes inside a raw string
  /// would terminate the literal.
  static final String _q = String.fromCharCode(39);

  static final RegExp _openDouble = RegExp(
    r'^<<<([A-Z_]+)\s*(?:path\s*=\s*"([^"]*)")?\s*>>>$',
  );

  /// Same shape with a single-quoted value; group 2 holds it either way.
  static final RegExp _openSingle = RegExp(
    r'^<<<([A-Z_]+)\s*(?:path\s*=\s*' +
        _q +
        r'([^' +
        _q +
        r']*)' +
        _q +
        r')?\s*>>>$',
  );

  /// Closing marker for a FILE_WRITE body.
  static final RegExp _endPattern = RegExp(r'^<<<END>>>$');

  /// A bare opener with no path, e.g. `<<<FOLDER_CREATE>>>`.
  static final RegExp _bareTag = RegExp(r'^<<<([A-Z_]+)>>>$');

  /// Phrases that mean "the model gave up and summarised".
  static const List<String> _placeholderPhrases = [
    'rest of code',
    'rest of the code',
    'rest of file',
    'rest of the file',
    'code unchanged',
    'unchanged code',
    'remains unchanged',
    'no changes here',
    'same as before',
    'existing code here',
    // Deliberately not "..." on its own: an ellipsis is legitimate in prose,
    // and flagging every one of them would make the check noise.
  ];

  /// Names that are too generic to prove anything was written.
  static const List<String> _placeholderOnlyMarkers = [
    '...',
    '// ...',
    '# ...',
    '/* ... */',
    '<!-- ... -->',
  ];

  /// Removes a markdown fence that wraps the *entire* payload.
  ///
  /// Only a fence around everything is stripped. Joining every fenced block
  /// would discard real content when a file body contains its own fence.
  static String _stripOuterFence(String input) {
    final bt = String.fromCharCode(96);
    final pattern = RegExp(
      '^\\s*' + bt + '{3,4}[a-zA-Z0-9_+-]*\\s*\\n([\\s\\S]*?)\\n?\\s*' + bt + '{3,4}\\s*\$',
    );
    final match = pattern.firstMatch(input);
    return match != null ? (match.group(1) ?? '') : input;
  }

  static ParseResult parse(String rawInput) {
    final actions = <CommandAction>[];
    final errors = <String>[];
    final warnings = <String>[];
    final rejections = <RejectionEntry>[];

    if (rawInput.trim().isEmpty) {
      return const ParseResult(actions: [], errors: ['Input text is empty']);
    }

    final cleaned = _stripOuterFence(rawInput);
    final lines = cleaned.split('\n');

    var blockCount = 0;
    var index = 0;

    int i = 0;
    while (i < lines.length) {
      final trimmed = lines[i].trim();

      // Ignore anything outside a block: prose between blocks is common and
      // harmless, unlike prose *inside* a file body.
      if (!trimmed.startsWith('<<<')) {
        i++;
        continue;
      }

      if (_endPattern.hasMatch(trimmed)) {
        // An END whose opener was already rejected or already closed. Not worth
        // a second error: the real problem is reported once, on the block.
        i++;
        continue;
      }

      final open = _openDouble.firstMatch(trimmed) ??
          _openSingle.firstMatch(trimmed);
      final bare = open == null ? _bareTag.firstMatch(trimmed) : null;

      if (open == null && bare == null) {
        errors.add('Unrecognised block on line ${i + 1}: $trimmed');
        i++;
        continue;
      }

      blockCount++;
      index++;

      final tag = (open ?? bare)!.group(1)!.toUpperCase();
      // group(2) is the double-quoted value, group(3) the single-quoted one.
      // A bare tag has neither, so the result is empty and reported below.
      final rawPath = open != null ? (open.group(2) ?? '') : '';

      final ActionType? type = switch (tag) {
        'FILE_WRITE' || 'FILE_CREATE' || 'WRITE_FILE' => ActionType.writeFile,
        'FILE_DELETE' || 'DELETE_FILE' => ActionType.deleteFile,
        'FOLDER_CREATE' || 'CREATE_FOLDER' || 'MKDIR' => ActionType.createFolder,
        'FOLDER_DELETE' || 'DELETE_FOLDER' || 'RMDIR' => ActionType.deleteFolder,
        _ => null,
      };

      if (type == null) {
        errors.add('Block $index: unknown action "$tag" on line ${i + 1}');
        rejections.add(RejectionEntry(
          index: index,
          action: tag,
          path: '—',
          reason: 'unknown action',
        ));
        i++;
        continue;
      }

      final path = rawPath.trim();
      if (path.isEmpty) {
        errors.add('Block $index: $tag is missing path="..."');
        rejections.add(RejectionEntry(
          index: index,
          action: tag,
          path: '(no path)',
          reason: 'missing path="..."',
        ));
        // A body without a path still owns its lines; consume them.
        i = _skipToEnd(lines, i + 1, type);
        continue;
      }

      final pathProblem = PathGuard.validateRelativePath(path);
      if (pathProblem != null) {
        errors.add('Block $index: $tag $path — $pathProblem');
        rejections.add(RejectionEntry(
          index: index,
          action: tag,
          path: path,
          reason: pathProblem,
        ));
        // Still consumed so the body does not leak into the next block.
        i = _skipToEnd(lines, i + 1, type);
        continue;
      }

      if (type != ActionType.writeFile) {
        actions.add(CommandAction(
          type: type,
          relativePath: path,
          index: index,
        ));
        i++;
        continue;
      }

      // ---- FILE_WRITE: body runs to <<<END>>> ----------------------------
      final bodyStart = i + 1;
      var bodyEnd = -1;
      for (var j = bodyStart; j < lines.length; j++) {
        if (_endPattern.hasMatch(lines[j].trim())) {
          bodyEnd = j;
          break;
        }
        // A new block opener before END means the END was forgotten. Treated as
        // an error rather than as body text, so a missing END can never write a
        // file containing the next block's markup.
        if (lines[j].trim().startsWith('<<<') &&
            !_endPattern.hasMatch(lines[j].trim())) {
          break;
        }
      }

      if (bodyEnd < 0) {
        errors.add('Block $index: FILE_WRITE $path is missing <<<END>>>');
        rejections.add(RejectionEntry(
          index: index,
          action: 'FILE_WRITE',
          path: path,
          reason: 'missing <<<END>>>',
        ));
        // Resume at the next opener so later blocks are still parsed. A stray
        // <<<END>>> belonging to this block is consumed here rather than
        // reported as a second, separate error.
        var next = bodyStart;
        while (next < lines.length) {
          final t = lines[next].trim();
          if (_endPattern.hasMatch(t)) {
            next++;
            break;
          }
          if (t.startsWith('<<<')) break;
          next++;
        }
        i = next;
        continue;
      }

      final body = lines.sublist(bodyStart, bodyEnd).join('\n');
      actions.add(CommandAction(
        type: ActionType.writeFile,
        relativePath: path,
        content: body,
        index: index,
      ));
      i = bodyEnd + 1;
    }

    // ---- placeholder scan --------------------------------------------------
    for (final action in actions) {
      if (action.type != ActionType.writeFile || action.content.isEmpty) continue;
      final hit = findPlaceholder(action.content);
      if (hit != null) {
        // `hit.toString()` used to read `line 2: "// rest of code unchanged"`,
        // which was then quoted again - the quote appeared twice. Print the
        // location, then the line once, quoted.
        warnings.add(
          'Block ${action.index} contains placeholder text on line ${hit.line}: '
          '"${hit.text.trim()}"',
        );
      }
    }

    // Printed in input order, whatever order they were discovered in.
    rejections.sort((a, b) => a.index.compareTo(b.index));

    return ParseResult(
      actions: actions,
      errors: errors,
      warnings: warnings,
      rejections: rejections,
      blockCount: blockCount,
      charCount: rawInput.length,
    );
  }

  /// Advances past a rejected block so the next one is still parsed.
  ///
  /// Only a FILE_WRITE owns a body, so only a FILE_WRITE may consume lines
  /// looking for `<<<END>>>`; skipping ahead for the others would swallow the
  /// block that follows.
  static int _skipToEnd(List<String> lines, int from, ActionType type) {
    if (type != ActionType.writeFile) return from;
    for (var j = from; j < lines.length; j++) {
      final t = lines[j].trim();
      if (_endPattern.hasMatch(t)) return j + 1;
      if (t.startsWith('<<<')) return j;
    }
    return from;
  }

  /// Finds text that proves the model truncated the file.
  ///
  /// Returns the first hit, or null. An ellipsis alone only counts when it is
  /// the entire body, because "..." in prose is normal.
  static PlaceholderHit? findPlaceholder(String content) {
    final lines = content.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final lower = lines[i].toLowerCase();
      for (final phrase in _placeholderPhrases) {
        if (lower.contains(phrase)) {
          return PlaceholderHit(i + 1, lines[i]);
        }
      }
      final stripped = lines[i].trim();
      if (_placeholderOnlyMarkers.contains(stripped) && lines.length == 1) {
        return PlaceholderHit(i + 1, lines[i]);
      }
      // A bare ellipsis line surrounded by nothing else.
      if ((stripped == '...' || stripped == '…') && lines.length <= 2) {
        return PlaceholderHit(i + 1, lines[i]);
      }
    }
    return null;
  }

  /// Convenience for callers that only need the contents.
  static List<CommandAction> parseActions(String input) => parse(input).actions;
}
