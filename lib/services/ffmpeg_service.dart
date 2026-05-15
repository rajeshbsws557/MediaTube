import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import '../utils/logger.dart';

/// FFmpeg Service (now using native MediaMuxer) for merging video and audio streams
class FFmpegService {
  static const MethodChannel _channel = MethodChannel('media_muxer');
  bool _initialized = false;

  /// Initialize
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    AppLogger.success('Muxer initialized');
  }

  /// Merges separate video and audio files into a single MP4 with progress
  Future<bool> mergeVideoAudio({
    required String videoPath,
    required String audioPath,
    required String outputPath,
    Function(double progress)? onProgress,
  }) async {
    await init();

    AppLogger.info('Native merging: $videoPath + $audioPath -> $outputPath');

    // Check if input files exist
    final videoFile = File(videoPath);
    final audioFile = File(audioPath);

    if (!await videoFile.exists()) {
      AppLogger.error('Video file not found: $videoPath');
      return false;
    }

    if (!await audioFile.exists()) {
      AppLogger.error('Audio file not found: $audioPath');
      return false;
    }

    try {
      // simulate initial progress
      onProgress?.call(0.1);

      final result = await _channel.invokeMethod<bool>('mergeVideoAudio', {
        'videoPath': videoPath,
        'audioPath': audioPath,
        'outputPath': outputPath,
      });

      if (result == true) {
        onProgress?.call(1.0);
        // Clean up source files
        try {
          await videoFile.delete();
          await audioFile.delete();
        } catch (e) {
          AppLogger.warning('Could not delete temp files: $e');
        }

        final outputFile = File(outputPath);
        if (await outputFile.exists()) {
          final size = await outputFile.length();
          AppLogger.success(
            'Native merge completed: ${(size / 1024 / 1024).toStringAsFixed(2)} MB',
          );
        }
        return true;
      }
      return false;
    } catch (e) {
      AppLogger.error('Native merge failed', e.toString());
      return false;
    }
  }

  /// Helper to clean up temp files
  Future<void> deleteTempFiles(List<String> paths) async {
    for (final path in paths) {
      try {
        final file = File(path);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (e) {
        AppLogger.warning('Error deleting temp file: $e');
      }
    }
  }
}
