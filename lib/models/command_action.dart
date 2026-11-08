enum ActionType {
  createFile,
  deleteFile,
  createFolder,
  deleteFolder,

  /// Emitted by the exporter for binary/image files.
  ///
  /// The export format has no way to carry binary payloads, so those entries
  /// are marked as "do not touch" instead of being exported as a text
  /// placeholder that would overwrite the real file with a few ASCII bytes.
  skipBinary,
}

class CommandAction {
  final ActionType type;
  final String relativePath;
  final String name;
  final String content;

  /// Byte size of the skipped binary, only used for [ActionType.skipBinary].
  final int sizeBytes;

  const CommandAction({
    required this.type,
    required this.relativePath,
    required this.name,
    this.content = '',
    this.sizeBytes = 0,
  });

  String get displayName {
    switch (type) {
      case ActionType.createFile:
        return 'CREATE_FILE';
      case ActionType.deleteFile:
        return 'DELETE_FILE';
      case ActionType.createFolder:
        return 'CREATE_FOLDER';
      case ActionType.deleteFolder:
        return 'DELETE_FOLDER';
      case ActionType.skipBinary:
        return 'SKIP_BINARY';
    }
  }

  bool get isDestructive =>
      type == ActionType.deleteFile || type == ActionType.deleteFolder;

  String get fullRelativePath {
    final cleaned = relativePath.endsWith('/')
        ? relativePath.substring(0, relativePath.length - 1)
        : relativePath;
    return '$cleaned/$name';
  }
}

enum LogLevel {
  info,
  success,
  warning,
  error,
}

class TerminalLog {
  final String message;
  final DateTime timestamp;
  final LogLevel level;

  TerminalLog({
    required this.message,
    DateTime? timestamp,
    this.level = LogLevel.info,
  }) : timestamp = timestamp ?? DateTime.now();

  String get formattedTime {
    final h = timestamp.hour.toString().padLeft(2, '0');
    final m = timestamp.minute.toString().padLeft(2, '0');
    final s = timestamp.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }
}
