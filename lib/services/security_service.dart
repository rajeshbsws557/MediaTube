import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../config/app_config.dart';

/// Service to handle app security and anti-clone protection
class SecurityService {
  static const MethodChannel _platform = MethodChannel(
    'com.rajesh.mediatube/security',
  );

  static final SecurityService _instance = SecurityService._internal();
  factory SecurityService() => _instance;
  SecurityService._internal();

  /// Verify app integrity (package name and signature)
  /// Returns true if secure, false if compromised
  Future<bool> verifyIntegrity(BuildContext context) async {
    try {
      // 1. Verify Package Name
      final packageInfo = await PackageInfo.fromPlatform();
      if (packageInfo.packageName != AppConfig.expectedPackageName) {
        debugPrint('❌ Security Alert: Package name mismatch!');
        debugPrint('Expected: ${AppConfig.expectedPackageName}');
        debugPrint('Actual: ${packageInfo.packageName}');
        _showCompromisedDialog(context, 'Invalid Package ID');
        return false;
      }

      // 2. Verify APK Signature (Android only)
      try {
        final String signature = await _platform.invokeMethod(
          'getAppSignature',
        );

        debugPrint('🔐 App Signature SHA-256: $signature');

        // If config hash is empty, just log it (first run/dev mode)
        if (AppConfig.expectedSignatureHash.isEmpty) {
          debugPrint(
            '⚠️ Security Warning: No expected signature hash configured.',
          );
          debugPrint(
            '👉 Copy the hash above to AppConfig.expectedSignatureHash',
          );
          return true; // Use lenient mode for dev
        }

        if (signature.toLowerCase() !=
            AppConfig.expectedSignatureHash.toLowerCase()) {
          debugPrint('❌ Security Alert: Signature mismatch!');
          _showCompromisedDialog(
            context,
            'Invalid Signature or Cloned APK',
            signature,
            AppConfig.expectedSignatureHash,
          );
          return false;
        }

        debugPrint('✅ Integrity check passed');
        return true;
      } on PlatformException catch (e) {
        debugPrint('⚠️ Failed to get signature: ${e.message}');
        // On non-Android or error, failing open for now to avoid locking legitimate users if API fails
        return true;
      }
    } catch (e) {
      debugPrint('❌ Security check failed: $e');
      return true; // Fail open to avoid crashes
    }
  }

  void _showCompromisedDialog(
    BuildContext context,
    String reason, [
    String? actual,
    String? expected,
  ]) {
    if (!context.mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.security, color: Colors.red),
            SizedBox(width: 8),
            Text('Security Alert'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'This application appears to be modified or unofficial.',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text('Reason: $reason'),
            if (actual != null) ...[
              const SizedBox(height: 16),
              const Text(
                'Debugging Info (Dev Only):',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
              ),
              SelectableText(
                'Actual: $actual',
                style: const TextStyle(fontSize: 10, fontFamily: 'monospace'),
              ),
              if (expected != null)
                SelectableText(
                  'Expected: $expected',
                  style: const TextStyle(fontSize: 10, fontFamily: 'monospace'),
                ),
            ],
            const SizedBox(height: 16),
            const Text(
              'Please uninstall this version and download the official app from GitHub.',
            ),
          ],
        ),
        actions: [
          // No buttons to dismiss - lock the app
          // But providing one to exit for UX niceness (or could forcibly exit)
          FilledButton(
            onPressed: () {
              SystemNavigator.pop(); // Exit app
            },
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Exit App'),
          ),
        ],
      ),
    );
  }
}
