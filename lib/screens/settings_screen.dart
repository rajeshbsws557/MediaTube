import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/settings_provider.dart';
import '../services/settings_service.dart';
import '../services/update_manager.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings', style: TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: SafeArea(
        top: false,
        child: Consumer<SettingsProvider>(
          builder: (context, settingsProvider, _) {
            return ListView(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 16,
                bottom: 16 + MediaQuery.of(context).padding.bottom,
              ),
              children: [
                _buildSectionHeader('Quick Actions', colorScheme.primary),
                Card(
                  elevation: 0,
                  color: colorScheme.surfaceContainerHighest.withAlpha(50),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(20.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Default Share Action',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'When you share a video directly to MediaTube...',
                          style: TextStyle(
                            fontSize: 14,
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 20),
                        _ShareOptionCard(
                          title: 'Always Ask',
                          subtitle: 'Show the regular quality selection menu',
                          icon: Icons.list_alt_rounded,
                          value: DefaultShareAction.alwaysAsk,
                          groupValue: settingsProvider.defaultShareAction,
                          onChanged: (v) => settingsProvider.setDefaultShareAction(v),
                        ),
                        _ShareOptionCard(
                          title: 'Auto-download Best Video',
                          subtitle: 'Download highest quality video in background',
                          icon: Icons.high_quality_rounded,
                          value: DefaultShareAction.autoVideo,
                          groupValue: settingsProvider.defaultShareAction,
                          onChanged: (v) => settingsProvider.setDefaultShareAction(v),
                        ),
                        _ShareOptionCard(
                          title: 'Auto-download Audio Only',
                          subtitle: 'Download standard MP3 in background',
                          icon: Icons.audio_file_rounded,
                          value: DefaultShareAction.autoAudio,
                          groupValue: settingsProvider.defaultShareAction,
                          onChanged: (v) => settingsProvider.setDefaultShareAction(v),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                _buildSectionHeader('Downloads', colorScheme.primary),
                Card(
                  elevation: 0,
                  color: colorScheme.surfaceContainerHighest.withAlpha(50),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(20.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.download_done_rounded, size: 24),
                            const SizedBox(width: 12),
                            const Text(
                              'Concurrent Tasks',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Padding(
                          padding: const EdgeInsets.only(left: 36.0),
                          child: Text(
                            'Choose how many downloads can run at the same time.',
                            style: TextStyle(
                              fontSize: 14,
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        SliderTheme(
                          data: SliderThemeData(
                            activeTrackColor: colorScheme.primary,
                            inactiveTrackColor: colorScheme.primaryContainer,
                            thumbColor: colorScheme.primary,
                            valueIndicatorColor: colorScheme.primary,
                          ),
                          child: Slider(
                            value: settingsProvider.maxConcurrentDownloads.toDouble(),
                            min: SettingsService.minConcurrentDownloads.toDouble(),
                            max: SettingsService.maxConcurrentDownloads.toDouble(),
                            divisions: SettingsService.maxConcurrentDownloads -
                                SettingsService.minConcurrentDownloads,
                            label: '${settingsProvider.maxConcurrentDownloads}',
                            onChanged: (value) {
                              final nextValue = value.round();
                              if (nextValue != settingsProvider.maxConcurrentDownloads) {
                                settingsProvider.setMaxConcurrentDownloads(nextValue);
                              }
                            },
                          ),
                        ),
                        Align(
                          alignment: Alignment.centerRight,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(
                              color: colorScheme.primaryContainer,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              'Limit: ${settingsProvider.maxConcurrentDownloads}',
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                color: colorScheme.onPrimaryContainer,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                _buildSectionHeader('System', colorScheme.primary),
                Card(
                  elevation: 0,
                  color: colorScheme.surfaceContainerHighest.withAlpha(50),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                    leading: Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(Icons.system_update_alt_rounded, color: colorScheme.primary),
                    ),
                    title: const Text(
                      'Check for Updates',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: const Text('Tap to check for a newer version'),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                    onTap: () {
                      UpdateManager().checkForUpdates(
                        context,
                        showNoUpdateMessage: true,
                      );
                    },
                  ),
                ),
                const SizedBox(height: 32),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title, Color color) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12.0, left: 8),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          fontSize: 13,
          letterSpacing: 1.2,
          fontWeight: FontWeight.bold,
          color: color,
        ),
      ),
    );
  }
}

class _ShareOptionCard extends StatelessWidget {
  final DefaultShareAction value;
  final DefaultShareAction groupValue;
  final String title;
  final String subtitle;
  final IconData icon;
  final ValueChanged<DefaultShareAction> onChanged;

  const _ShareOptionCard({
    required this.value,
    required this.groupValue,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final isSelected = value == groupValue;
    final colorScheme = Theme.of(context).colorScheme;
    
    return Padding(
      padding: const EdgeInsets.only(bottom: 12.0),
      child: InkWell(
        onTap: () => onChanged(value),
        borderRadius: BorderRadius.circular(16),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isSelected ? colorScheme.primary : colorScheme.outlineVariant.withAlpha(100),
              width: isSelected ? 2 : 1,
            ),
            color: isSelected 
                ? colorScheme.primaryContainer.withAlpha(80) 
                : colorScheme.surface,
          ),
          child: Row(
            children: [
              Icon(
                icon, 
                color: isSelected ? colorScheme.primary : colorScheme.onSurfaceVariant,
                size: 28,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
                        color: isSelected ? colorScheme.primary : colorScheme.onSurface,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 13,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (isSelected)
                Icon(Icons.check_circle_rounded, color: colorScheme.primary),
            ],
          ),
        ),
      ),
    );
  }
}
