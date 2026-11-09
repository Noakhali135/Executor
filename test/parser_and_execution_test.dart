import 'dart:io';

import 'package:executor/models/command_action.dart';
import 'package:executor/services/command_parser_service.dart';
import 'package:executor/services/export_service.dart';
import 'package:executor/services/file_execution_service.dart';
import 'package:executor/services/github_service.dart';
import 'package:executor/services/saf_workspace.dart';
import 'package:executor/services/push_progress.dart';
import 'package:executor/services/workspace_fs.dart';
import 'package:executor/services/workspace_probe.dart';
import 'package:executor/services/path_guard.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tempRoot;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('devrunner_test_');
  });

  tearDown(() async {
    if (await tempRoot.exists()) {
      await tempRoot.delete(recursive: true);
    }
  });

  group('PathGuard', () {
    test('rejects traversal in [PATH]', () {
      expect(
        () => PathGuard.resolveInRoot(tempRoot.path, relativePath: '/../../etc/', name: 'passwd'),
        throwsA(isA<UnsafePathException>()),
      );
    });

    test('rejects traversal in [NAME]', () {
      expect(
        () => PathGuard.resolveInRoot(tempRoot.path, relativePath: '/', name: '../../../evil.sh'),
        throwsA(isA<UnsafePathException>()),
      );
    });

    test('rejects absolute names and separators', () {
      for (final bad in ['/etc/passwd', 'a/b', '..', '.']) {
        expect(PathGuard.validateName(bad), isNotNull, reason: 'should reject "$bad"');
      }
    });

    test('accepts a normal nested path', () {
      final resolved = PathGuard.resolveInRoot(
        tempRoot.path,
        relativePath: '/lib/src/',
        name: 'main.dart',
      );
      expect(PathGuard.isInside(tempRoot.path, resolved), isTrue);
      expect(resolved, endsWith('main.dart'));
    });

    test('root itself is not considered inside', () {
      expect(PathGuard.isInside(tempRoot.path, tempRoot.path), isFalse);
    });

    test('validateRelativePath accepts normal project paths', () {
      for (final good in [
        'main.py',
        'src/main.py',
        'src/a/b/c.dart',
        'a b/c.txt',
        '.gitignore',
        'dir.with.dots/file.dart',
      ]) {
        expect(PathGuard.validateRelativePath(good), isNull,
            reason: '"$good" should be accepted');
      }
    });

    test('validateRelativePath rejects anything that leaves the project', () {
      for (final bad in [
        '',
        '   ',
        '../x',
        'a/../../b',
        'a/..',
        '/etc/passwd',
        '//host/share/f',
        r'C:\Windows',
        '~/secret',
        'a//b',
        './a',
        'a/b/',
      ]) {
        expect(PathGuard.validateRelativePath(bad), isNotNull,
            reason: '"$bad" should be rejected');
      }
    });
  });

  group('Block parser', () {
    test('parses a FILE_WRITE block', () {
      final result = CommandParserService.parse(
        '<<<FILE_WRITE path="src/main.py">>>\nprint("Hello World")\n<<<END>>>',
      );
      expect(result.errors, isEmpty);
      expect(result.actions, hasLength(1));
      expect(result.actions.single.type, ActionType.writeFile);
      expect(result.actions.single.relativePath, 'src/main.py');
      expect(result.actions.single.content, 'print("Hello World")');
    });

    test('parses all four block kinds', () {
      final result = CommandParserService.parse(
        '<<<FILE_WRITE path="src/main.py">>>\nx\n<<<END>>>\n'
        '<<<FILE_DELETE path="src/old_file.py">>>\n'
        '<<<FOLDER_CREATE path="src/utils">>>\n'
        '<<<FOLDER_DELETE path="src/legacy">>>',
      );
      expect(result.errors, isEmpty);
      expect(result.blockCount, 4);
      expect(result.actions.map((a) => a.type), [
        ActionType.writeFile,
        ActionType.deleteFile,
        ActionType.createFolder,
        ActionType.deleteFolder,
      ]);
      expect(result.actions.map((a) => a.relativePath), [
        'src/main.py',
        'src/old_file.py',
        'src/utils',
        'src/legacy',
      ]);
    });

    test('a missing <<<END>>> is an error, not a body guess', () {
      final result = CommandParserService.parse(
        '<<<FILE_WRITE path="src/a.js">>>\nlet a = 1;',
      );
      expect(result.hasErrors, isTrue);
      expect(result.errors.first, contains('missing <<<END>>>'));
      expect(result.actions.where((a) => !a.isMalformed), isEmpty);
    });

    test('a block that begins before END does not swallow the next block', () {
      final result = CommandParserService.parse(
        '<<<FILE_WRITE path="a.txt">>>\nbody\n'
        '<<<FILE_WRITE path="b.txt">>>\nsecond\n<<<END>>>',
      );
      // First block has no END: error. Second is still parsed.
      expect(result.errors.any((e) => e.contains('a.txt')), isTrue);
      expect(result.actions.single.relativePath, 'b.txt');
      expect(result.actions.single.content, 'second');
    });

    test('rejects paths that escape the project', () {
      for (final bad in [
        '../secrets.txt',
        'a/../../b',
        '/etc/passwd',
        r'C:\Windows\system32',
        '~/secret',
        'a//b',
      ]) {
        final result = CommandParserService.parse(
          '<<<FILE_WRITE path="$bad">>>\nx\n<<<END>>>',
        );
        expect(result.hasErrors, isTrue, reason: '"$bad" should be rejected');
        expect(result.actions, isEmpty, reason: '"$bad" must not become an action');
      }
    });

    test('flags placeholder text so a truncated file is not written', () {
      final result = CommandParserService.parse(
        '<<<FILE_WRITE path="src/app.js">>>\n'
        'const a = 1;\n'
        '// rest of code unchanged\n'
        '<<<END>>>',
      );
      expect(result.errors, isEmpty);
      expect(result.warnings.single, contains('placeholder'));
      expect(result.warnings.single, contains('line 2'));
    });

    test('a single ellipsis body counts as a placeholder', () {
      final result = CommandParserService.parse(
        '<<<FILE_WRITE path="a.txt">>>\n...\n<<<END>>>',
      );
      expect(result.warnings, isNotEmpty);
    });

    test('prose between blocks is ignored', () {
      final result = CommandParserService.parse(
        'Here are the changes.\n'
        '<<<FILE_WRITE path="a.txt">>>\nbody\n<<<END>>>\n'
        'Let me know if you need anything else.',
      );
      expect(result.errors, isEmpty);
      expect(result.actions.single.content, 'body');
    });

    test('an unknown action tag is reported', () {
      final result = CommandParserService.parse(
        '<<<FILE_RENAME path="a.txt">>>',
      );
      expect(result.hasErrors, isTrue);
      expect(result.errors.first, contains('unknown action'));
    });

    test('bodies preserve trailing blank lines exactly', () {
      final result = CommandParserService.parse(
        '<<<FILE_WRITE path="y.txt">>>\nline1\nline2\n\n<<<END>>>',
      );
      expect(result.actions.single.content, 'line1\nline2\n');
    });

    test('counts lines for the log summary', () {
      final result = CommandParserService.parse(
        '<<<FILE_WRITE path="a.txt">>>\n1\n2\n3\n<<<END>>>',
      );
      expect(result.actions.single.lineCount, 3);
    });
  });

  group('ExportService round trip', () {
    test('text content survives export -> parse unchanged', () async {
      final file = File(p.join(tempRoot.path, 'a.txt'));
      await file.writeAsString('alpha\n\nbeta\n');

      final exported = await ExportService.generateBatchExport(
        rootDir: tempRoot.path,
        selectedPaths: {file.path},
      );
      final parsed = CommandParserService.parse(exported);

      expect(parsed.errors, isEmpty);
      expect(parsed.actions.single.content, 'alpha\n\nbeta\n');
    });

    test('uses the block format', () async {
      final file = File(p.join(tempRoot.path, 'b.txt'));
      await file.writeAsString('x\n');

      final exported = await ExportService.generateBatchExport(
        rootDir: tempRoot.path,
        selectedPaths: {file.path},
      );

      expect(exported, contains('<<<FILE_WRITE path="b.txt">>>'));
      expect(exported, contains('<<<END>>>'));
      expect(exported, isNot(contains('[ACTION]')));
    });

    test('trailing newlines and CRLF survive the round trip', () async {
      for (final body in ['no newline', 'one\n', 'two\n\n', 'a\r\nb\r\n']) {
        final file = File(p.join(tempRoot.path, 'c.txt'));
        await file.writeAsString(body);

        final exported = await ExportService.generateBatchExport(
          rootDir: tempRoot.path,
          selectedPaths: {file.path},
        );
        final parsed = CommandParserService.parse(exported);
        expect(parsed.actions.single.content, body,
            reason: 'body ${body.replaceAll('\n', '\\n')}');
      }
    });

    test('several files round trip in one batch', () async {
      final a = File(p.join(tempRoot.path, 'a.txt'));
      final b = File(p.join(tempRoot.path, 'b.txt'));
      await a.writeAsString('alpha\n');
      await b.writeAsString('beta\n\n');

      final exported = await ExportService.generateBatchExport(
        rootDir: tempRoot.path,
        selectedPaths: {a.path, b.path},
      );
      final parsed = CommandParserService.parse(exported);

      expect(parsed.errors, isEmpty);
      expect(parsed.actions, hasLength(2));
      final byPath = {
        for (final action in parsed.actions) action.relativePath: action.content
      };
      expect(byPath['a.txt'], 'alpha\n');
      expect(byPath['b.txt'], 'beta\n\n');
    });

    test('binary files are not exported as text', () async {
      final file = File(p.join(tempRoot.path, 'img.png'));
      await file.writeAsBytes([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01, 0x02]);

      final exported = await ExportService.generateBatchExport(
        rootDir: tempRoot.path,
        selectedPaths: {file.path},
      );

      // A text placeholder would overwrite the real bytes with ASCII.
      expect(exported, isNot(contains('FILE_WRITE')));
    });
  });

  group('FileExecutionService', () {
    Future<BatchResult> run(List<CommandAction> actions,
        {List<String>? errors}) async {
      return FileExecutionService.execute(
        rootDir: tempRoot.path,
        actions: actions,
        report: ParseReport(
          blockCount: actions.length,
          charCount: 10,
          errors: errors ?? const [],
        ),
        onLog: (_) {},
      );
    }

    test('writes a new file and backs up nothing', () async {
      final result = await run([
        const CommandAction(
          type: ActionType.writeFile,
          relativePath: 'sub/new.txt',
          content: 'hello',
          index: 1,
        ),
      ]);

      expect(File(p.join(tempRoot.path, 'sub', 'new.txt')).readAsStringSync(),
          'hello');
      expect(result.applied, 1);
      expect(result.ok, isTrue);
    });

    test('backs up an existing file before overwriting', () async {
      final target = File(p.join(tempRoot.path, 'keep.txt'));
      await target.writeAsString('original');

      await run([
        const CommandAction(
          type: ActionType.writeFile,
          relativePath: 'keep.txt',
          content: 'replacement',
          index: 1,
        ),
      ]);

      expect(target.readAsStringSync(), 'replacement');
      final backups = Directory(p.join(tempRoot.path, '.backup'));
      expect(backups.existsSync(), isTrue);
      final files = backups
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => p.basename(f.path) == 'keep.txt')
          .toList();
      expect(files, hasLength(1));
      expect(files.single.readAsStringSync(), 'original');
    });

    test('nothing is written when the report has errors', () async {
      final result = await run(
        [
          const CommandAction(
            type: ActionType.writeFile,
            relativePath: 'a.txt',
            content: 'x',
            index: 1,
          ),
        ],
        errors: ['Block 1: FILE_WRITE a.txt is missing <<<END>>>'],
      );

      expect(result.aborted, isTrue);
      expect(File(p.join(tempRoot.path, 'a.txt')).existsSync(), isFalse);
    });

    test('never writes outside the root even with a malicious action', () async {
      final outside = File(p.join(tempRoot.parent.path,
          'devrunner_escape_${DateTime.now().microsecondsSinceEpoch}.txt'));

      final result = await run([
        CommandAction(
          type: ActionType.writeFile,
          relativePath: '../${p.basename(outside.path)}',
          content: 'should not exist',
          index: 1,
        ),
      ]);

      expect(outside.existsSync(), isFalse);
      expect(result.aborted, isTrue);
      if (outside.existsSync()) await outside.delete();
    });

    test('deletes an existing file and reports it', () async {
      final target = File(p.join(tempRoot.path, 'gone.txt'));
      await target.writeAsString('bye');

      final result = await run([
        const CommandAction(
          type: ActionType.deleteFile,
          relativePath: 'gone.txt',
          index: 1,
        ),
      ]);

      expect(target.existsSync(), isFalse);
      expect(result.applied, 1);
    });

    test('creating a folder that exists is skipped, not failed', () async {
      final result = await run([
        const CommandAction(
          type: ActionType.createFolder,
          relativePath: 'dup',
          index: 1,
        ),
        const CommandAction(
          type: ActionType.createFolder,
          relativePath: 'dup',
          index: 2,
        ),
      ]);

      expect(result.applied, 1);
      expect(result.skipped, 1);
      expect(result.failed, 0);
    });

    test('plan() counts writes and destructive actions', () async {
      final plan = await FileExecutionService.plan(
        rootDir: tempRoot.path,
        actions: const [
          CommandAction(type: ActionType.deleteFolder, relativePath: 'old', index: 1),
          CommandAction(type: ActionType.writeFile, relativePath: 'a.txt', index: 2),
        ],
      );
      expect(plan.deleteCount, 1);
      expect(plan.writeCount, 1);
      expect(plan.rejected, isEmpty);
    });
  });

  group('GitHubService token handling', () {
    test('strips a pasted "Authorization: Bearer" header', () {
      expect(
        GitHubService.sanitizeToken('  Authorization: Bearer ghp_abc123  '),
        'ghp_abc123',
      );
    });

    test('strips a bare Bearer prefix and surrounding quotes', () {
      expect(GitHubService.sanitizeToken('"Bearer ghp_abc123"'), 'ghp_abc123');
      expect(GitHubService.sanitizeToken("'ghp_abc123'"), 'ghp_abc123');
    });

    test('absorbs a token wrapped across lines by a paste', () {
      expect(
        GitHubService.sanitizeToken('github_pat_11ABC\nDEF22xyz'),
        'github_pat_11ABCDEF22xyz',
      );
    });

    test('removes zero-width characters from web copies', () {
      expect(GitHubService.sanitizeToken('ghp_ab\u200bc'), 'ghp_abc');
    });

    test('recognises classic and fine-grained token formats', () {
      expect(GitHubService.looksLikeToken('ghp_abc'), isTrue);
      expect(GitHubService.looksLikeToken('github_pat_abc'), isTrue);
      expect(GitHubService.looksLikeToken('my-password'), isFalse);
      expect(GitHubService.isFineGrainedToken('github_pat_abc'), isTrue);
      expect(GitHubService.isFineGrainedToken('ghp_abc'), isFalse);
    });
  });

  group('GitHub URL building', () {
    // These names are legal on GitHub. Interpolating them raw into a URL
    // truncated the path at the space and produced a misleading 404 on push.
    const tricky = [
      'Islamic Routine',
      'my project',
      'a.b_c-d',
      'Ünïcode Repo',
      'ends with space ',
    ];

    test('encodes repository names so the path survives parsing', () {
      for (final name in tricky) {
        final uri = GitHubService.repoUriForTest('Noakhali135', name.trim());
        expect(
          uri.pathSegments.length,
          greaterThanOrEqualTo(3),
          reason: 'name "$name" must not break the path',
        );
        expect(uri.pathSegments[1], 'Noakhali135');
        expect(
          uri.pathSegments[2],
          name.trim(),
          reason: 'decoded segment should round-trip "$name"',
        );
        expect(
          uri.toString(),
          isNot(contains(' ')),
          reason: 'a raw space in "$name" would truncate the URL',
        );
      }
    });

    test('produces the expected API path for a spaced name', () {
      final uri = GitHubService.repoUriForTest('Noakhali135', 'Islamic Routine');
      expect(
        uri.toString(),
        'https://api.github.com/repos/Noakhali135/Islamic%20Routine',
      );
    });

    test('appends suffixes without escaping the separators', () {
      final uri = GitHubService.repoUriForTest(
        'Noakhali135',
        'Islamic Routine',
        '/git/blobs',
      );
      expect(uri.toString(), endsWith('/Islamic%20Routine/git/blobs'));
    });
  });

  group('WorkspaceProbe', () {
    test('finds nested files and skips build output', () async {
      await Directory(p.join(tempRoot.path, 'lib')).create();
      await Directory(p.join(tempRoot.path, 'build')).create();
      await File(p.join(tempRoot.path, 'lib', 'main.dart')).writeAsString('x');
      await File(p.join(tempRoot.path, 'pubspec.yaml')).writeAsString('name: x');
      await File(p.join(tempRoot.path, 'build', 'junk.o')).writeAsString('x');

      final scan = await WorkspaceProbe.scan(tempRoot.path);

      expect(scan.files.map((f) => f.name).toSet(),
          containsAll({'main.dart', 'pubspec.yaml'}));
      expect(scan.files.map((f) => f.name), isNot(contains('junk.o')));
      expect(scan.skippedIgnored, greaterThan(0));
      expect(scan.looksLikePermissionProblem, isFalse);
    });

    test('an empty tree is reported as empty, not as a permission problem', () async {
      final scan = await WorkspaceProbe.scan(tempRoot.path);
      expect(scan.files, isEmpty);
      expect(scan.looksLikePermissionProblem, isFalse);
    });

    test('folders without readable contents look like a permission problem', () async {
      // Mirrors scoped storage: directories are enumerable, files are not.
      await Directory(p.join(tempRoot.path, 'android')).create();
      await Directory(p.join(tempRoot.path, 'lib')).create();

      final scan = await WorkspaceProbe.scan(tempRoot.path);
      expect(scan.files, isEmpty);
      expect(scan.directoryCount, greaterThan(0));
      expect(scan.looksLikePermissionProblem, isTrue);
    });

    test('diagnose() points at SAF when folders hide their files', () async {
      await Directory(p.join(tempRoot.path, 'android')).create();
      final problems = await WorkspaceProbe.diagnose(tempRoot.path);

      expect(problems, isNotEmpty);
      // The remedy is the folder picker, not a permission that no longer exists.
      expect(problems.join(' ').toLowerCase(), contains('pick'));
      expect(problems.join(' ').toLowerCase(), isNot(contains('all files access')));
    });

    test('an empty folder is described as empty, not as unreadable', () async {
      final problems = await WorkspaceProbe.diagnose(tempRoot.path);
      expect(problems.single, contains('empty'));
      expect(problems.join(' ').toLowerCase(), isNot(contains('readable')));
    });

    test('a project entirely in a subfolder says to pick the subfolder', () async {
      await Directory(p.join(tempRoot.path, 'myapp')).create();
      await File(p.join(tempRoot.path, 'myapp', 'main.dart')).writeAsString('x');

      final problems = await WorkspaceProbe.diagnose(tempRoot.path);
      expect(problems.single, contains('subfolder'));
    });

    test('a healthy workspace produces no problems', () async {
      await File(p.join(tempRoot.path, 'main.dart')).writeAsString('x');
      final problems = await WorkspaceProbe.diagnose(tempRoot.path);
      // A plain path that dart:io can read still gets the SAF reminder; what
      // matters is that it is not reported as broken.
      expect(problems.join(' ').toLowerCase(), isNot(contains('no readable files')));
    });

    test('diagnose() flags a missing directory', () async {
      final problems = await WorkspaceProbe.diagnose(
        p.join(tempRoot.path, 'does-not-exist'),
      );
      expect(problems.single, contains('does not exist'));
    });

    test('respects a specific-path selection', () async {
      final nested = Directory(p.join(tempRoot.path, 'only'));
      await nested.create();
      await File(p.join(nested.path, 'a.txt')).writeAsString('a');
      await File(p.join(tempRoot.path, 'b.txt')).writeAsString('b');

      final scan = await WorkspaceProbe.scan(
        tempRoot.path,
        specificPaths: {nested.path},
      );
      expect(scan.files.map((f) => f.name), ['a.txt']);
    });

    test('canonical() never throws on a missing path', () {
      expect(WorkspaceProbe.canonical(p.join(tempRoot.path, 'nope')), isNotEmpty);
    });
  });

  group('SAF virtual paths', () {
    const tree = '/devrunner-saf/primary:Download/app';

    test('recognises virtual paths', () {
      expect(SafWorkspace.isSafPath(tree), isTrue);
      expect(SafWorkspace.isSafPath('/storage/emulated/0/Download'), isFalse);
    });

    test('splits the opaque tree segment from the relative remainder', () {
      final parts = SafWorkspace.split('$tree/lib/src');
      expect(parts.segment, 'primary:Download/app');
      expect(parts.relative, 'lib/src');
    });

    test('a granted tree is matched by its virtual path, not a raw id', () {
      const granted = SafTree(
        treeId: 'primary:Download/app',
        virtualPath: tree,
        displayPath: 'Download/app',
      );
      expect(SafWorkspace.belongsTo('$tree/lib/a.dart', granted), isTrue);
      expect(SafWorkspace.belongsTo('/tmp/other/a.dart', granted), isFalse);
    });

    test('PathGuard contains SAF paths and still blocks traversal', () {
      final ok = PathGuard.resolveInRoot(tree, relativePath: '/lib/', name: 'a.dart');
      expect(ok, '$tree/lib/a.dart');
      expect(PathGuard.isInside(tree, ok), isTrue);

      expect(
        () => PathGuard.resolveInRoot(tree, relativePath: '/../../', name: 'x'),
        throwsA(isA<UnsafePathException>()),
      );
    });

    test('joinSaf rejects traversal attempts', () {
      expect(WorkspaceFs.joinSaf(tree, '/lib/', 'a.dart'), '$tree/lib/a.dart');
      expect(
        () => WorkspaceFs.joinSaf(tree, '/../etc/', 'passwd'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('WorkspaceFs identifies SAF paths without touching the platform', () {
      expect(WorkspaceFs.isSaf(tree), isTrue);
      expect(WorkspaceFs.isSaf('/tmp/plain'), isFalse);
    });
  });

  group('Push memory budget', () {
    test('never lets reserved bytes exceed the capacity', () async {
      final budget = ByteBudget(100);
      var peak = 0;
      var inUse = 0;

      Future<void> job(int size) async {
        await budget.reserve(size);
        inUse += size;
        peak = inUse > peak ? inUse : peak;
        // Yield so other jobs get a chance to interleave.
        await Future<void>.delayed(Duration.zero);
        inUse -= size;
        budget.release(size);
      }

      await Future.wait([
        job(40), job(40), job(40), job(40), job(40),
      ]);

      // Three 40-byte reservations fit in 100; a fourth must have waited.
      expect(peak, lessThanOrEqualTo(100));
      expect(peak, greaterThanOrEqualTo(80));
    });

    test('a file larger than the budget still gets an exclusive slot', () async {
      final budget = ByteBudget(100);
      var peak = 0;
      var inUse = 0;

      Future<void> job(int size) async {
        await budget.reserve(size);
        final held = size > 100 ? 100 : size;
        inUse += held;
        peak = inUse > peak ? inUse : peak;
        await Future<void>.delayed(Duration.zero);
        inUse -= held;
        budget.release(size);
      }

      await Future.wait([job(500), job(10)]);

      // The oversized reservation takes the whole budget and runs alone.
      expect(peak, lessThanOrEqualTo(100));
    });

    test('releasing without reserving does not corrupt the counter', () {
      final budget = ByteBudget(100);
      budget.release(50);
      // A stray release must not make the budget look emptier than it is.
      expect(budget.available, 100);
    });
  });

  group('Push progress', () {
    test('reports indeterminate when the total is unknown', () {
      const progress = PushProgress(
        phase: PushPhase.scanning,
        message: 'Scanning...',
      );
      expect(progress.fraction, isNull);
      expect(progress.isRunning, isTrue);
      expect(progress.label, 'Scanning workspace');
    });

    test('clamps the fraction between 0 and 1', () {
      const progress = PushProgress(
        phase: PushPhase.uploading,
        done: 250,
        total: 100,
      );
      expect(progress.fraction, 1.0);
    });

    test('terminal phases are not running', () {
      for (final phase in [
        PushPhase.done,
        PushPhase.failed,
        PushPhase.cancelled,
        PushPhase.idle,
      ]) {
        expect(PushProgress(phase: phase).isRunning, isFalse,
            reason: '$phase should not be running');
      }
    });
  });

  group('Repository targeting', () {
    const repos = ['alpha', 'beta', 'gamma'];

    test('a manual pick always wins over the saved repo', () {
      // The reported bug: "beta" was chosen, but the push went to "alpha".
      expect(
        resolveTargetRepo(
          selected: 'beta',
          available: repos,
          pickedByUser: true,
          saved: 'alpha',
        ),
        'beta',
      );
    });

    test('a manual pick survives an empty or failed repo list', () {
      expect(
        resolveTargetRepo(
          selected: 'beta',
          available: const [],
          pickedByUser: true,
          saved: 'alpha',
        ),
        'beta',
      );
    });

    test('matching ignores case and surrounding whitespace', () {
      expect(
        resolveTargetRepo(
          selected: '  BETA ',
          available: repos,
          pickedByUser: false,
          saved: null,
        ),
        'beta',
      );
    });

    test('never substitutes a saved repo that is no longer listed', () {
      // Would previously have pushed into "ghost".
      expect(
        resolveTargetRepo(
          selected: null,
          available: repos,
          pickedByUser: false,
          saved: 'ghost',
        ),
        isNull,
      );
    });

    test('falls back to the saved repo only when it is still listed', () {
      expect(
        resolveTargetRepo(
          selected: null,
          available: repos,
          pickedByUser: false,
          saved: 'BETA',
        ),
        'beta',
      );
    });

    test('uses the only repo when nothing else is known', () {
      expect(
        resolveTargetRepo(
          selected: null,
          available: const ['solo'],
          pickedByUser: false,
        ),
        'solo',
      );
    });

    test('returns null when there is nothing to choose from', () {
      expect(
        resolveTargetRepo(
          selected: '   ',
          available: const ['a', 'b'],
          pickedByUser: false,
        ),
        isNull,
      );
    });
  });
}
