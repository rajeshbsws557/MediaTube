import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/settings_provider.dart';
import '../services/settings_service.dart';
import '../services/update_manager.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SafeArea(
        top: false,
        child: Consumer<SettingsProvider>(
          builder: (context, settingsProvider, _) {
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Padding(
                  padding: EdgeInsets.only(bottom: 8.0, left: 16),
                  child: Text(
                    'Quick Actions',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: Colors.blue,
                    ),
                  ),
                ),
                Card(
                  elevation: 0,
                  color: Theme.of(
                    context,
                  ).colorScheme.surfaceContainerHighest.withAlpha(50),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Default Share Action',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'When you share a video directly to MediaTube...',
                          style: TextStyle(
                            fontSize: 14,
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 16),
                        RadioListTile<DefaultShareAction>(
                          title: const Text('Always Ask'),
                          subtitle: const Text(
                            'Show the regular quality selection menu',
                          ),
                          value: DefaultShareAction.alwaysAsk,
                          groupValue: settingsProvider.defaultShareAction,
                          onChanged: (value) => value != null
                              ? settingsProvider.setDefaultShareAction(value)
                              : null,
                          contentPadding: EdgeInsets.zero,
                        ),
                        RadioListTile<DefaultShareAction>(
                          title: const Text('Auto-download Best Video'),
                          subtitle: const Text(
                            'Download highest quality video in background',
                          ),
                          value: DefaultShareAction.autoVideo,
                          groupValue: settingsProvider.defaultShareAction,
                          onChanged: (value) => value != null
                              ? settingsProvider.setDefaultShareAction(value)
                              : null,
                          contentPadding: EdgeInsets.zero,
                        ),
                        RadioListTile<DefaultShareAction>(
                          title: const Text('Auto-download Audio Only'),
                          subtitle: const Text(
                            'Download standard MP3 in background',
                          ),
                          value: DefaultShareAction.autoAudio,
                          groupValue: settingsProvider.defaultShareAction,
                          onChanged: (value) => value != null
                              ? settingsProvider.setDefaultShareAction(value)
                              : null,
                          contentPadding: EdgeInsets.zero,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                const Padding(
                  padding: EdgeInsets.only(bottom: 8.0, left: 16),
                  child: Text(
                    'About',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: Colors.blue,
                    ),
                  ),
                ),
                Card(
                  elevation: 0,
                  color: Theme.of(
                    context,
                  ).colorScheme.surfaceContainerHighest.withAlpha(50),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: ListTile(
                    leading: const Icon(Icons.system_update_alt),
                    title: const Text('Check for Updates'),
                    subtitle: const Text('Tap to check for a newer version'),
                    onTap: () {
                      UpdateManager().checkForUpdates(
                        context,
                        showNoUpdateMessage: true,
                      );
                    },
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
