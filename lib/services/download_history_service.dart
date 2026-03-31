import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/models.dart';

/// Service for persisting download history locally
class DownloadHistoryService {
  static const String _historyKey = 'download_history';
  static const String _historyMediaKey = 'download_history_media';
  static const int _maxHistoryItems = 100; // Keep last 100 downloads
  
  SharedPreferences? _prefs;
  
  Future<void> _ensureInitialized() async {
    _prefs ??= await SharedPreferences.getInstance();
  }
  
  /// Save a download task to history
  Future<void> saveDownload(DownloadTask task) async {
    await _ensureInitialized();
    
    final history = await getHistory();
    
    // Update existing or add new
    final existingIndex = history.indexWhere((t) => t.id == task.id);
    if (existingIndex != -1) {
      history[existingIndex] = task;
    } else {
      history.insert(0, task);
    }
    
    // Limit history size
    while (history.length > _maxHistoryItems) {
      history.removeLast();
    }
    
    await _saveHistory(history);
  }
  
  /// Get all download history
  Future<List<DownloadTask>> getHistory() async {
    await _ensureInitialized();
    
    final jsonString = _prefs!.getString(_historyKey);
    if (jsonString == null || jsonString.isEmpty) {
      return [];
    }
    
    try {
      final List<dynamic> jsonList = json.decode(jsonString);
      return jsonList.map((j) => _taskFromJson(j)).toList();
    } catch (e) {
      return [];
    }
  }
  
  /// Remove a download from history
  Future<void> removeFromHistory(String taskId) async {
    await _ensureInitialized();
    
    final history = await getHistory();
    history.removeWhere((t) => t.id == taskId);
    await _saveHistory(history);
    await removeMediaForTask(taskId);
  }
  
  /// Clear all history
  Future<void> clearHistory() async {
    await _ensureInitialized();
    await _prefs!.remove(_historyKey);
    await _prefs!.remove(_historyMediaKey);
  }
  
  /// Clear only completed downloads from history
  Future<void> clearCompletedHistory() async {
    await _ensureInitialized();
    
    final history = await getHistory();
    final removedIds = history
        .where((t) =>
            t.status == DownloadStatus.completed ||
            t.status == DownloadStatus.cancelled ||
            t.status == DownloadStatus.failed)
        .map((t) => t.id)
        .toList();

    history.removeWhere((t) => 
        t.status == DownloadStatus.completed ||
        t.status == DownloadStatus.cancelled ||
        t.status == DownloadStatus.failed);
    await _saveHistory(history);

    for (final id in removedIds) {
      await removeMediaForTask(id);
    }
  }

  Future<void> saveMediaForTask(String taskId, DetectedMedia media) async {
    await _ensureInitialized();
    final mediaMap = await _getRawMediaMap();
    mediaMap[taskId] = _mediaToJson(media);
    await _prefs!.setString(_historyMediaKey, json.encode(mediaMap));
  }

  Future<void> removeMediaForTask(String taskId) async {
    await _ensureInitialized();
    final mediaMap = await _getRawMediaMap();
    if (mediaMap.remove(taskId) != null) {
      await _prefs!.setString(_historyMediaKey, json.encode(mediaMap));
    }
  }

  Future<Map<String, DetectedMedia>> getSavedMediaMap() async {
    await _ensureInitialized();
    final rawMap = await _getRawMediaMap();
    final result = <String, DetectedMedia>{};

    rawMap.forEach((taskId, rawValue) {
      if (rawValue is Map<String, dynamic>) {
        final media = _mediaFromJson(rawValue);
        if (media != null) {
          result[taskId] = media;
        }
      } else if (rawValue is Map) {
        final mapValue = rawValue.cast<String, dynamic>();
        final media = _mediaFromJson(mapValue);
        if (media != null) {
          result[taskId] = media;
        }
      }
    });

    return result;
  }

  Future<Map<String, dynamic>> _getRawMediaMap() async {
    final jsonString = _prefs!.getString(_historyMediaKey);
    if (jsonString == null || jsonString.isEmpty) {
      return <String, dynamic>{};
    }

    try {
      final decoded = json.decode(jsonString);
      if (decoded is Map<String, dynamic>) {
        return Map<String, dynamic>.from(decoded);
      }
      if (decoded is Map) {
        return decoded.cast<String, dynamic>();
      }
    } catch (_) {}

    return <String, dynamic>{};
  }

  Map<String, dynamic> _mediaToJson(DetectedMedia media) {
    return {
      'url': media.url,
      'title': media.title,
      'type': media.type.name,
      'source': media.source.name,
      'thumbnailUrl': media.thumbnailUrl,
      'fileSize': media.fileSize,
      'quality': media.quality,
      'format': media.format,
      'audioUrl': media.audioUrl,
      'isDash': media.isDash,
      'videoId': media.videoId,
      'streamIndex': media.streamIndex,
      'backendQuality': media.backendQuality,
      'useBackend': media.useBackend,
    };
  }

  DetectedMedia? _mediaFromJson(Map<String, dynamic> json) {
    final url = (json['url'] ?? '').toString();
    if (url.isEmpty) return null;

    MediaType parseType() {
      final raw = (json['type'] ?? '').toString();
      for (final type in MediaType.values) {
        if (type.name == raw) return type;
      }
      return MediaType.video;
    }

    MediaSource parseSource() {
      final raw = (json['source'] ?? '').toString();
      for (final source in MediaSource.values) {
        if (source.name == raw) return source;
      }
      return MediaSource.generic;
    }

    return DetectedMedia(
      url: url,
      title: (json['title'] ?? 'Recovered media').toString(),
      type: parseType(),
      source: parseSource(),
      thumbnailUrl: json['thumbnailUrl']?.toString(),
      fileSize: json['fileSize'] is int ? json['fileSize'] as int : int.tryParse((json['fileSize'] ?? '').toString()),
      quality: json['quality']?.toString(),
      format: json['format']?.toString(),
      audioUrl: json['audioUrl']?.toString(),
      isDash: json['isDash'] == true,
      videoId: json['videoId']?.toString(),
      streamIndex: json['streamIndex'] is int
          ? json['streamIndex'] as int
          : int.tryParse((json['streamIndex'] ?? '').toString()),
      backendQuality: json['backendQuality']?.toString(),
      useBackend: json['useBackend'] == true,
    );
  }
  
  Future<void> _saveHistory(List<DownloadTask> history) async {
    final jsonList = history.map((t) => _taskToJson(t)).toList();
    await _prefs!.setString(_historyKey, json.encode(jsonList));
  }
  
  Map<String, dynamic> _taskToJson(DownloadTask task) {
    return {
      'id': task.id,
      'url': task.url,
      'fileName': task.fileName,
      'savePath': task.savePath,
      'audioUrl': task.audioUrl,
      'requiresMerge': task.requiresMerge,
      'status': task.status.index,
      'progress': task.progress,
      'downloadedBytes': task.downloadedBytes,
      'totalBytes': task.totalBytes,
      'error': task.error,
      'statusMessage': task.statusMessage,
      'createdAt': task.createdAt.toIso8601String(),
      'completedAt': task.completedAt?.toIso8601String(),
      'tempPath': task.tempPath,
    };
  }
  
  DownloadTask _taskFromJson(Map<String, dynamic> json) {
    return DownloadTask(
      id: json['id'] ?? '',
      url: json['url'] ?? '',
      fileName: json['fileName'] ?? 'Unknown',
      savePath: json['savePath'] ?? '',
      audioUrl: json['audioUrl'],
      requiresMerge: json['requiresMerge'] ?? false,
      status: DownloadStatus.values[json['status'] ?? 0],
      progress: (json['progress'] ?? 0).toDouble(),
      downloadedBytes: json['downloadedBytes'] ?? 0,
      totalBytes: json['totalBytes'] ?? 0,
      error: json['error'],
      statusMessage: json['statusMessage'],
      createdAt: json['createdAt'] != null 
          ? DateTime.parse(json['createdAt']) 
          : DateTime.now(),
      completedAt: json['completedAt'] != null 
          ? DateTime.parse(json['completedAt']) 
          : null,
      tempPath: json['tempPath'],
    );
  }
}
