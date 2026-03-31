import 'package:shared_preferences/shared_preferences.dart';

enum DefaultShareAction { alwaysAsk, autoVideo, autoAudio }

class SettingsService {
  static const String _defaultShareActionKey = 'default_share_action';

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
}
