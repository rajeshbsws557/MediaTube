import 'package:flutter/foundation.dart';
import '../services/settings_service.dart';

class SettingsProvider extends ChangeNotifier {
  final SettingsService _settingsService = SettingsService();

  DefaultShareAction _defaultShareAction = DefaultShareAction.alwaysAsk;
  int _maxConcurrentDownloads = SettingsService.defaultMaxConcurrentDownloads;

  DefaultShareAction get defaultShareAction => _defaultShareAction;
  int get maxConcurrentDownloads => _maxConcurrentDownloads;

  SettingsProvider() {
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final defaultShareAction = await _settingsService.getDefaultShareAction();
    final maxConcurrentDownloads =
        await _settingsService.getMaxConcurrentDownloads();

    _defaultShareAction = defaultShareAction;
    _maxConcurrentDownloads = maxConcurrentDownloads;
    notifyListeners();
  }

  Future<void> setDefaultShareAction(DefaultShareAction action) async {
    if (_defaultShareAction != action) {
      _defaultShareAction = action;
      await _settingsService.setDefaultShareAction(action);
      notifyListeners();
    }
  }

  Future<void> setMaxConcurrentDownloads(int value) async {
    final normalized = value
        .clamp(
          SettingsService.minConcurrentDownloads,
          SettingsService.maxConcurrentDownloads,
        )
        .toInt();

    if (_maxConcurrentDownloads != normalized) {
      _maxConcurrentDownloads = normalized;
      await _settingsService.setMaxConcurrentDownloads(normalized);
      notifyListeners();
    }
  }
}
