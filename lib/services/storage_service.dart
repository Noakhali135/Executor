import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

class StorageService {
  static const String _keyWorkingDir = 'devrunner_working_dir';

  static Future<String?> getSavedDirectory() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_keyWorkingDir);
    if (saved != null && saved.isNotEmpty && Directory(saved).existsSync()) {
      return saved;
    }
    return saved;
  }

  static Future<void> saveDirectory(String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyWorkingDir, path);
  }

  static Future<bool> requestStoragePermissions() async {
    if (Platform.isAndroid) {
      if (await Permission.manageExternalStorage.isGranted) {
        return true;
      }
      final status = await Permission.manageExternalStorage.request();
      if (status.isGranted) return true;

      final storageStatus = await Permission.storage.request();
      return storageStatus.isGranted;
    }
    return true;
  }

  static Future<String?> pickDirectory() async {
    await requestStoragePermissions();
    try {
      final selectedPath = await FilePicker.platform.getDirectoryPath(
        dialogTitle: 'Select Project Working Directory',
      );
      if (selectedPath != null && selectedPath.isNotEmpty) {
        await saveDirectory(selectedPath);
        return selectedPath;
      }
    } catch (_) {}
    return null;
  }
}