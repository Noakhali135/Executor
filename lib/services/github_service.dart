import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/command_action.dart';
import 'saf_workspace.dart';
import 'secure_store.dart';
import 'push_progress.dart';
import 'workspace_probe.dart';

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

/// An authentication/authorisation problem that no amount of retrying will
/// fix. Carries an actionable remedy so the UI can tell the user exactly what
/// to change instead of dumping a wall of identical HTTP 401 lines.
class GitHubAuthException implements Exception {
  final String message;
  final String remedy;

  GitHubAuthException(this.message, this.remedy);

  @override
  String toString() => '$message $remedy';
}

/// Result of attempting to create a repository.
class CreateRepoResult {
  final bool success;
  final String message;
  final String? remedy;
  final String? repoName;

  /// True when the only problem is that the repo already exists, which the
  /// caller can recover from by selecting it instead.
  final bool alreadyExists;

  const CreateRepoResult({
    required this.success,
    required this.message,
    this.remedy,
    this.repoName,
    this.alreadyExists = false,
  });
}

/// Asks the user for a fresh token when the stored one is rejected.
///
/// Returning `null` means "not now"; returning a string means the caller
/// should retry with it.
typedef ReauthPrompt = Future<String?> Function(GitHubAuthException error);

/// Decides which repository a push should target.
///
/// Extracted so the rule can be tested without a widget: the user's explicit
/// choice always wins, a name that only differs in case or whitespace is still
/// a match, and a failed list never resets a valid selection. The bug this
/// replaces pushed into the previously saved repository while a different one
/// was visibly selected.
String? resolveTargetRepo({
  required String? selected,
  required List<String> available,
  required bool pickedByUser,
  String? saved,
}) {
  final choice = (selected ?? '').trim();

  if (pickedByUser) {
    // Whatever the user tapped, even if the list is stale or empty.
    return choice.isEmpty ? null : choice;
  }

  if (choice.isNotEmpty) {
    for (final name in available) {
      if (name.trim().toLowerCase() == choice.toLowerCase()) return name.trim();
    }
    // The selection is valid even when it is not in this particular list.
    return choice;
  }

  final savedName = (saved ?? '').trim();
  if (savedName.isNotEmpty) {
    for (final name in available) {
      if (name.trim().toLowerCase() == savedName.toLowerCase()) return name.trim();
    }
    // Do NOT invent a repository from a stale preference: that is how a push
    // ended up in the wrong place. Only fall back when it is still listed.
    if (available.isEmpty) return savedName;
  }

  return available.length == 1 ? available.first.trim() : null;
}

/// Result of listing the authenticated user's repositories.
class RepoListResult {
  final List<Map<String, dynamic>> repos;
  final String? error;

  const RepoListResult({required this.repos, this.error});
}

/// Result of a `GET /repos/{owner}/{repo}` probe performed before uploading.
class RepoAccess {
  final bool canRead;
  final bool canPush;
  final String? defaultBranch;
  final GitHubAuthException? failure;

  const RepoAccess({
    required this.canRead,
    required this.canPush,
    this.defaultBranch,
    this.failure,
  });
}

/// A file queued for upload, carrying its workspace-relative path.
class _PendingUpload {
  final WorkspaceFile file;
  final String relPath;

  const _PendingUpload({required this.file, required this.relPath});
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

  /// Parallel blob uploads.
  ///
  /// Memory is capped separately by [ByteBudget], so this no longer risks an
  /// out-of-memory kill; it is sized to saturate a phone connection without the
  /// per-socket cost of many more TLS handshakes.
  static const int uploadConcurrency = 10;

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
    await SecureStore.writeToken(sanitizeToken(token));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyUsername, username.trim());
  }

  static Future<void> clearToken() async {
    await SecureStore.deleteToken();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyUsername);
    await prefs.remove(_keySelectedRepo);
  }

  /// Normalises a token pasted by the user.
  ///
  /// Common paste mistakes that used to surface as a bare HTTP 401:
  ///  * a full header, e.g. `Authorization: Bearer ghp_xxx`
  ///  * a stray `Bearer ` / `token ` prefix
  ///  * surrounding quotes or a trailing newline from a web page copy
  ///  * the token wrapped across two lines (absorbed whitespace)
  static String sanitizeToken(String raw) {
    var value = raw.replaceAll('\u200b', '').trim();

    while (value.length >= 2 &&
        ((value.startsWith('"') && value.endsWith('"')) ||
            (value.startsWith("'") && value.endsWith("'")))) {
      value = value.substring(1, value.length - 1).trim();
    }

    if (value.toLowerCase().startsWith('authorization:')) {
      value = value.substring('authorization:'.length).trim();
    }

    final lower = value.toLowerCase();
    if (lower.startsWith('bearer ')) {
      value = value.substring('bearer '.length).trim();
    } else if (lower.startsWith('token ')) {
      value = value.substring('token '.length).trim();
    }

    // GitHub tokens never contain internal whitespace; wrapped pastes do.
    return value.replaceAll(RegExp(r'\s+'), '');
  }

  /// True when the string looks like any known GitHub token format.
  static bool looksLikeToken(String token) {
    return token.startsWith('ghp_') ||
        token.startsWith('gho_') ||
        token.startsWith('ghu_') ||
        token.startsWith('ghs_') ||
        token.startsWith('ghr_') ||
        token.startsWith('github_pat_');
  }

  static bool isFineGrainedToken(String token) =>
      token.startsWith('github_pat_');

  /// Percent-encodes one URL path segment.
  ///
  /// Repository names may legally contain spaces ("Islamic Routine"), dots and
  /// other punctuation. Interpolating them raw into a URL truncates the path at
  /// the first space, which is why pushing to such a repo used to fail with a
  /// misleading 404 while it appeared fine in the picker.
  static String _seg(String value) => Uri.encodeComponent(value.trim());

  /// Builds `https://api.github.com/repos/<owner>/<repo><suffix>`.
  static Uri _repoUri(String owner, String repoName, [String suffix = '']) {
    return Uri.parse('$_baseUrl/repos/${_seg(owner)}/${_seg(repoName)}$suffix');
  }

  /// Exposed for tests: the same URL builder the service uses internally.
  static Uri repoUriForTest(String owner, String repoName, [String suffix = '']) =>
      _repoUri(owner, repoName, suffix);

  static Map<String, String> _headers(String rawToken) {
    final token = sanitizeToken(rawToken);
    return {
      'Authorization': 'Bearer $token',
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
  static Future<String> _calculateGitBlobShaStreaming(WorkspaceFile file) async {
    final length = await file.length();
    final sink = _DigestSink();
    final hasher = sha1.startChunkedConversion(sink);
    hasher.add(utf8.encode('blob $length\x00'));
    // openRead() streams for direct files and yields a single chunk when the
    // bytes come from a granted SAF tree.
    await for (final chunk in file.openRead()) {
      hasher.add(chunk);
    }
    hasher.close();
    return sink.value.toString();
  }

  // ------------------------------------------------------------ endpoints ----

  static Future<TokenVerifyResult> verifyToken(String rawToken) async {
    final token = sanitizeToken(rawToken);
    if (token.isEmpty) {
      return const TokenVerifyResult(success: false, errorMessage: 'Token cannot be empty');
    }
    if (!looksLikeToken(token)) {
      return const TokenVerifyResult(
        success: false,
        errorMessage: 'That does not look like a GitHub token. It should start with '
            'ghp_ (classic) or github_pat_ (fine-grained).',
      );
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
      if (body is Map && body['message'] is String) {
        final msg = body['message'] as String;
        // GitHub returns 403 with this message when the hourly quota is gone.
        if (msg.toLowerCase().contains('rate limit')) {
          return 'API rate limit exceeded';
        }
        return msg;
      }
    } catch (_) {}

    switch (res.statusCode) {
      case 401:
        return 'Unauthorized — the token is invalid or expired';
      case 403:
        return 'Forbidden — the token lacks the required permission';
      case 404:
        return 'Not found — the repository does not exist or the token cannot see it';
      case 409:
        return 'Conflict — the branch changed remotely';
      case 422:
        return 'Unprocessable — the request was rejected by GitHub';
      case 429:
        return 'Too many requests — GitHub is rate limiting this device';
    }
    return 'GitHub returned HTTP ${res.statusCode}';
  }

  /// Convenience: is this response an authentication failure?
  static bool _isUnauthorized(http.Response res) => res.statusCode == 401;

  /// Is this response a rate-limit rejection (429, or 403 + rate-limit text)?
  static bool _isRateLimited(http.Response res) {
    if (res.statusCode == 429) return true;
    if (res.statusCode == 403) {
      if (res.headers['x-ratelimit-remaining'] == '0') return true;
      final text = res.body.toLowerCase();
      return text.contains('rate limit') || text.contains('secondary rate');
    }
    return false;
  }

  /// Builds the message + remedy shown when the token itself is the problem.
  static GitHubAuthException _authFailureFor(
    http.Response res, {
    required String token,
    required String action,
  }) {
    final isFineGrained = isFineGrainedToken(sanitizeToken(token));
    final scopeHeader = res.headers['x-oauth-scopes'] ?? '';
    final accepted = res.headers['x-accepted-oauth-scopes'] ?? '';

    final scopeNote = scopeHeader.trim().isEmpty
        ? 'The token exposes no OAuth scopes.'
        : 'Token scopes: "$scopeHeader".${accepted.trim().isEmpty ? '' : ' This call needs: "$accepted".'}';

    final remedy = isFineGrained
        ? 'This is a fine-grained token (github_pat_…). Open it in GitHub → '
            'Settings → Developer settings → Fine-grained tokens and make sure '
            '"Repository access" includes this repo with Contents = Read and write '
            'and Metadata = Read-only.'
        : 'Open GitHub → Settings → Developer settings → Tokens (classic) and check '
            'the token has the "repo" scope (and has not expired), then reconnect.';

    return GitHubAuthException(
      'Cannot $action: the token was rejected (401). $scopeNote',
      remedy,
    );
  }

  /// Verifies the token can actually read *and* write the target repository
  /// before a single blob is uploaded.
  ///
  /// This is the fix for pushes that failed part-way with a flood of 401s: a
  /// token can list repositories (repo picker works) yet still be unable to
  /// push to a specific one, and previously that was only discovered after
  /// every blob request had already failed.
  static Future<RepoAccess> checkRepoAccess({
    required String token,
    required String owner,
    required String repoName,
  }) async {
    final client = http.Client();
    try {
      final res = await client.get(
        _repoUri(owner, repoName),
        headers: _headers(token),
      ).timeout(_requestTimeout);

      if (_isRateLimited(res)) {
        final reset = res.headers['x-ratelimit-reset'];
        return RepoAccess(
          canRead: false,
          canPush: false,
          failure: GitHubAuthException(
            'GitHub is rate limiting this device.',
            reset == null
                ? 'Wait a few minutes and try again.'
                : 'Try again after the quota resets (epoch $reset).',
          ),
        );
      }

      if (_isUnauthorized(res)) {
        return RepoAccess(
          canRead: false,
          canPush: false,
          failure: _authFailureFor(res, token: token, action: 'open $owner/$repoName'),
        );
      }

      if (res.statusCode == 404) {
        return RepoAccess(
          canRead: false,
          canPush: false,
          failure: GitHubAuthException(
            'Repository $owner/$repoName was not found (404).',
            'It may be private under a different account, renamed, or the token '
                'has no access to it. Re-check the repository list and reconnect.',
          ),
        );
      }

      if (res.statusCode != 200) {
        return RepoAccess(
          canRead: false,
          canPush: false,
          failure: GitHubAuthException(
            'Could not open $owner/$repoName (${res.statusCode}): ${_extractMessage(res)}',
            'Try again, or create a new repository from this dialog.',
          ),
        );
      }

      final data = jsonDecode(res.body);
      final permissions = data['permissions'];

      // `permissions.push` is the authoritative "can I write here" flag. Older
      // responses without the block are treated as writable so we never block
      // a push that would have worked.
      final canPush = permissions is Map ? (permissions['push'] == true) : true;

      if (!canPush) {
        return RepoAccess(
          canRead: true,
          canPush: false,
          defaultBranch: data['default_branch'] as String?,
          failure: GitHubAuthException(
            'The token can read $owner/$repoName but not write to it.',
            'You need "Contents: Read and write" (or the classic "repo" scope) '
                'on this repository. Grants made to a different account, or a '
                'read-only collaborator role, will produce exactly this error.',
          ),
        );
      }

      return RepoAccess(
        canRead: true,
        canPush: true,
        defaultBranch: data['default_branch'] as String?,
      );
    } on TimeoutException {
      return RepoAccess(
        canRead: false,
        canPush: false,
        failure: GitHubAuthException(
          'Checking repository access timed out.',
          'Check the device internet connection and try again.',
        ),
      );
    } on SocketException {
      return RepoAccess(
        canRead: false,
        canPush: false,
        failure: GitHubAuthException(
          'Network error while checking repository access.',
          'Check the device internet connection and try again.',
        ),
      );
    } catch (e) {
      return RepoAccess(
        canRead: false,
        canPush: false,
        failure: GitHubAuthException(
          'Could not verify repository access: $e',
          'Try again.',
        ),
      );
    } finally {
      client.close();
    }
  }

  /// Returns repositories plus their default branch so a push never has to
  /// assume `main`.
  ///
  /// The error field exists because returning an empty list for every failure
  /// made a rejected token look like "this account has no repositories".
  static Future<RepoListResult> getUserRepos(String token) async {
    final client = http.Client();
    try {
      final res = await client.get(
        Uri.parse('$_baseUrl/user/repos?per_page=100&sort=updated'),
        headers: _headers(token),
      ).timeout(_requestTimeout);
      if (res.statusCode == 200) {
        final list = jsonDecode(res.body) as List;
        return RepoListResult(
          repos: list.map((e) => {
                'name': e['name'] as String,
                'full_name': e['full_name'] as String,
                'private': e['private'] as bool,
                'default_branch': e['default_branch'] as String? ?? 'main',
              }).toList(),
        );
      }
      if (_isRateLimited(res)) {
        return const RepoListResult(
          repos: [],
          error: 'GitHub is rate limiting this device. Wait a few minutes and retry.',
        );
      }
      if (_isUnauthorized(res)) {
        return const RepoListResult(
          repos: [],
          error: 'The token was rejected (401). Reconnect with a valid token.',
        );
      }
      return RepoListResult(
        repos: const [],
        error: 'Could not load repositories: ${_extractMessage(res)}',
      );
    } on TimeoutException {
      return const RepoListResult(repos: [], error: 'Loading repositories timed out.');
    } on SocketException {
      return const RepoListResult(repos: [], error: 'Network error while loading repositories.');
    } catch (e) {
      return RepoListResult(repos: const [], error: 'Could not load repositories: $e');
    } finally {
      client.close();
    }
  }

  /// Looks up the repository's default branch, falling back to `main`.
  /// Branch names for a repository, default branch first.
  ///
  /// The dialog used to guess the target branch from the repo list, which only
  /// knows `default_branch`. Picking a repo therefore could not confirm or
  /// offer any other branch.
  static Future<List<String>> getBranches({
    required String token,
    required String owner,
    required String repoName,
  }) async {
    final client = http.Client();
    try {
      final res = await client.get(
        _repoUri(owner, repoName, '/branches?per_page=100'),
        headers: _headers(token),
      ).timeout(_requestTimeout);

      if (res.statusCode != 200) return const [];
      final data = jsonDecode(res.body);
      if (data is! List) return const [];

      final names = <String>[];
      for (final item in data) {
        final name = (item is Map ? item['name'] : null) as String?;
        if (name != null && name.isNotEmpty) names.add(name);
      }
      return names;
    } catch (_) {
      return const [];
    } finally {
      client.close();
    }
  }

  static Future<String> getDefaultBranch({
    required String token,
    required String owner,
    required String repoName,
  }) async {
    final client = http.Client();
    try {
      final res = await client.get(
        _repoUri(owner, repoName),
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

  /// Creates a repository.
  ///
  /// Returns a typed result instead of a bare bool: "returned false" used to be
  /// reported as "Repo might already exist, proceeding...", which hid genuine
  /// failures such as an invalid name, a missing scope or a bad token.
  static Future<CreateRepoResult> createRepository({
    required String token,
    required String repoName,
    required bool isPrivate,
    required String description,
  }) async {
    final clean = repoName.trim();
    if (clean.isEmpty) {
      return const CreateRepoResult(
        success: false,
        message: 'Repository name is empty',
        remedy: 'Enter a name, e.g. "islamic-routine".',
      );
    }
    if (clean.contains(' ')) {
      // Spaces in repo names cause nothing but trouble downstream; GitHub
      // accepts them but they are easy to mistype when selecting later.
      // Not const: the message interpolates the runtime name.
      return CreateRepoResult(
        success: false,
        message: 'Repository names cannot contain spaces: "$clean"',
        remedy: 'Use hyphens instead, e.g. "islamic-routine".',
      );
    }

    final client = http.Client();
    try {
      final res = await client.post(
        Uri.parse('$_baseUrl/user/repos'),
        headers: _headers(token),
        body: jsonEncode({
          'name': clean,
          'private': isPrivate,
          'description': description,
          'auto_init': true,
        }),
      ).timeout(_requestTimeout);

      if (res.statusCode == 201) {
        return CreateRepoResult(
          success: true,
          message: 'Repository "$clean" created',
          repoName: (jsonDecode(res.body)['name'] as String?) ?? clean,
        );
      }

      // 422 = name already used by this account (GitHub sends "name already
      // exists on this account"). That one is genuinely recoverable.
      if (res.statusCode == 422 && res.body.toLowerCase().contains('already exists')) {
        return CreateRepoResult(
          success: false,
          message: 'Repository "$clean" already exists on your account.',
          remedy: 'Switch to "Existing Repo" and select it — creation is not needed.',
          alreadyExists: true,
          repoName: clean,
        );
      }

      if (_isUnauthorized(res)) {
        return CreateRepoResult(
          success: false,
          message: 'The token was rejected (401) while creating the repository.',
          remedy: 'Reconnect with a token that has the "repo" scope '
              '(or Contents: Read and write for fine-grained tokens).',
        );
      }

      return CreateRepoResult(
        success: false,
        message: 'GitHub refused to create "$clean": ${_extractMessage(res)}',
        remedy: 'Fix the name or the token permissions and try again.',
      );
    } on TimeoutException {
      return const CreateRepoResult(
        success: false,
        message: 'Creating the repository timed out.',
        remedy: 'Check the connection and try again.',
      );
    } on SocketException {
      return const CreateRepoResult(
        success: false,
        message: 'Network error while creating the repository.',
        remedy: 'Check the connection and try again.',
      );
    } catch (e) {
      return CreateRepoResult(
        success: false,
        message: 'Could not create the repository: $e',
        remedy: 'Try again.',
      );
    } finally {
      client.close();
    }
  }

  /// True once the user asked to abort the current push.
  static bool get cancelRequested => PushProgressReporter.cancelRequested;

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

  /// Pushes the workspace.
  ///
  /// Order of operations is deliberately "cheap check first":
  ///  1. verify the token can read *and* write the target repository — this is
  ///     what turns a flood of per-blob 401s into one actionable message,
  ///  2. only then enumerate, hash and upload.
  ///
  /// A rejected token offers a single re-authentication prompt; a branch that
  /// moved under us triggers a single clean retry.
  static Future<void> pushWorkspace({
    required String token,
    required String owner,
    required String repoName,
    required String branch,
    required String commitMessage,
    required String workingDir,
    Set<String>? specificPaths,
    required Function(String message, LogLevel level) onLog,
    ReauthPrompt? onReauth,
  }) async {
    var activeToken = sanitizeToken(token);

    // Two attempts: one with the stored token, one with a replacement if the
    // user supplies one after the pre-flight check rejects it.
    for (int authAttempt = 0; authAttempt < 2; authAttempt++) {
      final access = await checkRepoAccess(
        token: activeToken,
        owner: owner,
        repoName: repoName,
      );

      if (access.failure == null) {
        onLog(
          'Repository access verified: ${access.canPush ? 'read + write' : 'read only'}.',
          LogLevel.success,
        );
        break;
      }

      onLog('[AUTH] ${access.failure!.message}', LogLevel.error);
      onLog('[HOW TO FIX] ${access.failure!.remedy}', LogLevel.warning);

      final replacement = onReauth == null ? null : await onReauth(access.failure!);
      if (replacement == null || replacement.trim().isEmpty) {
        onLog('Push cancelled. No files were uploaded.', LogLevel.warning);
        return;
      }

      activeToken = sanitizeToken(replacement);
      onLog('Retrying with the new token...', LogLevel.info);

      if (authAttempt == 1) {
        onLog('Push cancelled: the replacement token was rejected as well.', LogLevel.error);
        return;
      }
    }

    for (int attempt = 0; attempt < 2; attempt++) {
      try {
        await _pushOnce(
          token: activeToken,
          owner: owner,
          repoName: repoName,
          branch: branch,
          commitMessage: commitMessage,
          workingDir: workingDir,
          specificPaths: specificPaths,
          onLog: onLog,
        );
        return;
      } on GitHubAuthException catch (e) {
        onLog('[AUTH] ${e.message}', LogLevel.error);
        onLog('[HOW TO FIX] ${e.remedy}', LogLevel.warning);
        onLog('Push aborted. No commit was created.', LogLevel.warning);
        PushProgressReporter.finish(
          PushPhase.failed,
          e.message,
        );
        return;
      } on PushCancelled {
        onLog(
          '[CANCELLED] Stopped on request. No commit was created; the branch is unchanged.',
          LogLevel.warning,
        );
        PushProgressReporter.finish(
          PushPhase.cancelled,
          'Cancelled. No commit was created.',
        );
        return;
      } on _PushConflict catch (e) {
        if (attempt == 0) {
          onLog('${e.message} Re-syncing with the remote and retrying once...', LogLevel.warning);
          continue;
        }
        onLog('Push aborted: ${e.message}', LogLevel.error);
        PushProgressReporter.finish(PushPhase.failed, e.message);
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
    // `dart:io` defaults to 6 idle sockets per host, so ten concurrent uploads
    // meant three of them waited for a free connection and paid for a fresh TLS
    // handshake each time. Match the pool to the concurrency.
    final client = IOClient(HttpClient()
      ..maxConnectionsPerHost = uploadConcurrency
      ..idleTimeout = const Duration(seconds: 15));
    final stopwatch = Stopwatch()..start();

    try {
      onLog('Connecting to GitHub API as @$owner...', LogLevel.info);

      final scanTimer = Stopwatch()..start();
      final files = await _collectFiles(
        workingDir: workingDir,
        specificPaths: specificPaths,
        onLog: onLog,
      );
      scanTimer.stop();
      if (files.isEmpty) {
        onLog('No files found to push to GitHub.', LogLevel.warning);
        return;
      }

      onLog(
        'Scanned ${files.length} file(s) in '
        '${(scanTimer.elapsedMilliseconds / 1000).toStringAsFixed(1)}s.',
        LogLevel.info,
      );

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
      // Sizes recorded in the remote tree. A changed file's size ~always equals
      // its previous size, which lets the whole push run without asking the
      // provider for a length once per file (that was many seconds on its own).
      final remoteSizes = <String, int>{};
      final baseTree = baseTreeSha;
      if (baseTree != null) {
        final treeFetchRes = await client.get(
          _repoUri(owner, repoName, '/git/trees/${_seg(baseTree)}?recursive=1'),
          headers: _headers(token),
        ).timeout(_requestTimeout);

        if (_isUnauthorized(treeFetchRes)) {
          throw _authFailureFor(treeFetchRes, token: token, action: 'read the repository tree');
        }
        if (_isRateLimited(treeFetchRes)) {
          throw GitHubAuthException(
            'GitHub is rate limiting this device.',
            'Wait a few minutes, then push again.',
          );
        }

        if (treeFetchRes.statusCode == 200) {
          final treeData = jsonDecode(treeFetchRes.body);
          if (treeData['tree'] is List) {
            for (final item in treeData['tree']) {
              if (item['type'] == 'blob' && item['path'] is String && item['sha'] is String) {
                existingRemoteBlobs[item['path'] as String] = item['sha'] as String;
                final itemSize = item['size'];
                if (itemSize is num) {
                  remoteSizes[item['path'] as String] = itemSize.toInt();
                }
              }
            }
          }
        }
      }

      final treeNodes = <Map<String, dynamic>>[];
      final filesToUpload = <_PendingUpload>[];
      int totalScannedBytes = 0;
      int totalUploadBytes = 0;
      int newCount = 0;
      int modifiedCount = 0;
      int unchangedCount = 0;
      int skippedTooLarge = 0;

      // Drop oversized files up front so the hashing pass never touches them.
      final candidates = <WorkspaceFile>[];
      final relPaths = <String, String>{};
      var sizesResolved = 0;
      for (final file in files) {
        final relPath = SafWorkspace.isSafPath(file.path)
            ? file.path.substring(workingDir.length + 1)
            : p.relative(file.path, from: workingDir).replaceAll(r'\', '/');

        // Prefer a size we already know: the scan result, or the remote tree.
        // Only an unknown size costs a provider round trip.
        var length = file.size;
        if (length < 0) length = remoteSizes[relPath] ?? -1;
        if (length < 0) {
          length = await file.length();
          sizesResolved++;
        }

        if (length > maxBlobBytes) {
          onLog(
            'Skipped ${file.name} (${_formatBytes(length)}) — exceeds the ${_formatBytes(maxBlobBytes)} per-file limit.',
            LogLevel.warning,
          );
          skippedTooLarge++;
          continue;
        }
        totalScannedBytes += length;
        relPaths[file.path] = relPath;
        candidates.add(file);
      }

      if (sizesResolved > 0) {
        onLog(
          'Resolved $sizesResolved file size(s) on demand '
          '(the rest came from the scan or the remote tree).',
          LogLevel.info,
        );
      }

      // Hashing is only needed to prove a file is UNCHANGED.
      //
      // A path that does not exist in the remote tree has to be uploaded
      // regardless, so its hash was never used. On a first push (or any new
      // file) the old code still read every byte twice: once to hash, once to
      // upload. That was the single biggest cost of a first push.
      final toCompare = <WorkspaceFile>[];
      final toUpload = <WorkspaceFile>[];
      for (final file in candidates) {
        final relPath = relPaths[file.path]!;
        if (existingRemoteBlobs.containsKey(relPath)) {
          toCompare.add(file);
        } else {
          newCount++;
          toUpload.add(file);
          // Sizes are already known from the scan / remote tree; never ask the
          // provider for one in this loop.
          totalUploadBytes += file.size >= 0 ? file.size : 0;
        }
      }

      onLog(
        '${toUpload.length} new file(s) need no hashing; '
        'comparing ${toCompare.length} that already exist on GitHub.',
        LogLevel.info,
      );

      PushProgressReporter.report(
        PushPhase.hashing,
        done: 0,
        total: toCompare.length,
        message: 'Comparing ${toCompare.length} file(s) with GitHub...',
      );

      // Hash only what can actually turn out to be unchanged: SAF files
      // natively (streamed, nothing crosses the channel), plain files here.
      final compareSafPaths = toCompare
          .where((f) => SafWorkspace.isSafPath(f.path))
          .map((f) => f.path)
          .toList();
      final nativeShas = await SafWorkspace.hashFiles(compareSafPaths);

      if (cancelRequested) throw const PushCancelled();

      if (compareSafPaths.isNotEmpty && nativeShas.isEmpty) {
        onLog(
          '[WARN] Could not compare against GitHub; those file(s) will be '
          'uploaded again.',
          LogLevel.warning,
        );
      }

      final remoteBefore = existingRemoteBlobs.length;
      for (int i = 0; i < toCompare.length; i++) {
        final file = toCompare[i];
        final relPath = relPaths[file.path]!;

        final localSha = SafWorkspace.isSafPath(file.path)
            ? nativeShas[file.path]
            : await _calculateGitBlobShaStreaming(file);

        // The sha decides; a size comparison would be unsound here because the
        // local size may itself be unknown, and it saves no work (a size change
        // still has to be hashed to be reported as modified).
        final remoteSha = existingRemoteBlobs[relPath];
        if (localSha != null && remoteSha == localSha) {
          unchangedCount++;
          // Reuse the remote blob by sha: this is what lets a commit include
          // unchanged files without re-uploading them.
          treeNodes.add({
            'path': relPath,
            'mode': '100644',
            'type': 'blob',
            'sha': localSha,
          });
        } else {
          modifiedCount++;
          final size = file.size >= 0 ? file.size : remoteSizes[relPath] ?? 0;
          totalUploadBytes += size;
          toUpload.add(file);
        }

        if (localSha == null && !SafWorkspace.isSafPath(file.path)) {
          onLog('Could not hash ${file.name}; uploading it to be safe.', LogLevel.warning);
        }

        if (cancelRequested) throw const PushCancelled();

        if (i % 25 == 0) {
          await Future.delayed(Duration.zero);
          PushProgressReporter.report(
            PushPhase.hashing,
            done: i,
            total: toCompare.length,
            message: 'Compared $i of ${toCompare.length} file(s) with GitHub',
          );
          if (i > 0 && i % 500 == 0) {
            onLog('Hashed $i/${toCompare.length} file(s)...', LogLevel.info);
          }
        }
      }

      for (final file in toUpload) {
        filesToUpload.add(_PendingUpload(file: file, relPath: relPaths[file.path]!));
      }

      if (remoteBefore == 0 && candidates.isNotEmpty) {
        onLog('Remote repository is empty; this will be the first commit.', LogLevel.info);
      }

      final summaryDiff = [
        if (newCount > 0) '$newCount new',
        if (modifiedCount > 0) '$modifiedCount modified',
        if (unchangedCount > 0) '$unchangedCount unchanged',
        if (skippedTooLarge > 0) '$skippedTooLarge skipped (too large)',
      ].join(', ');

      onLog(
        'Compared in ${(stopwatch.elapsedMilliseconds / 1000).toStringAsFixed(1)}s '
        '(scan alone: ${(scanTimer.elapsedMilliseconds / 1000).toStringAsFixed(1)}s).',
        LogLevel.info,
      );
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
        PushProgressReporter.finish(
          PushPhase.done,
          'Already up to date - nothing to upload.',
        );
        return;
      }

      onLog(
        'Uploading ${filesToUpload.length} file(s) '
        '(${_formatBytes(totalUploadBytes)}) with $uploadConcurrency parallel workers...',
        LogLevel.info,
      );
      int uploadedBytesCounter = 0;
      final failedFiles = <String>[];
      int processedCounter = 0;
      GitHubAuthException? authFailure;

      PushProgressReporter.report(
        PushPhase.uploading,
        done: 0,
        total: filesToUpload.length,
        message: 'Uploading ${filesToUpload.length} file(s)...',
      );

      // Bound the *encoded* cost, not the raw size: an upload holds the file,
      // a base64 string (~1.37x) and the JSON request body (~1.37x again), so
      // charge ~3x and cap the total. Peak heap stays around 30 MB no matter
      // how big the project is.
      const encodedCostFactor = 3;
      final budget = ByteBudget(30 * 1024 * 1024);

      await _runSlidingPool<_PendingUpload>(
        items: filesToUpload,
        concurrency: uploadConcurrency,
        worker: (item) async {
          // Once auth fails, stop burning through the remaining files: the
          // 401s would all be identical and the real problem is one token.
          if (authFailure != null || cancelRequested) return;
          int reserved = 0;
          try {
            // Reserve before reading so concurrency and file size cannot
            // combine into an out-of-memory kill.
            final length = await item.file.length();
            if (length > maxBlobBytes) {
              failedFiles.add(item.relPath);
              return;
            }
            reserved = (length > 0 ? length : 1) * encodedCostFactor;
            await budget.reserve(reserved);

            if (cancelRequested) return;

            final bytes = await item.file.readAsBytes();

            final blobRes = await client.post(
              _repoUri(owner, repoName, '/git/blobs'),
              headers: _headers(token),
              body: jsonEncode({
                'content': base64Encode(bytes),
                'encoding': 'base64',
              }),
            ).timeout(const Duration(seconds: 60));

            if (_isUnauthorized(blobRes)) {
              authFailure ??= _authFailureFor(blobRes, token: token, action: 'upload files');
              return;
            }

            if (_isRateLimited(blobRes)) {
              authFailure ??= GitHubAuthException(
                'GitHub is rate limiting this device mid-upload.',
                'Wait a few minutes and push again. Files already uploaded are cached.',
              );
              return;
            }

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
            if (authFailure == null) {
              failedFiles.add(item.relPath);
              onLog('Blob upload error for ${item.relPath}: $e', LogLevel.error);
            }
          } finally {
            if (reserved > 0) budget.release(reserved);
            processedCounter++;
            // Report progress on *every* file so the bar always moves; only
            // log every so often so the terminal stays readable.
            PushProgressReporter.report(
              PushPhase.uploading,
              done: processedCounter,
              total: filesToUpload.length,
              message:
                  '${_formatBytes(uploadedBytesCounter)} of ${_formatBytes(totalUploadBytes)} uploaded',
            );
            if (processedCounter % 25 == 0 ||
                processedCounter == filesToUpload.length) {
              onLog(
                'Uploaded $processedCounter/${filesToUpload.length} files '
                '(${_formatBytes(uploadedBytesCounter)} / ${_formatBytes(totalUploadBytes)})',
                LogLevel.info,
              );
            }
          }
        },
      );

      if (cancelRequested) {
        throw const PushCancelled();
      }

      if (authFailure != null) {
        // Abort before the commit: nothing is written to the branch.
        onLog(
          '[ABORTED] Authentication failed while uploading. Nothing was committed; the branch is unchanged.',
          LogLevel.error,
        );
        throw authFailure!;
      }

      if (failedFiles.isNotEmpty) {
        onLog(
          '[ABORTED] ${failedFiles.length} file(s) could not be uploaded. Nothing was committed; '
          'the branch is unchanged. First failures: ${failedFiles.take(5).join(', ')}',
          LogLevel.error,
        );
        PushProgressReporter.finish(
          PushPhase.failed,
          '${failedFiles.length} file(s) failed to upload. Nothing was committed.',
        );
        return;
      }

      PushProgressReporter.report(
        PushPhase.committing,
        message: 'All files uploaded. Creating the commit...',
      );
      onLog('Generating Git Tree with ${treeNodes.length} objects...', LogLevel.info);
      // Unchanged files (added during the compare pass) and uploaded files
      // (added by the workers) can arrive in any order; GitHub keys tree
      // entries by path, so sort for a stable, reviewable payload.
      treeNodes.sort((a, b) => (a['path'] as String).compareTo(b['path'] as String));
      final treePayload = <String, dynamic>{'tree': treeNodes};
      if (baseTreeSha != null) treePayload['base_tree'] = baseTreeSha;

      final treeRes = await client.post(
        _repoUri(owner, repoName, '/git/trees'),
        headers: _headers(token),
        body: jsonEncode(treePayload),
      ).timeout(const Duration(seconds: 60));

      if (_isUnauthorized(treeRes)) {
        throw _authFailureFor(treeRes, token: token, action: 'create the git tree');
      }
      if (treeRes.statusCode != 201) {
        onLog('Failed to create Git Tree: ${_extractMessage(treeRes)}', LogLevel.error);
        PushProgressReporter.finish(
          PushPhase.failed,
          'GitHub rejected the tree. Nothing was committed.',
        );
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
        _repoUri(owner, repoName, '/git/commits'),
        headers: _headers(token),
        body: jsonEncode(commitPayload),
      ).timeout(const Duration(seconds: 60));

      if (_isUnauthorized(commitRes)) {
        throw _authFailureFor(commitRes, token: token, action: 'create the commit');
      }
      if (commitRes.statusCode != 201) {
        onLog('Failed to create commit: ${_extractMessage(commitRes)}', LogLevel.error);
        PushProgressReporter.finish(
          PushPhase.failed,
          'GitHub rejected the commit. The branch is unchanged.',
        );
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
          _repoUri(owner, repoName, '/git/refs/heads/${_seg(branch)}'),
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
          PushProgressReporter.finish(
            PushPhase.done,
            'Pushed $shortSha: $newCount new, $modifiedCount modified.',
          );
        } else if (updateRefRes.statusCode == 409 || updateRefRes.statusCode == 422) {
          throw _PushConflict('Branch "$branch" was updated remotely while pushing.');
        } else {
          onLog('Failed to update branch reference: ${_extractMessage(updateRefRes)}', LogLevel.error);
          PushProgressReporter.finish(
            PushPhase.failed,
            'Could not move the branch. Nothing was committed.',
          );
        }
      } else {
        final createRefRes = await client.post(
          _repoUri(owner, repoName, '/git/refs'),
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
          PushProgressReporter.finish(
            PushPhase.done,
            'Created branch "$branch" at $shortSha.',
          );
        } else {
          onLog('Failed to create branch reference: ${_extractMessage(createRefRes)}', LogLevel.error);
          PushProgressReporter.finish(
            PushPhase.failed,
            'Could not create the branch. Nothing was committed.',
          );
        }
      }
    } on PushCancelled {
      // Nothing has been committed yet: the branch is untouched.
      rethrow;
    } on _PushConflict {
      // Handled by the retry wrapper.
      rethrow;
    } on GitHubAuthException {
      // Must reach the wrapper too, or the actionable remedy and the retry
      // prompt are lost to the generic handler below.
      rethrow;
    } on TimeoutException {
      onLog('Request timed out. The network is slow or GitHub is unreachable.', LogLevel.error);
      PushProgressReporter.finish(PushPhase.failed, 'Network timeout. The branch is unchanged.');
    } on SocketException {
      onLog('Network error: unable to reach GitHub. Check the device connection.', LogLevel.error);
      PushProgressReporter.finish(PushPhase.failed, 'Network error. The branch is unchanged.');
    } on FormatException {
      onLog('Unexpected response from GitHub (malformed JSON).', LogLevel.error);
    } catch (e) {
      onLog('Unexpected error during GitHub push: $e', LogLevel.error);
      PushProgressReporter.finish(PushPhase.failed, 'Unexpected error. The branch is unchanged.');
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
        _repoUri(owner, repoName, '/git/ref/heads/${_seg(branch)}'),
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
        _repoUri(owner, repoName, '/git/commits/${_seg(commitSha)}'),
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
  ///
  /// Uses [WorkspaceProbe], which survives individual unreadable entries
  /// instead of aborting the whole walk, and reports *why* nothing was found
  /// rather than logging a bare "No files found".
  static Future<List<WorkspaceFile>> _collectFiles({
    required String workingDir,
    Set<String>? specificPaths,
    required Function(String message, LogLevel level) onLog,
  }) async {
    PushProgressReporter.report(
      PushPhase.scanning,
      message: 'Scanning the workspace (this is the slow part for big projects)...',
    );

    // A granted folder is walked natively, so listen for its heartbeat: without
    // it the bar would sit still for however long the walk takes and the user
    // would assume the app had frozen again.
    StreamSubscription<Map<String, Object?>>? heartbeat;
    if (SafWorkspace.isSafPath(workingDir)) {
      heartbeat = SafWorkspace.progress.listen(
        (event) {
          if (event['type'] != 'scan') return;
          final scanned = (event['scanned'] as num?)?.toInt() ?? 0;
          final dirs = (event['dirs'] as num?)?.toInt() ?? 0;
          PushProgressReporter.report(
            PushPhase.scanning,
            done: scanned,
            total: 0,
            message: 'Found $scanned file(s) in $dirs folder(s) so far...',
          );
        },
        onError: (_) {},
      );
    }

    final WorkspaceScan scan;
    try {
      scan = specificPaths != null && specificPaths.isNotEmpty
          ? await WorkspaceProbe.scan(workingDir,
              maxFiles: 5000, specificPaths: specificPaths)
          : await WorkspaceProbe.scanForPush(workingDir, maxFiles: 5000);
    } finally {
      try {
        await heartbeat?.cancel();
      } catch (_) {
        // A broken progress stream must never fail the push itself.
      }
    }

    PushProgressReporter.report(
      PushPhase.scanning,
      done: scan.files.length,
      total: scan.files.length,
      message: 'Found ${scan.files.length} file(s) in ${scan.directoryCount} folder(s)',
    );

    onLog(
      'Scanned ${scan.directoryCount} folder(s) and found ${scan.files.length} file(s)'
      '${scan.skippedIgnored > 0 ? ' (${scan.skippedIgnored} skipped: build/VCS output)' : ''}.',
      LogLevel.info,
    );

    if (scan.unreadableEntries > 0) {
      onLog(
        '${scan.unreadableEntries} folder(s) could not be read and were skipped.',
        LogLevel.warning,
      );
      for (final error in scan.errors) {
        onLog('  $error', LogLevel.warning);
      }
    }

    if (scan.viaSaf && scan.files.isNotEmpty) {
      onLog(
        '[ACCESS] Reading ${scan.files.length} file(s) through the granted folder '
        '(Storage Access Framework) — no storage permission required.',
        LogLevel.success,
      );
    }

    if (scan.files.isEmpty) {
      if (scan.looksLikePermissionProblem) {
        // Folders visible, contents invisible: the folder was never granted.
        onLog(
          '[NO ACCESS] ${scan.directoryCount} folder(s) are visible but their contents are not readable.',
          LogLevel.error,
        );
        onLog(
          '[HOW TO FIX] Open the workspace picker and choose "Pick a folder", then '
          'grant this folder. The grant is permanent and needs no permission.',
          LogLevel.warning,
        );
      } else {
        onLog(
          '[EMPTY] No files found in $workingDir (and no build/VCS folders were skipped).',
          LogLevel.warning,
        );
      }
    }

    return scan.files;
  }
}
