package com.example.media_tube

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var nativeDownloader: NativeDownloader? = null
    private var youtubeExtractor: YoutubeExtractor? = null
    private var androidMuxer: AndroidMuxer? = null
    
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        nativeDownloader = NativeDownloader(this, flutterEngine)
        youtubeExtractor = YoutubeExtractor(this, flutterEngine)
        androidMuxer = AndroidMuxer(flutterEngine)
        
        // App Channel
        io.flutter.plugin.common.MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.rajesh.mediatube/app")
            .setMethodCallHandler { call, result ->
                if (call.method == "moveToBackground") {
                    val success = moveTaskToBack(true)
                    result.success(success)
                } else {
                    result.notImplemented()
                }
            }

        // Security Channel
        io.flutter.plugin.common.MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.rajesh.mediatube/security")
            .setMethodCallHandler { call, result ->
                if (call.method == "getAppSignature") {
                    try {
                        val signature = getAppSignature()
                        result.success(signature)
                    } catch (e: Exception) {
                        result.error("SIGNATURE_ERROR", e.message, null)
                    }
                } else {
                    result.notImplemented()
                }
            }
    }
    
    private fun getAppSignature(): String {
        try {
            val packageInfo = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.P) {
                packageManager.getPackageInfo(packageName, android.content.pm.PackageManager.GET_SIGNING_CERTIFICATES)
            } else {
                @Suppress("DEPRECATION")
                packageManager.getPackageInfo(packageName, android.content.pm.PackageManager.GET_SIGNATURES)
            }

            val signatures = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.P) {
                packageInfo.signingInfo?.apkContentsSigners
            } else {
                @Suppress("DEPRECATION")
                packageInfo.signatures
            }

            if (signatures == null || signatures.isEmpty()) return ""

            // Get SHA-256 of the first signature
            val md = java.security.MessageDigest.getInstance("SHA-256")
            val digest = md.digest(signatures[0].toByteArray())
            return digest.joinToString("") { "%02x".format(it) }
        } catch (e: Exception) {
            e.printStackTrace()
            return ""
        }
    }
    
    override fun getBackgroundMode(): io.flutter.embedding.android.FlutterActivityLaunchConfigs.BackgroundMode {
        return io.flutter.embedding.android.FlutterActivityLaunchConfigs.BackgroundMode.transparent
    }

    override fun onDestroy() {
        nativeDownloader?.dispose()
        youtubeExtractor?.dispose()
        super.onDestroy()
    }
}
