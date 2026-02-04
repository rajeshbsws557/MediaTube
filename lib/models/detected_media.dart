import 'package:uuid/uuid.dart';

enum MediaType { video, audio, stream }

enum MediaSource { generic, youtube }

class DetectedMedia {
  final String id;
  final String url;
  final String title;
  final MediaType type;
  final MediaSource source;
  final String? thumbnailUrl;
  final int? fileSize;
  final String? quality;
  final String? format;
  final String? audioUrl; // For DASH videos with separate audio
  final bool isDash;
  final String? videoId; // YouTube video ID for direct download
  final int? streamIndex; // Index in manifest for YouTube streams
  final String? backendQuality; // Quality preset for backend downloads ("best", "1080p", etc.)
  final bool useBackend; // Whether to use backend server for download

  DetectedMedia({
    String? id,
    required this.url,
    required this.title,
    required this.type,
    this.source = MediaSource.generic,
    this.thumbnailUrl,
    this.fileSize,
    this.quality,
    this.format,
    this.audioUrl,
    this.isDash = false,
    this.videoId,
    this.streamIndex,
    this.backendQuality,
    this.useBackend = false,
  }) : id = id ?? const Uuid().v4();

  String get extension {
    if (format != null) return format!;
    if (url.contains('.mp4')) return 'mp4';
    if (url.contains('.mp3')) return 'mp3';
    if (url.contains('.m3u8')) return 'm3u8';
    if (url.contains('.webm')) return 'webm';
    return 'mp4';
  }

  String get fileSizeFormatted {
    if (fileSize == null) return 'Unknown size';
    final kb = fileSize! / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
    final mb = kb / 1024;
    if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
    final gb = mb / 1024;
    return '${gb.toStringAsFixed(2)} GB';
  }

  DetectedMedia copyWith({
    String? id,
    String? url,
    String? title,
    MediaType? type,
    MediaSource? source,
    String? thumbnailUrl,
    int? fileSize,
    String? quality,
    String? format,
    String? audioUrl,
    bool? isDash,
    String? videoId,
    int? streamIndex,
    String? backendQuality,
    bool? useBackend,
  }) {
    return DetectedMedia(
      id: id ?? this.id,
      url: url ?? this.url,
      title: title ?? this.title,
      type: type ?? this.type,
      source: source ?? this.source,
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
      fileSize: fileSize ?? this.fileSize,
      quality: quality ?? this.quality,
      format: format ?? this.format,
      audioUrl: audioUrl ?? this.audioUrl,
      isDash: isDash ?? this.isDash,
      videoId: videoId ?? this.videoId,
      streamIndex: streamIndex ?? this.streamIndex,
      backendQuality: backendQuality ?? this.backendQuality,
      useBackend: useBackend ?? this.useBackend,
    );
  }
}
