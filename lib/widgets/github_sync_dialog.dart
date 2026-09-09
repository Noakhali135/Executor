import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/command_action.dart';
import '../services/github_service.dart';

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
  List<Map<String, dynamic>> _userRepos = [];
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

  Future<void> _fetchRepos(String token, {String? preferredRepo}) async {
    setState(() {
      _isLoadingRepos = true;
    });

    final repos = await GitHubService.getUserRepos(token);

    if (mounted) {
      final target = preferredRepo ?? _selectedRepo;
      final bool exists = target != null && repos.any((r) => r['name'] == target);

      setState(() {
        _userRepos = repos;
        _selectedRepo = exists ? target : null;
        _isLoadingRepos = false;
      });
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
        setState(() {
          _savedToken = input;
          _username = result.username;
          _isVerifying = false;
          _selectedRepo = savedRepo;
        });
        _fetchRepos(input, preferredRepo: savedRepo);
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
    });
  }

  Future<void> _executePush() async {
    if (_savedToken == null || _username == null) return;

    final targetRepo = _isCreateNew ? _newRepoController.text.trim() : _selectedRepo;
    if (targetRepo == null || targetRepo.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please select or create a repository first'),
          backgroundColor: Color(0xFFDC2626),
          behavior: SnackBarBehavior.floating,
        ),
      );
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
      widget.onLog('Creating new repository "$targetRepo" on GitHub...', LogLevel.info);
      final created = await GitHubService.createRepository(
        token: _savedToken!,
        repoName: targetRepo,
        isPrivate: _isPrivate,
        description: 'Created with DevRunner Mobile',
      );
      if (!created) {
        widget.onLog('Repository creation note: Repo might already exist, proceeding...', LogLevel.warning);
      } else {
        widget.onLog('Repository "$targetRepo" created successfully.', LogLevel.success);
      }
      await GitHubService.saveRepo(targetRepo);
    } else {
      await GitHubService.saveRepo(targetRepo);
    }

    Navigator.pop(context);

    await GitHubService.pushWorkspace(
      token: _savedToken!,
      owner: _username!,
      repoName: targetRepo,
      branch: branch,
      commitMessage: commitMsg,
      workingDir: widget.workingDir,
      specificPaths: _pushSelectedOnly ? widget.selectedExplorerPaths : null,
      onLog: widget.onLog,
    );
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
          'Use a Personal Access Token (PAT). Classic Token with "repo" scope is recommended.',
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
          if (_isLoadingRepos)
            const Center(child: Padding(padding: EdgeInsets.all(8.0), child: CircularProgressIndicator(strokeWidth: 2)))
          else
            DropdownButtonFormField<String>(
              value: _selectedRepo,
              hint: const Text(
                'Select or create a repository first',
                style: TextStyle(color: Color(0xFF64748B), fontSize: 12),
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
              items: _userRepos.map((r) {
                return DropdownMenuItem<String>(
                  value: r['name'],
                  child: Text('${r['name']} ${r['private'] ? '🔒' : '🌐'}'),
                );
              }).toList(),
              onChanged: (val) async {
                setState(() => _selectedRepo = val);
                if (val != null) {
                  await GitHubService.saveRepo(val);
                }
              },
            ),
        ],
        const SizedBox(height: 10),
        TextField(
          controller: _branchController,
          style: const TextStyle(color: Colors.white, fontSize: 12.5, fontFamily: 'monospace'),
          decoration: InputDecoration(
            labelText: 'Target Branch',
            labelStyle: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
            filled: true,
            fillColor: const Color(0xFF080C16),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          ),
        ),
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
            label: const Text('Push to GitHub', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ),
      ],
    );
  }
}