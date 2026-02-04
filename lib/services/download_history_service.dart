import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/models.dart';

/// Service for persisting download history locally
class DownloadHistoryService {
  static const String _historyKey = 'download_history';
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
  }
  
  /// Clear all history
  Future<void> clearHistory() async {
    await _ensureInitialized();
    await _prefs!.remove(_historyKey);
  }
  
  /// Clear only completed downloads from history
  Future<void> clearCompletedHistory() async {
    await _ensureInitialized();
    
    final history = await getHistory();
    history.removeWhere((t) => 
        t.status == DownloadStatus.completed ||
        t.status == DownloadStatus.cancelled ||
        t.status == DownloadStatus.failed);
    await _saveHistory(history);
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
