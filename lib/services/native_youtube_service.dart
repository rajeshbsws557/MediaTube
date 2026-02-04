import 'dart:convert';
import 'package:flutter/services.dart';

/// Service for on-device YouTube extraction using NewPipe Extractor.
///
/// This replaces the external Java server by running extraction directly
/// on the user's device, using their residential IP address.
class NativeYoutubeService {
  static const _channel = MethodChannel('youtube_extractor');

  /// Check if the native extractor is initialized
  static Future<bool> isInitialized() async {
    try {
      final result = await _channel.invokeMethod<bool>('isInitialized');
      return result ?? false;
    } catch (e) {
      return false;
    }
  }

  /// Get video info including title, duration, and available formats.
  ///
  /// Returns a map with:
  /// - videoId: String
  /// - title: String
  /// - duration: int (seconds)
  /// - uploader: String
  /// - thumbnail: String? (URL)
  /// - formats: List of video format maps
  /// - audioFormats: List of audio format maps
  static Future<Map<String, dynamic>> getVideoInfo(String url) async {
    try {
      final String result = await _channel.invokeMethod('getVideoInfo', {
        'url': url,
      });
      return json.decode(result) as Map<String, dynamic>;
    } on PlatformException catch (e) {
      throw NativeExtractionException(e.message ?? 'Unknown error');
    }
  }

  /// Get direct stream URLs for downloading.
  ///
  /// Returns a map with:
  /// - videoId: String
  /// - title: String
  /// - duration: int (seconds)
  /// - needsMerge: bool (true if video+audio need to be merged)
  /// - videoUrl: String (direct CDN URL)
  /// - audioUrl: String? (direct CDN URL, only if needsMerge is true)
  /// - videoFormat: String (e.g., "MPEG-4", "WebM")
  /// - audioFormat: String? (e.g., "M4A", "WebM Opus")
  /// - actualQuality: String (e.g., "1080p", "720p")
  static Future<DirectUrlsResult> getDirectUrls(
    String url, {
    String quality = 'best',
  }) async {
    try {
      final String result = await _channel.invokeMethod('getDirectUrls', {
        'url': url,
        'quality': quality,
      });
      final Map<String, dynamic> data = json.decode(result);
      return DirectUrlsResult.fromJson(data);
    } on PlatformException catch (e) {
      throw NativeExtractionException(e.message ?? 'Unknown error');
    }
  }
}

/// Exception thrown when native extraction fails
class NativeExtractionException implements Exception {
  final String message;
  NativeExtractionException(this.message);

  @override
  String toString() => 'NativeExtractionException: $message';
}

/// Result from getDirectUrls containing video/audio stream URLs
class DirectUrlsResult {
  final String videoId;
  final String title;
  final int duration;
  final bool needsMerge;
  final String videoUrl;
  final String? audioUrl;
  final String videoFormat;
  final String? audioFormat;
  final String actualQuality;

  DirectUrlsResult({
    required this.videoId,
    required this.title,
    required this.duration,
    required this.needsMerge,
    required this.videoUrl,
    this.audioUrl,
    required this.videoFormat,
    this.audioFormat,
    required this.actualQuality,
  });

  factory DirectUrlsResult.fromJson(Map<String, dynamic> json) {
    return DirectUrlsResult(
      videoId: json['videoId'] as String,
      title: json['title'] as String,
      duration: (json['duration'] as num).toInt(),
      needsMerge: json['needsMerge'] as bool? ?? false,
      videoUrl: json['videoUrl'] as String,
      audioUrl: json['audioUrl'] as String?,
      videoFormat: json['videoFormat'] as String? ?? 'unknown',
      audioFormat: json['audioFormat'] as String?,
      actualQuality: json['actualQuality'] as String? ?? 'unknown',
    );
  }

  Map<String, dynamic> toJson() => {
    'videoId': videoId,
    'title': title,
    'duration': duration,
    'needsMerge': needsMerge,
    'videoUrl': videoUrl,
    'audioUrl': audioUrl,
    'videoFormat': videoFormat,
    'audioFormat': audioFormat,
    'actualQuality': actualQuality,
  };
}
