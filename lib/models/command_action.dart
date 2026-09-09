enum ActionType {
  createFile,
  deleteFile,
  createFolder,
  deleteFolder,
}

class CommandAction {
  final ActionType type;
  final String relativePath;
  final String name;
  final String content;

  const CommandAction({
    required this.type,
    required this.relativePath,
    required this.name,
    this.content = '',
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
    }
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