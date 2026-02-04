package com.example.media_tube

import android.app.DownloadManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.webkit.CookieManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class NativeDownloader(private val context: Context, flutterEngine: FlutterEngine) {
    private val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "native_downloader")
    private val downloadManager = context.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
    private val activeDownloads = mutableMapOf<Long, DownloadInfo>()
    
    data class DownloadInfo(
        val taskId: String,
        val fileName: String,
        val savePath: String
    )
    
    private val downloadReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            val downloadId = intent?.getLongExtra(DownloadManager.EXTRA_DOWNLOAD_ID, -1) ?: return
            val info = activeDownloads[downloadId] ?: return
            
            val query = DownloadManager.Query().setFilterById(downloadId)
            val cursor = downloadManager.query(query)
            
            if (cursor.moveToFirst()) {
                val status = cursor.getInt(cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS))
                
                when (status) {
                    DownloadManager.STATUS_SUCCESSFUL -> {
                        channel.invokeMethod("onDownloadComplete", mapOf(
                            "taskId" to info.taskId,
                            "savePath" to info.savePath,
                            "success" to true
                        ))
                    }
                    DownloadManager.STATUS_FAILED -> {
                        val reason = cursor.getInt(cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_REASON))
                        channel.invokeMethod("onDownloadComplete", mapOf(
                            "taskId" to info.taskId,
                            "success" to false,
                            "error" to "Download failed with reason: $reason"
                        ))
                    }
                }
                activeDownloads.remove(downloadId)
            }
            cursor.close()
        }
    }
    
    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "downloadWithCookies" -> {
                    val url = call.argument<String>("url") ?: ""
                    val fileName = call.argument<String>("fileName") ?: "download"
                    val taskId = call.argument<String>("taskId") ?: ""
                    val cookies = call.argument<String>("cookies")
                    
                    try {
                        val downloadId = startDownload(url, fileName, taskId, cookies)
                        result.success(downloadId)
                    } catch (e: Exception) {
                        result.error("DOWNLOAD_ERROR", e.message, null)
                    }
                }
                "cancelDownload" -> {
                    val downloadId = call.argument<Long>("downloadId") ?: 0L
                    downloadManager.remove(downloadId)
                    activeDownloads.remove(downloadId)
                    result.success(true)
                }
                "getDownloadProgress" -> {
                    val downloadId = call.argument<Long>("downloadId") ?: 0L
                    val progress = getProgress(downloadId)
                    result.success(progress)
                }
                else -> result.notImplemented()
            }
        }
        
        // Register broadcast receiver for download completion
        val filter = IntentFilter(DownloadManager.ACTION_DOWNLOAD_COMPLETE)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(downloadReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            context.registerReceiver(downloadReceiver, filter)
        }
    }
    
    private fun startDownload(url: String, fileName: String, taskId: String, cookies: String?): Long {
        val downloadDir = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), "MediaTube")
        if (!downloadDir.exists()) {
            downloadDir.mkdirs()
        }
        
        val destinationFile = File(downloadDir, fileName)
        val savePath = destinationFile.absolutePath
        
        val request = DownloadManager.Request(Uri.parse(url)).apply {
            setTitle(fileName)
            setDescription("Downloading via MediaTube")
            setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
            setDestinationUri(Uri.fromFile(destinationFile))
            
            // Add headers that YouTube expects
            addRequestHeader("User-Agent", "Mozilla/5.0 (Linux; Android 10; SM-G975F) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36")
            addRequestHeader("Accept", "*/*")
            addRequestHeader("Accept-Language", "en-US,en;q=0.9")
            addRequestHeader("Origin", "https://www.youtube.com")
            addRequestHeader("Referer", "https://www.youtube.com/")
            
            // Add cookies from WebView if available
            val webViewCookies = cookies ?: CookieManager.getInstance().getCookie(url)
            if (!webViewCookies.isNullOrEmpty()) {
                addRequestHeader("Cookie", webViewCookies)
            }
            
            setAllowedOverMetered(true)
            setAllowedOverRoaming(true)
        }
        
        val downloadId = downloadManager.enqueue(request)
        activeDownloads[downloadId] = DownloadInfo(taskId, fileName, savePath)
        
        return downloadId
    }
    
    private fun getProgress(downloadId: Long): Map<String, Any> {
        val query = DownloadManager.Query().setFilterById(downloadId)
        val cursor = downloadManager.query(query)
        
        return if (cursor.moveToFirst()) {
            val bytesDownloaded = cursor.getLong(cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR))
            val bytesTotal = cursor.getLong(cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_TOTAL_SIZE_BYTES))
            val status = cursor.getInt(cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS))
            cursor.close()
            
            mapOf(
                "bytesDownloaded" to bytesDownloaded,
                "bytesTotal" to bytesTotal,
                "status" to status,
                "progress" to if (bytesTotal > 0) bytesDownloaded.toDouble() / bytesTotal else 0.0
            )
        } else {
            cursor.close()
            mapOf("status" to -1)
        }
    }
    
    fun dispose() {
        try {
            context.unregisterReceiver(downloadReceiver)
        } catch (e: Exception) {
            // Receiver might not be registered
        }
    }
}
