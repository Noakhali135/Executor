import 'dart:io';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

class StorageService {
  static const String _keyWorkingDir = 'devrunner_working_dir';

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

  static Future<bool> requestStoragePermissions() async {
    if (Platform.isAndroid) {
      try {
        if (await Permission.manageExternalStorage.isGranted) {
          return true;
        }
        final status = await Permission.manageExternalStorage.request();
        if (status.isGranted) return true;

        final storageStatus = await Permission.storage.request();
        return storageStatus.isGranted;
      } catch (_) {}
    }
    return true;
  }
}