import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import '../utils/utils.dart';

/// Data model for quick access sites
class QuickAccessSite {
  final String name;
  final String url;
  final IconData icon;
  final Color color;
  final String? imageAsset;

  const QuickAccessSite({
    required this.name,
    required this.url,
    required this.icon,
    required this.color,
    this.imageAsset,
  });

  Map<String, dynamic> toJson() {
    // We can't save IconData directly due to tree-shaking issues in release mode.
    // In a real app we'd map this to a string. For Custom sites, it's always Icons.language.
    return {
      'name': name,
      'url': url,
      // Just save a string identifier or default to 'custom'
      'iconName': 'custom',
      'color': color.toARGB32(),
    };
  }

  factory QuickAccessSite.fromJson(Map<String, dynamic> json) {
    return QuickAccessSite(
      name: json['name'],
      url: json['url'],
      icon: Icons.language, // Always use the constant Icon
      color: Color(json['color']),
    );
  }
}

/// Home screen widget with quick access to popular sites
class HomeScreen extends StatefulWidget {
  final Function(String url) onNavigate;

  const HomeScreen({super.key, required this.onNavigate});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const List<QuickAccessSite> _socialMedia = [
    QuickAccessSite(
      name: 'YouTube',
      url: 'https://m.youtube.com',
      icon: Icons.play_circle_filled,
      color: Color(0xFFFF0000),
    ),
    QuickAccessSite(
      name: 'Instagram',
      url: 'https://www.instagram.com',
      icon: Icons.camera_alt,
      color: Color(0xFFE1306C),
    ),
    QuickAccessSite(
      name: 'Facebook',
      url: 'https://m.facebook.com',
      icon: Icons.facebook,
      color: Color(0xFF1877F2),
    ),
    QuickAccessSite(
      name: 'Twitter/X',
      url: 'https://twitter.com',
      icon: Icons.alternate_email,
      color: Color(0xFF1DA1F2),
    ),
    QuickAccessSite(
      name: 'TikTok',
      url: 'https://www.tiktok.com',
      icon: Icons.music_note,
      color: Color(0xFF000000),
    ),
    QuickAccessSite(
      name: 'Snapchat',
      url: 'https://www.snapchat.com',
      icon: Icons.camera,
      color: Color(0xFFFFFC00),
    ),
  ];

  static const List<QuickAccessSite> _entertainment = [
    QuickAccessSite(
      name: 'Netflix',
      url: 'https://www.netflix.com',
      icon: Icons.movie,
      color: Color(0xFFE50914),
    ),
    QuickAccessSite(
      name: 'Prime Video',
      url: 'https://www.primevideo.com',
      icon: Icons.video_library,
      color: Color(0xFF00A8E1),
    ),
    QuickAccessSite(
      name: 'Disney+',
      url: 'https://www.disneyplus.com',
      icon: Icons.star,
      color: Color(0xFF113CCF),
    ),
    QuickAccessSite(
      name: 'Spotify',
      url: 'https://open.spotify.com',
      icon: Icons.headphones,
      color: Color(0xFF1DB954),
    ),
    QuickAccessSite(
      name: 'Twitch',
      url: 'https://www.twitch.tv',
      icon: Icons.videogame_asset,
      color: Color(0xFF9146FF),
    ),
    QuickAccessSite(
      name: 'Vimeo',
      url: 'https://vimeo.com',
      icon: Icons.play_circle_outline,
      color: Color(0xFF1AB7EA),
    ),
  ];

  static const List<QuickAccessSite> _others = [
    QuickAccessSite(
      name: 'Reddit',
      url: 'https://www.reddit.com',
      icon: Icons.forum,
      color: Color(0xFFFF4500),
    ),
    QuickAccessSite(
      name: 'Pinterest',
      url: 'https://www.pinterest.com',
      icon: Icons.push_pin,
      color: Color(0xFFBD081C),
    ),
    QuickAccessSite(
      name: 'LinkedIn',
      url: 'https://www.linkedin.com',
      icon: Icons.work,
      color: Color(0xFF0A66C2),
    ),
    QuickAccessSite(
      name: 'Dailymotion',
      url: 'https://www.dailymotion.com',
      icon: Icons.ondemand_video,
      color: Color(0xFF00AAFF),
    ),
    QuickAccessSite(
      name: 'SoundCloud',
      url: 'https://soundcloud.com',
      icon: Icons.cloud,
      color: Color(0xFFFF5500),
    ),
    QuickAccessSite(
      name: 'Google',
      url: 'https://www.google.com',
      icon: Icons.search,
      color: Color(0xFF4285F4),
    ),
  ];

  List<QuickAccessSite> _customSites = [];

  @override
  void initState() {
    super.initState();
    _loadCustomSites();
  }

  Future<void> _loadCustomSites() async {
    final prefs = await SharedPreferences.getInstance();
    final sitesJson = prefs.getStringList('custom_quick_sites');
    if (sitesJson != null) {
      setState(() {
        _customSites = sitesJson
            .map((s) => QuickAccessSite.fromJson(jsonDecode(s)))
            .toList();
      });
    }
  }

  Future<void> _saveCustomSites() async {
    final prefs = await SharedPreferences.getInstance();
    final sitesJson = _customSites.map((s) => jsonEncode(s.toJson())).toList();
    await prefs.setStringList('custom_quick_sites', sitesJson);
  }

  /// Resolves a user-typed site input into a proper URL.
  /// - Bare names like "netflix" become "https://netflix.com"
  /// - Names with dots like "bbc.co.uk" become "https://bbc.co.uk"
  /// - Full URLs are kept as-is
  static String _resolveQuickSiteUrl(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '';

    // Already has a scheme
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      return trimmed;
    }

    String host = trimmed;
    // If the input has no dot at all (e.g. "netflix"), append .com
    if (!host.contains('.')) {
      host = '$host.com';
    }

    return 'https://$host';
  }

  void _showAddSiteDialog() {
    final nameController = TextEditingController();
    final urlController = TextEditingController();

    showDialog(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            // Live-preview the resolved URL
            final resolvedUrl = _resolveQuickSiteUrl(urlController.text);
            final hasValidInput = nameController.text.trim().isNotEmpty &&
                urlController.text.trim().isNotEmpty;

            return AlertDialog(
              title: const Text('Add Quick Site'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: nameController,
                    decoration: const InputDecoration(
                      labelText: 'Name',
                      hintText: 'My Site',
                    ),
                    onChanged: (_) => setDialogState(() {}),
                  ),
                  TextField(
                    controller: urlController,
                    decoration: InputDecoration(
                      labelText: 'URL or site name',
                      hintText: 'netflix or example.com',
                      helperText: urlController.text.trim().isNotEmpty
                          ? 'Will open: $resolvedUrl'
                          : null,
                      helperMaxLines: 2,
                    ),
                    keyboardType: TextInputType.url,
                    onChanged: (_) => setDialogState(() {}),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: hasValidInput
                      ? () {
                          final fullUrl =
                              _resolveQuickSiteUrl(urlController.text);

                          setState(() {
                            _customSites.add(
                              QuickAccessSite(
                                name: nameController.text.trim(),
                                url: fullUrl,
                                icon: Icons.language,
                                color: Colors.blueAccent,
                              ),
                            );
                          });
                          _saveCustomSites();
                          Navigator.pop(dialogContext);
                        }
                      : null,
                  child: const Text('Add'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: isDark
              ? [const Color(0xFF0E0E18), const Color(0xFF121220)]
              : [const Color(0xFFF5F7FA), const Color(0xFFE4E8EE)],
        ),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Logo and welcome
            _buildHeader(context, isDark),
            const SizedBox(height: 32),

            // Search bar
            _buildSearchBar(context, isDark),
            const SizedBox(height: 32),

            // My Sites (Custom) section
            _buildSection(
              context,
              title: 'My Sites',
              icon: Icons.star,
              color: Colors.amber,
              sites: _customSites,
              isDark: isDark,
              isCustom: true,
            ),
            const SizedBox(height: 24),

            // Social Media section
            _buildSection(
              context,
              title: 'Social Media',
              icon: Icons.people,
              color: Colors.pink,
              sites: _socialMedia,
              isDark: isDark,
            ),
            const SizedBox(height: 24),

            // Entertainment section
            _buildSection(
              context,
              title: 'Entertainment',
              icon: Icons.movie_filter,
              color: Colors.purple,
              sites: _entertainment,
              isDark: isDark,
            ),
            const SizedBox(height: 24),

            // More sites section
            _buildSection(
              context,
              title: 'More Sites',
              icon: Icons.explore,
              color: Colors.teal,
              sites: _others,
              isDark: isDark,
            ),
            const SizedBox(height: 32),

            // Tip card
            _buildTipCard(context, isDark),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, bool isDark) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFFFF3A3A), Color(0xFFE50914)],
            ),
            borderRadius: BorderRadius.circular(18),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFFE50914).withAlpha(80),
                blurRadius: 20,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: const Icon(
            Icons.download_rounded,
            color: Colors.white,
            size: 30,
          ),
        ),
        const SizedBox(width: 16),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'MediaTube',
              style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.3,
                color: isDark ? Colors.white : Colors.black87,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              'Download videos from anywhere',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: isDark ? Colors.white54 : Colors.black45,
                letterSpacing: 0.2,
              ),
            ),
          ],
        ),
      ],
    );
  }

  // NOTE: Since HomeScreen is StatefulWidget, we can manage SearchBar lifecycle
  Widget _buildSearchBar(BuildContext context, bool isDark) {
    return _SearchBarWidget(isDark: isDark, onNavigate: widget.onNavigate);
  }

  Widget _buildSection(
    BuildContext context, {
    required String title,
    required IconData icon,
    required Color color,
    required List<QuickAccessSite> sites,
    required bool isDark,
    bool isCustom = false,
  }) {
    if (isCustom && sites.isEmpty) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: color.withAlpha(50),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: color, size: 20),
              ),
              const SizedBox(width: 12),
              Text(
                title,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: isDark ? Colors.white : Colors.black87,
                ),
              ),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.add_circle, color: Colors.blue),
            onPressed: _showAddSiteDialog,
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: color.withAlpha(50),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, color: color, size: 20),
                ),
                const SizedBox(width: 12),
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.white : Colors.black87,
                  ),
                ),
              ],
            ),
            if (isCustom)
              IconButton(
                icon: const Icon(Icons.add_circle, color: Colors.blue),
                onPressed: _showAddSiteDialog,
              ),
          ],
        ),
        const SizedBox(height: 16),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            childAspectRatio: 1,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
          ),
          itemCount: sites.length,
          itemBuilder: (context, index) {
            return _buildSiteCard(
              context,
              sites[index],
              isDark,
              isCustom: isCustom,
              index: index,
            );
          },
        ),
      ],
    );
  }

  Widget _buildSiteCard(
    BuildContext context,
    QuickAccessSite site,
    bool isDark, {
    bool isCustom = false,
    int index = -1,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => widget.onNavigate(site.url),
        onLongPress: isCustom
            ? () {
                showDialog(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Delete Quick Site?'),
                    content: Text(
                      'Remove ${site.name} from your quick access?',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Cancel'),
                      ),
                      TextButton(
                        onPressed: () {
                          setState(() {
                            _customSites.removeAt(index);
                          });
                          _saveCustomSites();
                          Navigator.pop(context);
                        },
                        child: const Text(
                          'Delete',
                          style: TextStyle(color: Colors.red),
                        ),
                      ),
                    ],
                  ),
                );
              }
            : null,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          decoration: BoxDecoration(
            color: isDark ? Colors.white.withAlpha(12) : Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isDark
                  ? Colors.white.withAlpha(15)
                  : Colors.black.withAlpha(8),
            ),
            boxShadow: isDark
                ? [
                    BoxShadow(
                      color: site.color.withAlpha(12),
                      blurRadius: 12,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : [
                    BoxShadow(
                      color: Colors.black.withAlpha(12),
                      blurRadius: 10,
                      offset: const Offset(0, 2),
                    ),
                  ],
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: site.color.withAlpha(40),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  site.icon,
                  color: site.color == const Color(0xFFFFFC00)
                      ? Colors.black
                      : site.color,
                  size: 28,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                site.name,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.white70 : Colors.black87,
                ),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTipCard(BuildContext context, bool isDark) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF667EEA), Color(0xFF764BA2)],
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF667EEA).withAlpha(80),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white.withAlpha(50),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.lightbulb, color: Colors.white, size: 24),
          ),
          const SizedBox(width: 16),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Pro Tip',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  'Navigate to any video and tap the download button to save media to your device!',
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Extracted StatefulWidget to properly manage TextEditingController lifecycle
class _SearchBarWidget extends StatefulWidget {
  final bool isDark;
  final Function(String url) onNavigate;
  const _SearchBarWidget({required this.isDark, required this.onNavigate});
  @override
  State<_SearchBarWidget> createState() => _SearchBarWidgetState();
}

class _SearchBarWidgetState extends State<_SearchBarWidget> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String _processUrl(String text) {
    // sanitizeToNavigableUrl handles both URLs and search queries.
    // For bare text like "funny cat videos" it returns a search engine URL.
    // It should only return null for empty input.
    return UrlInputSanitizer.sanitizeToNavigableUrl(text) ??
        'https://duckduckgo.com/?q=${Uri.encodeComponent(text.trim())}';
  }

  void _submitInput(String input) {
    final normalized = _processUrl(input);
    widget.onNavigate(normalized);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: widget.isDark ? Colors.white.withAlpha(25) : Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: widget.isDark
            ? null
            : [
                BoxShadow(
                  color: Colors.black.withAlpha(15),
                  blurRadius: 20,
                  offset: const Offset(0, 4),
                ),
              ],
      ),
      child: TextField(
        controller: _controller,
        decoration: InputDecoration(
          hintText: 'Search the web or paste a URL...',
          hintStyle: TextStyle(
            color: widget.isDark ? Colors.white54 : Colors.grey[500],
          ),
          prefixIcon: Icon(
            Icons.search,
            color: widget.isDark ? Colors.white54 : Colors.grey[500],
          ),
          suffixIcon: IconButton(
            icon: Icon(
              Icons.arrow_forward,
              color: widget.isDark ? Colors.white70 : Colors.grey[700],
            ),
            onPressed: () {
              if (_controller.text.isNotEmpty) {
                _submitInput(_controller.text);
              }
            },
          ),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 16,
          ),
        ),
        style: TextStyle(color: widget.isDark ? Colors.white : Colors.black87),
        onSubmitted: (text) {
          if (text.isNotEmpty) {
            _submitInput(text);
          }
        },
      ),
    );
  }
}
