import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:open_filex/open_filex.dart';
import 'dart:io';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';
import '../models/models.dart';
import '../providers/providers.dart';
import '../services/services.dart';
import 'nearby_radar_screen.dart';

class DownloadsScreen extends StatefulWidget {
  const DownloadsScreen({super.key});

  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends State<DownloadsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final CastDiscoveryService _castService = CastDiscoveryService();
  final LocalStreamServerService _localStreamServer = LocalStreamServerService();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _castService.addListener(_onCastServiceUpdated);
    unawaited(_initializeCasting());
  }

  @override
  void dispose() {
    _castService.removeListener(_onCastServiceUpdated);
    unawaited(_castService.stopDiscovery());
    _tabController.dispose();
    super.dispose();
  }

  void _onCastServiceUpdated() {
    if (!mounted) {
      return;
    }
    setState(() {});
  }

  Future<void> _initializeCasting() async {
    if (!Platform.isAndroid) {
      return;
    }

    await _requestCastPermissions();
    await _castService.ensureInitialized();
    await _castService.startDiscovery();
  }

  Future<void> _requestCastPermissions() async {
    final permissions = <Permission>[
      Permission.locationWhenInUse,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.nearbyWifiDevices,
    ];

    for (final permission in permissions) {
      try {
        await permission.request();
      } catch (_) {
        // Skip unsupported permissions on older Android APIs.
      }
    }
  }

  Future<void> _showCastPanel() async {
    if (!mounted) {
      return;
    }

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: FractionallySizedBox(
            heightFactor: 0.85,
            child: AnimatedBuilder(
              animation: _castService,
              builder: (context, _) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                      child: Row(
                        children: [
                          const Icon(Icons.cast),
                          const SizedBox(width: 10),
                          const Expanded(
                            child: Text(
                              'Cast to nearby displays',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Rescan',
                            onPressed: () {
                              unawaited(_castService.startDiscovery());
                            },
                            icon: const Icon(Icons.refresh),
                          ),
                        ],
                      ),
                    ),
                    if (_castService.lastError != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                        child: Text(
                          _castService.lastError!,
                          style: const TextStyle(color: Colors.red),
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        'Displays',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Expanded(
                      child: _castService.devices.isEmpty
                          ? const Center(
                              child: Text(
                                'No compatible displays detected yet',
                              ),
                            )
                          : ListView.builder(
                              itemCount: _castService.devices.length,
                              itemBuilder: (context, index) {
                                final device = _castService.devices[index];
                                final isConnected =
                                    _castService.connectedDeviceId == device.id;

                                return ListTile(
                                  leading: Icon(
                                    isConnected
                                        ? Icons.cast_connected
                                        : Icons.cast,
                                  ),
                                  title: Text(device.name),
                                  subtitle: Text(
                                    switch (device.type) {
                                      CastDeviceType.chromecast => 'Chromecast',
                                      CastDeviceType.dlna => 'DLNA/Smart TV',
                                      CastDeviceType.roku => 'Roku',
                                      CastDeviceType.unknown => 'Display',
                                    },
                                  ),
                                  trailing: FilledButton.tonal(
                                    onPressed: () async {
                                      if (isConnected) {
                                        await _castService.disconnect();
                                        return;
                                      }
                                      await _castService.connectToDevice(device.id);
                                    },
                                    child: Text(
                                      isConnected ? 'Disconnect' : 'Connect',
                                    ),
                                  ),
                                );
                              },
                            ),
                    ),
                    const Divider(height: 1),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: Text(
                        'Downloaded videos',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    SizedBox(
                      height: 230,
                      child: Selector<DownloadProvider, List<DownloadTask>>(
                        selector: (_, provider) => provider.completedDownloads
                            .where((task) => !task.isAudioOnly)
                            .toList(growable: false),
                        shouldRebuild: (prev, next) {
                          if (prev.length != next.length) {
                            return true;
                          }

                          for (var i = 0; i < prev.length; i++) {
                            if (prev[i].id != next[i].id ||
                                prev[i].status != next[i].status ||
                                prev[i].savePath != next[i].savePath) {
                              return true;
                            }
                          }

                          return false;
                        },
                        builder: (context, completedVideos, _) {
                          if (completedVideos.isEmpty) {
                            return const Center(
                              child: Text('No completed videos yet'),
                            );
                          }

                          return ListView.builder(
                            itemCount: completedVideos.length,
                            itemBuilder: (context, index) {
                              final task = completedVideos[index];
                              final connected = _castService.connectedDevice;

                              return ListTile(
                                key: ValueKey(task.id),
                                leading: const Icon(Icons.play_circle_outline),
                                title: Text(
                                  task.fileName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(task.totalSizeFormatted),
                                trailing: IconButton(
                                  tooltip: connected == null
                                      ? 'Connect a display first'
                                      : 'Cast video',
                                  onPressed: connected == null
                                      ? null
                                      : () {
                                          unawaited(_castDownload(task));
                                        },
                                  icon: const Icon(Icons.cast),
                                ),
                              );
                            },
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
      },
    );
  }

  Future<void> _castDownload(DownloadTask task) async {
    final connected = _castService.connectedDevice;
    if (connected == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Connect to a display first.')),
      );
      return;
    }

    final file = File(task.savePath);
    if (!await file.exists()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Video file is missing from storage.')),
      );
      return;
    }

    try {
      final streamUri = await _localStreamServer.registerFile(task.savePath);
      final success = await _castService.castMedia(
        preferredDeviceId: connected.id,
        mediaUrl: streamUri.toString(),
        title: task.fileName,
        subtitle: 'MediaTube',
        mimeType: _mimeTypeForPath(task.savePath),
      );

      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            success
                ? 'Casting ${task.fileName} to ${connected.name}'
                : 'Failed to start casting on ${connected.name}',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Casting failed: $e')),
      );
    }
  }

  String _mimeTypeForPath(String filePath) {
    final lower = filePath.toLowerCase();
    if (lower.endsWith('.mp4') || lower.endsWith('.m4v')) {
      return 'video/mp4';
    }
    if (lower.endsWith('.mkv')) {
      return 'video/x-matroska';
    }
    if (lower.endsWith('.webm')) {
      return 'video/webm';
    }
    if (lower.endsWith('.mp3')) {
      return 'audio/mpeg';
    }
    if (lower.endsWith('.m4a')) {
      return 'audio/mp4';
    }
    return 'application/octet-stream';
  }

  void _openNearbyRadar() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const NearbyRadarScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Downloads'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'Active'),
            Tab(text: 'Completed'),
            Tab(text: 'History'),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Nearby Radar Share',
            icon: const Icon(Icons.radar),
            onPressed: _openNearbyRadar,
          ),
          if (_castService.hasCompatibleDevices)
            IconButton(
              tooltip: _castService.connectedDevice == null
                  ? 'Cast'
                  : 'Cast connected',
              icon: Icon(
                _castService.connectedDevice == null
                    ? Icons.cast
                    : Icons.cast_connected,
              ),
              onPressed: _showCastPanel,
            ),
          // Use Selector to only rebuild when menu-relevant state changes
          Selector<DownloadProvider, ({bool hasActive, bool hasPaused})>(
            selector: (_, p) => (
              hasActive: p.hasActiveDownloads,
              hasPaused: p.hasPausedDownloads,
            ),
            builder: (context, state, _) {
              return PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert),
                onSelected: (value) =>
                    _handleMenuAction(value, context.read<DownloadProvider>()),
                itemBuilder: (context) => [
                  if (state.hasActive)
                    const PopupMenuItem(
                      value: 'pause_all',
                      child: ListTile(
                        leading: Icon(Icons.pause),
                        title: Text('Pause All'),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  if (state.hasPaused)
                    const PopupMenuItem(
                      value: 'resume_all',
                      child: ListTile(
                        leading: Icon(Icons.play_arrow),
                        title: Text('Resume All'),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  const PopupMenuItem(
                    value: 'clear_completed',
                    child: ListTile(
                      leading: Icon(Icons.cleaning_services),
                      title: Text('Clear Completed'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'clear_history',
                    child: ListTile(
                      leading: Icon(Icons.delete_sweep, color: Colors.red),
                      title: Text(
                        'Clear History',
                        style: TextStyle(color: Colors.red),
                      ),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: TabBarView(
          controller: _tabController,
          children: [
            // Active downloads - uses Selector for minimal rebuilds
            _ActiveDownloadsTab(),
            // Completed downloads
            _CompletedDownloadsTab(),
            // History (all downloads)
            _HistoryDownloadsTab(),
          ],
        ),
      ),
    );
  }

  void _handleMenuAction(String action, DownloadProvider provider) {
    switch (action) {
      case 'pause_all':
        provider.pauseAllDownloads();
        break;
      case 'resume_all':
        provider.resumeAllDownloads();
        break;
      case 'clear_completed':
        provider.clearCompleted();
        break;
      case 'clear_history':
        _showClearHistoryDialog(provider);
        break;
    }
  }

  void _showClearHistoryDialog(DownloadProvider provider) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear History'),
        content: const Text(
          'This will clear all download history. Active downloads will not be affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              provider.clearHistory();
              Navigator.pop(context);
            },
            child: const Text('Clear', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }
}

class _DownloadItem extends StatelessWidget {
  final DownloadTask task;
  final bool useProgressNotifier;

  const _DownloadItem({required this.task, this.useProgressNotifier = false});

  @override
  Widget build(BuildContext context) {
    final provider = context.read<DownloadProvider>();

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: InkWell(
        onTap: task.status == DownloadStatus.completed
            ? () => _openFile(context, task.savePath)
            : null,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _buildStatusIcon(),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          task.fileName,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            _buildStatusBadge(),
                            if (task.totalBytes > 0) ...[
                              const SizedBox(width: 8),
                              Text(
                                task.totalSizeFormatted,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey[600],
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                  _buildActionButtons(context, provider),
                ],
              ),
              if (task.isActive || task.status == DownloadStatus.paused) ...[
                const SizedBox(height: 12),
                // Use ValueListenableBuilder for granular progress updates
                useProgressNotifier
                    ? _buildOptimizedProgress(context, provider)
                    : _buildStandardProgress(),
              ],
              if (task.status == DownloadStatus.completed) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(Icons.play_circle, size: 16, color: Colors.green[700]),
                    const SizedBox(width: 4),
                    Text(
                      'Tap to play',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.green[700],
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const Spacer(),
                    if (task.completedAt != null)
                      Text(
                        _formatDate(task.completedAt!),
                        style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                      ),
                  ],
                ),
              ],
              if (task.status == DownloadStatus.failed &&
                  task.error != null) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.red.withAlpha(25),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.error_outline,
                        size: 16,
                        color: Colors.red,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          task.error!,
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.red,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatusIcon() {
    if (task.status == DownloadStatus.downloading) {
      return SizedBox(
        width: 48,
        height: 48,
        child: Stack(
          alignment: Alignment.center,
          children: [
            CircularProgressIndicator(
              value: task.progress,
              strokeWidth: 4,
              backgroundColor: Colors.grey[300],
              color: Colors.blue,
            ),
            Icon(Icons.downloading, size: 20, color: Colors.blue),
          ],
        ),
      );
    }

    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: _getStatusColor().withAlpha(30),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Icon(_getStatusIcon(), color: _getStatusColor(), size: 24),
    );
  }

  Widget _buildStatusBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: _getStatusColor().withAlpha(30),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        _getStatusLabel(),
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.bold,
          color: _getStatusColor(),
        ),
      ),
    );
  }

  Widget _buildActionButtons(BuildContext context, DownloadProvider provider) {
    switch (task.status) {
      case DownloadStatus.downloading:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: Icon(Icons.pause_circle, color: Colors.amber[700]),
              onPressed: () => provider.pauseDownload(task.id),
            ),
            IconButton(
              icon: const Icon(Icons.cancel, color: Colors.red),
              onPressed: () => provider.cancelDownload(task.id),
            ),
          ],
        );
      case DownloadStatus.paused:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.play_circle, color: Colors.green),
              onPressed: () => provider.resumeDownload(task.id),
            ),
            IconButton(
              icon: const Icon(Icons.cancel, color: Colors.red),
              onPressed: () {
                provider.cancelDownload(task.id);
                provider.removeDownload(task.id);
              },
            ),
          ],
        );
      case DownloadStatus.completed:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.share, color: Colors.blue),
              onPressed: () => _shareFile(context, task.savePath),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline, color: Colors.red),
              onPressed: () => _showDeleteDialog(context, provider),
            ),
          ],
        );
      case DownloadStatus.failed:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.refresh, color: Colors.blue),
              onPressed: () => provider.retryDownload(task.id),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline, color: Colors.red),
              onPressed: () => provider.deleteHistoryItem(task.id),
            ),
          ],
        );
      case DownloadStatus.pending:
      case DownloadStatus.merging:
        return const SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        );
      case DownloadStatus.cancelled:
        return IconButton(
          icon: const Icon(Icons.delete_outline, color: Colors.red),
          onPressed: () => provider.deleteHistoryItem(task.id),
        );
    }
  }

  void _openFile(BuildContext context, String path) async {
    final file = File(path);
    if (await file.exists()) {
      final result = await OpenFilex.open(path);
      if (result.type != ResultType.done && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open file: ${result.message}')),
        );
      }
    } else if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('File not found')));
    }
  }

  void _shareFile(BuildContext context, String path) async {
    final file = File(path);
    if (await file.exists()) {
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(path)],
          text: 'Check out this media file downloaded from MediaTube!',
        ),
      );
    } else if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('File not found to share')));
    }
  }

  void _showDeleteDialog(BuildContext context, DownloadProvider provider) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete Download'),
        content: const Text(
          'Delete this file from your device and remove from history?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              // Use deleteHistoryItem which handles both file and history deletion
              provider.deleteHistoryItem(task.id);
              Navigator.pop(dialogContext);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Download deleted'),
                    duration: Duration(seconds: 1),
                  ),
                );
              }
            },
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime date) {
    final now = DateTime.now();
    final diff = now.difference(date);

    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';

    return '${date.day}/${date.month}/${date.year}';
  }

  String _getStatusLabel() {
    switch (task.status) {
      case DownloadStatus.pending:
        return 'PENDING';
      case DownloadStatus.downloading:
        return 'DOWNLOADING';
      case DownloadStatus.paused:
        return 'PAUSED';
      case DownloadStatus.merging:
        return 'MERGING';
      case DownloadStatus.completed:
        return 'COMPLETED';
      case DownloadStatus.failed:
        return 'FAILED';
      case DownloadStatus.cancelled:
        return 'CANCELLED';
    }
  }

  IconData _getStatusIcon() {
    switch (task.status) {
      case DownloadStatus.pending:
        return Icons.hourglass_empty;
      case DownloadStatus.downloading:
        return Icons.downloading;
      case DownloadStatus.paused:
        return Icons.pause_circle;
      case DownloadStatus.merging:
        return Icons.merge_type;
      case DownloadStatus.completed:
        return Icons.check_circle;
      case DownloadStatus.failed:
        return Icons.error;
      case DownloadStatus.cancelled:
        return Icons.cancel;
    }
  }

  Color _getStatusColor() {
    switch (task.status) {
      case DownloadStatus.pending:
        return Colors.orange;
      case DownloadStatus.downloading:
        return Colors.blue;
      case DownloadStatus.paused:
        return Colors.amber.shade700;
      case DownloadStatus.merging:
        return Colors.purple;
      case DownloadStatus.completed:
        return Colors.green;
      case DownloadStatus.failed:
        return Colors.red;
      case DownloadStatus.cancelled:
        return Colors.grey;
    }
  }

  Color _getProgressColor() {
    if (task.status == DownloadStatus.paused) return Colors.amber.shade700;
    if (task.status == DownloadStatus.merging) return Colors.purple;
    return Colors.blue;
  }

  /// Standard progress bar - rebuilds with parent widget
  Widget _buildStandardProgress() {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: task.progress,
                  backgroundColor: Colors.grey[200],
                  minHeight: 8,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    _getProgressColor(),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Text(
              '${(task.progress * 100).toStringAsFixed(0)}%',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: _getStatusColor(),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          '${task.downloadedSizeFormatted} / ${task.totalSizeFormatted}',
          style: TextStyle(fontSize: 12, color: Colors.grey[600]),
        ),
      ],
    );
  }

  /// Optimized progress bar - uses ValueListenableBuilder for granular updates
  Widget _buildOptimizedProgress(
    BuildContext context,
    DownloadProvider provider,
  ) {
    final notifier = provider.getProgressNotifier(task.id);
    if (notifier == null) return _buildStandardProgress();

    return ValueListenableBuilder<double>(
      valueListenable: notifier,
      builder: (context, progress, _) {
        return Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: progress,
                      backgroundColor: Colors.grey[200],
                      minHeight: 8,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        _getProgressColor(),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  '${(progress * 100).toStringAsFixed(0)}%',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: _getStatusColor(),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            // Use task values for size (updated less frequently)
            Text(
              '${task.downloadedSizeFormatted} / ${task.totalSizeFormatted}',
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
          ],
        );
      },
    );
  }
}

/// Active downloads tab - uses Selector for list changes, ValueListenableBuilder for progress
class _ActiveDownloadsTab extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    // Use Selector that only rebuilds when the list of active download IDs changes
    return Selector<DownloadProvider, List<String>>(
      selector: (_, p) {
        final active = [...p.activeDownloads, ...p.pausedDownloads];
        return active.map((d) => '${d.id}:${d.status.index}').toList();
      },
      shouldRebuild: (prev, next) {
        if (prev.length != next.length) return true;
        for (int i = 0; i < prev.length; i++) {
          if (prev[i] != next[i]) return true;
        }
        return false;
      },
      builder: (context, ignored, child) {
        final provider = context.read<DownloadProvider>();
        final downloads = [
          ...provider.activeDownloads,
          ...provider.pausedDownloads,
        ];
        return _buildDownloadsList(
          context,
          downloads,
          emptyMessage: 'No active downloads',
          emptyIcon: Icons.download,
          useProgressNotifier: true, // Enable per-item progress tracking
        );
      },
    );
  }
}

/// Completed downloads tab - only rebuilds when completed downloads change
class _CompletedDownloadsTab extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Selector<DownloadProvider, List<DownloadTask>>(
      selector: (_, p) => p.completedDownloads,
      shouldRebuild: (prev, next) => prev.length != next.length,
      builder: (context, downloads, _) {
        return _buildGroupedDownloadsList(
          context,
          downloads,
          emptyMessage: 'No completed downloads',
          emptyIcon: Icons.check_circle_outline,
        );
      },
    );
  }
}

/// History tab - shows real-time updates for ongoing downloads
class _HistoryDownloadsTab extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    // Rebuild history list for structure/status changes, while per-item
    // progress updates remain granular via ValueListenableBuilder.
    return Selector<DownloadProvider, List<String>>(
      selector: (_, provider) => provider.allDownloadsHistory
          .map(
            (d) =>
                '${d.id}:${d.status.index}:${d.fileName}:${d.completedAt?.millisecondsSinceEpoch ?? 0}',
          )
          .toList(),
      shouldRebuild: (prev, next) {
        if (prev.length != next.length) return true;
        for (int i = 0; i < prev.length; i++) {
          if (prev[i] != next[i]) return true;
        }
        return false;
      },
      builder: (context, ignored, child) {
        final provider = context.read<DownloadProvider>();
        return _buildGroupedDownloadsList(
          context,
          provider.allDownloadsHistory,
          emptyMessage: 'No download history',
          emptyIcon: Icons.history,
          useProgressNotifier: true,
        );
      },
    );
  }
}

/// Shared single download list builder (used by Active tab)
Widget _buildDownloadsList(
  BuildContext context,
  List<DownloadTask> downloads, {
  required String emptyMessage,
  required IconData emptyIcon,
  bool useProgressNotifier = false,
}) {
  if (downloads.isEmpty) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(emptyIcon, size: 64, color: Colors.grey[400]),
          const SizedBox(height: 16),
          Text(
            emptyMessage,
            style: TextStyle(color: Colors.grey[600], fontSize: 16),
          ),
        ],
      ),
    );
  }

  return ListView.separated(
    padding: EdgeInsets.only(bottom: MediaQuery.of(context).padding.bottom + 16),
    itemCount: downloads.length,
    cacheExtent: 500,
    addAutomaticKeepAlives: false,
    addRepaintBoundaries: true,
    physics: const BouncingScrollPhysics(
      parent: AlwaysScrollableScrollPhysics(),
    ),
    separatorBuilder: (context, index) => const SizedBox(height: 2),
    itemBuilder: (context, index) {
      final task = downloads[index];
      return RepaintBoundary(
        child: Dismissible(
          key: Key(task.id),
          direction: DismissDirection.horizontal,
          background: _buildSwipeBackground(
            color: Colors.amber,
            icon: task.status == DownloadStatus.paused
                ? Icons.play_arrow
                : Icons.pause,
            alignment: Alignment.centerLeft,
          ),
          secondaryBackground: _buildSwipeBackground(
            color: Colors.red,
            icon: Icons.delete,
            alignment: Alignment.centerRight,
          ),
          confirmDismiss: (direction) async {
            final provider = context.read<DownloadProvider>();
            if (direction == DismissDirection.endToStart) {
              // Right to left -> Delete
              provider.deleteHistoryItem(task.id);
              return true;
            } else if (direction == DismissDirection.startToEnd) {
              // Left to right -> Pause/Resume
              if (task.status == DownloadStatus.downloading) {
                provider.pauseDownload(task.id);
              } else if (task.status == DownloadStatus.paused) {
                provider.resumeDownload(task.id);
              }
              return false; // Don't actually dismiss the item for pause/resume
            }
            return false;
          },
          child: _DownloadItem(
            task: task,
            useProgressNotifier: useProgressNotifier,
          ),
        ),
      );
    },
  );
}

Widget _buildSwipeBackground({
  required Color color,
  required IconData icon,
  required Alignment alignment,
}) {
  return Container(
    margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(12),
    ),
    alignment: alignment,
    padding: const EdgeInsets.symmetric(horizontal: 20),
    child: Icon(icon, color: Colors.white, size: 30),
  );
}

/// Shared grouped download list builder (used by Completed and History tabs)
Widget _buildGroupedDownloadsList(
  BuildContext context,
  List<DownloadTask> downloads, {
  required String emptyMessage,
  required IconData emptyIcon,
  bool useProgressNotifier = false,
}) {
  if (downloads.isEmpty) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(emptyIcon, size: 64, color: Colors.grey[400]),
          const SizedBox(height: 16),
          Text(
            emptyMessage,
            style: TextStyle(color: Colors.grey[600], fontSize: 16),
          ),
        ],
      ),
    );
  }

  final videoTasks = <DownloadTask>[];
  final audioTasks = <DownloadTask>[];
  for (final task in downloads) {
    if (task.isAudioOnly) {
      audioTasks.add(task);
    } else {
      videoTasks.add(task);
    }
  }

  return CustomScrollView(
    physics: const BouncingScrollPhysics(
      parent: AlwaysScrollableScrollPhysics(),
    ),
    slivers: [
      if (videoTasks.isNotEmpty) ...[
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(
              left: 16,
              top: 16,
              bottom: 8,
              right: 16,
            ),
            child: Text(
              'Videos (${videoTasks.length})',
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 16,
                color: Colors.blue,
              ),
            ),
          ),
        ),
        SliverList(
          delegate: SliverChildBuilderDelegate((context, index) {
            final task = videoTasks[index];
            return _DownloadItem(
              task: task,
              useProgressNotifier: useProgressNotifier,
            );
          }, childCount: videoTasks.length),
        ),
      ],
      if (audioTasks.isNotEmpty) ...[
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.only(
              left: 16,
              top: videoTasks.isNotEmpty ? 24 : 16,
              bottom: 8,
              right: 16,
            ),
            child: Text(
              'Audio (${audioTasks.length})',
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 16,
                color: Colors.purple,
              ),
            ),
          ),
        ),
        SliverList(
          delegate: SliverChildBuilderDelegate((context, index) {
            final task = audioTasks[index];
            return _DownloadItem(
              task: task,
              useProgressNotifier: useProgressNotifier,
            );
          }, childCount: audioTasks.length),
        ),
      ],
      SliverToBoxAdapter(child: SizedBox(height: 32 + MediaQuery.of(context).padding.bottom)), // Bottom padding
    ],
  );
}
