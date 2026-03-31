import 'package:flutter/foundation.dart';

/// Simple logger utility that only logs in debug mode
class AppLogger {
  static const bool _enableLogs = kDebugMode;
  static const int _maxLogLength = 800;
  static final RegExp _httpUrlRegex = RegExp(r'https?://[^\s)]+');
  static final RegExp _headerLeakRegex = RegExp(
    r'(authorization|cookie|set-cookie)\s*:\s*[^,\n]+',
    caseSensitive: false,
  );
  static const Set<String> _sensitiveQueryKeys = {
    'token',
    'access_token',
    'auth',
    'authorization',
    'sig',
    'signature',
    'key',
    'apikey',
    'api_key',
    'cookie',
  };

  static String _sanitizeMessage(String message) {
    var sanitized = message.replaceAllMapped(_httpUrlRegex, (match) {
      final raw = match.group(0) ?? '';
      final uri = Uri.tryParse(raw);
      if (uri == null || uri.queryParameters.isEmpty) {
        return raw;
      }

      final redactedParams = <String, String>{};
      uri.queryParameters.forEach((key, value) {
        if (_sensitiveQueryKeys.contains(key.toLowerCase())) {
          redactedParams[key] = '[REDACTED]';
        } else {
          redactedParams[key] = value;
        }
      });

      return uri
          .replace(
            queryParameters: redactedParams.isEmpty ? null : redactedParams,
            fragment: null,
          )
          .toString();
    });

    sanitized = sanitized.replaceAllMapped(_headerLeakRegex, (match) {
      final header = match.group(1) ?? 'header';
      return '$header: [REDACTED]';
    });

    if (sanitized.length > _maxLogLength) {
      return '${sanitized.substring(0, _maxLogLength)}... [truncated]';
    }

    return sanitized;
  }

  static void _debug(String prefix, String message) {
    debugPrint('$prefix ${_sanitizeMessage(message)}');
  }
  
  /// Log info message
  static void info(String message) {
    if (_enableLogs) {
      _debug('ℹ️', message);
    }
  }
  
  /// Log success message
  static void success(String message) {
    if (_enableLogs) {
      _debug('✅', message);
    }
  }
  
  /// Log warning message
  static void warning(String message) {
    if (_enableLogs) {
      _debug('⚠️', message);
    }
  }
  
  /// Log error message
  static void error(String message, [Object? error, StackTrace? stackTrace]) {
    if (_enableLogs) {
      _debug('❌', message);
      if (error != null) {
        _debug('   Error:', error.toString());
      }
      if (stackTrace != null) {
        _debug('   Stack:', stackTrace.toString());
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
      _debug('📊', message);
      _lastProgressLog = now;
    }
  }
  
  /// Log download-related message
  static void download(String message) {
    if (_enableLogs) {
      _debug('📥', message);
    }
  }
  
  /// Log network-related message
  static void network(String message) {
    if (_enableLogs) {
      _debug('🌐', message);
    }
  }
}
