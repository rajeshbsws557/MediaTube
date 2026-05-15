import 'package:shared_preferences/shared_preferences.dart';

enum DefaultShareAction { alwaysAsk, autoVideo, autoAudio }

class SettingsService {
  static const String _defaultShareActionKey = 'default_share_action';
  static const String _maxConcurrentDownloadsKey = 'max_concurrent_downloads';

  static const int minConcurrentDownloads = 1;
  static const int maxConcurrentDownloads = 4;
  static const int defaultMaxConcurrentDownloads = 2;

  int _normalizeConcurrentDownloads(int? value) {
    final candidate = value ?? defaultMaxConcurrentDownloads;
    return candidate
        .clamp(minConcurrentDownloads, maxConcurrentDownloads)
        .toInt();
  }

  Future<DefaultShareAction> getDefaultShareAction() async {
    final prefs = await SharedPreferences.getInstance();
    final index = prefs.getInt(_defaultShareActionKey);
    if (index != null &&
        index >= 0 &&
        index < DefaultShareAction.values.length) {
      return DefaultShareAction.values[index];
    }
    return DefaultShareAction.alwaysAsk;
  }

  Future<void> setDefaultShareAction(DefaultShareAction action) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_defaultShareActionKey, action.index);
  }

  Future<int> getMaxConcurrentDownloads() async {
    final prefs = await SharedPreferences.getInstance();
    return _normalizeConcurrentDownloads(prefs.getInt(_maxConcurrentDownloadsKey));
  }

  Future<void> setMaxConcurrentDownloads(int value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
      _maxConcurrentDownloadsKey,
      _normalizeConcurrentDownloads(value),
    );
  }
}
