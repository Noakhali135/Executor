import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'screens/runner_screen.dart';
import 'screens/explorer_screen.dart';
import 'services/storage_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Color(0xFF0B0F19),
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );
  runApp(const DevRunnerApp());
}

class DevRunnerApp extends StatelessWidget {
  const DevRunnerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DevRunner Mobile',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF070B14),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF6366F1),
          surface: Color(0xFF0B0F19),
        ),
      ),
      home: const MainShellScreen(),
    );
  }
}

class MainShellScreen extends StatefulWidget {
  const MainShellScreen({super.key});

  @override
  State<MainShellScreen> createState() => _MainShellScreenState();
}

class _MainShellScreenState extends State<MainShellScreen> {
  int _selectedTab = 0;
  String _workingDir = '';
  final TextEditingController _codeController = TextEditingController();
  final GlobalKey<ExplorerScreenState> _explorerKey = GlobalKey<ExplorerScreenState>();

  @override
  void initState() {
    super.initState();
    _loadInitialState();
  }

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _loadInitialState() async {
    final savedPath = await StorageService.getSavedDirectory();
    if (savedPath != null && savedPath.isNotEmpty) {
      setState(() {
        _workingDir = savedPath;
      });
    }
  }

  void _onDirectoryChanged(String newDir) {
    setState(() {
      _workingDir = newDir;
    });
    _explorerKey.currentState?.refresh();
  }

  void _onFileSelectedFromExplorer(String relativePath, String content) {
    setState(() {
      _codeController.text = content;
      _selectedTab = 0;
    });
  }

  void _onExecutionCompleted() {
    _explorerKey.currentState?.refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF070B14),
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(64),
        child: Container(
          padding: EdgeInsets.only(
            top: MediaQuery.of(context).padding.top + 6,
            left: 16,
            right: 16,
            bottom: 10,
          ),
          decoration: const BoxDecoration(
            color: Color(0xFF0B0F19),
            border: Border(
              bottom: BorderSide(color: Color(0xFF1E293B)),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF6366F1), Color(0xFF4F46E5)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(10),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF6366F1).withOpacity(0.35),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: const Center(
                      child: Text(
                        '</>',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'DevRunner Mobile',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      Text(
                        'CLI & Workspace Environment',
                        style: TextStyle(
                          color: Color(0xFF94A3B8),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: const Color(0xFF064E3B).withOpacity(0.4),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: const Color(0xFF059669)),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.circle, size: 8, color: Color(0xFF10B981)),
                    SizedBox(width: 6),
                    Text(
                      'Ready',
                      style: TextStyle(
                        color: Color(0xFF34D399),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      body: IndexedStack(
        index: _selectedTab,
        children: [
          RunnerScreen(
            workingDir: _workingDir,
            onDirectoryChanged: _onDirectoryChanged,
            codeController: _codeController,
            onExecutionCompleted: _onExecutionCompleted,
          ),
          ExplorerScreen(
            key: _explorerKey,
            workingDir: _workingDir,
            onFileSelected: _onFileSelectedFromExplorer,
            onRefreshRequested: () {},
          ),
        ],
      ),
      bottomNavigationBar: Container(
        height: 62,
        decoration: const BoxDecoration(
          color: Color(0xFF0B0F19),
          border: Border(
            top: BorderSide(color: Color(0xFF1E293B)),
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: _buildNavItem(
                icon: Icons.terminal_rounded,
                label: 'Runner',
                isSelected: _selectedTab == 0,
                onTap: () => setState(() => _selectedTab = 0),
              ),
            ),
            Expanded(
              child: _buildNavItem(
                icon: Icons.account_tree_outlined,
                label: 'Explorer',
                isSelected: _selectedTab == 1,
                onTap: () => setState(() => _selectedTab = 1),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNavItem({
    required IconData icon,
    required String label,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            icon,
            size: 20,
            color: isSelected ? const Color(0xFF818CF8) : const Color(0xFF64748B),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              color: isSelected ? Colors.white : const Color(0xFF64748B),
              fontSize: 12,
              fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ],
      ),
    );
  }
}