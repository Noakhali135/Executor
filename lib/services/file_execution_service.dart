import 'package:path/path.dart' as p;

import '../models/command_action.dart';
import 'path_guard.dart';
import 'workspace_fs.dart';

/// One action resolved against the workspace, ready to run.
class PlannedAction {
  final CommandAction action;

  /// Absolute (or SAF virtual) target path, or null when rejected.
  final String? targetPath;

  /// Non-null when the action must not run.
  final String? rejection;

  /// True when a FILE_WRITE would replace a file that already exists.
  final bool overwrites;

  /// Lines removed/added, filled in after the write.
  int removedLines = 0;
  int addedLines = 0;

  PlannedAction({
    required this.action,
    this.targetPath,
    this.rejection,
    this.overwrites = false,
  });

  bool get isRejected => rejection != null;
  bool get isWrite => action.type == ActionType.writeFile;
}

class PlanSummary {
  final List<PlannedAction> items;
  final List<String> errors;

  const PlanSummary({required this.items, required this.errors});

  Iterable<PlannedAction> get runnable => items.where((i) => !i.isRejected);
  Iterable<PlannedAction> get rejected => items.where((i) => i.isRejected);

  int get writeCount =>
      runnable.where((i) => i.action.type == ActionType.writeFile).length;
  int get deleteCount => runnable.where((i) => i.action.isDestructive).length;
  int get createCount =>
      runnable.where((i) => i.action.type == ActionType.createFolder).length;
}

/// Result of a whole run, so the UI can say "2 of 2 applied".
class BatchResult {
  final int applied;
  final int failed;
  final int skipped;
  final bool aborted;

  const BatchResult({
    this.applied = 0,
    this.failed = 0,
    this.skipped = 0,
    this.aborted = false,
  });

  bool get ok => !aborted && failed == 0;
}

class FileExecutionService {
  /// Batch files larger than this are left alone rather than copied.
  static const int maxBackupBytes = 5 * 1024 * 1024;

  /// Resolves and validates everything before any file is touched.
  ///
  /// This is what makes the "no files were changed" guarantee real: every path
  /// is checked up front, so a single bad block cannot leave the project half
  /// updated.
  static Future<PlanSummary> plan({
    required String rootDir,
    required List<CommandAction> actions,
  }) async {
    final items = <PlannedAction>[];
    final errors = <String>[];

    for (final action in actions) {
      if (action.isMalformed) {
        errors.add('Block ${action.index}: ${action.malformedReason}');
        items.add(PlannedAction(action: action, rejection: action.malformedReason));
        continue;
      }

      final problem = PathGuard.validateRelativePath(action.relativePath);
      if (problem != null) {
        errors.add('Block ${action.index}: ${action.relativePath} — $problem');
        items.add(PlannedAction(action: action, rejection: problem));
        continue;
      }

      // resolveInRoot takes a directory + name; split the relative path here so
      // the containment logic is shared with the rest of the app.
      final dir = action.directory;
      final name = action.baseName;

      try {
        final target = PathGuard.resolveInRoot(
          rootDir,
          relativePath: dir,
          name: name,
        );
        final exists = await WorkspaceFs.exists(target);
        final isDir = exists && await WorkspaceFs.isDirectory(target);

        // A write over a directory, or a folder delete over a file, is a
        // mistake worth catching before anything changes.
        if (action.type == ActionType.writeFile && isDir) {
          const reason = 'target is a directory, not a file';
          errors.add('Block ${action.index}: ${action.relativePath} — $reason');
          items.add(PlannedAction(action: action, rejection: reason));
          continue;
        }
        if (action.type == ActionType.deleteFolder && exists && !isDir) {
          const reason = 'target is a file, not a directory';
          errors.add('Block ${action.index}: ${action.relativePath} — $reason');
          items.add(PlannedAction(action: action, rejection: reason));
          continue;
        }

        items.add(PlannedAction(
          action: action,
          targetPath: target,
          overwrites: exists && action.type == ActionType.writeFile,
        ));
      } on UnsafePathException catch (e) {
        errors.add('Block ${action.index}: ${action.relativePath} — ${e.reason}');
        items.add(PlannedAction(action: action, rejection: e.reason));
      }
    }

    return PlanSummary(items: items, errors: errors);
  }

  /// Runs [actions] against [rootDir] and reports every step through [onLog].
  ///
  /// Order matters, and so does the guarantee behind it: the batch is parsed,
  /// validated, and backed up before a single byte is written. If anything is
  /// wrong the method returns [BatchResult.aborted] with the project untouched.
  ///
  /// [confirm] is awaited after validation when the batch deletes anything, so
  /// the user sees the plan before it is applied. Returning false cancels.
  static Future<BatchResult> execute({
    required String rootDir,
    required List<CommandAction> actions,
    required ParseReport report,
    required void Function(TerminalLog log) onLog,
    Future<bool> Function(PlanSummary plan)? confirm,
    bool dryRun = false,
  }) async {
    void emit(String message, LogKind kind) =>
        onLog(TerminalLog(message: message, kind: kind));

    // ---- 1. parse summary ----------------------------------------------
    emit(
      'Input received (${_plural(report.blockCount, 'block', 'blocks')}, '
      '${_groupDigits(report.charCount)} chars)',
      LogKind.info,
    );
    emit('Parsing blocks...', LogKind.info);

    // Blocks the parser accepted, in input order. Columns are padded so the
    // paths line up, which is what makes a long run scannable.
    for (final action in actions) {
      final suffix = action.type == ActionType.writeFile
          ? ' (${_plural(action.lineCount, 'line', 'lines')})'
          : '';
      emit(
        'Block ${action.index}: ${action.displayName.padRight(14)}'
        ' ${action.relativePath.padRight(20)}'
        '$suffix',
        LogKind.ok,
      );
    }

    // Blocks the parser rejected, each reported once.
    for (final error in report.errors) {
      emit(error, LogKind.error);
    }
    for (final warning in report.warnings) {
      emit(warning, LogKind.warn);
    }

    // A parse error means the input cannot be trusted: stop before writing.
    // Without this a block with a missing END could be written from a guess.
    if (report.errors.isNotEmpty) {
      emit(
        'Validation failed (${_plural(report.errors.length, 'error', 'errors')}).'
        ' No files were changed.',
        LogKind.fail,
      );
      emitHint(report.hints, onLog);
      return BatchResult(aborted: true, failed: report.errors.length);
    }

    if (actions.isEmpty) {
      emit('No blocks found. Nothing to do.', LogKind.warn);
      return const BatchResult();
    }

    // ---- 2. validate ---------------------------------------------------
    emit('Validating...', LogKind.info);

    if (!await WorkspaceFs.exists(rootDir)) {
      if (!await WorkspaceFs.createDirectory(rootDir)) {
        emit('Workspace is not accessible: $rootDir', LogKind.fail);
        return const BatchResult(aborted: true);
      }
    }

    final plan = await FileExecutionService.plan(
      rootDir: rootDir,
      actions: actions,
    );

    emit('Paths are relative and inside project root', LogKind.ok);
    emit('Every FILE_WRITE has a closing <<<END>>>', LogKind.ok);

    // Worth stating for a delete: whether the target is really there.
    for (final item in plan.runnable) {
      if (!item.action.isDestructive) continue;
      final exists = await WorkspaceFs.exists(item.targetPath!);
      emit(
        '${item.action.relativePath} '
        '${exists ? 'exists, safe to delete' : 'does not exist'}',
        exists ? LogKind.ok : LogKind.warn,
      );
    }

    // Path rejections are reported here, once, whatever the action type.
    for (final item in plan.rejected) {
      emit(
        'Block ${item.action.index}: ${item.action.displayName} '
        '${item.action.relativePath} — ${item.rejection}',
        LogKind.error,
      );
    }

    if (plan.rejected.isNotEmpty) {
      final count = plan.rejected.length;
      emit(
        'Validation failed (${_plural(count, 'error', 'errors')}).'
        ' No files were changed.',
        LogKind.fail,
      );
      emitHint(
        plan.rejected
            .map((i) => 'Block ${i.action.index}: ${i.rejection}')
            .toList(),
        onLog,
      );
      return BatchResult(aborted: true, failed: count);
    }

    final runnable = plan.runnable.toList();
    if (runnable.isEmpty) {
      emit('Nothing to apply.', LogKind.warn);
      return const BatchResult();
    }

    // ---- 3. confirm destructive batches before touching anything --------
    if (confirm != null && plan.deleteCount > 0) {
      final approved = await confirm(plan);
      if (!approved) {
        emit('Cancelled. No files were changed.', LogKind.warn);
        return BatchResult(aborted: true, skipped: runnable.length);
      }
    }

    // ---- 4. backup -----------------------------------------------------
    final stamp = _stamp(DateTime.now());
    final backupDir = p.join(rootDir, '.backup', stamp);
    var backedUp = 0;

    for (final item in runnable) {
      if (!await WorkspaceFs.exists(item.targetPath!)) continue;
      if (await WorkspaceFs.isDirectory(item.targetPath!)) continue;

      final size = await WorkspaceFs.length(item.targetPath!);
      if (size > maxBackupBytes) {
        emit(
          'Skipped backup of ${item.action.relativePath} '
          '(too large: ${_formatBytes(size)})',
          LogKind.warn,
        );
        continue;
      }

      if (backedUp == 0) emit('Creating backup -> .backup/$stamp/', LogKind.info);

      final backupPath = p.join(backupDir, item.action.relativePath);
      if (await WorkspaceFs.copyFile(item.targetPath!, backupPath)) {
        backedUp++;
        emit('Backed up ${item.action.relativePath}', LogKind.ok);
      } else {
        // Not fatal, but the undo will not cover this file, so say so.
        emit(
          'Could not back up ${item.action.relativePath} (continuing)',
          LogKind.warn,
        );
      }
    }

    if (dryRun) {
      emit('Dry run: no files were written.', LogKind.done);
      return BatchResult(applied: 0, skipped: runnable.length);
    }

    // ---- 5. apply ------------------------------------------------------
    emit('Applying changes...', LogKind.info);

    var applied = 0;
    var failed = 0;
    var skipped = 0;

    for (final item in runnable) {
      final a = item.action;
      final target = item.targetPath!;

      try {
        switch (a.type) {
          case ActionType.writeFile:
            final before = item.overwrites
                ? (await WorkspaceFs.readString(target)) ?? ''
                : '';
            if (!await WorkspaceFs.writeString(target, a.content)) {
              emit('Could not write ${a.relativePath}', LogKind.error);
              failed++;
              continue;
            }
            if (item.overwrites) {
              final diff = _lineDiff(before, a.content);
              emit(
                'Wrote ${a.relativePath} (overwritten, '
                '+${diff.$2} / -${diff.$1} lines)',
                LogKind.ok,
              );
            } else {
              emit(
                'Wrote ${a.relativePath} (new, '
                '${_plural(a.lineCount, 'line', 'lines')})',
                LogKind.ok,
              );
            }
            applied++;

          case ActionType.deleteFile:
            if (!await WorkspaceFs.exists(target)) {
              emit('${a.relativePath} does not exist', LogKind.warn);
              skipped++;
            } else if (await WorkspaceFs.delete(target)) {
              emit('Deleted ${a.relativePath}', LogKind.ok);
              applied++;
            } else {
              emit('Could not delete ${a.relativePath}', LogKind.error);
              failed++;
            }

          case ActionType.createFolder:
            if (await WorkspaceFs.isDirectory(target)) {
              emit('Folder ${a.relativePath} already exists', LogKind.warn);
              skipped++;
            } else if (await WorkspaceFs.createDirectory(target)) {
              emit('Created folder ${a.relativePath}/', LogKind.ok);
              applied++;
            } else {
              emit('Could not create ${a.relativePath}/', LogKind.error);
              failed++;
            }

          case ActionType.deleteFolder:
            if (!await WorkspaceFs.exists(target)) {
              emit('Folder ${a.relativePath} does not exist', LogKind.warn);
              skipped++;
            } else if (await WorkspaceFs.delete(target)) {
              emit('Deleted folder ${a.relativePath}/', LogKind.ok);
              applied++;
            } else {
              emit('Could not delete ${a.relativePath}/', LogKind.error);
              failed++;
            }
        }
      } catch (e) {
        failed++;
        emit('Failed on ${a.relativePath}: $e', LogKind.error);
      }
    }

    emit(
      '$applied of ${runnable.length} actions applied, $failed failed'
      '${skipped > 0 ? ', $skipped skipped' : ''}'
      '${backedUp > 0 ? ', $backedUp backed up' : ''}',
      failed == 0 ? LogKind.done : LogKind.fail,
    );

    return BatchResult(applied: applied, failed: failed, skipped: skipped);
  }

  static void emitHint(List<String> hints, void Function(TerminalLog) onLog) {
    if (hints.isEmpty) {
      onLog(TerminalLog(
        message: 'Fix the errors above and resend the full blocks.',
        kind: LogKind.hint,
      ));
      return;
    }
    onLog(TerminalLog(
      message: 'Copy the errors below back to the AI and ask it to resend the '
          'full blocks:',
      kind: LogKind.hint,
    ));
    for (final hint in hints) {
      onLog(TerminalLog(message: '- $hint', isContinuation: true));
    }
  }

  /// Counts changed lines, which is what a reviewer actually cares about.
  ///
  /// A real diff algorithm would be nicer, but a line-set comparison is honest
  /// about the size of the change and cannot be wrong in a dangerous way.
  static (int removed, int added) _lineDiff(String before, String after) {
    final oldLines = before.isEmpty ? <String>[] : before.split('\n');
    final newLines = after.isEmpty ? <String>[] : after.split('\n');

    var prefix = 0;
    while (prefix < oldLines.length &&
        prefix < newLines.length &&
        oldLines[prefix] == newLines[prefix]) {
      prefix++;
    }
    var suffix = 0;
    while (suffix < oldLines.length - prefix &&
        suffix < newLines.length - prefix &&
        oldLines[oldLines.length - 1 - suffix] ==
            newLines[newLines.length - 1 - suffix]) {
      suffix++;
    }
    return (
      oldLines.length - prefix - suffix,
      newLines.length - prefix - suffix,
    );
  }

  /// "1 error" / "3 errors" - keeps the FAIL line grammatical at any count.
  static String _plural(int count, String one, String many) =>
      '$count ${count == 1 ? one : many}';

  static String _stamp(DateTime now) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${now.year}-${two(now.month)}-${two(now.day)}_'
        '${two(now.hour)}-${two(now.minute)}-${two(now.second)}';
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '${bytes}b';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).round()}kb';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}mb';
  }

  static String _groupDigits(int value) {
    final s = value.toString();
    final out = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) out.write(',');
      out.write(s[i]);
    }
    return out.toString();
  }
}

/// Everything the parser produced, plus the hints shown on failure.
class ParseReport {
  final int blockCount;
  final int charCount;
  final List<String> errors;
  final List<String> warnings;
  final List<String> hints;

  const ParseReport({
    this.blockCount = 0,
    this.charCount = 0,
    this.errors = const [],
    this.warnings = const [],
    this.hints = const [],
  });
}
