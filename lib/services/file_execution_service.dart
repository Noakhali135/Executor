import 'dart:io';
import 'package:path/path.dart' as p;
import '../models/command_action.dart';

class FileExecutionService {
  static Future<List<TerminalLog>> executeBatch({
    required String rootDir,
    required List<CommandAction> actions,
    required Function(TerminalLog log) onLog,
  }) async {
    final logs = <TerminalLog>[];

    void emit(String message, LogLevel level) {
      final log = TerminalLog(message: message, level: level);
      logs.add(log);
      onLog(log);
    }

    emit('Checking working directory: $rootDir', LogLevel.info);
    final baseDir = Directory(rootDir);
    if (!await baseDir.exists()) {
      try {
        await baseDir.create(recursive: true);
        emit('Working directory did not exist. Created: $rootDir', LogLevel.warning);
      } catch (e) {
        emit('Unable to access or create working directory: $e', LogLevel.error);
        return logs;
      }
    }

    emit('Beginning execution of ${actions.length} batch action(s)...', LogLevel.info);
    int successCount = 0;
    int failCount = 0;

    for (int i = 0; i < actions.length; i++) {
      final action = actions[i];
      final sanitizedRelPath = action.relativePath.replaceFirst(RegExp(r'^/+'), '');
      final targetFolder = p.normalize(p.join(rootDir, sanitizedRelPath));
      final targetFullPath = p.normalize(p.join(targetFolder, action.name));

      try {
        switch (action.type) {
          case ActionType.createFile:
            final parent = Directory(targetFolder);
            if (!await parent.exists()) {
              await parent.create(recursive: true);
            }
            final file = File(targetFullPath);
            await file.writeAsString(action.content);
            emit(
              '[CREATE_FILE] ${action.relativePath}${action.name} (${action.content.length} chars)',
              LogLevel.success,
            );
            successCount++;
            break;

          case ActionType.deleteFile:
            final file = File(targetFullPath);
            if (await file.exists()) {
              await file.delete();
              emit('[DELETE_FILE] ${action.relativePath}${action.name} removed', LogLevel.success);
              successCount++;
            } else {
              emit(
                '[DELETE_FILE] Warning: File ${action.relativePath}${action.name} not found',
                LogLevel.warning,
              );
              successCount++;
            }
            break;

          case ActionType.createFolder:
            final dir = Directory(targetFullPath);
            if (!await dir.exists()) {
              await dir.create(recursive: true);
            }
            emit('[CREATE_FOLDER] ${action.relativePath}${action.name}/ created', LogLevel.success);
            successCount++;
            break;

          case ActionType.deleteFolder:
            final dir = Directory(targetFullPath);
            if (await dir.exists()) {
              await dir.delete(recursive: true);
              emit('[DELETE_FOLDER] ${action.relativePath}${action.name}/ deleted', LogLevel.success);
              successCount++;
            } else {
              emit(
                '[DELETE_FOLDER] Warning: Folder ${action.relativePath}${action.name}/ not found',
                LogLevel.warning,
              );
              successCount++;
            }
            break;
        }
      } catch (e) {
        failCount++;
        emit(
          '[ERROR] Failed to execute ${action.displayName} on ${action.name}: $e',
          LogLevel.error,
        );
      }
    }

    emit(
      'Execution finished. Success: $successCount, Failed: $failCount',
      failCount == 0 ? LogLevel.success : LogLevel.warning,
    );

    return logs;
  }
}