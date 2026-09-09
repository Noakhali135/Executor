import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/command_action.dart';

class TokenVerifyResult {
  final bool success;
  final String? username;
  final String? errorMessage;

  const TokenVerifyResult({
    required this.success,
    this.username,
    this.errorMessage,
  });
}

class _LocalFileToUpload {
  final File file;
  final String relPath;
  final Uint8List bytes;
  final String gitSha;
  final bool isNew;

  const _LocalFileToUpload({
    required this.file,
    required this.relPath,
    required this.bytes,
    required this.gitSha,
    required this.isNew,
  });
}

class GitHubService {
  static const String _keyToken = 'github_pat_token';
  static const String _keyUsername = 'github_pat_username';
  static const String _keySelectedRepo = 'github_last_selected_repo';
  static const String _baseUrl = 'https://api.github.com';

  static Future<String?> getToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyToken);
  }

  static Future<String?> getCachedUsername() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyUsername);
  }

  static Future<String?> getSavedRepo() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keySelectedRepo);
  }

  static Future<void> saveRepo(String repoName) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keySelectedRepo, repoName.trim());
  }

  static Future<void> saveToken(String token, String username) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyToken, token.trim());
    await prefs.setString(_keyUsername, username.trim());
  }

  static Future<void> clearToken() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyToken);
    await prefs.remove(_keyUsername);
    await prefs.remove(_keySelectedRepo);
  }

  static Map<String, String> _headers(String token) {
    final clean = token.trim();
    return {
      'Authorization': 'Bearer $clean',
      'Accept': 'application/vnd.github+json',
      'User-Agent': 'DevRunner-Mobile-App',
      'X-GitHub-Api-Version': '2022-11-28',
      'Content-Type': 'application/json',
    };
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) {
      return '$bytes B';
    } else if (bytes < 1024 * 1024) {
      final kb = bytes / 1024.0;
      return '${kb.toStringAsFixed(1)} KB';
    } else {
      final mb = bytes / (1024.0 * 1024.0);
      return '${mb.toStringAsFixed(2)} MB';
    }
  }

  static String _calculateGitBlobSha(Uint8List bytes) {
    final header = utf8.encode('blob ${bytes.length}\x00');
    final combined = Uint8List(header.length + bytes.length)
      ..setRange(0, header.length, header)
      ..setRange(header.length, header.length + bytes.length, bytes);
    return sha1.convert(combined).toString();
  }

  static Future<TokenVerifyResult> verifyToken(String rawToken) async {
    final token = rawToken.trim();
    if (token.isEmpty) {
      return const TokenVerifyResult(success: false, errorMessage: 'Token cannot be empty');
    }

    final client = http.Client();
    try {
      final res = await client.get(
        Uri.parse('$_baseUrl/user'),
        headers: _headers(token),
      ).timeout(const Duration(seconds: 15));

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        return TokenVerifyResult(
          success: true,
          username: data['login'] as String?,
        );
      } else {
        try {
          final errBody = jsonDecode(res.body);
          final msg = errBody['message'] ?? 'HTTP ${res.statusCode}';
          return TokenVerifyResult(
            success: false,
            errorMessage: '$msg (${res.statusCode})',
          );
        } catch (_) {
          return TokenVerifyResult(
            success: false,
            errorMessage: 'GitHub returned HTTP ${res.statusCode}',
          );
        }
      }
    } on SocketException catch (_) {
      return const TokenVerifyResult(
        success: false,
        errorMessage: 'Network error: Unable to resolve api.github.com. Check device internet.',
      );
    } catch (e) {
      return TokenVerifyResult(
        success: false,
        errorMessage: 'Connection failed: $e',
      );
    } finally {
      client.close();
    }
  }

  static Future<List<Map<String, dynamic>>> getUserRepos(String token) async {
    final client = http.Client();
    try {
      final res = await client.get(
        Uri.parse('$_baseUrl/user/repos?per_page=100&sort=updated'),
        headers: _headers(token),
      ).timeout(const Duration(seconds: 15));
      if (res.statusCode == 200) {
        final list = jsonDecode(res.body) as List;
        return list.map((e) => {
          'name': e['name'] as String,
          'full_name': e['full_name'] as String,
          'private': e['private'] as bool,
          'default_branch': e['default_branch'] as String? ?? 'main',
        }).toList();
      }
    } catch (_) {} finally {
      client.close();
    }
    return [];
  }

  static Future<bool> createRepository({
    required String token,
    required String repoName,
    required bool isPrivate,
    required String description,
  }) async {
    final client = http.Client();
    try {
      final res = await client.post(
        Uri.parse('$_baseUrl/user/repos'),
        headers: _headers(token),
        body: jsonEncode({
          'name': repoName.trim(),
          'private': isPrivate,
          'description': description,
          'auto_init': true,
        }),
      ).timeout(const Duration(seconds: 15));
      return res.statusCode == 201;
    } catch (_) {
      return false;
    } finally {
      client.close();
    }
  }

  static Future<void> _runSlidingPool<T>({
    required List<T> items,
    required int concurrency,
    required Future<void> Function(T item) worker,
  }) async {
    int nextIndex = 0;
    final futures = <Future<void>>[];

    Future<void> launchWorker() async {
      while (true) {
        int currentIndex;
        if (nextIndex >= items.length) {
          return;
        }
        currentIndex = nextIndex++;
        await worker(items[currentIndex]);
      }
    }

    final workerCount = items.length < concurrency ? items.length : concurrency;
    for (int i = 0; i < workerCount; i++) {
      futures.add(launchWorker());
    }

    await Future.wait(futures);
  }

  static Future<void> pushWorkspace({
    required String token,
    required String owner,
    required String repoName,
    required String branch,
    required String commitMessage,
    required String workingDir,
    Set<String>? specificPaths,
    required Function(String message, LogLevel level) onLog,
  }) async {
    final client = http.Client();
    final stopwatch = Stopwatch()..start();

    try {
      onLog('Connecting to GitHub API as @$owner...', LogLevel.info);

      final fileEntries = <File>[];

      if (specificPaths != null && specificPaths.isNotEmpty) {
        for (final pth in specificPaths) {
          final f = File(pth);
          final d = Directory(pth);
          if (await f.exists()) {
            fileEntries.add(f);
          } else if (await d.exists()) {
            final entries = await d.list(recursive: true, followLinks: false).toList();
            for (final e in entries) {
              if (e is File) {
                final rel = p.relative(e.path, from: workingDir);
                if (!p.split(rel).contains('.git')) {
                  fileEntries.add(e);
                }
              }
            }
          }
        }
      } else {
        final root = Directory(workingDir);
        if (!await root.exists()) {
          onLog('Working directory not found: $workingDir', LogLevel.error);
          return;
        }
        final entries = await root.list(recursive: true, followLinks: false).toList();
        for (final e in entries) {
          if (e is File) {
            final rel = p.relative(e.path, from: workingDir);
            if (p.split(rel).contains('.git')) {
              continue;
            }
            fileEntries.add(e);
          }
        }
      }

      if (fileEntries.isEmpty) {
        onLog('No files found to push to GitHub.', LogLevel.warning);
        return;
      }

      onLog('Scanned ${fileEntries.length} file(s) in workspace.', LogLevel.info);

      String? parentCommitSha;
      String? baseTreeSha;

      final refRes = await client.get(
        Uri.parse('$_baseUrl/repos/$owner/$repoName/git/ref/heads/$branch'),
        headers: _headers(token),
      ).timeout(const Duration(seconds: 15));

      if (refRes.statusCode == 200) {
        final refData = jsonDecode(refRes.body);
        parentCommitSha = refData['object']['sha'];
        final commitRes = await client.get(
          Uri.parse('$_baseUrl/repos/$owner/$repoName/git/commits/$parentCommitSha'),
          headers: _headers(token),
        ).timeout(const Duration(seconds: 15));
        if (commitRes.statusCode == 200) {
          baseTreeSha = jsonDecode(commitRes.body)['tree']['sha'];
        }
      } else {
        final defaultRefRes = await client.get(
          Uri.parse('$_baseUrl/repos/$owner/$repoName/git/ref/heads/main'),
          headers: _headers(token),
        ).timeout(const Duration(seconds: 15));
        if (defaultRefRes.statusCode == 200) {
          final refData = jsonDecode(defaultRefRes.body);
          parentCommitSha = refData['object']['sha'];
          final commitRes = await client.get(
            Uri.parse('$_baseUrl/repos/$owner/$repoName/git/commits/$parentCommitSha'),
            headers: _headers(token),
          ).timeout(const Duration(seconds: 15));
          if (commitRes.statusCode == 200) {
            baseTreeSha = jsonDecode(commitRes.body)['tree']['sha'];
          }
        }
      }

      final existingRemoteBlobs = <String, String>{};
      if (baseTreeSha != null) {
        try {
          final treeFetchRes = await client.get(
            Uri.parse('$_baseUrl/repos/$owner/$repoName/git/trees/$baseTreeSha?recursive=1'),
            headers: _headers(token),
          ).timeout(const Duration(seconds: 15));

          if (treeFetchRes.statusCode == 200) {
            final treeData = jsonDecode(treeFetchRes.body);
            if (treeData['tree'] is List) {
              for (final item in treeData['tree']) {
                if (item['type'] == 'blob' && item['path'] is String && item['sha'] is String) {
                  existingRemoteBlobs[item['path'] as String] = item['sha'] as String;
                }
              }
            }
          }
        } catch (_) {}
      }

      final treeNodes = <Map<String, dynamic>>[];
      final filesToUpload = <_LocalFileToUpload>[];
      int totalScannedBytes = 0;
      int totalUploadBytes = 0;
      int newCount = 0;
      int modifiedCount = 0;
      int unchangedCount = 0;

      for (int i = 0; i < fileEntries.length; i++) {
        final file = fileEntries[i];
        final relPath = p.relative(file.path, from: workingDir).replaceAll(r'\', '/');
        final bytes = await file.readAsBytes();
        final localSha = _calculateGitBlobSha(bytes);
        totalScannedBytes += bytes.length;

        if (existingRemoteBlobs.containsKey(relPath)) {
          if (existingRemoteBlobs[relPath] == localSha) {
            unchangedCount++;
            treeNodes.add({
              'path': relPath,
              'mode': '100644',
              'type': 'blob',
              'sha': localSha,
            });
          } else {
            modifiedCount++;
            totalUploadBytes += bytes.length;
            filesToUpload.add(_LocalFileToUpload(
              file: file,
              relPath: relPath,
              bytes: bytes,
              gitSha: localSha,
              isNew: false,
            ));
          }
        } else {
          newCount++;
          totalUploadBytes += bytes.length;
          filesToUpload.add(_LocalFileToUpload(
            file: file,
            relPath: relPath,
            bytes: bytes,
            gitSha: localSha,
            isNew: true,
          ));
        }

        if (i % 25 == 0) {
          await Future.delayed(Duration.zero);
        }
      }

      final summaryDiff = [
        if (newCount > 0) '$newCount new',
        if (modifiedCount > 0) '$modifiedCount modified',
        if (unchangedCount > 0) '$unchangedCount unchanged',
      ].join(', ');

      onLog('Diff analysis: $summaryDiff', LogLevel.info);
      onLog('Payload: ${filesToUpload.length} file(s) to upload (${_formatBytes(totalUploadBytes)}) [Total workspace: ${_formatBytes(totalScannedBytes)}]', LogLevel.info);

      if (filesToUpload.isEmpty) {
        onLog('[SUCCESS] Everything is up-to-date! All $unchangedCount file(s) already match GitHub.', LogLevel.success);
        return;
      }

      onLog('Streaming ${filesToUpload.length} file(s) across 16 parallel workers...', LogLevel.info);
      int uploadedCounter = 0;
      int uploadedBytesCounter = 0;

      await _runSlidingPool<_LocalFileToUpload>(
        items: filesToUpload,
        concurrency: 16,
        worker: (item) async {
          final contentBase64 = base64Encode(item.bytes);
          final blobRes = await client.post(
            Uri.parse('$_baseUrl/repos/$owner/$repoName/git/blobs'),
            headers: _headers(token),
            body: jsonEncode({
              'content': contentBase64,
              'encoding': 'base64',
            }),
          ).timeout(const Duration(seconds: 30));

          if (blobRes.statusCode == 201) {
            final blobSha = jsonDecode(blobRes.body)['sha'];
            treeNodes.add({
              'path': item.relPath,
              'mode': '100644',
              'type': 'blob',
              'sha': blobSha,
            });
            uploadedBytesCounter += item.bytes.length;
          } else {
            onLog('Blob error for ${item.relPath}: ${blobRes.body}', LogLevel.warning);
          }

          uploadedCounter++;
          if (uploadedCounter % 15 == 0 || uploadedCounter == filesToUpload.length) {
            onLog('Uploaded $uploadedCounter/${filesToUpload.length} files (${_formatBytes(uploadedBytesCounter)} / ${_formatBytes(totalUploadBytes)})...', LogLevel.info);
          }
        },
      );

      onLog('Generating Git Tree with ${treeNodes.length} objects...', LogLevel.info);
      final treePayload = <String, dynamic>{
        'tree': treeNodes,
      };
      if (baseTreeSha != null) {
        treePayload['base_tree'] = baseTreeSha;
      }

      final treeRes = await client.post(
        Uri.parse('$_baseUrl/repos/$owner/$repoName/git/trees'),
        headers: _headers(token),
        body: jsonEncode(treePayload),
      ).timeout(const Duration(seconds: 25));

      if (treeRes.statusCode != 201) {
        onLog('Failed to create Git Tree: ${treeRes.body}', LogLevel.error);
        return;
      }

      final newTreeSha = jsonDecode(treeRes.body)['sha'];

      onLog('Creating commit "$commitMessage"...', LogLevel.info);
      final commitPayload = <String, dynamic>{
        'message': commitMessage,
        'tree': newTreeSha,
      };
      if (parentCommitSha != null) {
        commitPayload['parents'] = [parentCommitSha];
      } else {
        commitPayload['parents'] = [];
      }

      final commitRes = await client.post(
        Uri.parse('$_baseUrl/repos/$owner/$repoName/git/commits'),
        headers: _headers(token),
        body: jsonEncode(commitPayload),
      ).timeout(const Duration(seconds: 25));

      if (commitRes.statusCode != 201) {
        onLog('Failed to create commit: ${commitRes.body}', LogLevel.error);
        return;
      }

      final newCommitSha = jsonDecode(commitRes.body)['sha'];
      final shortSha = newCommitSha.toString().substring(0, 7);

      final checkRef = await client.get(
        Uri.parse('$_baseUrl/repos/$owner/$repoName/git/ref/heads/$branch'),
        headers: _headers(token),
      ).timeout(const Duration(seconds: 15));

      final elapsedSeconds = stopwatch.elapsedMilliseconds / 1000.0;
      final speedText = elapsedSeconds > 0
          ? '${_formatBytes((totalUploadBytes / elapsedSeconds).round())}/s'
          : 'N/A';

      if (checkRef.statusCode == 200) {
        final updateRefRes = await client.patch(
          Uri.parse('$_baseUrl/repos/$owner/$repoName/git/refs/heads/$branch'),
          headers: _headers(token),
          body: jsonEncode({'sha': newCommitSha, 'force': true}),
        ).timeout(const Duration(seconds: 15));

        if (updateRefRes.statusCode == 200) {
          onLog('[SUCCESS] Pushed commit $shortSha to branch "$branch"', LogLevel.success);
          onLog('[PUSH STATS] $newCount new, $modifiedCount modified, $unchangedCount cached | ${_formatBytes(totalUploadBytes)} uploaded in ${elapsedSeconds.toStringAsFixed(1)}s ($speedText)', LogLevel.success);
          onLog('Repository URL: https://github.com/$owner/$repoName/tree/$branch', LogLevel.success);
        } else {
          onLog('Failed to update branch reference: ${updateRefRes.body}', LogLevel.error);
        }
      } else {
        final createRefRes = await client.post(
          Uri.parse('$_baseUrl/repos/$owner/$repoName/git/refs'),
          headers: _headers(token),
          body: jsonEncode({
            'ref': 'refs/heads/$branch',
            'sha': newCommitSha,
          }),
        ).timeout(const Duration(seconds: 15));

        if (createRefRes.statusCode == 201) {
          onLog('[SUCCESS] Created new branch "$branch" with commit $shortSha', LogLevel.success);
          onLog('[PUSH STATS] $newCount new, $modifiedCount modified, $unchangedCount cached | ${_formatBytes(totalUploadBytes)} uploaded in ${elapsedSeconds.toStringAsFixed(1)}s ($speedText)', LogLevel.success);
          onLog('Repository URL: https://github.com/$owner/$repoName/tree/$branch', LogLevel.success);
        } else {
          onLog('Failed to create branch reference: ${createRefRes.body}', LogLevel.error);
        }
      }
    } on SocketException catch (_) {
      onLog('Network error: Unable to reach GitHub. Please check device internet connection.', LogLevel.error);
    } catch (e) {
      onLog('Unexpected error during GitHub push: $e', LogLevel.error);
    } finally {
      client.close();
    }
  }
}