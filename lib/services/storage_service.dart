import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Workspace location.
///
/// The app requests **no storage permissions at all**. Workspaces come from
/// exactly two places, both permission-free:
///
///  * a folder granted through the Storage Access Framework (see
///    `SafWorkspace`), which persists across reboots, or
///  * the app-specific directory
///    `/storage/emulated/0/Android/data/<pkg>/files/DevRunner`, which is
///    private to the app and still reachable over USB/ADB.
class StorageService {
  static const String _keyWorkingDir = 'devrunner_working_dir';
  static const String _workspaceFolderName = 'DevRunner';

  static Future<String?> getSavedDirectory() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_keyWorkingDir);
    if (saved != null && saved.isNotEmpty) {
      return saved;
    }
    return null;
  }

  static Future<void> saveDirectory(String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyWorkingDir, path);
  }

  /// The default, permission-free workspace directory.
  ///
  /// Created on first use. Falls back to the documents directory on desktop.
  static Future<String> defaultWorkspaceDir() async {
    Directory base;
    try {
      if (Platform.isAndroid) {
        // App-specific external storage: no permission required, and visible
        // over MTP/adb so the user can still transfer projects in and out.
        base = await getExternalStorageDirectory() ??
            await getApplicationDocumentsDirectory();
      } else if (Platform.isIOS) {
        base = await getApplicationDocumentsDirectory();
      } else {
        base = await getApplicationDocumentsDirectory();
      }
    } catch (_) {
      base = Directory.current;
    }

    final workspace = Directory(p.join(base.path, _workspaceFolderName));
    if (!await workspace.exists()) {
      try {
        await workspace.create(recursive: true);
      } catch (_) {
        return base.path;
      }
    }
    return workspace.path;
  }
}
