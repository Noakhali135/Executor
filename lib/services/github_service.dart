import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/command_action.dart';

class GitHubService {
  static const String _keyToken = 'github_pat_token';
  static const String _keyUsername = 'github_pat_username';
  static const String _baseUrl = 'https://api.github.com';

  static const Set<String> _binaryExtensions = {
    'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'ico', 'svgz',
    'zip', 'apk', 'aab', 'tar', 'gz', 'rar', '7z', 'jar', 'exe',
    'dll', 'so', 'dylib', 'bin', 'dat', 'pdf', 'mp3', 'mp4', 'wav',
    'm4a', 'ogg', 'flac', 'ttf', 'otf', 'woff', 'woff2', 'class',
    'dex', 'iso', 'db', 'sqlite', 'aar',
  };

  static const Set<String> _ignoreDirs = {
    '.git', '.dart_tool', '.idea', 'build', '.gradle', 'node_modules',
  };

  static Future<String?> getToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyToken);
  }

  static Future<String?> getCachedUsername() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyUsername);
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
  }

  static Map<String, String> _headers(String token) {
    return {
      'Authorization': 'Bearer $token',
      'Accept': 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28',
      'Content-Type': 'application/json',
    };
  }

  static Future<String?> verifyToken(String token) async {
    try {
      final res = await http.get(
        Uri.parse('$_baseUrl/user'),
        headers: _headers(token),
      );
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        return data['login'] as String?;
      }
    } catch (_) {}
    return null;
  }

  static Future<List<Map<String, dynamic>>> getUserRepos(String token) async {
    try {
      final res = await http.get(
        Uri.parse('$_baseUrl/user/repos?per_page=50&sort=updated'),
        headers: _headers(token),
      );
      if (res.statusCode == 200) {
        final list = jsonDecode(res.body) as List;
        return list.map((e) => {
          'name': e['name'] as String,
          'full_name': e['full_name'] as String,
          'private': e['private'] as bool,
          'default_branch': e['default_branch'] as String? ?? 'main',
        }).toList();
      }
    } catch (_) {}
    return [];
  }

  static Future<bool> createRepository({
    required String token,
    required String repoName,
    required bool isPrivate,
    required String description,
  }) async {
    final res = await http.post(
      Uri.parse('$_baseUrl/user/repos'),
      headers: _headers(token),
      body: jsonEncode({
        'name': repoName,
        'private': isPrivate,
        'description': description,
        'auto_init': true,
      }),
    );
    return res.statusCode == 201;
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
    onLog('Connecting to GitHub API as @$owner...', LogLevel.info);

    final filesToUpload = <String, File>{};

    if (specificPaths != null && specificPaths.isNotEmpty) {
      for (final pth in specificPaths) {
        final f = File(pth);
        final d = Directory(pth);
        if (await f.exists()) {
          filesToUpload[p.normalize(f.path)] = f;
        } else if (await d.exists()) {
          final entries = await d.list(recursive: true, followLinks: false).toList();
          for (final e in entries) {
            if (e is File) {
              filesToUpload[p.normalize(e.path)] = e;
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
          final parts = p.split(rel);
          if (parts.any((p) => _ignoreDirs.contains(p) || p.startsWith('.'))) {
            continue;
          }
          filesToUpload[p.normalize(e.path)] = e;
        }
      }
    }

    if (filesToUpload.isEmpty) {
      onLog('No files found to push to GitHub.', LogLevel.warning);
      return;
    }

    onLog('Found ${filesToUpload.length} file(s) to synchronize.', LogLevel.info);

    String? parentCommitSha;
    String? baseTreeSha;

    final refRes = await http.get(
      Uri.parse('$_baseUrl/repos/$owner/$repoName/git/ref/heads/$branch'),
      headers: _headers(token),
    );

    if (refRes.statusCode == 200) {
      final refData = jsonDecode(refRes.body);
      parentCommitSha = refData['object']['sha'];
      final commitRes = await http.get(
        Uri.parse('$_baseUrl/repos/$owner/$repoName/git/commits/$parentCommitSha'),
        headers: _headers(token),
      );
      if (commitRes.statusCode == 200) {
        baseTreeSha = jsonDecode(commitRes.body)['tree']['sha'];
      }
    } else {
      final defaultRefRes = await http.get(
        Uri.parse('$_baseUrl/repos/$owner/$repoName/git/ref/heads/main'),
        headers: _headers(token),
      );
      if (defaultRefRes.statusCode == 200) {
        final refData = jsonDecode(defaultRefRes.body);
        parentCommitSha = refData['object']['sha'];
        final commitRes = await http.get(
          Uri.parse('$_baseUrl/repos/$owner/$repoName/git/commits/$parentCommitSha'),
          headers: _headers(token),
        );
        if (commitRes.statusCode == 200) {
          baseTreeSha = jsonDecode(commitRes.body)['tree']['sha'];
        }
      }
    }

    final treeNodes = <Map<String, dynamic>>[];
    int uploadedCount = 0;

    for (final entry in filesToUpload.entries) {
      final file = entry.value;
      final relPath = p.relative(file.path, from: workingDir).replaceAll(r'\', '/');
      final ext = p.extension(file.path).replaceFirst('.', '').toLowerCase();
      final isBinary = _binaryExtensions.contains(ext);

      String contentBase64;
      String encoding;

      if (isBinary) {
        final bytes = await file.readAsBytes();
        contentBase64 = base64Encode(bytes);
        encoding = 'base64';
      } else {
        try {
          final str = await file.readAsString();
          contentBase64 = base64Encode(utf8.encode(str));
          encoding = 'base64';
        } catch (_) {
          final bytes = await file.readAsBytes();
          contentBase64 = base64Encode(bytes);
          encoding = 'base64';
        }
      }

      final blobRes = await http.post(
        Uri.parse('$_baseUrl/repos/$owner/$repoName/git/blobs'),
        headers: _headers(token),
        body: jsonEncode({
          'content': contentBase64,
          'encoding': encoding,
        }),
      );

      if (blobRes.statusCode == 201) {
        final blobSha = jsonDecode(blobRes.body)['sha'];
        treeNodes.add({
          'path': relPath,
          'mode': '100644',
          'type': 'blob',
          'sha': blobSha,
        });
        uploadedCount++;
        if (uploadedCount % 5 == 0 || uploadedCount == filesToUpload.length) {
          onLog('Uploaded $uploadedCount/${filesToUpload.length} files as Git blobs...', LogLevel.info);
        }
      } else {
        onLog('Failed to upload blob for $relPath: ${blobRes.body}', LogLevel.warning);
      }
    }

    onLog('Creating Git Tree with $uploadedCount entries...', LogLevel.info);
    final treePayload = <String, dynamic>{
      'tree': treeNodes,
    };
    if (baseTreeSha != null) {
      treePayload['base_tree'] = baseTreeSha;
    }

    final treeRes = await http.post(
      Uri.parse('$_baseUrl/repos/$owner/$repoName/git/trees'),
      headers: _headers(token),
      body: jsonEncode(treePayload),
    );

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

    final commitRes = await http.post(
      Uri.parse('$_baseUrl/repos/$owner/$repoName/git/commits'),
      headers: _headers(token),
      body: jsonEncode(commitPayload),
    );

    if (commitRes.statusCode != 201) {
      onLog('Failed to create commit: ${commitRes.body}', LogLevel.error);
      return;
    }

    final newCommitSha = jsonDecode(commitRes.body)['sha'];
    final shortSha = newCommitSha.toString().substring(0, 7);

    if (refRes.statusCode == 200) {
      final updateRefRes = await http.patch(
        Uri.parse('$_baseUrl/repos/$owner/$repoName/git/refs/heads/$branch'),
        headers: _headers(token),
        body: jsonEncode({'sha': newCommitSha, 'force': true}),
      );
      if (updateRefRes.statusCode == 200) {
        onLog('[SUCCESS] Pushed commit $shortSha to branch "$branch"', LogLevel.success);
        onLog('Repository URL: https://github.com/$owner/$repoName/tree/$branch', LogLevel.success);
      } else {
        onLog('Failed to update branch reference: ${updateRefRes.body}', LogLevel.error);
      }
    } else {
      final createRefRes = await http.post(
        Uri.parse('$_baseUrl/repos/$owner/$repoName/git/refs'),
        headers: _headers(token),
        body: jsonEncode({
          'ref': 'refs/heads/$branch',
          'sha': newCommitSha,
        }),
      );
      if (createRefRes.statusCode == 201) {
        onLog('[SUCCESS] Created new branch "$branch" with commit $shortSha', LogLevel.success);
        onLog('Repository URL: https://github.com/$owner/$repoName/tree/$branch', LogLevel.success);
      } else {
        onLog('Failed to create branch reference: ${createRefRes.body}', LogLevel.error);
      }
    }
  }
}