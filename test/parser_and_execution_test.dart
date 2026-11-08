import 'dart:io';

import 'package:executor/models/command_action.dart';
import 'package:executor/services/command_parser_service.dart';
import 'package:executor/services/export_service.dart';
import 'package:executor/services/file_execution_service.dart';
import 'package:executor/services/github_service.dart';
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
  });

  group('CommandParserService', () {
    test('parses a create-file action', () {
      final result = CommandParserService.parse(
        '[ACTION]: CREATE_FILE\n[PATH]: /lib/\n[NAME]: a.dart\n[CONTENT]:\nvoid main() {}\n[ENDFILE]',
      );
      expect(result.errors, isEmpty);
      expect(result.actions, hasLength(1));
      expect(result.actions.single.content, 'void main() {}');
    });

    test('flags a traversal path as a blockable action, not a silent write', () {
      final plan = FileExecutionService.plan(
        rootDir: tempRoot.path,
        actions: CommandParserService.parse(
          '[ACTION]: CREATE_FILE\n[PATH]: /../../\n[NAME]: escape.txt\n[CONTENT]:\npwned',
        ).actions,
      );
      expect(plan.errors, isNotEmpty);
      expect(plan.runnable.where((i) => i.action.type == ActionType.createFile), isEmpty);
    });

    test('[REST] stops AI prose being appended to the last file', () {
      final result = CommandParserService.parse(
        '[ACTION]: CREATE_FILE\n[PATH]: /\n[NAME]: x.txt\n[CONTENT]:\nbody\n'
        '[REST]\nHere is a summary of the changes I made...',
      );
      expect(result.actions.single.content, 'body');
    });

    test('preserves trailing blank lines in file content', () {
      final result = CommandParserService.parse(
        '[ACTION]: CREATE_FILE\n[PATH]: /\n[NAME]: y.txt\n[CONTENT]:\nline1\nline2\n\n',
      );
      expect(result.actions.single.content, 'line1\nline2\n');
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

    test('binary files are marked SKIP_BINARY, never as text', () async {
      final file = File(p.join(tempRoot.path, 'img.png'));
      await file.writeAsBytes([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01, 0x02]);

      final exported = await ExportService.generateBatchExport(
        rootDir: tempRoot.path,
        selectedPaths: {file.path},
      );

      expect(exported, contains('SKIP_BINARY'));
      expect(CommandParserService.parse(exported).actions.single.type,
          ActionType.skipBinary);
    });
  });

  group('FileExecutionService', () {
    test('executes a create-file batch inside the workspace', () async {
      final dir = Directory(p.join(tempRoot.path, 'sub'));
      final logs = await FileExecutionService.executeBatch(
        rootDir: tempRoot.path,
        actions: [
          const CommandAction(
            type: ActionType.createFile,
            relativePath: '/sub/',
            name: 'new.txt',
            content: 'hello',
          ),
        ],
        onLog: (_) {},
      );

      expect(File(p.join(dir.path, 'new.txt')).readAsStringSync(), 'hello');
      expect(logs.last.message, contains('Failed: 0'));
    });

    test('never writes outside the root even with a malicious action', () async {
      final outside = File(p.join(tempRoot.parent.path, 'devrunner_escape_${DateTime.now().microsecondsSinceEpoch}.txt'));

      await FileExecutionService.executeBatch(
        rootDir: tempRoot.path,
        actions: [
          CommandAction(
            type: ActionType.createFile,
            relativePath: '/../../',
            name: p.basename(outside.path),
            content: 'should not exist',
          ),
        ],
        onLog: (_) {},
      );

      expect(outside.existsSync(), isFalse);
      if (outside.existsSync()) await outside.delete();
    });

    test('a missing delete target is reported as skipped, not success', () async {
      final logs = await FileExecutionService.executeBatch(
        rootDir: tempRoot.path,
        actions: [
          const CommandAction(type: ActionType.deleteFile, relativePath: '/', name: 'ghost.txt'),
        ],
        onLog: (_) {},
      );
      expect(logs.last.message, contains('Success: 0'));
      expect(logs.last.message, contains('Skipped: 1'));
    });

    test('plan() counts destructive actions for the confirmation sheet', () {
      final plan = FileExecutionService.plan(
        rootDir: tempRoot.path,
        actions: const [
          CommandAction(type: ActionType.deleteFolder, relativePath: '/old/', name: 'cache'),
          CommandAction(type: ActionType.createFile, relativePath: '/', name: 'a.txt'),
        ],
      );
      expect(plan.deleteCount, 1);
      expect(plan.createCount, 1);
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

      expect(scan.files.map((f) => p.basename(f.path)).toSet(),
          containsAll({'main.dart', 'pubspec.yaml'}));
      expect(scan.files.map((f) => p.basename(f.path)), isNot(contains('junk.o')));
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

    test('diagnose() explains the scoped-storage case', () async {
      await Directory(p.join(tempRoot.path, 'android')).create();
      final problems = await WorkspaceProbe.diagnose(tempRoot.path);

      expect(problems, isNotEmpty);
      expect(problems.join(' ').toLowerCase(), contains('all files access'));
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
      expect(scan.files.map((f) => p.basename(f.path)), ['a.txt']);
    });

    test('canonical() never throws on a missing path', () {
      expect(WorkspaceProbe.canonical(p.join(tempRoot.path, 'nope')), isNotEmpty);
    });
  });
}
