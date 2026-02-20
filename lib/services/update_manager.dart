import 'dart:convert';
import 'dart:io';
import 'dart:ui'; // For image filter
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import '../config/app_config.dart';

/// Model class for app version information from GitHub
class AppVersionInfo {
  final String version;
  final String changelog;
  final String downloadUrl;

  AppVersionInfo({
    required this.version,
    required this.changelog,
    required this.downloadUrl,
  });

  factory AppVersionInfo.fromGitHub(Map<String, dynamic> json) {
    final String tagName = json['tag_name'] ?? 'v0.0.0';
    final String cleanVersion = tagName.replaceAll('v', '');

    String apkUrl = '';
    // Find release APK asset
    if (json['assets'] != null) {
      final assets = json['assets'] as List;
      // Prefer arm64, then universal, then any apk
      final arm64 = assets.firstWhere(
        (a) => a['name'].toString().contains('arm64'),
        orElse: () => null,
      );
      if (arm64 != null) {
        apkUrl = arm64['browser_download_url'];
      } else {
        final anyApk = assets.firstWhere(
          (a) => a['name'].toString().endsWith('.apk'),
          orElse: () => null,
        );
        if (anyApk != null) apkUrl = anyApk['browser_download_url'];
      }
    }

    return AppVersionInfo(
      version: cleanVersion,
      changelog: json['body'] ?? 'No changelog available.',
      downloadUrl: apkUrl,
    );
  }
}

/// Service to manage app updates via GitHub Releases
class UpdateManager {
  static final UpdateManager _instance = UpdateManager._internal();
  factory UpdateManager() => _instance;
  UpdateManager._internal();

  final Dio _dio = Dio();
  CancelToken? _cancelToken;

  Future<void> checkForUpdates(
    BuildContext context, {
    bool showNoUpdateMessage = false,
  }) async {
    try {
      final versionInfo = await _fetchGitHubVersionInfo();
      if (versionInfo == null || versionInfo.downloadUrl.isEmpty) {
        if (showNoUpdateMessage && context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Unable to check for updates or no APK found'),
            ),
          );
        }
        return;
      }

      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = packageInfo.version;

      debugPrint(
        '📱 Current: $currentVersion, 🌐 GitHub: ${versionInfo.version}',
      );

      if (_isNewerVersion(versionInfo.version, currentVersion)) {
        if (context.mounted) {
          _showBeautifulUpdateDialog(context, versionInfo, currentVersion);
        }
      } else {
        if (showNoUpdateMessage && context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('App is up to date!')));
        }
      }
    } catch (e) {
      debugPrint('❌ Update check failed: $e');
      if (showNoUpdateMessage && context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  Future<AppVersionInfo?> _fetchGitHubVersionInfo() async {
    try {
      // https://api.github.com/repos/{owner}/{repo}/releases/latest
      final uri = Uri.https(
        'api.github.com',
        '/repos/${AppConfig.githubRepoOwner}/${AppConfig.githubRepoName}/releases/latest',
      );

      final response = await http.get(uri);
      if (response.statusCode == 200) {
        final json = jsonDecode(response.body);
        return AppVersionInfo.fromGitHub(json);
      }
      debugPrint('GitHub API Error: ${response.statusCode}');
      return null;
    } catch (e) {
      debugPrint('Failed to fetch GitHub release: $e');
      return null;
    }
  }

  bool _isNewerVersion(String serverVersion, String currentVersion) {
    try {
      final sParts = serverVersion.split('.').map(int.parse).toList();
      final cParts = currentVersion.split('.').map(int.parse).toList();
      while (sParts.length < 3) sParts.add(0);
      while (cParts.length < 3) cParts.add(0);
      for (int i = 0; i < 3; i++) {
        if (sParts[i] > cParts[i]) return true;
        if (sParts[i] < cParts[i]) return false;
      }
      return false;
    } catch (e) {
      return false;
    }
  }

  void _showBeautifulUpdateDialog(
    BuildContext context,
    AppVersionInfo info,
    String currentVer,
  ) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
        child: Dialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          elevation: 16,
          backgroundColor: Colors.transparent, // Glass effect base
          child: Container(
            decoration: BoxDecoration(
              color: Theme.of(context).scaffoldBackgroundColor.withValues(alpha: 0.9),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.2),
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.2),
                  blurRadius: 20,
                  spreadRadius: 5,
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Header Image / Icon
                Container(
                  height: 120,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [Colors.purple.shade900, Colors.deepPurple],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(24),
                    ),
                  ),
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(
                          Icons.rocket_launch,
                          size: 48,
                          color: Colors.white,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'New Version Available!',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.95),
                            fontWeight: FontWeight.bold,
                            fontSize: 18,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          _buildVersionBadge(
                            context,
                            'Current',
                            currentVer,
                            Colors.grey,
                          ),
                          const Icon(
                            Icons.arrow_forward_rounded,
                            color: Colors.grey,
                          ),
                          _buildVersionBadge(
                            context,
                            'New',
                            info.version,
                            Colors.green,
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      const Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'What\'s New',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        height: 100,
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.grey.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: SingleChildScrollView(
                          child: Text(info.changelog),
                        ),
                      ),
                      const SizedBox(height: 24),
                      Row(
                        children: [
                          Expanded(
                            child: TextButton(
                              onPressed: () => Navigator.pop(ctx),
                              child: const Text('Maybe Later'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: () {
                                Navigator.pop(ctx);
                                _startUpdate(
                                  context,
                                  info.downloadUrl,
                                  info.version,
                                );
                              },
                              style: FilledButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 12,
                                ),
                              ),
                              icon: const Icon(Icons.system_update_alt),
                              label: const Text('Update Now'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildVersionBadge(
    BuildContext context,
    String label,
    String version,
    Color color,
  ) {
    return Column(
      children: [
        Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: color.withValues(alpha: 0.5)),
          ),
          child: Text(
            'v$version',
            style: TextStyle(fontWeight: FontWeight.bold, color: color),
          ),
        ),
      ],
    );
  }

  Future<void> _startUpdate(
    BuildContext context,
    String url,
    String version,
  ) async {
    try {
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/MediaTube-v$version.apk';
      if (await File(path).exists()) await File(path).delete();

      if (!context.mounted) return;
      _cancelToken = CancelToken();

      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => _DownloadProgressDialog(
          downloadUrl: url,
          apkPath: path,
          dio: _dio,
          cancelToken: _cancelToken!,
          onComplete: () {
            Navigator.pop(ctx);
            OpenFilex.open(path);
          },
          onError: (msg) {
            Navigator.pop(ctx);
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(msg)));
          },
          onCancel: () => Navigator.pop(ctx),
        ),
      );
    } catch (e) {
      debugPrint('Update Error: $e');
    }
  }
}

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
  String _status = 'Starting...';

  @override
  void initState() {
    super.initState();
    _start();
  }

  void _start() async {
    try {
      await widget.dio.download(
        widget.downloadUrl,
        widget.apkPath,
        cancelToken: widget.cancelToken,
        onReceiveProgress: (rec, total) {
          if (total != -1 && mounted) {
            setState(() {
              _progress = rec / total;
              _status =
                  '${(rec / 1024 / 1024).toStringAsFixed(1)}MB / ${(total / 1024 / 1024).toStringAsFixed(1)}MB';
            });
          }
        },
      );
      if (mounted) {
        setState(() => _status = 'Installing...');
      }
      await Future.delayed(const Duration(milliseconds: 500));
      widget.onComplete();
    } catch (e) {
      if (!CancelToken.isCancel(e as DioException)) {
        widget.onError(e.toString());
      } else {
        widget.onCancel();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Downloading Update'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          LinearProgressIndicator(value: _progress),
          const SizedBox(height: 16),
          Text(_status),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => widget.cancelToken.cancel(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
