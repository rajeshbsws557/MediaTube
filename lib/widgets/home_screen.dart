import 'package:flutter/material.dart';

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
}

/// Home screen widget with quick access to popular sites
class HomeScreen extends StatelessWidget {
  final Function(String url) onNavigate;
  
  const HomeScreen({super.key, required this.onNavigate});

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

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: isDark 
              ? [const Color(0xFF1A1A2E), const Color(0xFF16213E)]
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
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF667EEA), Color(0xFF764BA2)],
            ),
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF667EEA).withAlpha(100),
                blurRadius: 20,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: const Icon(Icons.download_rounded, color: Colors.white, size: 32),
        ),
        const SizedBox(width: 16),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'MediaTube',
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
                color: isDark ? Colors.white : Colors.black87,
              ),
            ),
            Text(
              'Download videos from anywhere',
              style: TextStyle(
                fontSize: 14,
                color: isDark ? Colors.white60 : Colors.black54,
              ),
            ),
          ],
        ),
      ],
    );
  }

  // NOTE: Since HomeScreen is StatelessWidget, the TextEditingController
  // is intentionally lightweight here. For a StatefulWidget approach with
  // proper disposal, wrap HomeScreen in a StatefulWidget.
  Widget _buildSearchBar(BuildContext context, bool isDark) {
    return _SearchBarWidget(isDark: isDark, onNavigate: onNavigate);
  }

  Widget _buildSection(
    BuildContext context, {
    required String title,
    required IconData icon,
    required Color color,
    required List<QuickAccessSite> sites,
    required bool isDark,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
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
            return _buildSiteCard(context, sites[index], isDark);
          },
        ),
      ],
    );
  }

  Widget _buildSiteCard(BuildContext context, QuickAccessSite site, bool isDark) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => onNavigate(site.url),
        borderRadius: BorderRadius.circular(16),
        child: Container(
          decoration: BoxDecoration(
            color: isDark ? Colors.white.withAlpha(20) : Colors.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: isDark ? null : [
              BoxShadow(
                color: Colors.black.withAlpha(15),
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
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                  ),
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
    String url = text;
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      if (url.contains('.') && !url.contains(' ')) {
        url = 'https://$url';
      } else {
        url = 'https://www.google.com/search?q=${Uri.encodeComponent(url)}';
      }
    }
    return url;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: widget.isDark ? Colors.white.withAlpha(25) : Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: widget.isDark ? null : [
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
          hintText: 'Search or enter URL...',
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
                widget.onNavigate(_processUrl(_controller.text));
              }
            },
          ),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        ),
        style: TextStyle(
          color: widget.isDark ? Colors.white : Colors.black87,
        ),
        onSubmitted: (text) {
          if (text.isNotEmpty) {
            widget.onNavigate(_processUrl(text));
          }
        },
      ),
    );
  }
}
