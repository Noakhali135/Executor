import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/command_action.dart';
import 'secure_store.dart';

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

/// Thrown internally when the remote branch moved while we were building the
/// commit. Triggers a single clean retry against the new head.
class _PushConflict implements Exception {
  final String message;
  _PushConflict(this.message);
}

/// A file whose bytes will be uploaded.
class _LocalFileToUpload {
  final File file;
  final String relPath;
  final String gitSha;

  const _LocalFileToUpload({
    required this.file,
    required this.relPath,
    required this.gitSha,
  });
}

class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

class GitHubService {
  static const String _keyUsername = 'github_pat_username';
  static const String _keySelectedRepo = 'github_last_selected_repo';
  static const String _baseUrl = 'https://api.github.com';

  /// GitHub rejects blobs above 100 MB outright; we refuse earlier so a huge
  /// file cannot fail the whole push (or exhaust device memory).
  static const int maxBlobBytes = 45 * 1024 * 1024;

  /// Directories that are never worth pushing and are usually enormous.
  static const Set<String> _ignoredDirectoryNames = {
    '.git', '.dart_tool', 'build', 'node_modules', '.gradle', '.idea',
    '.vscode', '__pycache__', '.venv', 'venv', 'Pods', '.next', '.cache',
  };

  static const Duration _requestTimeout = Duration(seconds: 20);

  // ---------------------------------------------------------------- auth ----

  static Future<String?> getToken() => SecureStore.readToken();

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

  /// Stores the credential in the platform keystore and only the (non-secret)
  /// username in SharedPreferences.
  static Future<void> saveToken(String token, String username) async {
    await SecureStore.writeToken(token);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyUsername, username.trim());
  }

  static Future<void> clearToken() async {
    await SecureStore.deleteToken();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyUsername);
    await prefs.remove(_keySelectedRepo);
  }

  static Map<String, String> _headers(String token) {
    return {
      'Authorization': 'Bearer ${token.trim()}',
      'Accept': 'application/vnd.github+json',
      'User-Agent': 'DevRunner-Mobile-App',
      'X-GitHub-Api-Version': '2022-11-28',
      'Content-Type': 'application/json',
    };
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024.0).toStringAsFixed(1)} KB';
    return '${(bytes / (1024.0 * 1024.0)).toStringAsFixed(2)} MB';
  }

  // ----------------------------------------------------------------- sha ----

  /// Computes the git blob SHA without loading the file into memory.
  ///
  /// Previously every file was fully read and retained, so a large workspace
  /// could exhaust phone memory before the first upload.
  static Future<String> _calculateGitBlobShaStreaming(File file) async {
    final length = await file.length();
    final sink = _DigestSink();
    final hasher = sha1.startChunkedConversion(sink);
    hasher.add(utf8.encode('blob $length\x00'));
    await for (final chunk in file.openRead()) {
      hasher.add(chunk);
    }
    hasher.close();
    return sink.value.toString();
  }

  // ------------------------------------------------------------ endpoints ----

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
      ).timeout(_requestTimeout);

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        return TokenVerifyResult(success: true, username: data['login'] as String?);
      }
      return TokenVerifyResult(
        success: false,
        errorMessage: '${_extractMessage(res)} (${res.statusCode})',
      );
    } on TimeoutException {
      return const TokenVerifyResult(
        success: false,
        errorMessage: 'Request timed out. Check your internet connection.',
      );
    } on SocketException {
      return const TokenVerifyResult(
        success: false,
        errorMessage: 'Network error: unable to reach api.github.com.',
      );
    } catch (e) {
      return TokenVerifyResult(success: false, errorMessage: 'Connection failed: $e');
    } finally {
      client.close();
    }
  }

  static String _extractMessage(http.Response res) {
    try {
      final body = jsonDecode(res.body);
      if (body is Map && body['message'] is String) return body['message'] as String;
    } catch (_) {}
    if (res.statusCode == 401) return 'Invalid or expired token';
    if (res.statusCode == 403) return 'Forbidden (check token scopes / rate limit)';
    if (res.statusCode == 404) return 'Not found';
    return 'GitHub returned HTTP ${res.statusCode}';
  }

  /// Returns repositories plus their default branch so a push never has to
  /// assume `main`.
  static Future<List<Map<String, dynamic>>> getUserRepos(String token) async {
    final client = http.Client();
    try {
      final res = await client.get(
        Uri.parse('$_baseUrl/user/repos?per_page=100&sort=updated'),
        headers: _headers(token),
      ).timeout(_requestTimeout);
      if (res.statusCode == 200) {
        final list = jsonDecode(res.body) as List;
        return list.map((e) => {
              'name': e['name'] as String,
              'full_name': e['full_name'] as String,
              'private': e['private'] as bool,
              'default_branch': e['default_branch'] as String? ?? 'main',
            }).toList();
      }
    } on TimeoutException {
      return [];
    } catch (_) {
      return [];
    } finally {
      client.close();
    }
    return [];
  }

  /// Looks up the repository's default branch, falling back to `main`.
  static Future<String> getDefaultBranch({
    required String token,
    required String owner,
    required String repoName,
  }) async {
    final client = http.Client();
    try {
      final res = await client.get(
        Uri.parse('$_baseUrl/repos/$owner/$repoName'),
        headers: _headers(token),
      ).timeout(_requestTimeout);
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final branch = data['default_branch'] as String?;
        if (branch != null && branch.isNotEmpty) return branch;
      }
    } catch (_) {}
    finally {
      client.close();
    }
    return 'main';
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
      ).timeout(_requestTimeout);
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

    Future<void> launchWorker() async {
      while (true) {
        if (nextIndex >= items.length) return;
        final currentIndex = nextIndex++;
        await worker(items[currentIndex]);
      }
    }

    final workerCount = items.length < concurrency ? items.length : concurrency;
    final futures = <Future<void>>[];
    for (int i = 0; i < workerCount; i++) {
      futures.add(launchWorker());
    }
    await Future.wait(futures);
  }

  /// Pushes the workspace, retrying once if the branch moved underneath us.
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
    for (int attempt = 0; attempt < 2; attempt++) {
      try {
        await _pushOnce(
          token: token,
          owner: owner,
          repoName: repoName,
          branch: branch,
          commitMessage: commitMessage,
          workingDir: workingDir,
          specificPaths: specificPaths,
          onLog: onLog,
        );
        return;
      } on _PushConflict catch (e) {
        if (attempt == 0) {
          onLog('${e.message} Re-syncing with the remote and retrying once...', LogLevel.warning);
          continue;
        }
        onLog('Push aborted: ${e.message}', LogLevel.error);
        return;
      }
    }
  }

  static Future<void> _pushOnce({
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

      final files = await _collectFiles(
        workingDir: workingDir,
        specificPaths: specificPaths,
        onLog: onLog,
      );
      if (files.isEmpty) {
        onLog('No files found to push to GitHub.', LogLevel.warning);
        return;
      }

      onLog('Scanned ${files.length} file(s) in workspace.', LogLevel.info);

      // Resolve the target branch head (and the repo default as a fallback).
      String? parentCommitSha;
      String? baseTreeSha;
      final headSha = await _getBranchHead(
        client: client,
        token: token,
        owner: owner,
        repoName: repoName,
        branch: branch,
      );

      if (headSha == null) {
        final defaultBranch = await getDefaultBranch(
          token: token,
          owner: owner,
          repoName: repoName,
        );
        if (defaultBranch != branch) {
          onLog('Branch "$branch" not found; branching from "$defaultBranch".', LogLevel.info);
          parentCommitSha = await _getBranchHead(
            client: client,
            token: token,
            owner: owner,
            repoName: repoName,
            branch: defaultBranch,
          );
        }
      } else {
        parentCommitSha = headSha;
      }

      if (parentCommitSha != null) {
        baseTreeSha = await _getTreeShaForCommit(
          client: client,
          token: token,
          owner: owner,
          repoName: repoName,
          commitSha: parentCommitSha,
        );
      }

      final existingRemoteBlobs = <String, String>{};
      if (baseTreeSha != null) {
        final treeFetchRes = await client.get(
          Uri.parse('$_baseUrl/repos/$owner/$repoName/git/trees/$baseTreeSha?recursive=1'),
          headers: _headers(token),
        ).timeout(_requestTimeout);

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
      }

      final treeNodes = <Map<String, dynamic>>[];
      final filesToUpload = <_LocalFileToUpload>[];
      int totalScannedBytes = 0;
      int totalUploadBytes = 0;
      int newCount = 0;
      int modifiedCount = 0;
      int unchangedCount = 0;
      int skippedTooLarge = 0;

      for (int i = 0; i < files.length; i++) {
        final file = files[i];
        final relPath = p.relative(file.path, from: workingDir).replaceAll(r'\', '/');

        final length = await file.length();
        if (length > maxBlobBytes) {
          onLog(
            'Skipped ${p.basename(file.path)} (${_formatBytes(length)}) — exceeds the ${_formatBytes(maxBlobBytes)} per-file limit.',
            LogLevel.warning,
          );
          skippedTooLarge++;
          continue;
        }

        final localSha = await _calculateGitBlobShaStreaming(file);
        totalScannedBytes += length;

        final remoteSha = existingRemoteBlobs[relPath];
        if (remoteSha == localSha) {
          unchangedCount++;
          treeNodes.add({
            'path': relPath,
            'mode': '100644',
            'type': 'blob',
            'sha': localSha,
          });
        } else {
          if (remoteSha == null) {
            newCount++;
          } else {
            modifiedCount++;
          }
          totalUploadBytes += length;
          filesToUpload.add(_LocalFileToUpload(
            file: file,
            relPath: relPath,
            gitSha: localSha,
          ));
        }

        if (i % 25 == 0) await Future.delayed(Duration.zero);
      }

      final summaryDiff = [
        if (newCount > 0) '$newCount new',
        if (modifiedCount > 0) '$modifiedCount modified',
        if (unchangedCount > 0) '$unchangedCount unchanged',
        if (skippedTooLarge > 0) '$skippedTooLarge skipped (too large)',
      ].join(', ');

      onLog('Diff analysis: $summaryDiff', LogLevel.info);
      onLog(
        'Payload: ${filesToUpload.length} file(s) to upload '
        '(${_formatBytes(totalUploadBytes)}) [Total workspace: ${_formatBytes(totalScannedBytes)}]',
        LogLevel.info,
      );

      if (filesToUpload.isEmpty) {
        onLog(
          '[SUCCESS] Everything is up-to-date! All $unchangedCount file(s) already match GitHub.',
          LogLevel.success,
        );
        return;
      }

      onLog('Streaming ${filesToUpload.length} file(s) across 16 parallel workers...', LogLevel.info);
      int uploadedCounter = 0;
      int uploadedBytesCounter = 0;
      final failedFiles = <String>[];
      int processedCounter = 0;

      await _runSlidingPool<_LocalFileToUpload>(
        items: filesToUpload,
        concurrency: 16,
        worker: (item) async {
          try {
            // Read only inside the worker so peak memory stays bounded even
            // for large batches.
            final bytes = await item.file.readAsBytes();

            if (bytes.length > maxBlobBytes) {
              failedFiles.add(item.relPath);
              return;
            }

            final blobRes = await client.post(
              Uri.parse('$_baseUrl/repos/$owner/$repoName/git/blobs'),
              headers: _headers(token),
              body: jsonEncode({
                'content': base64Encode(bytes),
                'encoding': 'base64',
              }),
            ).timeout(const Duration(seconds: 60));

            if (blobRes.statusCode == 201) {
              final blobSha = jsonDecode(blobRes.body)['sha'];
              treeNodes.add({
                'path': item.relPath,
                'mode': '100644',
                'type': 'blob',
                'sha': blobSha,
              });
              uploadedBytesCounter += bytes.length;
            } else {
              // Record the failure; the commit is aborted below rather than
              // producing a "successful" push with files silently missing.
              failedFiles.add(item.relPath);
              onLog('Blob upload failed for ${item.relPath}: ${_extractMessage(blobRes)}', LogLevel.error);
            }
          } catch (e) {
            failedFiles.add(item.relPath);
            onLog('Blob upload error for ${item.relPath}: $e', LogLevel.error);
          } finally {
            uploadedCounter++;
            processedCounter++;
            if (processedCounter % 15 == 0 || processedCounter == filesToUpload.length) {
              onLog(
                'Processed $processedCounter/${filesToUpload.length} files '
                '(${_formatBytes(uploadedBytesCounter)} / ${_formatBytes(totalUploadBytes)})...',
                LogLevel.info,
              );
            }
          }
        },
      );

      if (failedFiles.isNotEmpty) {
        onLog(
          '[ABORTED] ${failedFiles.length} file(s) could not be uploaded. Nothing was committed; '
          'the branch is unchanged. First failures: ${failedFiles.take(5).join(', ')}',
          LogLevel.error,
        );
        return;
      }

      onLog('Generating Git Tree with ${treeNodes.length} objects...', LogLevel.info);
      final treePayload = <String, dynamic>{'tree': treeNodes};
      if (baseTreeSha != null) treePayload['base_tree'] = baseTreeSha;

      final treeRes = await client.post(
        Uri.parse('$_baseUrl/repos/$owner/$repoName/git/trees'),
        headers: _headers(token),
        body: jsonEncode(treePayload),
      ).timeout(const Duration(seconds: 60));

      if (treeRes.statusCode != 201) {
        onLog('Failed to create Git Tree: ${_extractMessage(treeRes)}', LogLevel.error);
        return;
      }
      final newTreeSha = jsonDecode(treeRes.body)['sha'];

      onLog('Creating commit "$commitMessage"...', LogLevel.info);
      final commitPayload = <String, dynamic>{
        'message': commitMessage,
        'tree': newTreeSha,
        'parents': parentCommitSha != null ? [parentCommitSha] : <String>[],
      };

      final commitRes = await client.post(
        Uri.parse('$_baseUrl/repos/$owner/$repoName/git/commits'),
        headers: _headers(token),
        body: jsonEncode(commitPayload),
      ).timeout(const Duration(seconds: 60));

      if (commitRes.statusCode != 201) {
        onLog('Failed to create commit: ${_extractMessage(commitRes)}', LogLevel.error);
        return;
      }
      final newCommitSha = jsonDecode(commitRes.body)['sha'] as String;
      final shortSha = newCommitSha.substring(0, 7);

      final elapsedSeconds = stopwatch.elapsedMilliseconds / 1000.0;
      final speedText = elapsedSeconds > 0
          ? '${_formatBytes((totalUploadBytes / elapsedSeconds).round())}/s'
          : 'N/A';

      final branchExists = await _getBranchHead(
            client: client,
            token: token,
            owner: owner,
            repoName: repoName,
            branch: branch,
          ) !=
          null;

      if (branchExists) {
        // No `force`: a fast-forward only. If someone else pushed in the
        // meantime the PATCH is rejected and we retry on the fresh head
        // instead of destroying their commits.
        final updateRefRes = await client.patch(
          Uri.parse('$_baseUrl/repos/$owner/$repoName/git/refs/heads/$branch'),
          headers: _headers(token),
          body: jsonEncode({'sha': newCommitSha, 'force': false}),
        ).timeout(_requestTimeout);

        if (updateRefRes.statusCode == 200) {
          onLog('[SUCCESS] Pushed commit $shortSha to branch "$branch"', LogLevel.success);
          onLog(
            '[PUSH STATS] $newCount new, $modifiedCount modified, $unchangedCount cached | '
            '${_formatBytes(totalUploadBytes)} uploaded in ${elapsedSeconds.toStringAsFixed(1)}s ($speedText)',
            LogLevel.success,
          );
          onLog('Repository URL: https://github.com/$owner/$repoName/tree/$branch', LogLevel.success);
        } else if (updateRefRes.statusCode == 409 || updateRefRes.statusCode == 422) {
          throw _PushConflict('Branch "$branch" was updated remotely while pushing.');
        } else {
          onLog('Failed to update branch reference: ${_extractMessage(updateRefRes)}', LogLevel.error);
        }
      } else {
        final createRefRes = await client.post(
          Uri.parse('$_baseUrl/repos/$owner/$repoName/git/refs'),
          headers: _headers(token),
          body: jsonEncode({'ref': 'refs/heads/$branch', 'sha': newCommitSha}),
        ).timeout(_requestTimeout);

        if (createRefRes.statusCode == 201) {
          onLog('[SUCCESS] Created new branch "$branch" with commit $shortSha', LogLevel.success);
          onLog(
            '[PUSH STATS] $newCount new, $modifiedCount modified, $unchangedCount cached | '
            '${_formatBytes(totalUploadBytes)} uploaded in ${elapsedSeconds.toStringAsFixed(1)}s ($speedText)',
            LogLevel.success,
          );
          onLog('Repository URL: https://github.com/$owner/$repoName/tree/$branch', LogLevel.success);
        } else {
          onLog('Failed to create branch reference: ${_extractMessage(createRefRes)}', LogLevel.error);
        }
      }
    } on _PushConflict {
      rethrow;
    } on TimeoutException {
      onLog('Request timed out. The network is slow or GitHub is unreachable.', LogLevel.error);
    } on SocketException {
      onLog('Network error: unable to reach GitHub. Check the device connection.', LogLevel.error);
    } on FormatException {
      onLog('Unexpected response from GitHub (malformed JSON).', LogLevel.error);
    } catch (e) {
      onLog('Unexpected error during GitHub push: $e', LogLevel.error);
    } finally {
      client.close();
    }
  }

  static Future<String?> _getBranchHead({
    required http.Client client,
    required String token,
    required String owner,
    required String repoName,
    required String branch,
  }) async {
    try {
      final res = await client.get(
        Uri.parse('$_baseUrl/repos/$owner/$repoName/git/ref/heads/$branch'),
        headers: _headers(token),
      ).timeout(_requestTimeout);
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        return data['object']?['sha'] as String?;
      }
    } catch (_) {}
    return null;
  }

  static Future<String?> _getTreeShaForCommit({
    required http.Client client,
    required String token,
    required String owner,
    required String repoName,
    required String commitSha,
  }) async {
    try {
      final res = await client.get(
        Uri.parse('$_baseUrl/repos/$owner/$repoName/git/commits/$commitSha'),
        headers: _headers(token),
      ).timeout(_requestTimeout);
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        return data['tree']?['sha'] as String?;
      }
    } catch (_) {}
    return null;
  }

  /// Collects candidate files, skipping VCS internals and build output.
  static Future<List<File>> _collectFiles({
    required String workingDir,
    Set<String>? specificPaths,
    required Function(String message, LogLevel level) onLog,
  }) async {
    final files = <File>[];

    bool isIgnored(String path) =>
        p.split(path).any((segment) => _ignoredDirectoryNames.contains(segment));

    if (specificPaths != null && specificPaths.isNotEmpty) {
      for (final path in specificPaths) {
        final f = File(path);
        final d = Directory(path);
        if (await f.exists()) {
          if (!isIgnored(f.path)) files.add(f);
        } else if (await d.exists()) {
          try {
            final entries = await d.list(recursive: true, followLinks: false).toList();
            for (final e in entries) {
              if (e is File && !isIgnored(e.path)) files.add(e);
            }
          } catch (e) {
            onLog('Could not read $path: $e', LogLevel.warning);
          }
        }
      }
      return files;
    }

    final root = Directory(workingDir);
    if (!await root.exists()) {
      onLog('Working directory not found: $workingDir', LogLevel.error);
      return files;
    }
    try {
      final entries = await root.list(recursive: true, followLinks: false).toList();
      for (final e in entries) {
        if (e is File && !isIgnored(e.path)) files.add(e);
      }
    } catch (e) {
      onLog('Could not enumerate workspace: $e', LogLevel.error);
    }
    return files;
  }
}
