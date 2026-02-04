package com.example.media_tube

import android.app.DownloadManager
import android.content.Context
import android.net.Uri
import android.os.Environment
import io.flutter.plugin.common.MethodChannel
import java.io.File

class DownloadHelper(private val context: Context) {
    
    fun downloadFile(
        url: String,
        fileName: String,
        title: String,
        result: MethodChannel.Result
    ) {
        try {
            val downloadManager = context.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
            
            val request = DownloadManager.Request(Uri.parse(url)).apply {
                setTitle(title)
                setDescription("Downloading video...")
                setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
                setDestinationInExternalPublicDir(
                    Environment.DIRECTORY_DOWNLOADS,
                    "MediaTube/$fileName"
                )
                setAllowedOverMetered(true)
                setAllowedOverRoaming(true)
                
                // Add browser headers to avoid blocking
                addRequestHeader("User-Agent", "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36")
                addRequestHeader("Accept", "*/*")
                addRequestHeader("Accept-Language", "en-US,en;q=0.9")
                addRequestHeader("Referer", "https://www.youtube.com/")
                addRequestHeader("Origin", "https://www.youtube.com")
            }
            
            val downloadId = downloadManager.enqueue(request)
            result.success(mapOf(
                "success" to true,
                "downloadId" to downloadId,
                "path" to "${Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)}/MediaTube/$fileName"
            ))
        } catch (e: Exception) {
            result.success(mapOf(
                "success" to false,
                "error" to e.message
            ))
        }
    }
}
