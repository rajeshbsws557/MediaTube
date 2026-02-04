import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import '../config/app_config.dart';

/// Model class for app version information from the server
class AppVersionInfo {
  final String version;
  final String changelog;
  final String downloadUrl;

  AppVersionInfo({
    required this.version,
    required this.changelog,
    required this.downloadUrl,
  });

  factory AppVersionInfo.fromJson(Map<String, dynamic> json) {
    return AppVersionInfo(
      version: json['version'] ?? '0.0.0',
      changelog: json['changelog'] ?? '',
      downloadUrl: json['downloadUrl'] ?? '',
    );
  }
}

/// Service to manage app updates
/// Checks for new versions from the Java backend server
/// and handles downloading and installing updates
class UpdateManager {
  // Base URL from app configuration
  static const String _baseUrl = AppConfig.backendBaseUrl;

  static const String _versionEndpoint = '/api/app-version';

  /// Singleton instance
  static final UpdateManager _instance = UpdateManager._internal();
  factory UpdateManager() => _instance;
  UpdateManager._internal();

  /// Dio instance for downloading
  final Dio _dio = Dio();

  /// Current download cancel token
  CancelToken? _cancelToken;

  /// Check for app updates and show dialog if update is available
  ///
  /// [context] - BuildContext for showing the dialog
  /// [showNoUpdateMessage] - If true, shows a snackbar when no update is available
  Future<void> checkForUpdates(
    BuildContext context, {
    bool showNoUpdateMessage = false,
  }) async {
    try {
      final versionInfo = await _fetchVersionInfo();
      if (versionInfo == null) {
        if (showNoUpdateMessage && context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Unable to check for updates')),
          );
        }
        return;
      }

      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = packageInfo.version;
      final serverVersion = versionInfo.version;

      debugPrint('📱 Current app version: $currentVersion');
      debugPrint('🌐 Server version: $serverVersion');

      if (_isNewerVersion(serverVersion, currentVersion)) {
        if (context.mounted) {
          _showUpdateDialog(context, versionInfo, currentVersion);
        }
      } else {
        debugPrint('✅ App is up to date');
        if (showNoUpdateMessage && context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('App is up to date!')),
          );
        }
      }
    } catch (e) {
      debugPrint('❌ Error checking for updates: $e');
      if (showNoUpdateMessage && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error checking for updates: $e')),
        );
      }
    }
  }

  /// Fetch version info from the server
  Future<AppVersionInfo?> _fetchVersionInfo() async {
    try {
      final response = await http
          .get(Uri.parse('$_baseUrl$_versionEndpoint'))
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body);
        return AppVersionInfo.fromJson(json);
      } else {
        debugPrint('❌ Server returned status code: ${response.statusCode}');
        return null;
      }
    } catch (e) {
      debugPrint('❌ Failed to fetch version info: $e');
      return null;
    }
  }

  /// Compare two version strings (e.g., "1.2.0" vs "1.1.0")
  /// Returns true if [serverVersion] is newer than [currentVersion]
  bool _isNewerVersion(String serverVersion, String currentVersion) {
    try {
      final serverParts = serverVersion.split('.').map(int.parse).toList();
      final currentParts = currentVersion.split('.').map(int.parse).toList();

      // Pad shorter version with zeros
      while (serverParts.length < 3) serverParts.add(0);
      while (currentParts.length < 3) currentParts.add(0);

      // Compare major, minor, patch
      for (int i = 0; i < 3; i++) {
        if (serverParts[i] > currentParts[i]) return true;
        if (serverParts[i] < currentParts[i]) return false;
      }
      return false; // Versions are equal
    } catch (e) {
      debugPrint('❌ Error comparing versions: $e');
      return false;
    }
  }

  /// Show update dialog with changelog
  void _showUpdateDialog(
    BuildContext context,
    AppVersionInfo versionInfo,
    String currentVersion,
  ) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: Row(
          children: [
            Icon(
              Icons.system_update,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 8),
            const Text('Update Available'),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Current: v$currentVersion',
                          style: TextStyle(
                            color:
                                Theme.of(context).colorScheme.onPrimaryContainer,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'New: v${versionInfo.version}',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color:
                                Theme.of(context).colorScheme.onPrimaryContainer,
                          ),
                        ),
                      ],
                    ),
                    Icon(
                      Icons.arrow_forward,
                      color: Theme.of(context).colorScheme.onPrimaryContainer,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'What\'s New:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  versionInfo.changelog,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Later'),
          ),
          FilledButton.icon(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              _startUpdate(context, versionInfo.downloadUrl, versionInfo.version);
            },
            icon: const Icon(Icons.download),
            label: const Text('Update Now'),
          ),
        ],
      ),
    );
  }

  /// Start downloading and installing the update
  Future<void> _startUpdate(
    BuildContext context,
    String downloadUrl,
    String version,
  ) async {
    try {
      debugPrint('🚀 Starting update download from: $downloadUrl');

      // Get the download directory
      final Directory tempDir = await getTemporaryDirectory();
      final String apkPath = '${tempDir.path}/MediaTube-$version.apk';

      // Delete old APK if exists
      final File apkFile = File(apkPath);
      if (await apkFile.exists()) {
        await apkFile.delete();
      }

      // Show download progress dialog
      if (!context.mounted) return;

      _cancelToken = CancelToken();

      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => _DownloadProgressDialog(
          downloadUrl: downloadUrl,
          apkPath: apkPath,
          dio: _dio,
          cancelToken: _cancelToken!,
          onComplete: () {
            Navigator.of(dialogContext).pop();
            _installApk(context, apkPath);
          },
          onError: (error) {
            Navigator.of(dialogContext).pop();
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Download failed: $error')),
              );
            }
          },
          onCancel: () {
            Navigator.of(dialogContext).pop();
          },
        ),
      );
    } catch (e) {
      debugPrint('❌ Error starting update: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to start update: $e')),
        );
      }
    }
  }

  /// Install the downloaded APK
  Future<void> _installApk(BuildContext context, String apkPath) async {
    try {
      debugPrint('📦 Installing APK from: $apkPath');

      final result = await OpenFilex.open(apkPath);

      if (result.type != ResultType.done) {
        debugPrint('❌ Failed to open APK: ${result.message}');
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to install: ${result.message}'),
              action: SnackBarAction(
                label: 'Retry',
                onPressed: () => _installApk(context, apkPath),
              ),
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('❌ Error installing APK: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to install update: $e')),
        );
      }
    }
  }

  /// Cancel any ongoing download
  void cancelUpdate() {
    _cancelToken?.cancel('Update cancelled by user');
    _cancelToken = null;
  }
}

/// Dialog widget to show download progress
class _DownloadProgressDialog extends StatefulWidget {
  final String downloadUrl;
  final String apkPath;
  final Dio dio;
  final CancelToken cancelToken;
  final VoidCallback onComplete;
  final Function(String) onError;
  final VoidCallback onCancel;

  const _DownloadProgressDialog({
    required this.downloadUrl,
    required this.apkPath,
    required this.dio,
    required this.cancelToken,
    required this.onComplete,
    required this.onError,
    required this.onCancel,
  });

  @override
  State<_DownloadProgressDialog> createState() =>
      _DownloadProgressDialogState();
}

class _DownloadProgressDialogState extends State<_DownloadProgressDialog> {
  double _progress = 0;
  String _status = 'Starting download...';
  bool _isDownloading = true;

  @override
  void initState() {
    super.initState();
    _startDownload();
  }

  Future<void> _startDownload() async {
    try {
      await widget.dio.download(
        widget.downloadUrl,
        widget.apkPath,
        cancelToken: widget.cancelToken,
        onReceiveProgress: (received, total) {
          if (total != -1) {
            setState(() {
              _progress = received / total;
              _status =
                  'Downloading... ${(received / 1024 / 1024).toStringAsFixed(1)} MB / ${(total / 1024 / 1024).toStringAsFixed(1)} MB';
            });
          }
        },
        options: Options(
          responseType: ResponseType.bytes,
          followRedirects: true,
          receiveTimeout: const Duration(minutes: 10),
        ),
      );

      setState(() {
        _isDownloading = false;
        _status = 'Download complete!';
      });

      // Small delay before installing
      await Future.delayed(const Duration(milliseconds: 500));
      widget.onComplete();
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        debugPrint('📥 Download cancelled');
        widget.onCancel();
      } else {
        debugPrint('❌ Download error: $e');
        widget.onError(e.message ?? 'Download failed');
      }
    } catch (e) {
      debugPrint('❌ Download error: $e');
      widget.onError(e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          Icon(
            _isDownloading ? Icons.downloading : Icons.check_circle,
            color: _isDownloading
                ? Theme.of(context).colorScheme.primary
                : Colors.green,
          ),
          const SizedBox(width: 8),
          Text(_isDownloading ? 'Downloading Update' : 'Download Complete'),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          LinearProgressIndicator(
            value: _progress,
            backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
          ),
          const SizedBox(height: 16),
          Text(
            _status,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 8),
          Text(
            '${(_progress * 100).toStringAsFixed(0)}%',
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).colorScheme.primary,
                ),
          ),
        ],
      ),
      actions: _isDownloading
          ? [
              TextButton(
                onPressed: () {
                  widget.cancelToken.cancel('Cancelled by user');
                },
                child: const Text('Cancel'),
              ),
            ]
          : null,
    );
  }
}

