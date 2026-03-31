import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../models/models.dart';
import '../providers/providers.dart';

class MediaSelectionSheet extends StatefulWidget {
  final List<DetectedMedia> media;
  final bool isYouTube;
  final bool isFetching;
  final VoidCallback onRefresh;
  final String? errorMessage;

  const MediaSelectionSheet({
    super.key,
    required this.media,
    required this.isYouTube,
    required this.isFetching,
    required this.onRefresh,
    this.errorMessage,
  });

  @override
  State<MediaSelectionSheet> createState() => _MediaSelectionSheetState();
}

class _MediaSelectionSheetState extends State<MediaSelectionSheet> {
  bool _isRefreshing = false;
  MediaType _selectedType = MediaType.video;
  static const int _maxBatchQueue = 10;

  void _handleRefresh() async {
    if (_isRefreshing || widget.isFetching) return;

    setState(() {
      _isRefreshing = true;
    });

    // Call the refresh callback
    widget.onRefresh();

    // Reset after a short delay (the actual fetch is async)
    await Future.delayed(const Duration(milliseconds: 500));
    if (mounted) {
      setState(() {
        _isRefreshing = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.3,
      maxChildSize: 0.9,
      expand: false,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          ),
          child: Column(
            children: [
              // Handle
              Container(
                margin: const EdgeInsets.symmetric(vertical: 8),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey[400],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),

              // Header
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    Icon(
                      widget.isYouTube
                          ? Icons.play_circle
                          : Icons.video_library,
                      color: widget.isYouTube ? Colors.red : null,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.isYouTube
                                ? 'YouTube Streams'
                                : 'Detected Media',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          if (widget.media.isNotEmpty)
                            Text(
                              '${widget.media.length} streams available',
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: Colors.grey[600]),
                            ),
                        ],
                      ),
                    ),
                    if (widget.isYouTube)
                      IconButton(
                        icon: (_isRefreshing || widget.isFetching)
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.refresh),
                        tooltip: 'Refresh streams',
                        onPressed: (_isRefreshing || widget.isFetching)
                            ? null
                            : _handleRefresh,
                      ),
                  ],
                ),
              ),

              // Quick download button for best quality
              if (widget.media.isNotEmpty) ...[
                _buildHeroThumbnail(),
                const SizedBox(height: 16),
                _buildTypeToggle(),
                const SizedBox(height: 8),
                _buildQuickDownloadBar(context),
              ],

              const Divider(height: 1),

              // Media list
              Expanded(
                child: widget.isFetching && widget.media.isEmpty
                    ? _buildLoadingState()
                    : widget.errorMessage != null && widget.media.isEmpty
                    ? _buildErrorState()
                    : widget.media.isEmpty
                    ? _buildEmptyState()
                    : _buildMediaList(scrollController),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildHeroThumbnail() {
    final firstMedia = widget.media.firstOrNull;
    if (firstMedia?.thumbnailUrl == null) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: Image.network(
            firstMedia!.thumbnailUrl!,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) => Container(
              color: Colors.grey[200],
              child: const Icon(
                Icons.broken_image,
                size: 48,
                color: Colors.grey,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTypeToggle() {
    final hasVideo = widget.media.any((m) => m.type == MediaType.video);
    final hasAudio = widget.media.any((m) => m.type == MediaType.audio);

    if (!hasVideo || !hasAudio) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: SizedBox(
        width: double.infinity,
        child: SegmentedButton<MediaType>(
          segments: const [
            ButtonSegment(
              value: MediaType.video,
              icon: Icon(Icons.movie),
              label: Text('Video'),
            ),
            ButtonSegment(
              value: MediaType.audio,
              icon: Icon(Icons.music_note),
              label: Text('Audio'),
            ),
          ],
          selected: {_selectedType},
          onSelectionChanged: (Set<MediaType> newSelection) {
            setState(() {
              _selectedType = newSelection.first;
            });
          },
        ),
      ),
    );
  }

  Widget _buildLoadingState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 48,
            height: 48,
            child: CircularProgressIndicator(strokeWidth: 3),
          ),
          const SizedBox(height: 16),
          Text(
            'Fetching streams...',
            style: TextStyle(color: Colors.grey[600], fontSize: 16),
          ),
          const SizedBox(height: 8),
          Text(
            'This may take a few seconds',
            style: TextStyle(color: Colors.grey[500], fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.video_file, size: 64, color: Colors.grey[400]),
          const SizedBox(height: 16),
          Text(
            widget.isYouTube
                ? 'Navigate to a YouTube video to see available streams'
                : 'No media detected on this page yet',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey[600]),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: _handleRefresh,
            icon: const Icon(Icons.refresh),
            label: Text(widget.isYouTube ? 'Fetch Streams' : 'Scan Page Again'),
          ),
          if (!widget.isYouTube)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Tip: play the video once, then tap Scan Page Again.',
                style: TextStyle(color: Colors.grey[500], fontSize: 12),
                textAlign: TextAlign.center,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildErrorState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 64, color: Colors.orange[400]),
            const SizedBox(height: 16),
            Text(
              widget.errorMessage ?? 'An error occurred',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey[700], fontSize: 14),
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: _handleRefresh,
              icon: const Icon(Icons.refresh),
              label: const Text('Try Again'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 12,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Quick download bar - allows instant download of recommended quality
  Widget _buildQuickDownloadBar(BuildContext context) {
    // Find best video (prefer 720p non-DASH, or highest muxed)
    final videos = widget.media
        .where((m) => m.type == MediaType.video)
        .toList();
    DetectedMedia? bestVideo;

    // Look for 720p first
    for (final v in videos) {
      if (v.quality?.contains('720') == true && !v.isDash) {
        bestVideo = v;
        break;
      }
    }

    // Fallback to highest non-DASH video
    if (bestVideo == null) {
      for (final v in videos) {
        if (!v.isDash) {
          bestVideo = v;
          break;
        }
      }
    }

    // Fallback to any video
    bestVideo ??= videos.isNotEmpty ? videos.first : null;

    if (bestVideo == null) return const SizedBox.shrink();

    final batchCandidates = widget.media
        .where((m) => m.type == _selectedType)
        .toList();

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        children: [
          ElevatedButton.icon(
            onPressed: () => _quickDownload(context, bestVideo!),
            icon: const Icon(Icons.download),
            label: Text(
              'Download ${bestVideo.quality ?? "Video"} ${bestVideo.isDash ? "(DASH)" : ""}',
            ),
            style: ElevatedButton.styleFrom(
              minimumSize: const Size(double.infinity, 48),
              backgroundColor: Theme.of(context).colorScheme.primary,
              foregroundColor: Theme.of(context).colorScheme.onPrimary,
            ),
          ),
          if (batchCandidates.length > 1) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => _downloadAllOfType(context),
              icon: const Icon(Icons.playlist_add_check),
              label: Text(
                'Download all ${_selectedType == MediaType.video ? "videos" : "audio"} (${batchCandidates.length})',
              ),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(double.infinity, 44),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _downloadAllOfType(BuildContext context) async {
    final downloadProvider = context.read<DownloadProvider>();
    final selected = widget.media.where((m) => m.type == _selectedType).toList();
    final queue = selected.take(_maxBatchQueue).toList();

    var queuedCount = 0;
    try {
      for (final media in queue) {
        await downloadProvider.startDownload(media);
        queuedCount++;
        await Future.delayed(const Duration(milliseconds: 40));
      }
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed while queuing downloads: $e'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    if (!context.mounted) return;
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.playlist_add_check, color: Colors.white, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                selected.length > _maxBatchQueue
                    ? 'Queued first $queuedCount of ${selected.length} items'
                    : 'Queued $queuedCount ${_selectedType == MediaType.video ? "videos" : "audio files"}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _quickDownload(BuildContext context, DetectedMedia media) async {
    final downloadProvider = context.read<DownloadProvider>();
    try {
      await downloadProvider.startDownload(media);
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to start download: $e'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    if (!context.mounted) return;
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.download, color: Colors.white, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Downloading: ${media.title}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Widget _buildMediaList(ScrollController scrollController) {
    // Filter media by selected type
    final filteredMedia = widget.media
        .where((m) => m.type == _selectedType)
        .toList();

    if (filteredMedia.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _selectedType == MediaType.video
                    ? Icons.videocam_off
                    : Icons.music_off,
                size: 48,
                color: Colors.grey[400],
              ),
              const SizedBox(height: 16),
              Text(
                'No ${_selectedType == MediaType.video ? "video" : "audio"} streams available',
                style: TextStyle(color: Colors.grey[600]),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      controller: scrollController,
      padding: const EdgeInsets.only(bottom: 16),
      // Performance optimizations for smooth 60fps scrolling
      cacheExtent: 500,
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      itemCount: filteredMedia.length,
      itemBuilder: (context, index) {
        return RepaintBoundary(
          child: _MediaListItem(media: filteredMedia[index]),
        );
      },
    );
  }
}

class _MediaListItem extends StatefulWidget {
  final DetectedMedia media;

  const _MediaListItem({required this.media});

  @override
  State<_MediaListItem> createState() => _MediaListItemState();
}

class _MediaListItemState extends State<_MediaListItem> {
  bool _isDownloading = false;

  @override
  Widget build(BuildContext context) {
    final downloadProvider = context.read<DownloadProvider>();

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      elevation: 0,
      color: Theme.of(
        context,
      ).colorScheme.surfaceContainerHighest.withAlpha(128),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: _isDownloading ? null : () => _startDownload(downloadProvider),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              // Thumbnail
              _buildThumbnail(),
              const SizedBox(width: 12),

              // Info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.media.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w500),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        _buildBadge(_getTypeLabel()),
                        if (widget.media.quality != null)
                          _buildBadge(widget.media.quality!, isPrimary: true),
                        if (widget.media.fileSize != null) _buildSizeBadge(),
                        if (widget.media.isDash)
                          _buildBadge('DASH', color: Colors.orange),
                      ],
                    ),
                  ],
                ),
              ),

              const SizedBox(width: 8),

              // Download button
              _buildDownloadButton(downloadProvider),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildThumbnail() {
    return Container(
      width: 56,
      height: 56,
      decoration: BoxDecoration(
        color: _getTypeColor().withAlpha(25),
        borderRadius: BorderRadius.circular(8),
      ),
      child: widget.media.thumbnailUrl != null
          ? ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.network(
                widget.media.thumbnailUrl!,
                fit: BoxFit.cover,
                cacheWidth: 112,
                cacheHeight: 112,
                loadingBuilder: (context, child, loadingProgress) {
                  if (loadingProgress == null) return child;
                  return Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        value: loadingProgress.expectedTotalBytes != null
                            ? loadingProgress.cumulativeBytesLoaded /
                                  loadingProgress.expectedTotalBytes!
                            : null,
                      ),
                    ),
                  );
                },
                errorBuilder: (context, error, stackTrace) => _buildIcon(),
              ),
            )
          : _buildIcon(),
    );
  }

  Widget _buildIcon() {
    return Icon(_getTypeIcon(), color: _getTypeColor(), size: 28);
  }

  Widget _buildDownloadButton(DownloadProvider downloadProvider) {
    if (_isDownloading) {
      return const SizedBox(
        width: 40,
        height: 40,
        child: Padding(
          padding: EdgeInsets.all(8),
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    return Material(
      color: Colors.green,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => _startDownload(downloadProvider),
        child: const SizedBox(
          width: 40,
          height: 40,
          child: Icon(Icons.download, color: Colors.white, size: 20),
        ),
      ),
    );
  }

  Future<void> _startDownload(DownloadProvider downloadProvider) async {
    if (!mounted || _isDownloading) return;
    setState(() => _isDownloading = true);
    HapticFeedback.lightImpact();

    try {
      // Await to ensure background service is initialized before closing sheet.
      await downloadProvider.startDownload(widget.media);

      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.download, color: Colors.white, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Downloading: ${widget.media.title}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to start download: $e'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isDownloading = false);
      }
    }
  }

  IconData _getTypeIcon() {
    switch (widget.media.type) {
      case MediaType.video:
        return Icons.movie;
      case MediaType.audio:
        return Icons.music_note;
      case MediaType.stream:
        return Icons.live_tv;
    }
  }

  Color _getTypeColor() {
    switch (widget.media.type) {
      case MediaType.video:
        return Colors.blue;
      case MediaType.audio:
        return Colors.green;
      case MediaType.stream:
        return Colors.purple;
    }
  }

  String _getTypeLabel() {
    switch (widget.media.type) {
      case MediaType.video:
        return widget.media.format?.toUpperCase() ?? 'VIDEO';
      case MediaType.audio:
        return widget.media.format?.toUpperCase() ?? 'AUDIO';
      case MediaType.stream:
        return 'STREAM';
    }
  }

  Widget _buildBadge(String text, {Color? color, bool isPrimary = false}) {
    final badgeColor = color ?? _getTypeColor();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: isPrimary ? badgeColor : badgeColor.withAlpha(25),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.bold,
          color: isPrimary ? Colors.white : badgeColor,
        ),
      ),
    );
  }

  Widget _buildSizeBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.grey.withAlpha(25),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        widget.media.fileSizeFormatted,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w500,
          color: Colors.grey[700],
        ),
      ),
    );
  }
}
