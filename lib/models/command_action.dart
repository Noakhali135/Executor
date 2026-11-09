/// Outcome of one step, shown as the prefix of every log line.
enum LogKind {
  info,
  ok,
  warn,
  error,
  fail,
  done,
  hint,
}

extension LogKindLabel on LogKind {
  /// Fixed-width prefix so the terminal columns line up.
  String get label => switch (this) {
        LogKind.info => 'INFO ',
        LogKind.ok => 'OK   ',
        LogKind.warn => 'WARN ',
        LogKind.error => 'ERROR',
        LogKind.fail => 'FAIL ',
        LogKind.done => 'DONE ',
        LogKind.hint => 'HINT ',
      };
}

/// A single line in the execution output.
class TerminalLog {
  final String message;
  final DateTime timestamp;
  final LogKind kind;

  /// Continuation lines align under the message column instead of restarting
  /// with a prefix, so a multi-line HINT stays readable.
  final bool isContinuation;

  TerminalLog({
    required this.message,
    this.kind = LogKind.info,
    this.isContinuation = false,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  String get formattedTime {
    final h = timestamp.hour.toString().padLeft(2, '0');
    final m = timestamp.minute.toString().padLeft(2, '0');
    final s = timestamp.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  /// `[10:22:01] INFO   message`
  String get formatted => isContinuation
      ? '           ${' ' * 5} $message'
      : '[${formattedTime}] ${kind.label} ${message}';
}

/// What a block does.
enum ActionType {
  writeFile,
  deleteFile,
  createFolder,
  deleteFolder,
}

/// One `<<<...>>>` block from the input.
class CommandAction {
  final ActionType type;

  /// Project-relative path exactly as written in the block (e.g. `src/main.py`).
  final String relativePath;

  /// Body of a FILE_WRITE block. Empty for the other actions.
  final String content;

  /// 1-based position of the block in the input, used in messages.
  final int index;

  /// Set when the block itself is malformed (missing `<<<END>>>`, unknown tag).
  final String? malformedReason;

  const CommandAction({
    required this.type,
    required this.relativePath,
    this.content = '',
    this.index = 0,
    this.malformedReason,
  });

  bool get isMalformed => malformedReason != null;

  String get displayName => switch (type) {
        ActionType.writeFile => 'FILE_WRITE',
        ActionType.deleteFile => 'FILE_DELETE',
        ActionType.createFolder => 'FOLDER_CREATE',
        ActionType.deleteFolder => 'FOLDER_DELETE',
      };

  bool get isDestructive =>
      type == ActionType.deleteFile || type == ActionType.deleteFolder;

  /// Number of lines in [content]; 0 for non-write actions.
  int get lineCount {
    if (content.isEmpty) return 0;
    // A trailing newline does not start a new line.
    final normalised = content.endsWith('\n')
        ? content.substring(0, content.length - 1)
        : content;
    return '\n'.allMatches(normalised).length + 1;
  }

  /// Last path segment, for compact display.
  String get baseName {
    final cleaned = relativePath.replaceAll('\\', '/');
    final parts = cleaned.split('/').where((s) => s.isNotEmpty).toList();
    return parts.isEmpty ? relativePath : parts.last;
  }

  /// Directory part with a trailing slash, or '' for a top-level entry.
  String get directory {
    final cleaned = relativePath.replaceAll('\\', '/');
    final idx = cleaned.lastIndexOf('/');
    if (idx <= 0) return '';
    return cleaned.substring(0, idx + 1);
  }
}
