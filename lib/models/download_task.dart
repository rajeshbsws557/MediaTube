enum DownloadStatus { pending, downloading, paused, merging, completed, failed, cancelled }

class DownloadTask {
  final String id;
  final String url;
  final String fileName;
  String savePath;  // Made non-final to allow native downloader to update the path
  final String? audioUrl; // For DASH videos
  final bool requiresMerge;
  DownloadStatus status;
  double progress;
  int downloadedBytes; // Track bytes for resume
  int totalBytes; // Total file size
  String? error;
  String? statusMessage; // Custom status message (e.g., "Downloading video...")
  DateTime createdAt;
  DateTime? completedAt;
  String? tempPath; // Temporary file for partial downloads

  DownloadTask({
    required this.id,
    required this.url,
    required this.fileName,
    required this.savePath,
    this.audioUrl,
    this.requiresMerge = false,
    this.status = DownloadStatus.pending,
    this.progress = 0,
    this.downloadedBytes = 0,
    this.totalBytes = 0,
    this.error,
    this.statusMessage,
    DateTime? createdAt,
    this.completedAt,
    this.tempPath,
  }) : createdAt = createdAt ?? DateTime.now();

  bool get canPause => status == DownloadStatus.downloading;
  bool get canResume => status == DownloadStatus.paused;
  bool get isActive => status == DownloadStatus.downloading || 
                       status == DownloadStatus.merging ||
                       status == DownloadStatus.pending;

  String get statusText {
    // Use custom status message if available
    if (statusMessage != null && statusMessage!.isNotEmpty) {
      return '$statusMessage ${(progress * 100).toStringAsFixed(0)}%';
    }
    
    switch (status) {
      case DownloadStatus.pending:
        return 'Pending';
      case DownloadStatus.downloading:
        return 'Downloading ${(progress * 100).toStringAsFixed(1)}%';
      case DownloadStatus.paused:
        return 'Paused - ${(progress * 100).toStringAsFixed(1)}%';
      case DownloadStatus.merging:
        return 'Merging video & audio...';
      case DownloadStatus.completed:
        return 'Completed';
      case DownloadStatus.failed:
        return 'Failed: ${error ?? "Unknown error"}';
      case DownloadStatus.cancelled:
        return 'Cancelled';
    }
  }

  String get downloadedSizeFormatted {
    if (downloadedBytes < 1024) return '$downloadedBytes B';
    if (downloadedBytes < 1024 * 1024) return '${(downloadedBytes / 1024).toStringAsFixed(1)} KB';
    return '${(downloadedBytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  String get totalSizeFormatted {
    if (totalBytes <= 0) return 'Unknown';
    if (totalBytes < 1024) return '$totalBytes B';
    if (totalBytes < 1024 * 1024) return '${(totalBytes / 1024).toStringAsFixed(1)} KB';
    return '${(totalBytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  DownloadTask copyWith({
    String? id,
    String? url,
    String? fileName,
    String? savePath,
    String? audioUrl,
    bool? requiresMerge,
    DownloadStatus? status,
    double? progress,
    int? downloadedBytes,
    int? totalBytes,
    String? error,
    String? statusMessage,
    DateTime? createdAt,
    DateTime? completedAt,
    String? tempPath,
  }) {
    return DownloadTask(
      id: id ?? this.id,
      url: url ?? this.url,
      fileName: fileName ?? this.fileName,
      savePath: savePath ?? this.savePath,
      audioUrl: audioUrl ?? this.audioUrl,
      requiresMerge: requiresMerge ?? this.requiresMerge,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      downloadedBytes: downloadedBytes ?? this.downloadedBytes,
      totalBytes: totalBytes ?? this.totalBytes,
      error: error ?? this.error,
      statusMessage: statusMessage ?? this.statusMessage,
      createdAt: createdAt ?? this.createdAt,
      completedAt: completedAt ?? this.completedAt,
      tempPath: tempPath ?? this.tempPath,
    );
  }
}
