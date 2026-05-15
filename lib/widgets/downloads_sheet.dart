import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/models.dart';
import '../providers/providers.dart';

class DownloadsSheet extends StatelessWidget {
  const DownloadsSheet({super.key});

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

              // Header with actions
              Selector<
                DownloadProvider,
                ({
                  int total,
                  int active,
                  int paused,
                  int completed,
                  bool hasActive,
                  bool hasPaused,
                })
              >(
                selector: (_, provider) => (
                  total: provider.downloads.length,
                  active: provider.activeDownloads.length,
                  paused: provider.pausedDownloads.length,
                  completed: provider.completedDownloads.length,
                  hasActive: provider.hasActiveDownloads,
                  hasPaused: provider.hasPausedDownloads,
                ),
                builder: (context, summary, _) {
                  final downloadProvider = context.read<DownloadProvider>();
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Row(
                      children: [
                        const Icon(Icons.download_done),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Downloads',
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                              if (summary.total > 0)
                                Text(
                                  '${summary.active} active, ${summary.paused} paused, ${summary.completed} completed',
                                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: Colors.grey[600],
                                  ),
                                ),
                            ],
                          ),
                        ),
                        if (summary.hasActive)
                          IconButton(
                            icon: const Icon(Icons.pause_circle_outline),
                            tooltip: 'Pause All',
                            onPressed: downloadProvider.pauseAllDownloads,
                          ),
                        if (summary.hasPaused)
                          IconButton(
                            icon: const Icon(Icons.play_circle_outline),
                            tooltip: 'Resume All',
                            onPressed: downloadProvider.resumeAllDownloads,
                          ),
                        if (summary.total > 0)
                          PopupMenuButton<String>(
                            icon: const Icon(Icons.more_vert),
                            onSelected: (value) {
                              switch (value) {
                                case 'clear':
                                  downloadProvider.clearCompleted();
                                  break;
                                case 'cancel_all':
                                  _showCancelAllDialog(context, downloadProvider);
                                  break;
                              }
                            },
                            itemBuilder: (context) => [
                              const PopupMenuItem(
                                value: 'clear',
                                child: Row(
                                  children: [
                                    Icon(Icons.cleaning_services, size: 20),
                                    SizedBox(width: 8),
                                    Text('Clear Finished'),
                                  ],
                                ),
                              ),
                              if (summary.hasActive)
                                const PopupMenuItem(
                                  value: 'cancel_all',
                                  child: Row(
                                    children: [
                                      Icon(Icons.cancel, size: 20, color: Colors.red),
                                      SizedBox(width: 8),
                                      Text('Cancel All', style: TextStyle(color: Colors.red)),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                      ],
                    ),
                  );
                },
              ),

              const Divider(height: 1),

              // Downloads list
              Expanded(
                child: Selector<DownloadProvider, List<String>>(
                  selector: (_, provider) => provider.downloads
                      .map(
                        (d) =>
                            '${d.id}:${d.status.index}:${(d.progress * 100).toStringAsFixed(0)}',
                      )
                      .toList(growable: false),
                  shouldRebuild: (prev, next) {
                    if (prev.length != next.length) {
                      return true;
                    }
                    for (var i = 0; i < prev.length; i++) {
                      if (prev[i] != next[i]) {
                        return true;
                      }
                    }
                    return false;
                  },
                  builder: (context, signatures, child) {
                    final downloads = context.read<DownloadProvider>().downloads;
                    if (downloads.isEmpty) {
                      return _buildEmptyState();
                    }

                    return ListView.separated(
                      controller: scrollController,
                      cacheExtent: 420,
                      addAutomaticKeepAlives: false,
                      addRepaintBoundaries: true,
                      itemCount: downloads.length,
                        separatorBuilder: (context, index) =>
                          const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final task = downloads[index];
                        return RepaintBoundary(
                          child: _DownloadListItem(
                            key: ValueKey(task.id),
                            task: task,
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.download,
            size: 64,
            color: Colors.grey[400],
          ),
          const SizedBox(height: 16),
          Text(
            'No downloads yet',
            style: TextStyle(
              color: Colors.grey[600],
              fontSize: 16,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Browse websites to find media to download',
            style: TextStyle(
              color: Colors.grey[500],
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  void _showCancelAllDialog(BuildContext context, DownloadProvider provider) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancel All Downloads'),
        content: const Text('Are you sure you want to cancel all active downloads?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('No'),
          ),
          TextButton(
            onPressed: () {
              provider.cancelAllDownloads();
              Navigator.pop(context);
            },
            child: const Text('Yes', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }
}

class _DownloadListItem extends StatelessWidget {
  final DownloadTask task;

  const _DownloadListItem({super.key, required this.task});

  @override
  Widget build(BuildContext context) {
    final downloadProvider = context.read<DownloadProvider>();
    
    return Dismissible(
      key: Key(task.id),
      direction: DismissDirection.endToStart,
      confirmDismiss: (direction) async {
        if (task.status == DownloadStatus.downloading || 
            task.status == DownloadStatus.paused) {
          return await _showDeleteConfirmDialog(context);
        }
        return true;
      },
      background: Container(
        color: Colors.red,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 16),
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      onDismissed: (_) {
        downloadProvider.cancelDownload(task.id);
        downloadProvider.removeDownload(task.id);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            // Status icon with progress
            _buildStatusIndicator(),
            const SizedBox(width: 12),
            
            // File info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    task.fileName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Flexible(child: _buildStatusBadge()),
                      const SizedBox(width: 8),
                      if (task.totalBytes > 0 && (task.isActive || task.status == DownloadStatus.paused))
                        Flexible(
                          child: Text(
                            '${task.downloadedSizeFormatted} / ${task.totalSizeFormatted}',
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.grey[600],
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                  ),
                  if (task.status == DownloadStatus.downloading ||
                      task.status == DownloadStatus.merging ||
                      task.status == DownloadStatus.paused)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: task.progress,
                          backgroundColor: Colors.grey[200],
                          valueColor: AlwaysStoppedAnimation<Color>(_getProgressColor()),
                          minHeight: 6,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            
            const SizedBox(width: 8),
            
            // Action buttons
            _buildActionButtons(context, downloadProvider),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusIndicator() {
    final color = _getStatusColor();
    
    if (task.status == DownloadStatus.downloading) {
      return SizedBox(
        width: 44,
        height: 44,
        child: Stack(
          alignment: Alignment.center,
          children: [
            CircularProgressIndicator(
              value: task.progress,
              strokeWidth: 3,
              color: color,
              backgroundColor: color.withAlpha(50),
            ),
            Text(
              '${(task.progress * 100).toInt()}%',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
          ],
        ),
      );
    }
    
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: color.withAlpha(25),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Icon(_getStatusIcon(), color: color, size: 24),
    );
  }

  Widget _buildStatusBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: _getStatusColor().withAlpha(25),
        borderRadius: BorderRadius.circular(4),
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
        return Icons.pause_circle_filled;
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
    switch (task.status) {
      case DownloadStatus.paused:
        return Colors.amber.shade700;
      case DownloadStatus.merging:
        return Colors.purple;
      default:
        return Colors.blue;
    }
  }

  Widget _buildActionButtons(BuildContext context, DownloadProvider provider) {
    switch (task.status) {
      case DownloadStatus.pending:
        return IconButton(
          icon: const Icon(Icons.close, color: Colors.grey),
          tooltip: 'Cancel',
          onPressed: () => provider.cancelDownload(task.id),
        );
        
      case DownloadStatus.downloading:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: Icon(Icons.pause, color: Colors.amber.shade700),
              tooltip: 'Pause',
              onPressed: () => provider.pauseDownload(task.id),
            ),
            IconButton(
              icon: const Icon(Icons.close, color: Colors.grey),
              tooltip: 'Cancel',
              onPressed: () => provider.cancelDownload(task.id),
            ),
          ],
        );
        
      case DownloadStatus.paused:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.play_arrow, color: Colors.green),
              tooltip: 'Resume',
              onPressed: () => provider.resumeDownload(task.id),
            ),
            IconButton(
              icon: const Icon(Icons.close, color: Colors.grey),
              tooltip: 'Cancel',
              onPressed: () {
                provider.cancelDownload(task.id);
                provider.removeDownload(task.id);
              },
            ),
          ],
        );
        
      case DownloadStatus.merging:
        return const SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        );
        
      case DownloadStatus.completed:
        return IconButton(
          icon: const Icon(Icons.folder_open, color: Colors.blue),
          tooltip: 'Show in folder',
          onPressed: () {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Saved to: ${task.savePath}'),
                action: SnackBarAction(
                  label: 'OK',
                  onPressed: () {},
                ),
              ),
            );
          },
        );
        
      case DownloadStatus.failed:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.refresh, color: Colors.blue),
              tooltip: 'Retry',
              onPressed: () => provider.retryDownload(task.id),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline, color: Colors.red),
              tooltip: 'Remove',
              onPressed: () => provider.removeDownload(task.id),
            ),
          ],
        );
        
      case DownloadStatus.cancelled:
        return IconButton(
          icon: const Icon(Icons.delete_outline, color: Colors.red),
          tooltip: 'Remove',
          onPressed: () => provider.removeDownload(task.id),
        );
    }
  }

  Future<bool> _showDeleteConfirmDialog(BuildContext context) async {
    return await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancel Download?'),
        content: const Text('This will stop and remove this download. Are you sure?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('No'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Yes', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    ) ?? false;
  }
}
