import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import 'php_template_engine.dart';

class PhpVersionInfo {
  final bool isAvailable;
  final String versionString;
  final String binaryPath;

  const PhpVersionInfo({
    required this.isAvailable,
    required this.versionString,
    required this.binaryPath,
  });
}

class PhpExecutionResult {
  final int exitCode;
  final String stdout;
  final String stderr;
  final Duration duration;

  const PhpExecutionResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    required this.duration,
  });

  bool get isSuccess => exitCode == 0;
}

class PhpService {
  static const String _keyPhpPath = 'devrunner_custom_php_path';
  static Process? _activePhpServer;
  static int? _activePhpServerPort;
  static String? _activeDocRoot;

  static const List<String> _commonPhpPaths = [
    'php',
    '/data/data/com.termux/files/usr/bin/php',
    '/system/bin/php',
    '/data/local/tmp/php',
    '/usr/bin/php',
    '/usr/local/bin/php',
  ];

  static Future<String?> getCustomPhpPath() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyPhpPath);
  }

  static Future<void> saveCustomPhpPath(String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyPhpPath, path.trim());
  }

  static Future<PhpVersionInfo> detectPhp() async {
    final customPath = await getCustomPhpPath();
    final candidates = <String>[];

    if (customPath != null && customPath.isNotEmpty) {
      candidates.add(customPath);
    }
    candidates.addAll(_commonPhpPaths);

    for (final path in candidates) {
      try {
        final result = await Process.run(path, ['-v']).timeout(const Duration(seconds: 4));
        if (result.exitCode == 0) {
          final firstLine = (result.stdout as String).split('\n').first.trim();
          return PhpVersionInfo(
            isAvailable: true,
            versionString: firstLine,
            binaryPath: path,
          );
        }
      } catch (_) {}
    }

    return const PhpVersionInfo(
      isAvailable: false,
      versionString: 'PHP CLI not found (Smart Template Engine Active)',
      binaryPath: '',
    );
  }

  static Future<PhpExecutionResult> runCliScript({
    required String scriptPath,
    required String workingDir,
    List<String> arguments = const [],
  }) async {
    final phpInfo = await detectPhp();
    final stopwatch = Stopwatch()..start();

    if (!phpInfo.isAvailable) {
      return PhpExecutionResult(
        exitCode: 127,
        stdout: '',
        stderr: 'PHP CLI executable not found in system or Termux.\n\n'
            '• In-App GUI Render mode is active and renders templates directly.\n'
            '• For native CLI/backend execution, install Termux and run:\n'
            '    pkg install php\n'
            'DevRunner will automatically link to Termux PHP.',
        duration: stopwatch.elapsed,
      );
    }

    try {
      final allArgs = [scriptPath, ...arguments];
      final result = await Process.run(
        phpInfo.binaryPath,
        allArgs,
        workingDirectory: workingDir,
      ).timeout(const Duration(seconds: 60));

      return PhpExecutionResult(
        exitCode: result.exitCode,
        stdout: result.stdout.toString(),
        stderr: result.stderr.toString(),
        duration: stopwatch.elapsed,
      );
    } catch (e) {
      return PhpExecutionResult(
        exitCode: 1,
        stdout: '',
        stderr: 'Execution error: $e',
        duration: stopwatch.elapsed,
      );
    }
  }

  static Future<int?> startPhpServer({
    required String docRoot,
    int? requestedPort,
  }) async {
    if (_activePhpServer != null && _activeDocRoot == docRoot && _activePhpServerPort != null) {
      return _activePhpServerPort;
    }

    await stopPhpServer();

    final phpInfo = await detectPhp();
    if (!phpInfo.isAvailable) {
      return null;
    }

    final portFinder = await ServerSocket.bind(InternetAddress.loopbackIPv4, requestedPort ?? 0);
    final port = portFinder.port;
    await portFinder.close();

    try {
      final process = await Process.start(
        phpInfo.binaryPath,
        [
          '-S',
          '127.0.0.1:$port',
          '-t',
          docRoot,
        ],
        workingDirectory: docRoot,
      );

      _activePhpServer = process;
      _activePhpServerPort = port;
      _activeDocRoot = docRoot;

      return port;
    } catch (_) {
      return null;
    }
  }

  static Future<void> stopPhpServer() async {
    _activePhpServer?.kill();
    _activePhpServer = null;
    _activePhpServerPort = null;
    _activeDocRoot = null;
  }

  static String renderPhpFileToHtml({
    required String phpCode,
    String fileName = 'index.php',
  }) {
    return PhpTemplateEngine.render(
      phpCode: phpCode,
      defaultTitle: fileName,
    );
  }
}