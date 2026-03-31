import 'package:flutter/foundation.dart';
import '../services/settings_service.dart';

class SettingsProvider extends ChangeNotifier {
  final SettingsService _settingsService = SettingsService();

  DefaultShareAction _defaultShareAction = DefaultShareAction.alwaysAsk;

  DefaultShareAction get defaultShareAction => _defaultShareAction;

  SettingsProvider() {
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    _defaultShareAction = await _settingsService.getDefaultShareAction();
    notifyListeners();
  }

  Future<void> setDefaultShareAction(DefaultShareAction action) async {
    if (_defaultShareAction != action) {
      _defaultShareAction = action;
      await _settingsService.setDefaultShareAction(action);
      notifyListeners();
    }
  }
}
