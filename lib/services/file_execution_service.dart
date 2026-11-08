import 'dart:io';
import 'package:path/path.dart' as p;
import '../models/command_action.dart';
import 'file_types.dart';
import 'path_guard.dart';

/// One planned action, resolved and validated before anything touches disk.
class PlannedAction {
  final CommandAction action;
  final String? targetPath;

  /// Non-null when the action must not run (path escape, bad name, ...).
  final String? rejection;

  const PlannedAction({
    required this.action,
    this.targetPath,
    this.rejection,
  });

  bool get isRejected => rejection != null;
}

class PlanSummary {
  final List<PlannedAction> items;
  final List<String> errors;

  const PlanSummary({required this.items, required this.errors});

  Iterable<PlannedAction> get runnable => items.where((i) => !i.isRejected);
  Iterable<PlannedAction> get rejected => items.where((i) => i.isRejected);

  int get createCount => runnable
      .where((i) =>
          i.action.type == ActionType.createFile ||
          i.action.type == ActionType.createFolder)
      .length;
  int get deleteCount => runnable.where((i) => i.action.isDestructive).length;
  int get skipCount =>
      runnable.where((i) => i.action.type == ActionType.skipBinary).length;
}

class FileExecutionService {
  /// Resolves and validates every action against [rootDir] without writing.
  ///
  /// Used to power the pre-flight confirmation sheet and to guarantee that a
  /// batch is either fully inside the workspace or not run at all.
  static PlanSummary plan({
    required String rootDir,
    required List<CommandAction> actions,
  }) {
    final items = <PlannedAction>[];
    final errors = <String>[];

    for (final action in actions) {
      if (action.type == ActionType.skipBinary) {
        items.add(PlannedAction(action: action));
        continue;
      }
      try {
        final target = PathGuard.resolveInRoot(
          rootDir,
          relativePath: action.relativePath,
          name: action.name,
        );
        items.add(PlannedAction(action: action, targetPath: target));
      } on UnsafePathException catch (e) {
        final message = 'Blocked ${action.displayName} ${action.fullRelativePath}: ${e.reason}';
        errors.add(message);
        items.add(PlannedAction(action: action, rejection: e.reason));
      }
    }

    return PlanSummary(items: items, errors: errors);
  }

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

    if (actions.isEmpty) {
      emit('No actions to execute.', LogLevel.warning);
      return logs;
    }

    emit('Checking working directory: $rootDir', LogLevel.info);
    final baseDir = Directory(rootDir);
    if (!await baseDir.exists()) {
      try {
        await baseDir.create(recursive: true);
        emit('Working directory created: $rootDir', LogLevel.warning);
      } catch (e) {
        emit('Unable to access working directory: $e', LogLevel.error);
        return logs;
      }
    }

    final plan = FileExecutionService.plan(rootDir: rootDir, actions: actions);

    for (final blocked in plan.rejected) {
      emit(
        '[BLOCKED] ${blocked.action.displayName} ${blocked.action.fullRelativePath} — ${blocked.rejection}',
        LogLevel.error,
      );
    }

    final runnable = plan.runnable.toList();
    emit('Executing ${runnable.length} action(s)...', LogLevel.info);
    int successCount = 0;
    int failCount = 0;
    int skipCount = 0;

    for (int i = 0; i < runnable.length; i++) {
      final planned = runnable[i];
      final action = planned.action;

      if (action.type == ActionType.skipBinary) {
        emit(
          '[SKIP_BINARY] ${action.fullRelativePath} left untouched (${FileTypes.formatSize(action.sizeBytes)})',
          LogLevel.warning,
        );
        skipCount++;
        continue;
      }

      final targetFullPath = planned.targetPath!;
      final targetFolder = p.dirname(targetFullPath);

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
              '[CREATE_FILE] ${action.fullRelativePath} (${action.content.length} chars)',
              LogLevel.success,
            );
            successCount++;
            break;

          case ActionType.deleteFile:
            final file = File(targetFullPath);
            if (await file.exists()) {
              await file.delete();
              emit('[DELETE_FILE] ${action.fullRelativePath} removed', LogLevel.success);
              successCount++;
            } else {
              // Not counted as success: the previous implementation reported a
              // missing target as a successful delete, hiding broken scripts.
              emit(
                '[DELETE_FILE] Skipped: ${action.fullRelativePath} does not exist',
                LogLevel.warning,
              );
              skipCount++;
            }
            break;

          case ActionType.createFolder:
            final dir = Directory(targetFullPath);
            if (!await dir.exists()) {
              await dir.create(recursive: true);
            }
            emit('[CREATE_FOLDER] ${action.fullRelativePath}/ created', LogLevel.success);
            successCount++;
            break;

          case ActionType.deleteFolder:
            final dir = Directory(targetFullPath);
            if (await dir.exists()) {
              // Never follow a symlink out of the workspace.
              final resolved = await dir.resolveSymbolicLinks();
              if (!PathGuard.isInside(rootDir, resolved)) {
                emit(
                  '[BLOCKED] ${action.fullRelativePath} resolves outside the workspace (symlink)',
                  LogLevel.error,
                );
                failCount++;
                break;
              }
              await dir.delete(recursive: true);
              emit('[DELETE_FOLDER] ${action.fullRelativePath}/ deleted', LogLevel.success);
              successCount++;
            } else {
              emit(
                '[DELETE_FOLDER] Skipped: ${action.fullRelativePath}/ does not exist',
                LogLevel.warning,
              );
              skipCount++;
            }
            break;

          case ActionType.skipBinary:
            break;
        }
      } catch (e) {
        failCount++;
        emit(
          '[ERROR] Failed to execute ${action.displayName} on ${action.fullRelativePath}: $e',
          LogLevel.error,
        );
      }
    }

    emit(
      'Execution finished. Success: $successCount, Skipped: $skipCount, Failed: $failCount',
      failCount == 0 ? LogLevel.success : LogLevel.warning,
    );

    return logs;
  }
}
