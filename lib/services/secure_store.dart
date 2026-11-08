import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Key/value storage for the GitHub token.
///
/// The token is a credential with `repo` scope, so it is kept in the platform
/// keystore/keychain (Android Keystore-backed EncryptedSharedPreferences on
/// Android, Keychain on iOS) instead of plain `SharedPreferences`.
///
/// A one-shot migration moves any token written by older builds out of
/// SharedPreferences and deletes the plaintext copy.
class SecureStore {
  SecureStore._();

  static const String _tokenKey = 'devrunner_secure_github_token';
  static const String _legacyTokenKey = 'github_pat_token';

  static const FlutterSecureStorage _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  static Future<String?> readToken() async {
    try {
      final value = await _storage.read(key: _tokenKey);
      if (value != null && value.isNotEmpty) return value;
    } catch (_) {
      // Fall through to migration/return null; callers degrade gracefully.
    }
    return _migrateLegacyToken();
  }

  static Future<void> writeToken(String token) async {
    final clean = token.trim();
    if (clean.isEmpty) return;
    await _storage.write(key: _tokenKey, value: clean);
    await _deleteLegacyToken();
  }

  static Future<void> deleteToken() async {
    try {
      await _storage.delete(key: _tokenKey);
    } catch (_) {}
    await _deleteLegacyToken();
  }

  /// Moves a plaintext token from SharedPreferences into secure storage.
  static Future<String?> _migrateLegacyToken() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final legacy = prefs.getString(_legacyTokenKey);
      if (legacy == null || legacy.trim().isEmpty) return null;

      final clean = legacy.trim();
      await _storage.write(key: _tokenKey, value: clean);
      await prefs.remove(_legacyTokenKey);
      return clean;
    } catch (_) {
      return null;
    }
  }

  static Future<void> _deleteLegacyToken() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.containsKey(_legacyTokenKey)) {
        await prefs.remove(_legacyTokenKey);
      }
    } catch (_) {}
  }
}
