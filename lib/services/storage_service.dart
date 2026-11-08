import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Workspace location and storage-permission policy.
///
/// Design goal: the app must be fully usable with **zero** runtime
/// permissions, because `MANAGE_EXTERNAL_STORAGE` ("All files access") is a
/// Play Store sensitive permission and is not granted by default on
/// Android 11+.
///
///  * The default workspace lives in the app-specific external directory
///    (`/storage/emulated/0/Android/data/<pkg>/files/DevRunner`), which needs
///    no permission at all and is still reachable over USB/ADB.
///  * Anything outside that directory requires either the legacy
///    `WRITE_EXTERNAL_STORAGE` permission (Android ≤ 10) or the explicit
///    "All files access" opt-in (Android 11+).
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

  /// True when this app has been granted broad filesystem access.
  static Future<bool> hasBroadStorageAccess() async {
    if (!Platform.isAndroid) return true;
    try {
      if (await Permission.manageExternalStorage.isGranted) return true;
      if (await Permission.storage.isGranted) return true;
    } catch (_) {}
    return false;
  }

  /// Requests only the legacy storage permission.
  ///
  /// This is intentionally *not* called on startup any more: asking for
  /// "All files access" before the user has shown any intent to leave the app
  /// workspace is both a bad first impression and a review risk.
  static Future<bool> requestLegacyStoragePermission() async {
    if (!Platform.isAndroid) return true;
    try {
      if (await Permission.storage.isGranted) return true;
      final status = await Permission.storage.request();
      return status.isGranted;
    } catch (_) {
      return false;
    }
  }

  /// Explicit, user-initiated request for "All files access" (Android 11+).
  ///
  /// Android has no in-app dialog for this permission: the request opens the
  /// system settings page. The user then leaves and returns to the app, so the
  /// grant is re-checked a few times with a short delay instead of trusting the
  /// value returned the instant the settings screen was dismissed (which is
  /// usually still `denied` and made the app look like it had failed).
  static Future<bool> requestAllFilesAccess() async {
    if (!Platform.isAndroid) return true;
    try {
      if (await Permission.manageExternalStorage.isGranted) return true;

      await Permission.manageExternalStorage.request();

      // Poll for the grant the user just made in system settings.
      for (var attempt = 0; attempt < 5; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 400));
        if (await Permission.manageExternalStorage.isGranted) return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Re-checks access after the app resumes from system settings.
  static Future<bool> refreshAllFilesAccess() async {
    if (!Platform.isAndroid) return true;
    try {
      return await Permission.manageExternalStorage.isGranted ||
          await Permission.storage.isGranted;
    } catch (_) {
      return false;
    }
  }

  /// Opens the system screen where "All files access" can be toggled.
  static Future<void> openAppSettingsPage() async {
    try {
      await openAppSettings();
    } catch (_) {}
  }

  /// True when writing to [path] is likely to fail for permission reasons.
  ///
  /// Used to warn the user *before* they pick a directory they cannot write
  /// to, instead of failing halfway through an execute.
  static Future<bool> canWriteTo(String path) async {
    try {
      final dir = Directory(path);
      if (!await dir.exists()) return false;
      final probe = File(p.join(path, '.devrunner_write_test'));
      await probe.writeAsString('ok', flush: true);
      await probe.delete();
      return true;
    } catch (_) {
      return false;
    }
  }
}
