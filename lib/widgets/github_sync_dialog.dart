import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/command_action.dart';
import '../services/github_service.dart';
import '../services/push_progress.dart';
import '../services/workspace_probe.dart';

class GitHubSyncDialog extends StatefulWidget {
  final String workingDir;
  final Set<String>? selectedExplorerPaths;
  final Function(String message, LogLevel level) onLog;

  const GitHubSyncDialog({
    super.key,
    required this.workingDir,
    this.selectedExplorerPaths,
    required this.onLog,
  });

  @override
  State<GitHubSyncDialog> createState() => _GitHubSyncDialogState();
}

class _GitHubSyncDialogState extends State<GitHubSyncDialog> {
  final TextEditingController _tokenController = TextEditingController();
  final TextEditingController _newRepoController = TextEditingController();
  final TextEditingController _branchController = TextEditingController(text: 'main');
  final TextEditingController _commitController = TextEditingController(text: 'Update via DevRunner Mobile');

  String? _savedToken;
  String? _username;
  bool _isVerifying = false;
  bool _isPushing = false;

  bool _isCreateNew = false;
  bool _isPrivate = true;
  String? _selectedRepo;
  String _selectedRepoDefaultBranch = 'main';
  List<Map<String, dynamic>> _userRepos = [];
  String? _reposError;
  bool _isLoadingRepos = false;
  bool _pushSelectedOnly = false;

  @override
  void initState() {
    super.initState();
    _pushSelectedOnly = widget.selectedExplorerPaths != null && widget.selectedExplorerPaths!.isNotEmpty;
    _loadAuthStatus();
  }

  @override
  void dispose() {
    _tokenController.dispose();
    _newRepoController.dispose();
    _branchController.dispose();
    _commitController.dispose();
    super.dispose();
  }

  Future<void> _loadAuthStatus() async {
    final token = await GitHubService.getToken();
    final user = await GitHubService.getCachedUsername();
    final savedRepo = await GitHubService.getSavedRepo();

    if (token != null && token.isNotEmpty && user != null) {
      setState(() {
        _savedToken = token;
        _username = user;
        _selectedRepo = savedRepo;
      });
      _fetchRepos(token, preferredRepo: savedRepo);
    }
  }

  /// Generation counter for [_fetchRepos].
  ///
  /// The dropdown starts a refresh when it shows, and every refresh used to
  /// apply its own result on arrival. Opening the dialog and grabbing a
  /// dropdown before the list finished meant the in-flight *initial* request
  /// landed afterwards and put the saved repository straight back - so the
  /// push went to the old repo even though a different one was visibly
  /// selected. Only the newest request may now touch the selection.
  int _reposRequestId = 0;

  /// True once the user picked a repository by hand. Nothing may override it.
  bool _repoPickedByUser = false;

  /// Names available in the dropdown: the fetched list plus the selection
  /// itself, so a repo that is missing from a stale list is still selectable.
  List<String> get _repoNames {
    final names = <String>[
      for (final repo in _userRepos)
        if ((repo['name'] as String?)?.trim().isNotEmpty ?? false)
          (repo['name'] as String).trim(),
    ];
    final selected = (_selectedRepo ?? '').trim();
    if (selected.isNotEmpty && !names.any((n) => n.toLowerCase() == selected.toLowerCase())) {
      names.insert(0, selected);
    }
    return names;
  }

  /// The repository the next push will go to; '' when nothing is chosen.
  ///
  /// Single source of truth: the destination banner, the button label and the
  /// push itself all read this, so what is displayed cannot differ from where
  /// the commit actually goes.
  String get _pushDestination {
    if (_isCreateNew) return _newRepoController.text.trim();
    final resolved = resolveTargetRepo(
      selected: _selectedRepo,
      available: _repoNames,
      pickedByUser: _repoPickedByUser,
    );
    return (resolved ?? '').trim();
  }

  String get _pushDestinationLabel {
    final target = _pushDestination;
    if (target.isEmpty) return 'Choose a repository';
    return 'Push to $target';
  }

  Widget _destinationBanner() {
    final target = _pushDestination;
    final ready = target.isNotEmpty;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: ready ? const Color(0xFF0F1F1A) : const Color(0xFF2A1215),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: ready ? const Color(0xFF10B981) : const Color(0xFFDC2626),
        ),
      ),
      child: Row(
        children: [
          Icon(
            ready ? Icons.arrow_forward_rounded : Icons.warning_amber_rounded,
            size: 14,
            color: ready ? const Color(0xFF34D399) : const Color(0xFFF87171),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              ready
                  ? 'Pushing to $_username/$target'
                      '${_isCreateNew ? ' (will be created)' : ''}'
                  : 'Pick a repository — nothing will be pushed without one.',
              style: TextStyle(
                color: ready ? const Color(0xFFA7F3D0) : const Color(0xFFFCA5A5),
                fontSize: 11.5,
                height: 1.3,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _repoLabel(String name) {
    for (final repo in _userRepos) {
      if ((repo['name'] as String?)?.trim().toLowerCase() == name.toLowerCase()) {
        return '$name ${repo['private'] == true ? '🔒' : '🌐'}';
      }
    }
    // Not in the list we fetched, but still the chosen target.
    return '$name (selected)';
  }

  Future<void> _fetchRepos(String token, {String? preferredRepo}) async {
    final requestId = ++_reposRequestId;

    setState(() {
      _isLoadingRepos = true;
      _reposError = null;
    });

    final result = await GitHubService.getUserRepos(token);
    final repos = result.repos;

    if (!mounted) return;

    // A newer request superseded this one; its answer is the truth.
    if (requestId != _reposRequestId) return;

    if (repos.isEmpty) {
      // Keep whatever the user already had: a failed or rate-limited list must
      // never be mistaken for "you have to choose again".
      final kept = (preferredRepo ?? _selectedRepo)?.trim();
      setState(() {
        _isLoadingRepos = false;
        _reposError = result.error ??
            'No repositories were returned for this account.';
        if (kept != null && kept.isNotEmpty) _selectedRepo = kept;
      });
      if (result.error != null) {
        widget.onLog('[REPOS] ${result.error!}', LogLevel.warning);
      }
      return;
    }

    // The user's own choice always wins, even if it is not in this list (a
    // freshly created repo, or a stale list). This is the rule that stops a
    // push from ever silently landing in a different repository.
    if (_repoPickedByUser && (_selectedRepo ?? '').trim().isNotEmpty) {
      setState(() {
        _userRepos = repos;
        _isLoadingRepos = false;
      });
      return;
    }

    final target = (preferredRepo ?? _selectedRepo)?.trim();
    Map<String, dynamic>? match;
    if (target != null && target.isNotEmpty) {
      final lower = target.toLowerCase();
      for (final repo in repos) {
        final name = (repo['name'] as String?)?.trim().toLowerCase();
        if (name == lower) {
          match = repo;
          break;
        }
      }
    }

    // Fallback chain: saved match -> first repo -> previous selection.
    final resolved = match?['name'] as String? ??
        (repos.isNotEmpty ? repos.first['name'] as String? : null) ??
        target;

    final defaultBranch = (match?['default_branch'] as String?) ?? 'main';

    setState(() {
      _userRepos = repos;
      _selectedRepo = resolved;
      _selectedRepoDefaultBranch = defaultBranch;
      if (resolved != null) _branchController.text = defaultBranch;
      _isLoadingRepos = false;
    });

    if (match == null && target != null && target.isNotEmpty) {
      widget.onLog(
        'Saved repository "$target" is not in this account any more; using '
        '"$resolved" instead. Pick another from the dropdown if that is wrong.',
        LogLevel.warning,
      );
    }
  }

  Future<void> _handlePasteToken() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data != null && data.text != null) {
      _tokenController.text = data.text!.trim();
    }
  }

  Future<void> _verifyAndSaveToken() async {
    final input = _tokenController.text.trim();
    if (input.isEmpty) return;

    setState(() {
      _isVerifying = true;
    });

    final result = await GitHubService.verifyToken(input);
    if (result.success && result.username != null) {
      await GitHubService.saveToken(input, result.username!);
      final savedRepo = await GitHubService.getSavedRepo();
      if (mounted) {
        final keepManualPick =
            _repoPickedByUser && (_selectedRepo ?? '').trim().isNotEmpty;
        setState(() {
          _savedToken = input;
          _username = result.username;
          _isVerifying = false;
          // A new token must not silently move the destination back to the
          // previously saved repo when the user has already chosen one.
          if (!keepManualPick) _selectedRepo = savedRepo;
        });
        _fetchRepos(
          input,
          preferredRepo: keepManualPick ? _selectedRepo : savedRepo,
        );
      }
    } else {
      if (mounted) {
        setState(() {
          _isVerifying = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result.errorMessage ?? 'Token verification failed'),
            backgroundColor: const Color(0xFFDC2626),
            duration: const Duration(seconds: 4),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Future<void> _disconnect() async {
    await GitHubService.clearToken();
    setState(() {
      _savedToken = null;
      _username = null;
      _userRepos = [];
      _selectedRepo = null;
      _repoPickedByUser = false;
    });
  }

  Future<void> _executePush() async {
    if (_savedToken == null || _username == null) return;

    // What the user chose is final.
    //
    // This used to fall back to the *saved* repository whenever the selection
    // looked empty, which meant a push could silently land in the previously
    // used repo even though another one was selected on screen. There is no
    // more fallback-to-saved: either the user picked something (dropdown or
    // "Create New"), or the push stops and asks.
    // Non-nullable from here on, so it survives the awaits below: a nullable
    // local is not promoted across an await boundary. Same getter the banner
    // and the button use, so they cannot disagree.
    final String target = _pushDestination;

    if (target.isEmpty) {
      if (mounted) {
        setState(() => _isPushing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Choose a repository first — nothing was pushed.'),
            backgroundColor: Color(0xFFDC2626),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    // Never let the model and the screen disagree about the destination.
    if (_selectedRepo != target && mounted) {
      setState(() => _selectedRepo = target);
    }

    // Say it once, loudly, before a single byte is uploaded.
    widget.onLog(
      'Pushing to repository: $target'
      '${_isCreateNew ? ' (new)' : ''}',
      LogLevel.info,
    );

    // Pre-flight the workspace: pushing to a folder Android will not let us
    // read used to fail with a bare "No files found to push to GitHub".
    final probe = await WorkspaceProbe.scanForPush(widget.workingDir, maxFiles: 200);
    if (probe.files.isEmpty) {
      final problems = await WorkspaceProbe.diagnose(widget.workingDir);
      for (final problem in problems) {
        widget.onLog('[WORKSPACE] $problem', LogLevel.error);
      }
      if (probe.looksLikePermissionProblem) {
        widget.onLog(
          '[HOW TO FIX] Open the workspace picker and choose "Pick a folder", then '
          'grant this folder to DevRunner. The grant is permanent.',
          LogLevel.warning,
        );
      }
      if (mounted) {
        setState(() => _isPushing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              probe.looksLikePermissionProblem
                  ? 'This folder is not granted to DevRunner. Pick it again.'
                  : 'This folder contains no files to push.',
            ),
            backgroundColor: const Color(0xFFDC2626),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 5),
          ),
        );
      }
      return;
    }

    final branch = _branchController.text.trim().isEmpty ? 'main' : _branchController.text.trim();
    final commitMsg = _commitController.text.trim().isEmpty
        ? 'Update via DevRunner'
        : _commitController.text.trim();

    setState(() {
      _isPushing = true;
    });

    if (_isCreateNew) {
      widget.onLog('Creating new repository "$target" on GitHub...', LogLevel.info);
      final created = await GitHubService.createRepository(
        token: _savedToken!,
        repoName: target,
        isPrivate: _isPrivate,
        description: 'Created with DevRunner Mobile',
      );

      if (!created.success) {
        // Stop here rather than pretending and pushing into a repo that does
        // not exist. This is what used to produce a 404 several steps later.
        widget.onLog('[CREATE FAILED] ${created.message}', LogLevel.error);
        if (created.remedy != null) {
          widget.onLog('[HOW TO FIX] ${created.remedy!}', LogLevel.warning);
        }
        if (mounted) {
          setState(() => _isPushing = false);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(created.message),
              backgroundColor: const Color(0xFFDC2626),
              behavior: SnackBarBehavior.floating,
              duration: const Duration(seconds: 5),
            ),
          );
        }
        return;
      }

      widget.onLog('[SUCCESS] ${created.message}', LogLevel.success);
      // Adopt the canonical name GitHub returned (it may differ in casing) and
      // treat the new repo as the selected one from now on.
      final canonical = created.repoName ?? target;
      await GitHubService.saveRepo(canonical);
      _selectedRepo = canonical;
      _branchController.text = 'main';
    } else {
      await GitHubService.saveRepo(target);
    }

    // Capture a context that outlives this dialog: the re-auth prompt is shown
    // *after* this dialog is popped so the user can watch the terminal, and
    // this dialog's own context would already be deactivated by then.
    final navigatorContext = Navigator.of(context, rootNavigator: true).context;

    // Drive the shared progress reporter; the Runner renders it, so status
    // stays visible after this dialog closes.
    PushProgressReporter.begin('Preparing push...');

    if (mounted) Navigator.pop(context);

    // The dialog is gone but the callback still targets the Runner's log list,
    // which owns its own mounted checks.
    try {
      await GitHubService.pushWorkspace(
        token: _savedToken!,
        owner: _username!,
        repoName: target,
        branch: branch,
        commitMessage: commitMsg,
        workingDir: widget.workingDir,
        specificPaths: _pushSelectedOnly ? widget.selectedExplorerPaths : null,
        onLog: widget.onLog,
        onReauth: (error) => _promptForNewToken(navigatorContext, error),
      );

      // pushWorkspace owns the terminal phase: it knows whether it actually
      // committed. Only guard against a phase left hanging.
      final last = PushProgressReporter.current.value;
      if (last.isRunning) {
        PushProgressReporter.finish(
          PushPhase.failed,
          'Push ended without confirming a commit. Check the log above.',
        );
      }
    } catch (e) {
      // Never rethrow: this runs after the dialog is popped, so an unhandled
      // async error here would surface as an uncaught exception far from the
      // cause.
      PushProgressReporter.finish(PushPhase.failed, '$e');
    } finally {
      // Clear a successful result after a while so the panel does not sit on
      // screen forever. Failures stay put: the user needs to read them.
      Future.delayed(const Duration(seconds: 20), () {
        if (PushProgressReporter.current.value.phase == PushPhase.done) {
          PushProgressReporter.reset();
        }
      });
    }
  }

  /// Shown from the Runner's log when a push fails on auth: lets the user
  /// replace the stored token without leaving the flow.
  Future<String?> _promptForNewToken(
    BuildContext navigatorContext,
    GitHubAuthException error,
  ) async {
    // The caller's own context is gone by now; validate against the navigator.
    if (!navigatorContext.mounted) return null;

    final controller = TextEditingController();
    try {
      final newToken = await showDialog<String>(
        context: navigatorContext,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF111827),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: const BorderSide(color: Color(0xFF7F1D1D)),
          ),
          title: const Row(
            children: [
              Icon(Icons.key_off_rounded, color: Color(0xFFF87171), size: 18),
              SizedBox(width: 8),
              Text(
                'GitHub rejected the token',
                style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                error.message,
                style: const TextStyle(color: Color(0xFFFCA5A5), fontSize: 12, height: 1.35),
              ),
              const SizedBox(height: 8),
              Text(
                error.remedy,
                style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 12, height: 1.35),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                obscureText: true,
                style: const TextStyle(color: Colors.white, fontFamily: 'monospace', fontSize: 12.5),
                decoration: InputDecoration(
                  hintText: 'ghp_… or github_pat_…',
                  hintStyle: const TextStyle(color: Color(0xFF475569)),
                  filled: true,
                  fillColor: const Color(0xFF080C16),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel', style: TextStyle(color: Color(0xFF94A3B8))),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF6366F1),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('Retry push', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      );

      if (newToken == null || newToken.isEmpty) return null;

      final verified = await GitHubService.verifyToken(newToken);
      if (verified.success && verified.username != null) {
        await GitHubService.saveToken(newToken, verified.username!);
        return newToken;
      }
      widget.onLog(
        '[AUTH] The replacement token was rejected too: '
        '${verified.errorMessage ?? 'unknown error'}',
        LogLevel.error,
      );
      return null;
    } finally {
      controller.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF0F1523),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Color(0xFF1E293B)),
      ),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Row(
                  children: [
                    Icon(Icons.cloud_upload_rounded, color: Color(0xFF818CF8), size: 20),
                    SizedBox(width: 8),
                    Text(
                      'GitHub Sync & Push',
                      style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close, color: Color(0xFF94A3B8), size: 18),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
            const SizedBox(height: 14),
            if (_savedToken == null) _buildTokenSetupView() else _buildPushFormView(),
          ],
        ),
      ),
    );
  }

  Widget _buildTokenSetupView() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Connect your GitHub Account',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13.5),
        ),
        const SizedBox(height: 4),
        const Text(
          'Use a Personal Access Token. Classic tokens need the "repo" scope; '
          'fine-grained tokens need Contents: Read and write on each repo.',
          style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _tokenController,
          obscureText: true,
          style: const TextStyle(color: Colors.white, fontFamily: 'monospace', fontSize: 12.5),
          decoration: InputDecoration(
            hintText: 'ghp_xxxxxxxxxxxxxxxxxxxx',
            hintStyle: const TextStyle(color: Color(0xFF475569)),
            filled: true,
            fillColor: const Color(0xFF080C16),
            suffixIcon: IconButton(
              icon: const Icon(Icons.paste_rounded, color: Color(0xFF818CF8), size: 18),
              onPressed: _handlePasteToken,
              tooltip: 'Paste Token',
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Color(0xFF1E293B)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Color(0xFF6366F1)),
            ),
          ),
        ),
        const SizedBox(height: 14),
        SizedBox(
          width: double.infinity,
          height: 42,
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF6366F1),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: _isVerifying ? null : _verifyAndSaveToken,
            child: _isVerifying
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Text('Verify & Save Token', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ),
      ],
    );
  }

  Widget _buildPushFormView() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xFF080C16),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFF1E293B)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  const Icon(Icons.circle, color: Color(0xFF10B981), size: 8),
                  const SizedBox(width: 8),
                  Text(
                    '@$_username',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                  ),
                ],
              ),
              InkWell(
                onTap: _disconnect,
                child: const Text(
                  'Disconnect',
                  style: TextStyle(color: Color(0xFFF87171), fontSize: 11.5),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: ChoiceChip(
                label: const Center(child: Text('Existing Repo')),
                selected: !_isCreateNew,
                selectedColor: const Color(0xFF6366F1),
                // Selecting "Existing Repo" means _isCreateNew must be false.
                onSelected: (val) => setState(() => _isCreateNew = !val),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: ChoiceChip(
                label: const Center(child: Text('Create New')),
                selected: _isCreateNew,
                selectedColor: const Color(0xFF6366F1),
                onSelected: (val) => setState(() => _isCreateNew = val),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (_isCreateNew) ...[
          TextField(
            controller: _newRepoController,
            // The destination banner and the button label both show this name,
            // so they must refresh as it is typed.
            onChanged: (_) => setState(() {}),
            style: const TextStyle(color: Colors.white, fontSize: 12.5),
            decoration: InputDecoration(
              labelText: 'Repository Name',
              labelStyle: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
              filled: true,
              fillColor: const Color(0xFF080C16),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
          const SizedBox(height: 6),
          SwitchListTile(
            title: const Text('Private Repository', style: TextStyle(color: Colors.white, fontSize: 12.5)),
            value: _isPrivate,
            activeColor: const Color(0xFF6366F1),
            contentPadding: EdgeInsets.zero,
            onChanged: (val) => setState(() => _isPrivate = val),
          ),
        ] else ...[
          // A failed list download must be visible and retryable rather than
          // looking like "this account has no repositories".
          if (_reposError != null && !_isLoadingRepos)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _reposError!,
                      style: const TextStyle(color: Color(0xFFFCA5A5), fontSize: 11),
                    ),
                  ),
                  TextButton(
                    onPressed: () {
                      final token = _savedToken;
                      if (token == null || token.isEmpty) return;
                      _fetchRepos(token, preferredRepo: _selectedRepo);
                    },
                    child: const Text('Retry', style: TextStyle(fontSize: 11)),
                  ),
                ],
              ),
            ),
          if (_isLoadingRepos)
            const Center(child: Padding(padding: EdgeInsets.all(8.0), child: CircularProgressIndicator(strokeWidth: 2)))
          else
            DropdownButtonFormField<String>(
              // DropdownButtonFormField throws if `value` is not one of `items`.
              // A repo created this session, or one missing from a stale list,
              // would otherwise crash the dialog. Validate it here and keep the
              // choice as a pinned extra item so it stays visible AND selected.
              value: _repoNames.contains(_selectedRepo) ? _selectedRepo : null,
              hint: Text(
                _reposError != null
                    ? 'Could not load your repositories — tap Retry'
                    : _userRepos.isEmpty
                        ? 'No repositories found — try "Create New"'
                        : 'Select a repository',
                style: const TextStyle(color: Color(0xFF64748B), fontSize: 12),
              ),
              dropdownColor: const Color(0xFF111827),
              style: const TextStyle(color: Colors.white, fontSize: 12.5),
              decoration: InputDecoration(
                labelText: 'Select Repository',
                labelStyle: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
                filled: true,
                fillColor: const Color(0xFF080C16),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              ),
              items: [
                for (final name in _repoNames)
                  DropdownMenuItem<String>(
                    value: name,
                    child: Text(_repoLabel(name)),
                  ),
              ],
              onChanged: (val) async {
                if (val == null) return;
                final match = _userRepos.firstWhere(
                  (r) => r['name'] == val,
                  orElse: () => const {'default_branch': 'main'},
                );
                final branch = (match['default_branch'] as String?) ?? 'main';
                setState(() {
                  _selectedRepo = val;
                  _repoPickedByUser = true;
                  _selectedRepoDefaultBranch = branch;
                  _branchController.text = branch;
                });
                widget.onLog('Target repository set to "$val".', LogLevel.info);
                await GitHubService.saveRepo(val);
              },
            ),
        ],
        const SizedBox(height: 10),
        TextField(
          controller: _branchController,
          style: const TextStyle(color: Colors.white, fontSize: 12.5, fontFamily: 'monospace'),
          decoration: InputDecoration(
            labelText: 'Target Branch (repo default: $_selectedRepoDefaultBranch)',
            labelStyle: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
            filled: true,
            fillColor: const Color(0xFF080C16),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          ),
        ),
        const SizedBox(height: 10),
        // The destination, spelled out. If this ever disagrees with the
        // dropdown, the push is blocked rather than guessing.
        _destinationBanner(),
        const SizedBox(height: 10),
        TextField(
          controller: _commitController,
          style: const TextStyle(color: Colors.white, fontSize: 12.5),
          decoration: InputDecoration(
            labelText: 'Commit Message',
            labelStyle: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
            filled: true,
            fillColor: const Color(0xFF080C16),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          ),
        ),
        if (widget.selectedExplorerPaths != null && widget.selectedExplorerPaths!.isNotEmpty) ...[
          const SizedBox(height: 6),
          CheckboxListTile(
            title: Text(
              'Push only selected files (${widget.selectedExplorerPaths!.length})',
              style: const TextStyle(color: Color(0xFFC7D2FE), fontSize: 12),
            ),
            value: _pushSelectedOnly,
            activeColor: const Color(0xFF6366F1),
            contentPadding: EdgeInsets.zero,
            onChanged: (val) => setState(() => _pushSelectedOnly = val ?? false),
          ),
        ],
        const SizedBox(height: 14),
        SizedBox(
          width: double.infinity,
          height: 44,
          child: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF10B981),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: _isPushing ? null : _executePush,
            icon: const Icon(Icons.cloud_upload_rounded, color: Colors.white, size: 18),
            label: Text(
              _pushDestinationLabel,
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            ),
          ),
        ),
      ],
    );
  }
}