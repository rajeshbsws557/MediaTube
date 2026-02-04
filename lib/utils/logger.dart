import 'package:flutter/foundation.dart';

/// Simple logger utility that only logs in debug mode
class AppLogger {
  static const bool _enableLogs = kDebugMode;
  
  /// Log info message
  static void info(String message) {
    if (_enableLogs) {
      debugPrint('ℹ️ $message');
    }
  }
  
  /// Log success message
  static void success(String message) {
    if (_enableLogs) {
      debugPrint('✅ $message');
    }
  }
  
  /// Log warning message
  static void warning(String message) {
    if (_enableLogs) {
      debugPrint('⚠️ $message');
    }
  }
  
  /// Log error message
  static void error(String message, [Object? error, StackTrace? stackTrace]) {
    if (_enableLogs) {
      debugPrint('❌ $message');
      if (error != null) {
        debugPrint('   Error: $error');
      }
      if (stackTrace != null) {
        debugPrint('   Stack: $stackTrace');
      }
    }
  }
  
  /// Log download progress (throttled)
  static DateTime? _lastProgressLog;
  static void progress(String message) {
    if (!_enableLogs) return;
    
    final now = DateTime.now();
    if (_lastProgressLog == null || 
        now.difference(_lastProgressLog!).inMilliseconds > 500) {
      debugPrint('📊 $message');
      _lastProgressLog = now;
    }
  }
  
  /// Log download-related message
  static void download(String message) {
    if (_enableLogs) {
      debugPrint('📥 $message');
    }
  }
  
  /// Log network-related message
  static void network(String message) {
    if (_enableLogs) {
      debugPrint('🌐 $message');
    }
  }
}
