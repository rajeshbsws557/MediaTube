import 'dart:async';
import 'dart:io';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new/statistics.dart';
import '../utils/logger.dart';

/// FFmpeg Service for merging video and audio streams
class FFmpegService {
  bool _initialized = false;
  
  /// Initialize FFmpeg
  Future<void> init() async {
    if (_initialized) return;
    
    // Enable log callback for debugging
    FFmpegKitConfig.enableLogCallback((log) {
      // Logs handled internally
    });
    
    _initialized = true;
    AppLogger.success('FFmpeg initialized');
  }
  
  /// Get video duration in milliseconds using FFprobe
  Future<int> _getVideoDuration(String videoPath) async {
    try {
      final session = await FFmpegKit.execute('-i "$videoPath" 2>&1');
      final output = await session.getOutput() ?? '';
      
      // Parse duration from FFmpeg output: Duration: 00:05:30.12
      final durationMatch = RegExp(r'Duration:\s*(\d+):(\d+):(\d+)\.(\d+)').firstMatch(output);
      if (durationMatch != null) {
        final hours = int.parse(durationMatch.group(1)!);
        final minutes = int.parse(durationMatch.group(2)!);
        final seconds = int.parse(durationMatch.group(3)!);
        final ms = int.parse(durationMatch.group(4)!) * 10; // centiseconds to ms
        return (hours * 3600 + minutes * 60 + seconds) * 1000 + ms;
      }
    } catch (e) {
      AppLogger.warning('Could not get video duration: $e');
    }
    return 0;
  }
  
  /// Merges separate video and audio files into a single MP4 with progress
  Future<bool> mergeVideoAudio({
    required String videoPath,
    required String audioPath,
    required String outputPath,
    Function(double progress)? onProgress,
  }) async {
    await init();
    
    AppLogger.info('FFmpeg merging: $videoPath + $audioPath -> $outputPath');
    
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
    
    // Get video duration for progress calculation
    final totalDurationMs = await _getVideoDuration(videoPath);
    AppLogger.info('Video duration: ${totalDurationMs}ms');
    
    // Delete output file if it exists
    final outputFile = File(outputPath);
    if (await outputFile.exists()) {
      await outputFile.delete();
    }
    
    // FFmpeg command to merge video + audio
    final command = '-i "$videoPath" -i "$audioPath" -c:v copy -c:a aac -strict experimental -y "$outputPath"';
    
    // Create a completer for async progress tracking
    final completer = Completer<bool>();
    
    // Enable statistics callback for progress
    FFmpegKitConfig.enableStatisticsCallback((Statistics statistics) {
      if (totalDurationMs > 0) {
        final timeMs = statistics.getTime();
        if (timeMs > 0) {
          final progress = (timeMs / totalDurationMs).clamp(0.0, 0.99);
          onProgress?.call(progress);
        }
      }
    });
    
    // Execute with async callback
    FFmpegKit.executeAsync(command, (session) async {
      final returnCode = await session.getReturnCode();
      
      if (ReturnCode.isSuccess(returnCode)) {
        // Verify output file exists and has content
        if (await outputFile.exists()) {
          final size = await outputFile.length();
          if (size > 0) {
            AppLogger.success('FFmpeg merge completed: ${(size / 1024 / 1024).toStringAsFixed(2)} MB');
            onProgress?.call(1.0);
            
            // Clean up source files
            try {
              await videoFile.delete();
              await audioFile.delete();
            } catch (e) {
              AppLogger.warning('Could not delete temp files: $e');
            }
            
            completer.complete(true);
            return;
          }
        }
        AppLogger.error('Output file not created or empty');
        completer.complete(false);
      } else {
        final logs = await session.getAllLogsAsString();
        AppLogger.error('FFmpeg failed with code: $returnCode', logs);
        completer.complete(false);
      }
    });
    
    return completer.future;
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